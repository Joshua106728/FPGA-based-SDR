"""
fpga_pipeline_sim.py
====================
Simulates the full FPGA DSP pipeline with exact fixed-point integer math,
matching the SystemVerilog modules in top.sv exactly.

Input modes:
  - WAV file: FM-modulates the audio → uint8 I/Q at 220500 Hz → DSP pipeline
  - CSV file: loads uint8 I/Q directly (Sample_Index, I, Q columns)

Pipeline (matches top.sv exactly):
  input → dc_offset → lpf_wrapper → fm_demodulate
        → decimation → de_emphasis → i2s_truncate → audio

Audio output is unscaled (raw 16-bit PCM, exactly as the FPGA produces).

Usage:
    python fpga_pipeline_sim.py song.wav
    python fpga_pipeline_sim.py song_stage0_raw_iq.csv
    python fpga_pipeline_sim.py song.wav --no-play
"""

import argparse
import os
from math import gcd

import numpy as np
import pandas as pd
from scipy.signal import firwin, lfilter, resample_poly
import sounddevice as sd
import soundfile as sf
import matplotlib.pyplot as plt

# ============================================================
# Constants — must match types.sv and module parameters exactly
# ============================================================
SAMPLE_DW         = 8
DATA_DW           = 18
FRACTIONAL_BITS   = 10
RUNNING_SUM_ALPHA = 11

SDR_SAMPLE_RATE   = 250_000
DECIM_FACTOR      = 6
AUDIO_SAMPLE_RATE = SDR_SAMPLE_RATE // DECIM_FACTOR   # 41666 Hz

MAX_FREQ_DEV = 75_000

# de_emphasis.sv localparams — MUST match hardware exactly
# tau=75us, fs=41667 Hz (250kHz/6): a = round(exp(-1/(75e-6*41667)) * 65536)
ALPHA_FP        = 47589
ONE_MINUS_ALPHA = 17947   # 47589 + 17947 = 65536

# fm_demodulate.sv: SCALE_OUT = 18'b00_0011_1010_1001_1000 = 15000
SCALE_OUT = 15000

PCM_IN_W = 18   # de_emphasis output width (DATA_DW)
PCM_W    = 16   # i2s_master_tx output width


# ============================================================
# Stage 0a: WAV → FM modulate → uint8 I/Q
# Matches fm_sdr_prototype.py transmitter exactly.
# ============================================================
def wav_to_iq(wav_path: str) -> tuple[np.ndarray, np.ndarray]:
    print(f"[WAV->IQ] Loading '{wav_path}'...")
    audio, fs = sf.read(wav_path)
    if audio.ndim > 1:
        audio = audio[:, 0]
    audio = audio.astype(np.float64)

    g = gcd(SDR_SAMPLE_RATE, int(fs))
    audio_up = resample_poly(audio, SDR_SAMPLE_RATE // g, int(fs) // g)

    peak = np.max(np.abs(audio_up)) + 1e-9
    audio_scaled = audio_up / peak * 0.35

    phase = 2 * np.pi * MAX_FREQ_DEV * np.cumsum(audio_scaled) / SDR_SAMPLE_RATE
    iq = np.exp(1j * phase)

    i_u8 = np.clip(np.round(iq.real * 128 + 128), 0, 255).astype(np.uint8)
    q_u8 = np.clip(np.round(iq.imag * 128 + 128), 0, 255).astype(np.uint8)

    print(f"[WAV->IQ] {len(i_u8):,} samples at {SDR_SAMPLE_RATE} Hz")
    return i_u8, q_u8


# ============================================================
# Stage 0b: Load CSV → uint8 I/Q
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
# Stage 2: DC Offset — matches dc_offset.sv exactly
#
# Converts uint8 → Q7.10 (18-bit signed) by flipping MSB then
# shifting left by FRACTIONAL_BITS. Running mean uses an
# exponential decay right-shift with ±1 nudge when update=0.
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

        mean_i = np.int32(mean_i + upd_i)
        mean_q = np.int32(mean_q + upd_q)
        corr_i[k] = si[k] - mean_i
        corr_q[k] = sq[k] - mean_q

    print(f"[DC Offset] Done. Final mean_i={mean_i}, mean_q={mean_q}")
    return corr_i, corr_q


# ============================================================
# Stage 3: LPF — approximates lpf_wrapper.sv
# 64-tap Hamming FIR, 90 kHz cutoff at 220500 Hz sample rate.
# ============================================================
def low_pass_filter(corr_i: np.ndarray, corr_q: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    print("[LPF] Applying 90 kHz low-pass filter...")
    nyquist     = SDR_SAMPLE_RATE / 2.0
    cutoff_norm = 90_000 / nyquist
    taps = firwin(64, cutoff_norm, window="hamming")
    lpf_i = lfilter(taps, 1.0, corr_i.astype(np.float64)).astype(np.int32)
    lpf_q = lfilter(taps, 1.0, corr_q.astype(np.float64)).astype(np.int32)
    print("[LPF] Done.")
    return lpf_i, lpf_q


# ============================================================
# Stage 4: FM Demodulate — matches fm_demodulate.sv exactly
#
# Fixed-point operations (all integers):
#   num_sub  = curr_q*prev_i - curr_i*prev_q   (37-bit)
#   num      = num_sub[36:5]                   (32-bit signed, >>5)
#   denom    = {2'b0, (I²+Q²+1)[36:15]}        (24-bit unsigned, >>15)
#   div      = truncate-toward-zero(num/denom)  (Xilinx divider)
#   scaled   = div * SCALE_OUT                  (50-bit)
#   output   = scaled[27:10]                   (18-bit signed)
# ============================================================
def fm_demodulate(lpf_i: np.ndarray, lpf_q: np.ndarray) -> np.ndarray:
    print("[FM Demod] Running IQ discriminator (exact fixed-point)...")
    n  = len(lpf_i)
    ci = lpf_i.astype(np.int64)
    cq = lpf_q.astype(np.int64)

    # Registered prev values (initialized to 0 on reset)
    pi = np.empty(n, dtype=np.int64); pi[0] = 0; pi[1:] = ci[:-1]
    pq = np.empty(n, dtype=np.int64); pq[0] = 0; pq[1:] = cq[:-1]

    # Numerator: num_sub[36:5] → 32-bit signed
    num_sub = cq * pi - ci * pq                        # 37-bit
    num     = (num_sub >> 5).astype(np.int32)           # [36:5]

    # Denominator: {2'b0, denom_add[36:15]} → 24-bit unsigned
    denom_add = ci * ci + cq * cq + 1                  # 37-bit, always ≥ 1
    denom     = (denom_add >> 15) & np.int64(0x3FFFFF) # [36:15] = 22 bits, top 2 zero
    denom     = np.where(denom == 0, np.int64(1), denom)

    # Integer division truncated toward zero (Xilinx divider behaviour)
    num64 = num.astype(np.int64)
    div_result = np.where(
        num64 >= 0,
        num64 // denom,
        -((-num64) // denom)
    ).astype(np.int32)

    # Scale: scaled_result[27:10] → 18-bit signed
    scaled = div_result.astype(np.int64) * np.int64(SCALE_OUT)
    raw18  = (scaled >> 10) & np.int64(0x3FFFF)        # 18 unsigned bits
    demod  = np.where(raw18 >= np.int64(1 << 17),
                      raw18.astype(np.int32) - (1 << 18),
                      raw18.astype(np.int32))

    print(f"[FM Demod] Done. Peak: {np.max(np.abs(demod))}")
    return demod


# ============================================================
# Stage 5: Decimation — matches decim.sv (keep every Nth sample)
# ============================================================
def decimation(demod: np.ndarray) -> np.ndarray:
    print(f"[Decimation] {SDR_SAMPLE_RATE} → {AUDIO_SAMPLE_RATE} Hz (factor {DECIM_FACTOR})...")
    out = demod[::DECIM_FACTOR]
    print(f"[Decimation] Done. {len(out):,} samples.")
    return out


# ============================================================
# Stage 6: De-emphasis — matches de_emphasis.sv exactly
#
# Q0.16 IIR: acc = ALPHA_FP*y[n-1] + ONE_MINUS_ALPHA*x[n]
#            y[n] = acc[33:16]   (18-bit signed)
# ALPHA_FP=47589, ONE_MINUS_ALPHA=17947 (tau=75us, fs=41667 Hz)
# ============================================================
def de_emphasis(audio: np.ndarray) -> np.ndarray:
    print("[De-emphasis] Applying 75 µs IIR filter...")
    n = len(audio)
    y_prev = np.int32(0)
    out    = np.zeros(n, dtype=np.int32)

    for k in range(n):
        x      = np.int32(audio[k])
        acc    = np.int64(ALPHA_FP) * np.int64(y_prev) + np.int64(ONE_MINUS_ALPHA) * np.int64(x)
        y_curr = np.int32(acc >> 16)   # acc[33:16]
        out[k] = y_curr
        y_prev = y_curr

    out = np.clip(out, -(1 << (PCM_IN_W - 1)), (1 << (PCM_IN_W - 1)) - 1)
    print("[De-emphasis] Done.")
    return out


# ============================================================
# Stage 7: I2S truncation — matches i2s_master_tx.sv
# audio_latch <= sample_q18[PCM_IN_W-1:2]  →  bits [17:2] = 16-bit
# ============================================================
def i2s_truncate(deemph: np.ndarray) -> np.ndarray:
    return (deemph.astype(np.int32) >> 2).astype(np.int16)


# ============================================================
# CSV saver
# ============================================================
def save_stage_csv(data: np.ndarray, path: str, label: str) -> None:
    n = len(data)
    idx = np.arange(n, dtype=np.int32)
    rows = np.column_stack([idx, data])
    if data.ndim == 2:
        cols = ",".join(f"col{i}" for i in range(data.shape[1]))
        header = f"Sample_Index,{cols}"
    else:
        header = "Sample_Index,Value"
    np.savetxt(path, rows, fmt="%d", delimiter=",", header=header, comments="")
    print(f"[CSV] {label}: {n:,} samples → '{os.path.basename(path)}'")


# ============================================================
# Audio playback — raw int16, no peak normalization
# ============================================================
def play_audio(audio: np.ndarray, fs: int) -> None:
    print(f"[Play] {len(audio)/fs:.2f}s @ {fs} Hz, peak={np.max(np.abs(audio))}")
    try:
        sd.play(audio, samplerate=fs)
        sd.wait()
    except Exception as e:
        print(f"[Play] Skipped: {e}")


# ============================================================
# Plot
# ============================================================
def plot_pipeline(raw_i, raw_q, corr_i, corr_q,
                  lpf_i, lpf_q, demod, decim, deemph, pcm16) -> None:
    fig, axes = plt.subplots(7, 1, figsize=(13, 18))
    fig.suptitle("FPGA Pipeline Simulation (exact fixed-point)", fontsize=13)

    n   = min(500, len(raw_i))
    nd  = min(500, len(demod))
    ndc = min(500, len(decim))
    na  = min(500, len(deemph))

    axes[0].plot(raw_i[:n], label="I", lw=0.8)
    axes[0].plot(raw_q[:n], label="Q", lw=0.8)
    axes[0].set_title("Stage 0 — Raw I/Q (uint8)"); axes[0].legend(); axes[0].grid(True)

    axes[1].plot(corr_i[:n], label="I", lw=0.8)
    axes[1].plot(corr_q[:n], label="Q", lw=0.8)
    axes[1].set_title("Stage 2 — DC Offset Removed (Q7.10, 18-bit)"); axes[1].legend(); axes[1].grid(True)

    axes[2].plot(lpf_i[:n], label="I", lw=0.8)
    axes[2].plot(lpf_q[:n], label="Q", lw=0.8)
    axes[2].set_title("Stage 3 — LPF output (18-bit)"); axes[2].legend(); axes[2].grid(True)

    axes[3].plot(demod[:nd], lw=0.8, color="purple")
    axes[3].set_title("Stage 4 — FM Demodulated (18-bit, SDR rate, exact fixed-point)"); axes[3].grid(True)

    axes[4].plot(decim[:ndc], lw=0.8, color="darkorange")
    axes[4].set_title(f"Stage 5 — Decimated ({AUDIO_SAMPLE_RATE} Hz, 18-bit)"); axes[4].grid(True)

    axes[5].plot(deemph[:na], lw=0.8, color="crimson")
    axes[5].set_title("Stage 6 — De-emphasis (18-bit, ALPHA=47589)"); axes[5].grid(True)

    axes[6].plot(pcm16[:na], lw=0.8, color="forestgreen")
    axes[6].set_title("Stage 7 — I2S PCM16 output (>>2, raw unscaled)"); axes[6].grid(True)

    plt.tight_layout()
    plt.savefig("fpga_pipeline_sim.png", dpi=150)
    print("[Plot] Saved → fpga_pipeline_sim.png")
    plt.show()


# ============================================================
# Main
# ============================================================
def main():
    parser = argparse.ArgumentParser(
        description="FPGA DSP pipeline simulation (exact fixed-point). "
                    "Input: WAV file (FM modulated) or CSV (Sample_Index,I,Q)."
    )
    parser.add_argument("input", nargs="+",
                        help="song.wav (FM modulate → IQ) or stage0_raw_iq.csv.")
    parser.add_argument("--no-play", action="store_true", help="Skip audio playback.")
    parser.add_argument("--no-plot", action="store_true", help="Skip plots.")
    args = parser.parse_args()

    print("=" * 55)
    print("  FPGA Pipeline Simulation (exact fixed-point)")
    print("=" * 55)

    out_dir = os.path.dirname(os.path.abspath(args.input[0]))
    stem    = os.path.splitext(os.path.basename(args.input[0]))[0]

    # Stage 0: get uint8 I/Q
    if args.input[0].lower().endswith(".wav"):
        print(f"[Input] WAV mode — FM modulating '{args.input[0]}'")
        raw_i, raw_q = wav_to_iq(args.input[0])
    else:
        raw_i, raw_q = load_csv(args.input)

    save_stage_csv(
        np.column_stack([raw_i.astype(np.int32), raw_q.astype(np.int32)]),
        os.path.join(out_dir, f"{stem}_fpga_stage0_iq.csv"), "Raw uint8 IQ")

    # Stage 2: DC offset
    corr_i, corr_q = dc_offset(raw_i, raw_q)
    save_stage_csv(np.column_stack([corr_i, corr_q]),
                   os.path.join(out_dir, f"{stem}_fpga_stage1_dc.csv"), "DC removed (I,Q)")

    # Stage 3: LPF
    lpf_i, lpf_q = low_pass_filter(corr_i, corr_q)
    save_stage_csv(np.column_stack([lpf_i, lpf_q]),
                   os.path.join(out_dir, f"{stem}_fpga_stage2_lpf.csv"), "LPF (I,Q)")

    # Stage 4: FM Demodulate
    demod = fm_demodulate(lpf_i, lpf_q)
    save_stage_csv(demod, os.path.join(out_dir, f"{stem}_fpga_stage3_demod.csv"), "FM demod")

    # Stage 5: Decimation
    decim = decimation(demod)
    save_stage_csv(decim, os.path.join(out_dir, f"{stem}_fpga_stage4_decimated.csv"), "Decimated")

    # Stage 6: De-emphasis
    deemph = de_emphasis(decim)
    save_stage_csv(deemph, os.path.join(out_dir, f"{stem}_fpga_stage5_deemphasis.csv"), "De-emphasis")

    # Stage 7: I2S truncation (18-bit → 16-bit, drop 2 LSBs)
    pcm16 = i2s_truncate(deemph)
    save_stage_csv(pcm16.astype(np.int32),
                   os.path.join(out_dir, f"{stem}_fpga_stage6_i2s.csv"), "I2S PCM16")

    # Save WAV — raw int16, no normalization
    wav_out = os.path.join(out_dir, f"{stem}_fpga_output.wav")
    sf.write(wav_out, pcm16, AUDIO_SAMPLE_RATE, subtype='PCM_16')
    print(f"[WAV] Saved (unscaled int16) → '{wav_out}'")

    # Golden reference files for RTL testbench
    np.savetxt(os.path.join(out_dir, "golden_output.txt"), deemph, fmt="%d")
    np.savetxt(os.path.join(out_dir, "golden_demod.txt"),  demod,  fmt="%d")
    print("[Golden] Saved golden_output.txt, golden_demod.txt")

    if not args.no_play:
        play_audio(pcm16, AUDIO_SAMPLE_RATE)

    if not args.no_plot:
        plot_pipeline(raw_i, raw_q, corr_i, corr_q,
                      lpf_i, lpf_q, demod, decim, deemph, pcm16)

    print("=" * 55)
    print("  Pipeline complete.")
    print("=" * 55)


if __name__ == "__main__":
    main()
