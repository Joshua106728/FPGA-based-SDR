import numpy as np
import scipy.signal as signal
import sounddevice as sd
import soundfile as sf
import matplotlib.pyplot as plt
import os

# --- Global Settings ---

# Audio recording/playback sample rate (standard CD quality)
AUDIO_SAMPLE_RATE = 44100
RECORDING_DURATION_SECONDS = 5

# SDR (software-defined radio) signal settings
SDR_SAMPLE_RATE = 220_500       # How many radio samples per second
CARRIER_FREQUENCY = 0           # Baseband simulation (no real carrier shift needed)
MAX_FREQUENCY_DEVIATION = 75_000  # How far the FM signal swings in Hz (standard FM = 75 kHz)

# Filter settings
LOW_PASS_CUTOFF_HZ = 90_000     # Cut off everything above this frequency before demodulation
DE_EMPHASIS_TIME_CONSTANT = 75e-6  # Standard FM de-emphasis time constant (75 microseconds)

# How much we downsample the signal after demodulation to get back to audio rate
DOWNSAMPLE_FACTOR = 5

# Fixed-point conversion settings (for simulating hardware behavior)
FIXED_POINT_TOTAL_BITS = 16     # Total number of bits (like a 16-bit integer)
FIXED_POINT_FRACTION_BITS = 14  # How many of those bits are used for the decimal part


def get_audio_source(use_microphone: bool = False) -> tuple[np.ndarray, int]:
    """
    Gets the audio signal we want to transmit over FM.

    If use_microphone is True, records from the mic for a few seconds.
    Otherwise, generates a simple 1 kHz test beep tone.

    Input:  use_microphone — True to record from mic, False for test tone
    Output: (audio_samples, sample_rate) — the audio data and its sample rate
    """
    sample_rate = AUDIO_SAMPLE_RATE
    duration = RECORDING_DURATION_SECONDS

    # Either record from the microphone or generate a synthetic test tone
    if use_microphone:
        print(f"[Audio Source] Recording {duration}s from microphone...")
        audio_samples = sd.rec(
            int(duration * sample_rate),
            samplerate=sample_rate,
            channels=1,
            dtype="float32"
        )
        sd.wait()
        audio_samples = audio_samples.flatten()
        print("[Audio Source] Recording complete.")
    else:
        print("[Audio Source] Generating 1 kHz test tone...")
        time_axis = np.linspace(0, duration, int(duration * sample_rate), endpoint=False)
        audio_samples = 0.8 * np.sin(2 * np.pi * time_axis).astype(np.float32)

    # Normalize so the loudest point is at 90% volume (avoids clipping)
    loudest_peak = np.max(np.abs(audio_samples))
    if loudest_peak > 0:
        audio_samples = audio_samples / loudest_peak * 0.9

    return audio_samples, sample_rate


def fm_transmit(audio_samples: np.ndarray, audio_sample_rate: int) -> tuple[np.ndarray, np.ndarray, int]:
    """
    Simulates an FM radio transmitter. Takes audio and produces a complex I/Q signal
    as if it were being broadcast over the air (with a little simulated noise added).

    Input:  audio_samples — the audio waveform to broadcast
            audio_sample_rate — the sample rate of that audio
    Output: (iq_signal, time_axis, sdr_sample_rate) — the FM-modulated radio signal,
            a matching time axis, and the SDR sample rate
    """
    print("[Transmitter] Upsampling audio to SDR sample rate...")

    # Upsample audio to match the SDR's higher sample rate
    upsampled_audio = signal.resample_poly(audio_samples, DOWNSAMPLE_FACTOR, 1)
    num_samples = len(upsampled_audio)
    time_axis = np.arange(num_samples) / SDR_SAMPLE_RATE

    # Scale the audio down so it doesn't over-deviate the FM signal
    peak_amplitude = np.max(np.abs(upsampled_audio)) + 1e-9
    scaled_audio = upsampled_audio / peak_amplitude * 0.35

    print("[Transmitter] FM modulating (baseband)...")

    # FM modulation: audio amplitude controls how fast the phase changes
    # Integrating (cumsum) the audio gives us instantaneous phase
    instantaneous_phase = 2 * np.pi * MAX_FREQUENCY_DEVIATION * np.cumsum(scaled_audio) / SDR_SAMPLE_RATE
    iq_signal = np.exp(1j * instantaneous_phase).astype(np.complex128)

    # Add realistic background noise (simulating a real radio channel)
    target_snr_db = 60
    signal_power = np.mean(np.abs(iq_signal) ** 2)
    noise_power = signal_power / (10 ** (target_snr_db / 10))
    noise = np.sqrt(noise_power / 2) * (
        np.random.randn(num_samples) + 1j * np.random.randn(num_samples)
    )
    iq_signal += noise

    print(f"[Transmitter] Done. {num_samples} I/Q samples at {SDR_SAMPLE_RATE} Hz.")
    return iq_signal, time_axis, SDR_SAMPLE_RATE


def remove_dc_offset(iq_signal: np.ndarray) -> np.ndarray:
    """
    Removes any constant bias (DC offset) from the I and Q channels.
    Real SDR hardware often picks up a small DC error — this corrects it.

    Input:  iq_signal — raw complex I/Q samples from the receiver
    Output: iq_signal with DC bias subtracted from both channels
    """
    print("[DC Removal] Removing DC offset...")

    # Compute and subtract the average value from each channel independently
    dc_bias_i = np.mean(iq_signal.real)
    dc_bias_q = np.mean(iq_signal.imag)
    iq_corrected = (iq_signal.real - dc_bias_i) + 1j * (iq_signal.imag - dc_bias_q)

    print(f"[DC Removal] Removed I offset={dc_bias_i:.5f}, Q offset={dc_bias_q:.5f}")
    return iq_corrected

def low_pass_filter(iq_signal: np.ndarray, sample_rate: int) -> np.ndarray:
    """
    Applies a low-pass filter to the I/Q signal to block out-of-band noise
    and interference above the FM channel bandwidth.

    Input:  iq_signal — complex I/Q samples
            sample_rate — the sample rate of the signal in Hz
    Output: filtered complex I/Q samples
    """
    print(f"[LPF] Applying low-pass filter (cutoff = {LOW_PASS_CUTOFF_HZ} Hz)...")

    # Design the FIR filter — normalize cutoff relative to Nyquist frequency
    num_filter_taps = 64
    nyquist_frequency = sample_rate / 2.0
    normalized_cutoff = LOW_PASS_CUTOFF_HZ / nyquist_frequency
    filter_coefficients = signal.firwin(num_filter_taps, normalized_cutoff, window="hamming")

    # Apply the filter separately to the real (I) and imaginary (Q) parts
    filtered_i = signal.lfilter(filter_coefficients, 1.0, iq_signal.real)
    filtered_q = signal.lfilter(filter_coefficients, 1.0, iq_signal.imag)
    iq_filtered = filtered_i + 1j * filtered_q

    print(f"[LPF] Done. Filter has {num_filter_taps} taps.")
    return iq_filtered


def fm_demodulate(iq_filtered: np.ndarray) -> np.ndarray:
    """
    Extracts the original audio from the FM-modulated I/Q signal using an
    IQ discriminator — basically recovering how fast the phase was changing.

    Input:  iq_filtered — the filtered complex I/Q signal
    Output: demodulated audio as a 1D float array (still at SDR sample rate)
    """
    print("[FM Demod] Demodulating FM signal (IQ discriminator)...")

    # Pull out the I (in-phase) and Q (quadrature) components
    i_channel = iq_filtered.real.copy()
    q_channel = iq_filtered.imag.copy()

    # Compute sample-to-sample differences to find the rate of phase change
    delta_i = np.diff(i_channel, prepend=i_channel[0])
    delta_q = np.diff(q_channel, prepend=q_channel[0])

    # IQ discriminator formula: recovers instantaneous frequency
    numerator   = i_channel * delta_q - q_channel * delta_i
    denominator = i_channel**2 + q_channel**2
    denominator = np.where(denominator < 1e-10, 1e-10, denominator)  # Avoid divide-by-zero

    recovered_audio = numerator / denominator

    # Scale the output to match the expected amplitude range
    recovered_audio *= SDR_SAMPLE_RATE / (2 * np.pi * MAX_FREQUENCY_DEVIATION)

    # Normalize so the loudest peak sits at 80% volume
    loudest_peak = np.max(np.abs(recovered_audio))
    print(f"[FM Demod] Peak amplitude before gain: {loudest_peak:.4f}")
    if loudest_peak > 1e-6:
        recovered_audio = recovered_audio / loudest_peak * 0.80

    print("[FM Demod] Done.")
    return recovered_audio


def downsample_to_audio_rate(demodulated_audio: np.ndarray, input_sample_rate: int) -> tuple[np.ndarray, int]:
    """
    Reduces the sample rate of the demodulated signal from the SDR rate
    down to a standard audio rate (divides by DOWNSAMPLE_FACTOR).

    Input:  demodulated_audio — audio signal at the SDR sample rate
            input_sample_rate — the current sample rate in Hz
    Output: (downsampled_audio, new_sample_rate)
    """
    output_sample_rate = input_sample_rate // DOWNSAMPLE_FACTOR
    print(f"[Decimation] Downsampling {input_sample_rate} Hz → {output_sample_rate} Hz "
          f"(factor {DOWNSAMPLE_FACTOR})...")

    downsampled_audio = signal.resample_poly(demodulated_audio, 1, DOWNSAMPLE_FACTOR)

    print(f"[Decimation] Done. Output rate = {output_sample_rate} Hz.")
    return downsampled_audio, output_sample_rate


def de_emphasis_filter(audio_samples: np.ndarray, sample_rate: int) -> np.ndarray:
    """
    Applies FM de-emphasis to undo the pre-emphasis boost added by the transmitter.
    This restores the correct tonal balance (reduces harshness in high frequencies).
    Also applies a final cleanup filter to cut anything above 15 kHz.

    Input:  audio_samples — audio after decimation
            sample_rate — the sample rate of the audio in Hz
    Output: audio with proper FM tonal balance restored
    """
    print(f"[De-emphasis] Applying 75 µs de-emphasis filter at {sample_rate} Hz...")

    # First-order IIR low-pass filter based on the standard 75 µs time constant
    decay = np.exp(-1.0 / (DE_EMPHASIS_TIME_CONSTANT * sample_rate))
    numerator_coeff = np.array([1.0 - decay])
    denominator_coeff = np.array([1.0, -decay])
    audio_de_emphasized = signal.lfilter(numerator_coeff, denominator_coeff, audio_samples)

    # Final cleanup: cut any leftover noise above 15 kHz (beyond human hearing)
    nyquist = sample_rate / 2.0
    high_freq_cutoff = min(15_000 / nyquist, 0.99)
    cleanup_filter = signal.firwin(128, high_freq_cutoff, window="hamming")
    audio_de_emphasized = signal.filtfilt(cleanup_filter, 1.0, audio_de_emphasized)

    print("[De-emphasis] Done.")
    return audio_de_emphasized


def convert_to_fixed_point(float_audio: np.ndarray,
                            total_bits: int = FIXED_POINT_TOTAL_BITS,
                            fraction_bits: int = FIXED_POINT_FRACTION_BITS) -> tuple[np.ndarray, np.ndarray]:
    """
    Converts the floating-point audio to fixed-point integers, simulating how
    the signal would look when processed in real hardware (like an FPGA or DSP chip).

    Input:  float_audio — the final audio as floating-point values
            total_bits — word size (e.g. 16 for 16-bit)
            fraction_bits — how many bits represent the fractional part
    Output: (fixed_point_integers, fixed_point_as_floats) — the integer version
            and its float equivalent (for easy comparison/plotting)
    """
    print(f"[Fixed Point] Converting to Q{total_bits - fraction_bits}.{fraction_bits} "
          f"({total_bits}-bit)...")

    # Compute the scale factor and the min/max integer range
    scale_factor = 2 ** fraction_bits
    max_integer_value = 2 ** (total_bits - 1) - 1
    min_integer_value = -(2 ** (total_bits - 1))

    # Scale, round, and clip to the valid integer range
    scaled_values = float_audio * scale_factor
    clipped_values = np.clip(np.round(scaled_values), min_integer_value, max_integer_value)
    fixed_point_integers = clipped_values.astype(np.int16)

    # Convert back to float so we can measure and plot the quantization error
    fixed_point_as_floats = fixed_point_integers.astype(np.float64) / scale_factor

    # Report how much precision was lost in the conversion
    quantization_error = float_audio[:len(fixed_point_as_floats)] - fixed_point_as_floats
    print(f"[Fixed Point] Max quantization error: {np.max(np.abs(quantization_error)):.6f}")
    print(f"[Fixed Point] RMS quantization error: {np.sqrt(np.mean(quantization_error**2)):.6f}")

    return fixed_point_integers, fixed_point_as_floats


def play_and_save_audio(audio_samples: np.ndarray, sample_rate: int,
                        output_filename: str = "fm_receiver_output.wav") -> None:
    """
    Plays the recovered audio through your speakers and saves it as a WAV file.

    Input:  audio_samples — the final audio waveform to play
            sample_rate — the sample rate of that audio
            output_filename — where to save the WAV file (default: fm_receiver_output.wav)
    Output: (none) — plays audio and writes file to disk
    """
    # Normalize to 90% volume before playback to avoid speaker clipping
    loudest_peak = np.max(np.abs(audio_samples))
    if loudest_peak > 0:
        normalized_audio = audio_samples / loudest_peak * 0.9
    else:
        normalized_audio = audio_samples

    print(f"[Output] Playing recovered audio ({len(audio_samples)/sample_rate:.1f}s)...")
    sd.play(normalized_audio.astype(np.float32), samplerate=sample_rate)
    sd.wait()

    # Save to disk as a standard WAV file
    sf.write(output_filename, normalized_audio.astype(np.float32), sample_rate)
    print(f"[Output] Audio saved to '{output_filename}'.")


def plot_pipeline(source_audio: np.ndarray,
                  iq_signal: np.ndarray,
                  demodulated_audio: np.ndarray,
                  final_audio: np.ndarray,
                  fixed_point_audio: np.ndarray,
                  audio_sample_rate: int) -> None:
    """
    Generates a 6-panel diagnostic plot showing what the signal looks like
    at each stage of the FM pipeline — from raw audio all the way to output.

    Input:  source_audio — the original audio before transmission
            iq_signal — the FM-modulated I/Q signal (after filtering)
            demodulated_audio — audio recovered from the FM signal (at SDR rate)
            final_audio — audio after decimation and de-emphasis
            fixed_point_audio — the final audio converted to fixed-point (as floats)
            audio_sample_rate — the sample rate of the final output audio
    Output: (none) — saves 'fm_sdr_pipeline_plots.png' and shows the plot
    """
    print("[Plot] Generating pipeline diagnostic plots...")

    # Limit how many points we draw to keep the plot snappy
    MAX_PLOT_POINTS = 50_000

    def thin_out(array, max_points=MAX_PLOT_POINTS):
        """Skip samples evenly so we don't plot millions of points."""
        step = max(1, len(array) // max_points)
        return array[::step]

    # Build time axes for each stage
    time_source = np.arange(len(source_audio)) / AUDIO_SAMPLE_RATE
    time_iq = np.arange(len(iq_signal)) / SDR_SAMPLE_RATE
    time_demod = np.arange(len(demodulated_audio)) / SDR_SAMPLE_RATE
    time_final = np.arange(len(final_audio)) / audio_sample_rate

    fig, axes = plt.subplots(3, 2, figsize=(14, 10))
    fig.suptitle("FM SDR Prototype — Pipeline Diagnostic", fontsize=14, fontweight="bold")

    # Panel 1: Original audio going into the transmitter
    ax = axes[0, 0]
    ax.plot(thin_out(time_source), thin_out(source_audio), color="steelblue", lw=0.6)
    ax.set_title(f"1. Source Audio (full {len(source_audio)/AUDIO_SAMPLE_RATE:.1f}s)")
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("Amplitude")

    # Panel 2: The I-channel of the FM-modulated radio signal
    ax = axes[0, 1]
    ax.plot(thin_out(time_iq), thin_out(iq_signal.real), color="darkorange", lw=0.4)
    ax.set_title(f"2. I-channel of FM-Modulated I/Q (full {time_iq[-1]:.1f}s)")
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("Amplitude")

    # Panel 3: Frequency spectrum of the filtered I/Q signal
    ax = axes[1, 0]
    fft_size = 4096
    frequency_bins = np.fft.fftfreq(fft_size, d=1.0 / SDR_SAMPLE_RATE)
    spectrum_magnitude = np.abs(np.fft.fft(iq_signal[:fft_size]))
    ax.plot(np.fft.fftshift(frequency_bins) / 1000,
            20 * np.log10(np.fft.fftshift(spectrum_magnitude) + 1e-12),
            color="green", lw=0.8)
    ax.set_title("3. I/Q Spectrum (after LPF)")
    ax.set_xlabel("Frequency (kHz)")
    ax.set_ylabel("Magnitude (dB)")

    # Panel 4: Demodulated audio before downsampling
    ax = axes[1, 1]
    ax.plot(thin_out(time_demod), thin_out(demodulated_audio), color="purple", lw=0.4)
    ax.set_title(f"4. Demodulated Audio — full {time_demod[-1]:.1f}s (SDR rate)")
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("Amplitude")

    # Panel 5: Final recovered audio after all processing
    ax = axes[2, 0]
    ax.plot(thin_out(time_final), thin_out(final_audio), color="crimson", lw=0.6)
    ax.set_title(f"5. Recovered Audio — full {time_final[-1]:.1f}s "
                 f"(after decimation + de-emphasis)")
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("Amplitude")

    # Panel 6: Zoom in on the loudest 0.5-second window, float vs fixed-point comparison
    ax = axes[2, 1]
    window_size = int(0.5 * audio_sample_rate)
    num_available_samples = min(len(final_audio), len(fixed_point_audio))

    # Find the loudest 0.5-second chunk by RMS energy
    rms_per_window = np.array([
        np.sqrt(np.mean(final_audio[i:i + window_size] ** 2))
        for i in range(0, max(1, num_available_samples - window_size), window_size // 4)
    ])
    loudest_window_start = np.argmax(rms_per_window) * (window_size // 4)
    loudest_window_end = min(loudest_window_start + window_size, num_available_samples)
    zoom_time_axis = np.arange(loudest_window_end - loudest_window_start) / audio_sample_rate

    ax.plot(zoom_time_axis, final_audio[loudest_window_start:loudest_window_end],
            label="Float", color="royalblue", lw=1.2)
    ax.plot(zoom_time_axis, fixed_point_audio[loudest_window_start:loudest_window_end],
            label="Fixed-point (Q2.14)", color="tomato", lw=0.8, linestyle="--")
    ax.set_title(f"6. Float vs Fixed-Point — 0.5s at loudest region "
                 f"(t={loudest_window_start/audio_sample_rate:.1f}s)")
    ax.set_xlabel("Time (s into window)")
    ax.set_ylabel("Amplitude")
    ax.legend()

    plt.tight_layout()
    plt.savefig("fm_sdr_pipeline_plots.png", dpi=150)
    print("[Plot] Saved to 'fm_sdr_pipeline_plots.png'.")
    plt.show()

def run_pipeline(use_microphone: bool = False) -> None:
    """
    Runs the full FM SDR pipeline from start to finish:
    get audio → transmit → filter → demodulate → downsample → clean up → play & plot.

    Input:  use_microphone — True to record from mic, False for a test tone
    Output: (none) — plays audio, saves a WAV file, and shows diagnostic plots
    """
    print("=" * 60)
    print(" " * 20 + "FM SDR Python Prototype")
    print("=" * 60)

    # Step 1: Get the audio we want to "broadcast"
    source_audio, audio_sample_rate = get_audio_source(use_microphone=True)

    # Step 2: Simulate FM transmission — produces a noisy I/Q radio signal
    iq_raw, time_axis, sdr_sample_rate = fm_transmit(source_audio, audio_sample_rate)

    # Step 3: Clean up the received signal
    iq_dc_removed = remove_dc_offset(iq_raw)
    iq_filtered = low_pass_filter(iq_dc_removed, sdr_sample_rate)

    # Step 4: Demodulate — recover audio from the FM signal
    demodulated_audio = fm_demodulate(iq_filtered)

    # Step 5: Bring the sample rate back down to audio range
    downsampled_audio, downsampled_rate = downsample_to_audio_rate(demodulated_audio, sdr_sample_rate)

    # Step 6: Apply de-emphasis to restore tonal balance
    final_audio = de_emphasis_filter(downsampled_audio, downsampled_rate)

    # Step 7: Simulate fixed-point hardware conversion
    _, fixed_point_audio = convert_to_fixed_point(final_audio)

    # Step 8: Play and save the result
    play_and_save_audio(final_audio, downsampled_rate)

    # Step 9: Show diagnostic plots of every stage
    plot_pipeline(
        source_audio=source_audio,
        iq_signal=iq_filtered,
        demodulated_audio=demodulated_audio,
        final_audio=final_audio,
        fixed_point_audio=fixed_point_audio,
        audio_sample_rate=downsampled_rate
    )

    print("=" * 60)
    print("  Pipeline complete.")
    print("=" * 60)


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(
        description="FM SDR Python Prototype"
    )
    parser.add_argument(
        "--mic",
        action="store_true",
        help="Use microphone as audio source (default: 1 kHz test tone)"
    )
    args = parser.parse_args()

    run_pipeline(use_microphone=args.mic)