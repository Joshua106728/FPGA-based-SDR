"""
fpga_pipeline_sim.py
====================
Simulates the full FPGA DSP pipeline in fixed-point integer math,
matching the SystemVerilog modules as closely as possible, then plays
the recovered audio.

Pipeline (matches top.sv exactly):
  CSV (uint8 I/Q) → dc_offset → lpf_wrapper → fm_demodulate
                  → decimation → de_emphasis → play audio

Per-stage CSVs are written alongside the input file for direct
comparison against the fm_receiver.py prototype stage outputs:
  <stem>_sim_stage1_dc_removed.csv   — integer I/Q  (Q7.10, 18-bit)
  <stem>_sim_stage2_lpf.csv          — integer I/Q  (18-bit, truncated to 16-bit for FM)
  <stem>_sim_stage3_demod.csv        — integer mono (16-bit, full SDR rate)
  <stem>_sim_stage4_decimated.csv    — integer mono (16-bit, audio rate)
  <stem>_sim_stage5_deemphasis.csv   — integer mono (18-bit, final output)

Usage:
    python fpga_pipeline_sim.py ../IQ_Samples/song_stage0_raw_iq.csv
    python fpga_pipeline_sim.py ../IQ_Samples/song_stage0_raw_iq.csv --no-play
"""

import argparse
import os

import numpy as np
import pandas as pd
from scipy.signal import firwin, lfilter
import sounddevice as sd
import soundfile as sf
import matplotlib.pyplot as plt

# ============================================================
# Constants — must match types.sv and module parameters
# ============================================================
SAMPLE_DW         = 8           # rf_cdc output width (uint8)
DATA_DW           = 18          # internal FPGA fixed-point width
FRACTIONAL_BITS   = 10          # Q7.10 from dc_offset
RUNNING_SUM_ALPHA = 11          # dc_offset exponential decay shift

SDR_SAMPLE_RATE   = 250_000     # Hz — sample rate at LPF / FM demod input
DECIM_FACTOR      = 6           # 250000 / 6 = 41666.67 Hz audio rate
AUDIO_SAMPLE_RATE = SDR_SAMPLE_RATE // DECIM_FACTOR  # 41666.67 Hz

MAX_FREQ_DEV = 75_000           # standard FM peak deviation (Hz)

# de_emphasis.sv Q0.16 coefficients (tau=75us, fs=36750 Hz)
# These must match de_emphasis.sv — localparam values
# ALPHA_FP        = 65518         # round(exp(-1/(75e-6 * 36750)) * 65536)
# ONE_MINUS_ALPHA = 65536 - ALPHA_FP  # 18

ALPHA_FP        = 47589
ONE_MINUS_ALPHA = 17947   # 47589 + 17947 = 65536

PCM_IN_W = 18                   # final output width (i2s_if sample_q18)
PCM_W = 16

# ============================================================
# Stage CSV saver — integer format for HDL comparison
# ============================================================
def save_stage_csv(data: np.ndarray, path: str, label: str) -> None:
    """Save a pipeline stage output as integer CSV for HDL comparison."""
    n = len(data)
    idx = np.arange(n, dtype=np.int32)
    if data.ndim == 2:
        rows = np.column_stack([idx, data])
        cols = ",".join(f"col{i}" for i in range(data.shape[1]))
        header = f"Sample_Index,{cols}"
    else:
        rows = np.column_stack([idx, data])
        header = "Sample_Index,Value"
    np.savetxt(path, rows, fmt="%d", delimiter=",", header=header, comments="")
    size_kb = os.path.getsize(path) / 1e3
    print(f"[Stage CSV] {label}: {n:,} samples → '{path}' ({size_kb:.0f} KB)")


# ============================================================
# Stage 1: Load CSV
# Accepts any CSV with Sample_Index, I, Q columns (uint8 values).
# ============================================================
def load_csv(paths: list[str]) -> tuple[np.ndarray, np.ndarray]:
    all_i, all_q = [], []
    for path in paths:
        df = pd.read_csv(path, skipinitialspace=True)
        all_i.append(df['I'].to_numpy(dtype=np.uint8))
        all_q.append(df['Q'].to_numpy(dtype=np.uint8))
        print(f"[Load] {path}: {len(df):,} samples")
    i = np.concatenate(all_i)
    q = np.concatenate(all_q)
    print(f"[Load] Total: {len(i):,} samples")
    return i, q


# ============================================================
# Stage 2: DC Offset removal — matches dc_offset.sv exactly
#
# Conversion: flip MSB to go unsigned→sign-magnitude, then
# shift left by FRACTIONAL_BITS to get Q7.10 (18-bit signed).
# SV line: {~sample_i[MSB], sample_i[6:0], {FRACTIONAL_BITS{0}}}
#
# Running mean uses RUNNING_SUM_ALPHA=11 right-shift, with ±1
# nudge when the update would otherwise be zero.
#
# Key: correction uses next_mean (updated mean), not old mean.
# ============================================================
def dc_offset(sample_i: np.ndarray, sample_q: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    print("[DC Offset] Removing DC bias...")
    n = len(sample_i)

    def to_q7_10(x: np.ndarray) -> np.ndarray:
        flipped = x.astype(np.int32) ^ 0x80
        signed  = np.where(flipped >= 128, flipped - 256, flipped)
        return (signed << FRACTIONAL_BITS).astype(np.int32)

    si = to_q7_10(sample_i)
    sq = to_q7_10(sample_q)

    corr_i = np.zeros(n, dtype=np.int32)
    corr_q = np.zeros(n, dtype=np.int32)
    mean_i = np.int32(0)
    mean_q = np.int32(0)

    for k in range(n):
        diff_i = np.int32(si[k]) - mean_i
        diff_q = np.int32(sq[k]) - mean_q

        upd_i = diff_i >> RUNNING_SUM_ALPHA
        upd_q = diff_q >> RUNNING_SUM_ALPHA

        if   upd_i == 0 and diff_i > 0: upd_i = np.int32(1)
        elif upd_i == 0 and diff_i < 0: upd_i = np.int32(-1)
        if   upd_q == 0 and diff_q > 0: upd_q = np.int32(1)
        elif upd_q == 0 and diff_q < 0: upd_q = np.int32(-1)

        mean_i += upd_i
        mean_q += upd_q
        corr_i[k] = si[k] - mean_i
        corr_q[k] = sq[k] - mean_q

    print(f"[DC Offset] Done. Final mean_i={mean_i}, mean_q={mean_q}")
    return corr_i, corr_q


# ============================================================
# Stage 3: Low Pass Filter — approximates lpf_wrapper.sv
# (Xilinx FIR Compiler IP with coefficients from lpf_coeffs.coe)
# Cutoff 90 kHz at 220500 Hz sample rate, 64-tap Hamming window.
# Result truncated to int32 to stay in fixed-point world.
# ============================================================
def low_pass_filter(corr_i: np.ndarray, corr_q: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    print("[LPF] Applying low-pass filter (cutoff=90 kHz)...")
    nyquist     = SDR_SAMPLE_RATE / 2.0
    cutoff_norm = 90_000 / nyquist
    taps = firwin(64, cutoff_norm, window="hamming")
    lpf_i = lfilter(taps, 1.0, corr_i.astype(np.float64)).astype(np.int32)
    lpf_q = lfilter(taps, 1.0, corr_q.astype(np.float64)).astype(np.int32)
    print("[LPF] Done.")
    return lpf_i, lpf_q


# ============================================================
# Stage 4: FM Demodulate — IQ discriminator (matches fm_receiver.py)
#
#   dI = I[n] - I[n-1],  dQ = Q[n] - Q[n-1]
#   num = I*dQ - Q*dI
#   den = I^2 + Q^2   (clamped to avoid divide-by-zero)
#   audio = (num / den) * (SDR_RATE / (2*pi*MAX_DEV))
#
# Operates on the int32 LPF output at full SDR rate.
# Division uses float64 for precision; result clipped to 16-bit signed.
# ============================================================
def fm_demodulate(lpf_i: np.ndarray, lpf_q: np.ndarray) -> np.ndarray:
    print("[FM Demod] Running IQ discriminator (SDR rate)...")
    i = lpf_i.astype(np.int64)
    q = lpf_q.astype(np.int64)

    di = np.diff(i, prepend=i[0])
    dq = np.diff(q, prepend=q[0])

    num = i * dq - q * di
    den = i * i + q * q
    den = np.where(den < 16, 16, den)

    # Scale to fill int16 range: equivalent to SV's K = round(32767 * SDR_RATE / (2π * MAX_DEV))
    scale = 32767.0 * SDR_SAMPLE_RATE / (2 * np.pi * MAX_FREQ_DEV)
    audio = np.clip((num / den.astype(np.float64)) * scale, -32768, 32767).astype(np.int16)

    print(f"[FM Demod] Done. Peak: {np.max(np.abs(audio))}")
    return audio


# ============================================================
# Stage 5: Decimation — keep every DECIM_FACTOR-th sample
# Matches the concept in decimation.sv (mod-N counter, keep at count=0).
# ============================================================
def decimation(demod_audio: np.ndarray) -> np.ndarray:
    print(f"[Decimation] {SDR_SAMPLE_RATE} → {AUDIO_SAMPLE_RATE} Hz "
          f"(factor {DECIM_FACTOR})...")
    out = demod_audio[::DECIM_FACTOR]
    print(f"[Decimation] Done. {len(out):,} samples remaining.")
    return out


# ============================================================
# Stage 6: De-emphasis — matches de_emphasis.sv exactly
#
# First-order IIR in Q0.16 fixed point:
#   acc    = ALPHA_FP * y[n-1] + ONE_MINUS_ALPHA * x[n]
#   y[n]   = acc[31:16]   (drop lower 16 bits = >>16)
# Output sign-extended to PCM_IN_W (18-bit).
# ============================================================
def de_emphasis(audio: np.ndarray) -> np.ndarray:
    print("[De-emphasis] Applying 75 µs IIR filter...")
    n = len(audio)
    y_prev = np.int32(0)
    out    = np.zeros(n, dtype=np.int32)

    for k in range(n):
        x     = np.int32(audio[k])
        acc   = np.int64(ALPHA_FP) * np.int64(y_prev) + np.int64(ONE_MINUS_ALPHA) * np.int64(x)
        y_curr = np.int32(acc >> 16)
        out[k] = y_curr
        y_prev = y_curr

    max_18 =  (1 << (PCM_IN_W - 1)) - 1   #  131071
    min_18 = -(1 << (PCM_IN_W - 1))        # -131072
    out = np.clip(out, min_18, max_18)
    print("[De-emphasis] Done.")
    return out

# ============================================================
# Audio Playback Helpers
# ============================================================
def play_audio_scaled(audio: np.ndarray, fs: int) -> None:
    """
    Playback with normalization/scaling (current behavior).
    """
    peak = np.max(np.abs(audio))

    if peak == 0:
        print("[Play Scaled] Audio is silent.")
        return

    norm = (audio / peak * 0.9).astype(np.float32)

    print(f"[Play Scaled] {len(norm)/fs:.2f}s @ {fs} Hz...")
    try:
        sd.play(norm, samplerate=fs)
        sd.wait()
    except Exception as e:
        print(f"[Play Scaled] Skipped: {e}")


def play_audio_raw(audio: np.ndarray, fs: int) -> None:
    """
    Playback with NO scaling or normalization.
    Sends raw float32 values directly to the audio device.
    """
    raw = audio.astype(np.float32)

    print(f"[Play Raw] {len(raw)/fs:.2f}s @ {fs} Hz...")
    print(f"[Play Raw] Peak sample value = {np.max(np.abs(raw))}")

    try:
        sd.play(raw, samplerate=fs)
        sd.wait()
    except Exception as e:
        print(f"[Play Raw] Skipped: {e}")


# ============================================================
# WAV Save Helpers
# ============================================================
def save_wav_scaled(audio: np.ndarray, fs: int, path: str) -> None:
    """
    Save normalized/scaled WAV.
    """
    peak = np.max(np.abs(audio))

    if peak > 0:
        out = (audio / peak * 0.9).astype(np.float32)
    else:
        out = audio.astype(np.float32)

    sf.write(path, out, fs)
    print(f"[WAV] Saved scaled WAV → '{path}'")


def save_wav_raw(audio: np.ndarray, fs: int, path: str) -> None:
    """
    Save raw WAV with absolutely no scaling.
    """
    out = audio.astype(np.float32)

    sf.write(path, out, fs)
    print(f"[WAV] Saved raw WAV → '{path}'")

# ============================================================
# Main
# ============================================================
def main():
    parser = argparse.ArgumentParser(
        description="FPGA Pipeline Simulation — feed song_stage0_raw_iq.csv to compare with RTL."
    )
    parser.add_argument("csv", nargs="+",
                        help="One or more CSVs with Sample_Index,I,Q columns (uint8 values).")
    parser.add_argument("--no-play",  action="store_true", help="Skip audio playback.")
    args = parser.parse_args()

    print("=" * 55)
    print("  FPGA Pipeline Simulation")
    print("=" * 55)

    out_dir = os.path.dirname(os.path.abspath(args.csv[0]))

    # Stage 1: Load
    raw_i, raw_q = load_csv(args.csv)

    # Stage 2: DC offset removal
    corr_i, corr_q = dc_offset(raw_i, raw_q)
    save_stage_csv(np.column_stack([corr_i, corr_q]),
                   os.path.join(out_dir, "fpga_stage1_dc_removed.csv"), "DC removed (I,Q)")

    # Stage 3: LPF
    lpf_i, lpf_q = low_pass_filter(corr_i, corr_q)
    save_stage_csv(np.column_stack([lpf_i, lpf_q]),
                   os.path.join(out_dir, "fpga_stage2_lpf.csv"), "LPF output (I,Q)")

    # Stage 4: FM Demodulate
    demod = fm_demodulate(lpf_i, lpf_q)
    save_stage_csv(demod, os.path.join(out_dir, "fpga_stage3_demod.csv"),
                   "FM demod (mono, SDR rate)")

    # Stage 5: Decimation (220500 → 36750 Hz)
    decim = decimation(demod)
    save_stage_csv(decim, os.path.join(out_dir, "fpga_stage4_decimated.csv"),
                   "Decimated audio")

    # Stage 6: De-emphasis
    deemph = de_emphasis(decim)
    save_stage_csv(deemph, os.path.join(out_dir, "fpga_stage5_deemphasis.csv"),
                   "De-emphasis output")

    # ============================================================
    # Save BOTH WAV versions
    # ============================================================
    scaled_wav = os.path.join(out_dir, "fpga_pipeline_output_scaled.wav")
    raw_wav    = os.path.join(out_dir, "fpga_pipeline_output_raw.wav")

    save_wav_scaled(deemph, AUDIO_SAMPLE_RATE, scaled_wav)
    save_wav_raw(deemph, AUDIO_SAMPLE_RATE, raw_wav)

    # ============================================================
    # Playback BOTH versions
    # ============================================================
    if not args.no_play:

        print("\n--- Playing SCALED version ---")
        play_audio_scaled(deemph, AUDIO_SAMPLE_RATE)

        print("\n--- Playing RAW version ---")
        play_audio_raw(deemph, AUDIO_SAMPLE_RATE)

        print("=" * 55)
        print("  Pipeline complete.")
        print("=" * 55)


if __name__ == "__main__":
    main()
