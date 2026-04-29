"""
fpga_pipeline_sim.py
====================
Simulates the full FPGA DSP pipeline in fixed-point integer math,
matching the SystemVerilog modules exactly, then plays the result
through your MacBook's speaker.

Pipeline:
  CSV (uint8 I/Q) → dc_offset → lpf → decimation → fm_demodulate
                  → de_emphasis → play audio

Usage:
    python fpga_pipeline_sim.py IQ_DATA_1000_1.csv
    python fpga_pipeline_sim.py IQ_DATA_1000_1.csv IQ_DATA_1000_2.csv ...
    python fpga_pipeline_sim.py IQ_DATA_1000_*.csv   (all at once)

Dependencies:
    python -m pip install numpy scipy sounddevice matplotlib pandas
"""

import argparse
import numpy as np
import pandas as pd
from scipy.signal import firwin, lfilter
import sounddevice as sd
import matplotlib.pyplot as plt
import sys

# ============================================================
# Constants — must match types.sv and your module parameters
# ============================================================
SAMPLE_DW         = 8          # rf_cdc output width (uint8)
DATA_DW           = 18         # internal FPGA fixed-point width
FRACTIONAL_BITS   = 10         # Q7.10 format from dc_offset
RUNNING_SUM_ALPHA = 11         # dc_offset exponential decay shift

SDR_SAMPLE_RATE   = 220_500    # Hz — LPF output rate
DECIM_FACTOR      = 6          # 220500 / 6 = 36750 Hz audio rate
AUDIO_SAMPLE_RATE = SDR_SAMPLE_RATE // DECIM_FACTOR  # 36750 Hz

MAX_FREQ_DEV      = 75_000     # Hz — FM deviation

# De-emphasis: alpha = exp(-1 / (75e-6 * 36750))
# Represented in Q0.16 fixed point
ALPHA_FP          = 65512      # round(0.999637 * 65536)
ONE_MINUS_ALPHA   = 65536 - ALPHA_FP  # 24

PCM_IN_W          = 18         # i2s_if sample_q18 width


# ============================================================
# Stage 1: Load CSV
# ============================================================
def load_csv(paths: list[str]) -> tuple[np.ndarray, np.ndarray]:
    """
    Load one or more CSV files and concatenate their I/Q columns.
    Matches rf_cdc output: unsigned 8-bit integers.
    """
    all_i, all_q = [], []
    for path in paths:
        df = pd.read_csv(path, skipinitialspace=True)
        all_i.append(df['I'].to_numpy(dtype=np.uint8))
        all_q.append(df['Q'].to_numpy(dtype=np.uint8))
        print(f"[Load] {path}: {len(df)} samples")
    i = np.concatenate(all_i)
    q = np.concatenate(all_q)
    print(f"[Load] Total: {len(i)} samples")
    return i, q


# ============================================================
# Stage 2: DC Offset removal
# Matches dc_offset.sv exactly:
#   - Convert uint8 → Q7.10 signed 18-bit
#   - Running mean with alpha shift of 11
#   - Subtract mean from sample
# ============================================================
def dc_offset(sample_i: np.ndarray, sample_q: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """
    Fixed-point DC offset removal matching dc_offset.sv.

    Conversion: flip MSB to go from unsigned → sign-magnitude,
    then shift left by FRACTIONAL_BITS (10) to get Q7.10 format.
    This matches the SystemVerilog line:
        {~sample_i[SAMPLE_DW-1], sample_i[SAMPLE_DW-2:0], {FRACTIONAL_BITS{0}}}
    """
    print("[DC Offset] Removing DC bias...")
    n = len(sample_i)

    # Convert uint8 → signed Q7.10 (18-bit)
    # Flip MSB: XOR with 0x80 converts offset binary to sign-magnitude
    def to_q7_10(x: np.ndarray) -> np.ndarray:
        flipped = x.astype(np.int32) ^ 0x80   # flip MSB
        # re-interpret as signed 8-bit range (-128..127)
        signed = np.where(flipped >= 128, flipped - 256, flipped)
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

        # Nudge by ±1 if update rounded to zero but diff was nonzero
        if upd_i == 0 and diff_i > 0: upd_i = np.int32(1)
        elif upd_i == 0 and diff_i < 0: upd_i = np.int32(-1)
        if upd_q == 0 and diff_q > 0: upd_q = np.int32(1)
        elif upd_q == 0 and diff_q < 0: upd_q = np.int32(-1)

        mean_i = mean_i + upd_i
        mean_q = mean_q + upd_q

        corr_i[k] = si[k] - mean_i
        corr_q[k] = sq[k] - mean_q

    print(f"[DC Offset] Done. Final mean_i={mean_i}, mean_q={mean_q}")
    return corr_i, corr_q


# ============================================================
# Stage 3: Low Pass Filter
# Matches lpf_wrapper.sv — Xilinx FIR Compiler IP.
# We approximate it here with the same firwin design using
# the coefficients from lpf_coeffs.coe (90 kHz cutoff, 18-bit input).
# ============================================================
def low_pass_filter(corr_i: np.ndarray, corr_q: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """
    FIR low-pass filter matching lpf_wrapper.sv.
    Cutoff at 90 kHz relative to SDR sample rate of 220500 Hz.
    Uses floating-point here since we're approximating the IP behavior.
    """
    print("[LPF] Applying low-pass filter (cutoff=90kHz)...")
    nyquist = SDR_SAMPLE_RATE / 2.0
    cutoff_norm = 90_000 / nyquist
    taps = firwin(64, cutoff_norm, window="hamming")

    lpf_i = lfilter(taps, 1.0, corr_i.astype(np.float64))
    lpf_q = lfilter(taps, 1.0, corr_q.astype(np.float64))

    # Convert back to int32 to stay in fixed-point world
    lpf_i = lpf_i.astype(np.int32)
    lpf_q = lpf_q.astype(np.int32)
    print("[LPF] Done.")
    return lpf_i, lpf_q


# ============================================================
# Stage 4: Decimation
# Matches decimation.sv — keep every 6th valid sample.
# Also truncates from DATA_DW (18-bit) to 16-bit by dropping 2 LSBs.
# ============================================================
def decimation(lpf_i: np.ndarray, lpf_q: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """
    Downsample by DECIM_FACTOR=6, matching decimation.sv.
    Keeps sample at count==0 (every 6th), drops the rest.
    Truncates to 16-bit by taking bits [17:2] (dropping 2 LSBs).
    """
    print(f"[Decimation] Downsampling by {DECIM_FACTOR} ({SDR_SAMPLE_RATE} → {AUDIO_SAMPLE_RATE} Hz)...")
    decim_i = (lpf_i[::DECIM_FACTOR] >> 2).astype(np.int16)
    decim_q = (lpf_q[::DECIM_FACTOR] >> 2).astype(np.int16)
    print(f"[Decimation] Done. {len(decim_i)} samples remaining.")
    return decim_i, decim_q


# ============================================================
# Stage 5: FM Demodulate
# Matches fm_demodulate.sv — IQ discriminator:
#   numerator   = I*dQ - Q*dI
#   denominator = I^2 + Q^2
#   audio       = numerator / denominator  (scaled)
# ============================================================
def fm_demodulate(decim_i: np.ndarray, decim_q: np.ndarray) -> np.ndarray:
    """
    FM IQ discriminator matching fm_demodulate.sv.
    Operates on 16-bit signed I/Q samples.
    Returns 16-bit signed audio samples.
    """
    print("[FM Demod] Running IQ discriminator...")
    i = decim_i.astype(np.int32)
    q = decim_q.astype(np.int32)

    # Stage 1: delta (difference from previous sample)
    di = np.diff(i, prepend=i[0])   # dI = I[n] - I[n-1]
    dq = np.diff(q, prepend=q[0])   # dQ = Q[n] - Q[n-1]

    # Stage 2: numerator and denominator
    numerator   = i * dq - q * di                    # I*dQ - Q*dI
    denominator = i * i + q * q                      # I^2 + Q^2

    # Stage 3: clamp denominator to avoid divide-by-zero (matches EPSILON=16)
    denominator = np.where(denominator < 16, 16, denominator)

    # Stage 4: divide
    quot = numerator / denominator.astype(np.float64)

    # Stage 5: scale — SDR_RATE / (2*pi*MAX_FREQ_DEV)
    scale = SDR_SAMPLE_RATE / (2 * np.pi * MAX_FREQ_DEV)
    scaled = quot * scale

    # Stage 6: saturate to 16-bit signed
    sat_max =  32767
    sat_min = -32768
    audio = np.clip(scaled, sat_min, sat_max).astype(np.int16)

    print(f"[FM Demod] Done. Peak amplitude: {np.max(np.abs(audio))}")
    return audio


# ============================================================
# Stage 6: De-emphasis
# Matches de_emphasis.sv — first-order IIR in Q0.16 fixed point:
#   acc[n] = ALPHA_FP * y[n-1] + ONE_MINUS_ALPHA * x[n]
#   y[n]   = acc[n] >> 16
# Output sign-extended to PCM_IN_W (18-bit).
# ============================================================
def de_emphasis(audio: np.ndarray) -> np.ndarray:
    """
    First-order IIR de-emphasis matching de_emphasis.sv.
    Coefficients computed for fs=36750 Hz, tau=75us.
    """
    print("[De-emphasis] Applying 75µs IIR filter...")
    n = len(audio)
    y_prev = np.int32(0)
    out = np.zeros(n, dtype=np.int32)

    for k in range(n):
        x = np.int32(audio[k])
        # acc = ALPHA_FP * y[n-1] + ONE_MINUS_ALPHA * x[n]
        acc = np.int64(ALPHA_FP) * np.int64(y_prev) + np.int64(ONE_MINUS_ALPHA) * np.int64(x)
        # shift right 16 to remove Q0.16 scale
        y_curr = np.int32(acc >> 16)
        out[k] = y_curr
        y_prev = y_curr

    # Sign-extend to PCM_IN_W (18-bit) — in Python just keep as int32
    # Clip to 18-bit signed range
    max_18 =  (1 << (PCM_IN_W - 1)) - 1   #  131071
    min_18 = -(1 << (PCM_IN_W - 1))        # -131072
    out = np.clip(out, min_18, max_18)

    print("[De-emphasis] Done.")
    return out


# ============================================================
# Play audio
# ============================================================
def play_audio(audio: np.ndarray, fs: int) -> None:
    """
    Normalize and play through MacBook speaker via sounddevice.
    """
    peak = np.max(np.abs(audio))
    if peak == 0:
        print("[Play] Audio is silent, nothing to play.")
        return

    normalized = (audio / peak * 0.9).astype(np.float32)
    print(f"[Play] Playing {len(normalized)/fs:.2f}s of audio at {fs} Hz...")
    sd.play(normalized, samplerate=fs)
    sd.wait()
    print("[Play] Done.")


# ============================================================
# Plot pipeline stages
# ============================================================
def plot_pipeline(raw_i, raw_q, corr_i, corr_q,
                  lpf_i, lpf_q, decim_i, decim_q,
                  demod, deemph) -> None:

    fig, axes = plt.subplots(5, 1, figsize=(13, 12))
    fig.suptitle("FPGA Pipeline Simulation — RF Raiders (Team 16)", fontsize=13)

    n = min(500, len(raw_i))

    axes[0].plot(raw_i[:n], label="I", lw=0.8)
    axes[0].plot(raw_q[:n], label="Q", lw=0.8)
    axes[0].set_title("Stage 1 — Raw I/Q from CSV (uint8)")
    axes[0].legend(); axes[0].grid(True)

    axes[1].plot(corr_i[:n], label="I", lw=0.8)
    axes[1].plot(corr_q[:n], label="Q", lw=0.8)
    axes[1].set_title("Stage 2 — After DC Offset Removal (Q7.10)")
    axes[1].legend(); axes[1].grid(True)

    n2 = min(500, len(lpf_i))
    axes[2].plot(lpf_i[:n2], label="I", lw=0.8)
    axes[2].plot(lpf_q[:n2], label="Q", lw=0.8)
    axes[2].set_title("Stage 3+4 — After LPF + Decimation (16-bit)")
    axes[2].legend(); axes[2].grid(True)

    n3 = min(500, len(demod))
    axes[3].plot(demod[:n3], lw=0.8, color="purple")
    axes[3].set_title("Stage 5 — FM Demodulated Audio (16-bit)")
    axes[3].grid(True)

    axes[4].plot(deemph[:n3], lw=0.8, color="crimson")
    axes[4].set_title("Stage 6 — After De-emphasis (18-bit, final output)")
    axes[4].grid(True)

    plt.tight_layout()
    plt.savefig("fpga_pipeline_sim.png", dpi=150)
    print("[Plot] Saved → fpga_pipeline_sim.png")
    plt.show()


# ============================================================
# Main
# ============================================================
def main():
    parser = argparse.ArgumentParser(description="FPGA Pipeline Simulation from CSV I/Q")
    parser.add_argument("csv", nargs="+", help="One or more CSV files (IQ_DATA_1000_*.csv)")
    parser.add_argument("--no-play", action="store_true", help="Skip audio playback")
    parser.add_argument("--no-plot", action="store_true", help="Skip plots")
    args = parser.parse_args()

    print("=" * 55)
    print("  FPGA Pipeline Simulation — RF Raiders (Team 16)")
    print("=" * 55)

    # Stage 1: Load
    raw_i, raw_q = load_csv(args.csv)

    # Stage 2: DC offset
    corr_i, corr_q = dc_offset(raw_i, raw_q)

    # Stage 3: LPF
    lpf_i, lpf_q = low_pass_filter(corr_i, corr_q)

    # Stage 4: Decimation
    decim_i, decim_q = decimation(lpf_i, lpf_q)

    # Stage 5: FM demodulate
    demod = fm_demodulate(decim_i, decim_q)

    # Stage 6: De-emphasis
    deemph = de_emphasis(demod)

    # Export golden reference files for RTL comparison
    np.savetxt("golden_output.txt", deemph, fmt="%d")
    np.savetxt("golden_demod.txt",  demod,  fmt="%d")
    print("[Golden] Saved golden_output.txt and golden_demod.txt")

    # Play
    if not args.no_play:
        play_audio(deemph, AUDIO_SAMPLE_RATE)

    # Plot
    if not args.no_plot:
        plot_pipeline(raw_i, raw_q, corr_i, corr_q,
                      lpf_i, lpf_q, decim_i, decim_q,
                      demod, deemph)

    print("=" * 55)
    print("  Pipeline complete.")
    print("=" * 55)


if __name__ == "__main__":
    main()