"""
rf_to_audio.py
==============
Reads an ILA CSV exported from Vivado containing rf_cdc outputs,
runs the full DSP pipeline, and plays audio through your speaker.

Usage:
    python rf_to_audio.py ila_export.csv
    python rf_to_audio.py ila_export.csv --no-play   # just plot
    python rf_to_audio.py ila_export.csv --out out.wav

The ILA CSV must contain columns named (case-insensitive):
    sample_i      — 8-bit unsigned I sample
    sample_q      — 8-bit unsigned Q sample
    sample_valid  — 1-bit valid flag

If the ILA CSV uses probe names like "probe1", "probe2", "probe3"
instead of signal names, pass --probe-map:
    python rf_to_audio.py ila.csv --probe-map 1=sample_i 2=sample_q 3=sample_valid

Dependencies:
    python -m pip install numpy scipy sounddevice matplotlib pandas
"""

import argparse
import sys
import numpy as np
import pandas as pd
from scipy.signal import firwin, lfilter
from scipy.io.wavfile import write
import matplotlib.pyplot as plt

try:
    import sounddevice as sd
    HAS_AUDIO = True
except ImportError:
    HAS_AUDIO = False
    print("[Warning] sounddevice not found — audio playback disabled. "
          "Install with: python -m pip install sounddevice")

# ============================================================
# Constants — must match types.sv
# ============================================================
SAMPLE_DW         = 8
DATA_DW           = 18
FRACTIONAL_BITS   = 10
RUNNING_SUM_ALPHA = 11
SDR_SAMPLE_RATE   = 220500
DECIM_FACTOR      = 6
AUDIO_SAMPLE_RATE = SDR_SAMPLE_RATE // DECIM_FACTOR  # 36750 Hz
SCALE_OUT         = 0b00_0011_1010_1001_1000          # 15000
ALPHA_FP          = 65518
ONE_MINUS_ALPHA   = 18


# ============================================================
# Step 1 — Load ILA CSV
# ============================================================
def load_ila_csv(path: str, probe_map: dict) -> tuple:
    """
    Load Vivado ILA export CSV and extract sample_i, sample_q, sample_valid.

    Vivado exports either:
      A) Signal names as column headers  (ideal)
      B) "probe0", "probe1"... as headers with a separate header row

    Returns arrays of uint8 I, uint8 Q, and bool valid.
    """
    # Try reading directly first
    df = pd.read_csv(path, skipinitialspace=True)

    # Vivado sometimes adds a leading comment row — skip it
    if df.columns[0].startswith('%') or df.columns[0].startswith('//'):
        df = pd.read_csv(path, skipinitialspace=True, comment='%')

    # Normalize column names to lowercase and strip whitespace
    df.columns = [c.strip().lower() for c in df.columns]

    print(f"[Load] CSV columns: {list(df.columns)}")
    print(f"[Load] Total rows: {len(df)}")

    # Apply probe map if provided (e.g. {"1": "sample_i"})
    for probe_num, sig_name in probe_map.items():
        probe_col = f"probe{probe_num}"
        if probe_col in df.columns:
            df = df.rename(columns={probe_col: sig_name.lower()})

    # Find the columns
    col_i     = _find_col(df, ['sample_i', 'dbg_sample_i', 'i'])
    col_q     = _find_col(df, ['sample_q', 'dbg_sample_q', 'q'])
    col_valid = _find_col(df, ['sample_valid', 'dbg_sample_valid', 'valid'])

    if col_i is None or col_q is None:
        raise ValueError(
            f"Could not find sample_i/sample_q columns in {list(df.columns)}.\n"
            "Use --probe-map to specify which probe number maps to which signal.\n"
            "Example: --probe-map 1=sample_i 2=sample_q 3=sample_valid"
        )

    # Parse values — Vivado exports hex with 0x prefix or plain integers
    def parse_col(series):
        if series.dtype == object:
            return series.apply(
                lambda x: int(str(x).strip(), 16)
                if str(x).strip().startswith('0x') or str(x).strip().startswith('0X')
                else int(str(x).strip(), 10)
            ).to_numpy()
        return series.to_numpy(dtype=int)

    i_raw = parse_col(df[col_i]).astype(np.uint8)
    q_raw = parse_col(df[col_q]).astype(np.uint8)

    if col_valid is not None:
        valid = parse_col(df[col_valid]).astype(bool)
    else:
        # If no valid column, assume all rows are valid samples
        print("[Load] No sample_valid column found — assuming all rows are valid")
        valid = np.ones(len(i_raw), dtype=bool)

    # Filter to only valid samples
    i_vals = i_raw[valid]
    q_vals = q_raw[valid]

    print(f"[Load] Valid samples: {len(i_vals)} "
          f"({len(i_vals)/SDR_SAMPLE_RATE:.2f}s at {SDR_SAMPLE_RATE} Hz)")

    if len(i_vals) < 100:
        print("[Warning] Very few valid samples — check ILA trigger settings")

    return i_vals, q_vals


def _find_col(df, candidates):
    for c in candidates:
        if c in df.columns:
            return c
    return None


# ============================================================
# Step 2 — DC Offset Removal (mirrors dc_offset.sv exactly)
# ============================================================
def dc_offset(sample_i: np.ndarray, sample_q: np.ndarray):
    """Fixed-point DC offset removal matching dc_offset.sv."""
    print("[DC Offset] Removing DC bias...")
    n = len(sample_i)

    # Convert uint8 → signed Q7.10 (18-bit)
    # Flip MSB: XOR with 0x80 converts offset-binary to sign-magnitude
    def to_q7_10(x):
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

        upd_i = np.int32(diff_i >> RUNNING_SUM_ALPHA)
        upd_q = np.int32(diff_q >> RUNNING_SUM_ALPHA)

        if upd_i == 0 and diff_i > 0:  upd_i = np.int32(1)
        elif upd_i == 0 and diff_i < 0: upd_i = np.int32(-1)
        if upd_q == 0 and diff_q > 0:  upd_q = np.int32(1)
        elif upd_q == 0 and diff_q < 0: upd_q = np.int32(-1)

        mean_i += upd_i
        mean_q += upd_q
        corr_i[k] = si[k] - mean_i
        corr_q[k] = sq[k] - mean_q

    print(f"[DC Offset] Done. Final mean_i={mean_i}, mean_q={mean_q}")
    return corr_i, corr_q


# ============================================================
# Step 3 — Low-Pass Filter (approximates LPF IP)
# ============================================================
def low_pass_filter(corr_i, corr_q):
    print("[LPF] Applying low-pass filter (cutoff=90kHz)...")
    nyquist    = SDR_SAMPLE_RATE / 2.0
    cutoff     = min(90_000 / nyquist, 0.99)
    taps       = firwin(64, cutoff, window='hamming')
    lpf_i      = lfilter(taps, 1.0, corr_i.astype(np.float64)).astype(np.int32)
    lpf_q      = lfilter(taps, 1.0, corr_q.astype(np.float64)).astype(np.int32)
    print("[LPF] Done.")
    return lpf_i, lpf_q


# ============================================================
# Step 4 — FM Demodulation (matches fm_demodulate.sv)
# ============================================================
def fm_demodulate(lpf_i, lpf_q):
    print("[FM Demod] Running discriminator...")
    I = lpf_i.astype(np.int64)
    Q = lpf_q.astype(np.int64)

    # Numerator: I[n]*Q[n-1] - Q[n]*I[n-1]  (note: correct sign vs original bug)
    num_i   = I * np.roll(Q, 1)
    num_q   = Q * np.roll(I, 1)
    num_sub = num_i - num_q
    num     = (num_sub >> 5).astype(np.int32)

    # Denominator: I^2 + Q^2  (avoid zero)
    denom_i   = I * I
    denom_q   = Q * Q
    denom_add = denom_i + denom_q + 1
    denom     = (denom_add >> 15).astype(np.int32)
    denom     = np.where(denom < 1, 1, denom)

    # Divide and scale
    quot          = (num / denom).astype(np.int64)
    scaled        = quot * SCALE_OUT
    demod_sample  = ((scaled >> 10) & 0x3FFFF).astype(np.int32)
    # Sign-extend 18-bit
    demod_sample  = np.where(demod_sample >= 2**17,
                             demod_sample - 2**18, demod_sample)

    print(f"[FM Demod] Done. Peak: {np.max(np.abs(demod_sample))}")
    return demod_sample


# ============================================================
# Step 5 — Decimation (matches decim.sv — keep 1 in 6)
# ============================================================
def decimation(demod):
    print(f"[Decim] Downsampling by {DECIM_FACTOR}...")
    decimated = demod[::DECIM_FACTOR]
    print(f"[Decim] {len(decimated)} samples → {len(decimated)/AUDIO_SAMPLE_RATE:.2f}s")
    return decimated


# ============================================================
# Step 6 — De-emphasis (matches de_emphasis.sv exactly)
# ============================================================
def de_emphasis(audio):
    print("[De-emph] Applying 75µs IIR...")
    n      = len(audio)
    y_prev = np.int32(0)
    out    = np.zeros(n, dtype=np.int32)
    for k in range(n):
        x      = np.int32(np.clip(audio[k], -2**17, 2**17-1))
        acc    = np.int64(ALPHA_FP) * np.int64(y_prev) \
               + np.int64(ONE_MINUS_ALPHA) * np.int64(x)
        y_curr = np.int32(acc >> 16)
        out[k] = y_curr
        y_prev = y_curr
    print("[De-emph] Done.")
    return out


# ============================================================
# Play audio
# ============================================================
def play_audio(audio, fs):
    if not HAS_AUDIO:
        print("[Play] sounddevice not available — skipping playback")
        return
    peak = np.max(np.abs(audio))
    if peak == 0:
        print("[Play] Audio is silent.")
        return
    norm = (audio / peak * 0.9).astype(np.float32)
    print(f"[Play] Playing {len(norm)/fs:.2f}s at {fs} Hz ...")
    sd.play(norm, samplerate=fs)
    sd.wait()
    print("[Play] Done.")


# ============================================================
# Plot
# ============================================================
def plot(raw_i, raw_q, corr_i, corr_q, demod, audio_final):
    fig, axes = plt.subplots(4, 1, figsize=(13, 10))
    fig.suptitle("RF → Audio Pipeline (from ILA CSV)", fontsize=13)

    n = min(500, len(raw_i))
    axes[0].plot(raw_i[:n], label='I', lw=0.8)
    axes[0].plot(raw_q[:n], label='Q', lw=0.8)
    axes[0].set_title("Stage 1 — Raw I/Q from ILA (uint8)")
    axes[0].legend(); axes[0].grid(True)

    axes[1].plot(corr_i[:n], label='I', lw=0.8)
    axes[1].plot(corr_q[:n], label='Q', lw=0.8)
    axes[1].set_title("Stage 2 — After DC Offset (Q7.10)")
    axes[1].legend(); axes[1].grid(True)

    n2 = min(500, len(demod))
    axes[2].plot(demod[:n2], lw=0.8, color='purple')
    axes[2].set_title("Stage 3 — FM Demodulated (before decimate)")
    axes[2].grid(True)

    n3 = min(500, len(audio_final))
    axes[3].plot(audio_final[:n3], lw=0.8, color='crimson')
    axes[3].set_title("Stage 4 — Final Audio (after decimate + de-emphasis)")
    axes[3].grid(True)

    plt.tight_layout()
    plt.savefig("rf_pipeline_plot.png", dpi=150)
    print("[Plot] Saved → rf_pipeline_plot.png")
    plt.show()


# ============================================================
# Main
# ============================================================
def parse_probe_map(args):
    mapping = {}
    for item in args:
        parts = item.split('=')
        if len(parts) == 2:
            mapping[parts[0].strip()] = parts[1].strip()
    return mapping


def main():
    parser = argparse.ArgumentParser(
        description="Reconstruct audio from Vivado ILA CSV (rf_cdc outputs)")
    parser.add_argument("csv",        help="Vivado ILA export CSV file")
    parser.add_argument("--out",      default="rf_audio_output.wav",
                        help="Output WAV file (default: rf_audio_output.wav)")
    parser.add_argument("--no-play",  action="store_true",
                        help="Skip audio playback")
    parser.add_argument("--no-plot",  action="store_true",
                        help="Skip plots")
    parser.add_argument("--probe-map", nargs="+", default=[],
                        metavar="N=signal",
                        help="Map probe numbers to signal names. "
                             "Example: --probe-map 1=sample_i 2=sample_q 3=sample_valid")
    args = parser.parse_args()

    probe_map = parse_probe_map(args.probe_map)

    print("=" * 55)
    print("  RF → Audio Pipeline from ILA CSV")
    print("=" * 55)

    # Load
    raw_i, raw_q = load_ila_csv(args.csv, probe_map)

    if len(raw_i) == 0:
        print("ERROR: No valid samples found. Check ILA trigger and probe map.")
        sys.exit(1)

    # Pipeline
    corr_i, corr_q = dc_offset(raw_i, raw_q)
    lpf_i,  lpf_q  = low_pass_filter(corr_i, corr_q)
    demod          = fm_demodulate(lpf_i, lpf_q)
    decimated      = decimation(demod)
    audio_final    = de_emphasis(decimated)

    # Save WAV
    peak = np.max(np.abs(audio_final))
    if peak > 0:
        wav_data = np.int16(
            np.clip(audio_final / peak * 32767, -32768, 32767))
    else:
        wav_data = np.zeros(len(audio_final), dtype=np.int16)
    write(args.out, AUDIO_SAMPLE_RATE, wav_data)
    print(f"[Out] Saved → {args.out}")

    # Play
    if not args.no_play:
        play_audio(audio_final, AUDIO_SAMPLE_RATE)

    # Plot
    if not args.no_plot:
        plot(raw_i, raw_q, corr_i, corr_q, demod, audio_final)

    print("=" * 55)
    print("  Done.")
    print("=" * 55)


if __name__ == "__main__":
    main()