"""
fm_receiver.py — FM Receiver for SDR# Baseband Recordings.

This is the receiver-only counterpart to the original FM SDR prototype. It:

  1. Converts an SDR# baseband WAV recording → CSV (uint8 format that
     matches the original prototype's `load_iq_from_csv` expectations).
  2. Runs the receiver pipeline on the CSV:
        DC removal → low-pass filter → FM demod → decimate → de-emphasis
  3. Plays the recovered audio, saves it as a WAV, and shows a 6-panel
     diagnostic plot of every pipeline stage.

The wav_to_csv() function handles any WAV variant SDR# can produce
(WAV STRICT / FULL / RF64; PCM_U8, PCM_16, PCM_24, FLOAT_32) by going
through libsndfile's normalized float read.

Usage:
    python fm_receiver.py recording.wav
    python fm_receiver.py recording.wav --rate 250000
    python fm_receiver.py recording.wav --no-keep-csv

Tip: record at 0.25 MSPS in SDR# (8-bit PCM IQ if available) for the best
match to the original prototype's defaults and the cleanest pipeline output.
"""

import argparse
import os

import numpy as np
import scipy.signal as signal
import sounddevice as sd
import soundfile as sf
import matplotlib.pyplot as plt


# --- Pipeline settings (mirror the original prototype) ---
LOW_PASS_CUTOFF_HZ = 90_000          # cut everything above this before demod
DE_EMPHASIS_TIME_CONSTANT = 75e-6    # standard FM de-emphasis (75 µs in US)
DOWNSAMPLE_FACTOR = 6                # decimation factor after demod
MAX_FREQUENCY_DEVIATION = 75_000     # standard FM peak deviation
FIXED_POINT_TOTAL_BITS = 16
FIXED_POINT_FRACTION_BITS = 14
DEFAULT_MAX_SECONDS = 5.0            # trim input to this many seconds by default


# ----------------------------------------------------------------------
# Stage 0 — Convert SDR# WAV → CSV
# ----------------------------------------------------------------------
def wav_to_csv(wav_path: str, csv_path: str = None) -> tuple[str, int]:
    """
    Convert an SDR# baseband WAV recording to a CSV with columns
    (Sample_Index, I, Q) where I and Q are uint8 values centered at 128.

    Works with any bit depth SDR# can produce (8/16/24-bit PCM, 32-bit
    float) and any WAV variant (STRICT / FULL / RF64) because we read
    through libsndfile's normalized-float interface.

    Input:  wav_path — path to a 2-channel I/Q WAV file from SDR#
            csv_path — output CSV path (default: alongside the WAV)
    Output: (csv_path, sample_rate) — written file path and its sample rate
    """
    if csv_path is None:
        csv_path = os.path.splitext(wav_path)[0] + ".csv"

    print(f"[WAV->CSV] Reading '{wav_path}'...")

    # libsndfile returns float64 in [-1, 1] regardless of the source bit
    # depth, so the rest of this function is bit-depth-agnostic.
    data, sample_rate = sf.read(wav_path)

    if data.ndim != 2 or data.shape[1] != 2:
        raise ValueError(
            f"Expected stereo I/Q WAV, got shape {data.shape}. "
            f"Confirm SDR# was set to baseband (not audio) recording."
        )

    duration_sec = len(data) / sample_rate
    print(f"[WAV->CSV] {len(data):,} samples @ {sample_rate} Hz "
          f"({duration_sec:.2f} s)")

    # Map normalized float [-1, 1] back to uint8 [0, 255] centered at 128.
    # Using *128+128 is the exact inverse of libsndfile's PCM_U8
    # normalization (and a fine quantization for higher-bit-depth inputs).
    i_u8 = np.clip(np.round(data[:, 0] * 128.0 + 128.0), 0, 255).astype(np.int32)
    q_u8 = np.clip(np.round(data[:, 1] * 128.0 + 128.0), 0, 255).astype(np.int32)
    indices = np.arange(len(i_u8), dtype=np.int32)

    print(f"[WAV->CSV] Writing '{csv_path}'...")
    rows = np.column_stack([indices, i_u8, q_u8])
    np.savetxt(
        csv_path, rows, fmt="%d", delimiter=",",
        header="Sample_Index, I, Q", comments="",
    )

    size_mb = os.path.getsize(csv_path) / 1e6
    print(f"[WAV->CSV] Wrote {size_mb:.1f} MB.")
    return csv_path, int(sample_rate)


# ----------------------------------------------------------------------
# Stage CSV saver — write pipeline intermediate outputs for HDL comparison
# ----------------------------------------------------------------------
def save_stage_csv(data: np.ndarray, path: str, label: str) -> None:
    """
    Save a pipeline stage output to CSV for HDL simulation comparison.

    Complex input  → columns: Sample_Index, I, Q  (float, normalized to [-1,1])
    Real input     → columns: Sample_Index, Value
    """
    n = len(data)
    indices = np.arange(n, dtype=np.int32)
    if np.iscomplexobj(data):
        rows = np.column_stack([indices, data.real, data.imag])
        header = "Sample_Index,I,Q"
        fmt = ["%d", "%.8f", "%.8f"]
    else:
        rows = np.column_stack([indices, data])
        header = "Sample_Index,Value"
        fmt = ["%d", "%.8f"]
    np.savetxt(path, rows, fmt=fmt, delimiter=",", header=header, comments="")
    size_kb = os.path.getsize(path) / 1e3
    print(f"[Stage CSV] {label}: wrote {n:,} samples → '{path}' ({size_kb:.0f} KB)")


# ----------------------------------------------------------------------
# Receiver pipeline (lifted from the original prototype, transmit removed)
# ----------------------------------------------------------------------
def load_iq_from_csv(csv_path: str, sample_rate: int) -> tuple[np.ndarray, int]:
    """Load (Sample_Index, I, Q) CSV → complex IQ array in [-1, 1]."""
    print(f"[CSV Loader] Reading '{csv_path}'...")
    data = np.loadtxt(csv_path, delimiter=",", skiprows=1)
    i = (data[:, 1] - 128.0) / 128.0
    q = (data[:, 2] - 128.0) / 128.0
    iq = (i + 1j * q).astype(np.complex128)
    print(f"[CSV Loader] Loaded {len(iq):,} samples @ {sample_rate} Hz.")
    return iq, sample_rate


def remove_dc_offset(iq_signal: np.ndarray) -> np.ndarray:
    """Subtract the mean from I and Q channels independently."""
    print("[DC Removal] Removing DC offset...")
    dc_i = np.mean(iq_signal.real)
    dc_q = np.mean(iq_signal.imag)
    out = (iq_signal.real - dc_i) + 1j * (iq_signal.imag - dc_q)
    print(f"[DC Removal] I offset={dc_i:.5f}, Q offset={dc_q:.5f}")
    return out


def low_pass_filter(iq_signal: np.ndarray, sample_rate: int) -> np.ndarray:
    """Apply low-pass FIR filter to limit out-of-band energy before demod."""
    print(f"[LPF] Applying low-pass filter (cutoff = {LOW_PASS_CUTOFF_HZ} Hz)...")
    nyquist = sample_rate / 2.0
    normalized = LOW_PASS_CUTOFF_HZ / nyquist
    if normalized >= 1.0:
        print("[LPF] Cutoff exceeds Nyquist; skipping filter.")
        return iq_signal

    taps = signal.firwin(64, normalized, window="hamming")
    fi = signal.lfilter(taps, 1.0, iq_signal.real)
    fq = signal.lfilter(taps, 1.0, iq_signal.imag)
    print("[LPF] Done.")
    return fi + 1j * fq


def fm_demodulate(iq_filtered: np.ndarray, sample_rate: int) -> np.ndarray:
    """IQ discriminator FM demodulation."""
    print("[FM Demod] Demodulating FM signal (IQ discriminator)...")
    i = iq_filtered.real.copy()
    q = iq_filtered.imag.copy()
    di = np.diff(i, prepend=i[0])
    dq = np.diff(q, prepend=q[0])

    num = i * dq - q * di
    den = i ** 2 + q ** 2
    den = np.where(den < 1e-10, 1e-10, den)
    audio = num / den
    audio *= sample_rate / (2 * np.pi * MAX_FREQUENCY_DEVIATION)

    peak = np.max(np.abs(audio))
    print(f"[FM Demod] Peak amplitude before gain: {peak:.4f}")
    if peak > 1e-6:
        audio = audio / peak * 0.80
    print("[FM Demod] Done.")
    return audio


def downsample_to_audio_rate(audio: np.ndarray, in_rate: int) -> tuple[np.ndarray, int]:
    """Decimate by DOWNSAMPLE_FACTOR (=5)."""
    out_rate = in_rate // DOWNSAMPLE_FACTOR
    print(f"[Decimation] {in_rate} Hz -> {out_rate} Hz (factor {DOWNSAMPLE_FACTOR})...")
    out = signal.resample_poly(audio, 1, DOWNSAMPLE_FACTOR)
    print(f"[Decimation] Done. Output rate = {out_rate} Hz.")
    return out, out_rate


def de_emphasis_filter(audio: np.ndarray, sample_rate: int) -> np.ndarray:
    """Apply 75 µs FM de-emphasis IIR + 15 kHz cleanup low-pass."""
    print(f"[De-emphasis] Applying 75 us de-emphasis @ {sample_rate} Hz...")
    decay = np.exp(-1.0 / (DE_EMPHASIS_TIME_CONSTANT * sample_rate))
    b = np.array([1.0 - decay])
    a = np.array([1.0, -decay])
    out = signal.lfilter(b, a, audio)

    nyq = sample_rate / 2.0
    cutoff = min(15_000 / nyq, 0.99)
    cleanup = signal.firwin(128, cutoff, window="hamming")
    out = signal.filtfilt(cleanup, 1.0, out)
    print("[De-emphasis] Done.")
    return out


def convert_to_fixed_point(
    float_audio: np.ndarray,
    total_bits: int = FIXED_POINT_TOTAL_BITS,
    fraction_bits: int = FIXED_POINT_FRACTION_BITS,
) -> tuple[np.ndarray, np.ndarray]:
    """Q-format fixed-point conversion (for hardware-style sanity checks)."""
    print(f"[Fixed Point] Converting to Q{total_bits - fraction_bits}.{fraction_bits} "
          f"({total_bits}-bit)...")
    scale = 2 ** fraction_bits
    max_v = 2 ** (total_bits - 1) - 1
    min_v = -(2 ** (total_bits - 1))

    scaled = np.clip(np.round(float_audio * scale), min_v, max_v).astype(np.int16)
    floats = scaled.astype(np.float64) / scale

    err = float_audio[: len(floats)] - floats
    print(f"[Fixed Point] Max quantization error: {np.max(np.abs(err)):.6f}")
    print(f"[Fixed Point] RMS quantization error: {np.sqrt(np.mean(err ** 2)):.6f}")
    return scaled, floats


def play_and_save_audio(
    audio: np.ndarray, sample_rate: int,
    out_path: str = "fm_receiver_output.wav",
) -> None:
    """Normalize, play through default audio device, and save a WAV."""
    peak = np.max(np.abs(audio))
    norm = (audio / peak * 0.9) if peak > 0 else audio
    print(f"[Output] Playing recovered audio ({len(audio) / sample_rate:.1f}s)...")
    try:
        sd.play(norm.astype(np.float32), samplerate=sample_rate)
        sd.wait()
    except Exception as e:
        print(f"[Output] (Playback skipped: {e})")
    sf.write(out_path, norm.astype(np.float32), sample_rate)
    print(f"[Output] Audio saved to '{out_path}'.")


# ----------------------------------------------------------------------
# Diagnostic plot — receiver-pipeline view (no source/transmit panels)
# ----------------------------------------------------------------------
def plot_pipeline(
    iq_raw: np.ndarray,
    iq_filtered: np.ndarray,
    demodulated: np.ndarray,
    final_audio: np.ndarray,
    fixed_point_audio: np.ndarray,
    sdr_rate: int,
    audio_rate: int,
) -> None:
    """6-panel diagnostic of every receiver stage."""
    print("[Plot] Generating pipeline diagnostic plots...")

    MAX_PLOT_POINTS = 50_000

    def thin(arr):
        step = max(1, len(arr) // MAX_PLOT_POINTS)
        return arr[::step]

    t_iq = np.arange(len(iq_raw)) / sdr_rate
    t_demod = np.arange(len(demodulated)) / sdr_rate
    t_final = np.arange(len(final_audio)) / audio_rate

    fig, axes = plt.subplots(3, 2, figsize=(14, 10))
    fig.suptitle("FM SDR Receiver — Pipeline Diagnostic",
                 fontsize=14, fontweight="bold")

    # 1. Raw I-channel (the input signal as it came off the SDR)
    ax = axes[0, 0]
    ax.plot(thin(t_iq), thin(iq_raw.real), color="steelblue", lw=0.4)
    ax.set_title(f"1. Raw I-channel from WAV (full {t_iq[-1]:.1f}s)")
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("Amplitude")

    # 2. Filtered I-channel (after DC removal + LPF)
    ax = axes[0, 1]
    ax.plot(thin(t_iq), thin(iq_filtered.real), color="darkorange", lw=0.4)
    ax.set_title("2. Filtered I-channel (after DC removal + LPF)")
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("Amplitude")

    # 3. Spectrum after LPF — useful to see the FM signal shape
    ax = axes[1, 0]
    fft_size = min(4096, len(iq_filtered))
    if fft_size > 0:
        f = np.fft.fftfreq(fft_size, d=1.0 / sdr_rate)
        spec = np.abs(np.fft.fft(iq_filtered[:fft_size]))
        ax.plot(np.fft.fftshift(f) / 1000,
                20 * np.log10(np.fft.fftshift(spec) + 1e-12),
                color="green", lw=0.8)
    ax.set_title("3. I/Q Spectrum (after LPF)")
    ax.set_xlabel("Frequency (kHz)")
    ax.set_ylabel("Magnitude (dB)")

    # 4. Demodulated audio at SDR rate
    ax = axes[1, 1]
    ax.plot(thin(t_demod), thin(demodulated), color="purple", lw=0.4)
    ax.set_title(f"4. Demodulated audio — full {t_demod[-1]:.1f}s (SDR rate)")
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("Amplitude")

    # 5. Final audio after decimation + de-emphasis
    ax = axes[2, 0]
    ax.plot(thin(t_final), thin(final_audio), color="crimson", lw=0.6)
    ax.set_title(f"5. Recovered audio — full {t_final[-1]:.1f}s "
                 f"(after decimation + de-emphasis)")
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("Amplitude")

    # 6. Float vs fixed-point on the loudest 0.5s window
    ax = axes[2, 1]
    win = int(0.5 * audio_rate)
    n_avail = min(len(final_audio), len(fixed_point_audio))
    if n_avail > win:
        rms = np.array([
            np.sqrt(np.mean(final_audio[i:i + win] ** 2))
            for i in range(0, n_avail - win, max(1, win // 4))
        ])
        start = int(np.argmax(rms)) * (win // 4)
        end = min(start + win, n_avail)
    else:
        start, end = 0, n_avail

    t_zoom = np.arange(end - start) / audio_rate
    ax.plot(t_zoom, final_audio[start:end],
            label="Float", color="royalblue", lw=1.2)
    ax.plot(t_zoom, fixed_point_audio[start:end],
            label="Fixed-point (Q2.14)", color="tomato", lw=0.8, linestyle="--")
    ax.set_title(f"6. Float vs Fixed-Point — 0.5s @ loudest region "
                 f"(t={start / audio_rate:.1f}s)")
    ax.set_xlabel("Time (s into window)")
    ax.set_ylabel("Amplitude")
    ax.legend()

    plt.tight_layout()
    out_path = "fm_receiver_plots.png"
    plt.savefig(out_path, dpi=150)
    print(f"[Plot] Saved to '{out_path}'.")
    plt.show()


# ----------------------------------------------------------------------
# End-to-end driver
# ----------------------------------------------------------------------
def run_receiver(
    wav_path: str,
    sample_rate_override: int = None,
    keep_csv: bool = True,
    max_seconds: float = DEFAULT_MAX_SECONDS,
) -> None:
    """
    Full receiver pipeline: WAV -> CSV -> demod -> audio.

    Input:  wav_path             — SDR# baseband WAV recording
            sample_rate_override — override the WAV's reported rate (Hz)
            keep_csv             — keep the intermediate CSV file
            max_seconds          — trim input to this many seconds (0 = full file)
    """
    print("=" * 60)
    print(" " * 16 + "FM SDR Receiver Pipeline")
    print("=" * 60)

    # Stage 0: WAV -> CSV
    csv_path, wav_rate = wav_to_csv(wav_path)
    sdr_rate = sample_rate_override if sample_rate_override else wav_rate

    if sample_rate_override and sample_rate_override != wav_rate:
        print(f"[Driver] Overriding sample rate: {wav_rate} -> {sdr_rate} Hz.")

    # Stage 1: CSV -> complex IQ
    iq_raw, _ = load_iq_from_csv(csv_path, sdr_rate)

    # Trim to the first max_seconds of IQ data for HDL comparison
    if max_seconds > 0:
        max_samples = int(max_seconds * sdr_rate)
        if len(iq_raw) > max_samples:
            print(f"[Trim] Keeping first {max_seconds}s "
                  f"({max_samples:,} / {len(iq_raw):,} samples).")
            iq_raw = iq_raw[:max_samples]

    # Build a base path for stage CSVs alongside the input WAV
    base = os.path.splitext(wav_path)[0]

    # Stage 0 CSV: uint8 format (same as song.csv / ad.csv) but trimmed to max_seconds
    _i_u8 = np.clip(np.round(iq_raw.real * 128 + 128), 0, 255).astype(np.int32)
    _q_u8 = np.clip(np.round(iq_raw.imag * 128 + 128), 0, 255).astype(np.int32)
    _idx  = np.arange(len(iq_raw), dtype=np.int32)
    _stage0_path = f"{base}_stage0_raw_iq.csv"
    np.savetxt(_stage0_path, np.column_stack([_idx, _i_u8, _q_u8]),
               fmt="%d", delimiter=",", header="Sample_Index,I,Q", comments="")
    print(f"[Stage CSV] Raw IQ (uint8, trimmed): wrote {len(iq_raw):,} samples → '{_stage0_path}'")

    # Stage 2: clean
    iq_dc = remove_dc_offset(iq_raw)
    save_stage_csv(iq_dc,  f"{base}_stage1_dc_removed.csv",  "DC removed")

    iq_lpf = low_pass_filter(iq_dc, sdr_rate)
    save_stage_csv(iq_lpf, f"{base}_stage2_lpf.csv",         "LPF output")

    # Stage 3: demodulate
    demod = fm_demodulate(iq_lpf, sdr_rate)
    save_stage_csv(demod,  f"{base}_stage3_demod.csv",        "FM demod output")

    # Stage 4: decimate to audio rate
    audio_decimated, audio_rate = downsample_to_audio_rate(demod, sdr_rate)
    save_stage_csv(audio_decimated, f"{base}_stage4_decimated.csv", "Decimated audio")

    # Stage 5: de-emphasis + cleanup
    audio_final = de_emphasis_filter(audio_decimated, audio_rate)
    save_stage_csv(audio_final, f"{base}_stage5_deemphasis.csv",    "De-emphasis output")

    # Stage 6: fixed-point sanity check
    _, audio_fp = convert_to_fixed_point(audio_final)

    # Stage 7: play + save
    play_and_save_audio(audio_final, audio_rate)

    # Stage 8: plots
    plot_pipeline(
        iq_raw=iq_raw,
        iq_filtered=iq_lpf,
        demodulated=demod,
        final_audio=audio_final,
        fixed_point_audio=audio_fp,
        sdr_rate=sdr_rate,
        audio_rate=audio_rate,
    )

    if not keep_csv:
        os.remove(csv_path)
        print(f"[Cleanup] Removed intermediate CSV '{csv_path}'.")

    print("=" * 60)
    print("  Receiver complete.")
    print("=" * 60)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="FM SDR Receiver — process an SDR# baseband WAV recording."
    )
    parser.add_argument(
        "wav_path",
        help="Path to the SDR# baseband WAV recording (any bit depth / WAV variant).",
    )
    parser.add_argument(
        "--rate", type=int, default=None, metavar="HZ",
        help="Override sample rate (Hz). Default: read from WAV header.",
    )
    parser.add_argument(
        "--no-keep-csv", action="store_true",
        help="Delete the intermediate CSV after processing.",
    )
    parser.add_argument(
        "--seconds", type=float, default=DEFAULT_MAX_SECONDS, metavar="SEC",
        help=f"Process only the first SEC seconds of the recording "
             f"(default: {DEFAULT_MAX_SECONDS}; 0 = full file).",
    )
    args = parser.parse_args()

    run_receiver(
        wav_path=args.wav_path,
        sample_rate_override=args.rate,
        keep_csv=not args.no_keep_csv,
        max_seconds=args.seconds,
    )