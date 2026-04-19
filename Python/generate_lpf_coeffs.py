import numpy as np
import scipy.signal as signal

# ============================================================
# Step 1: Design the filter
# ============================================================
SAMPLE_RATE = 250_000
LOW_PASS_CUTOFF_HZ = 90_000
COEFF_BIT_WIDTH = 18

num_filter_taps = 64
nyquist_frequency = SAMPLE_RATE / 2.0
normalized_cutoff = LOW_PASS_CUTOFF_HZ / nyquist_frequency
filter_coefficients = signal.firwin(num_filter_taps, normalized_cutoff, window="hamming")

# ============================================================
# Step 2: Quantize to fixed-point integers
# ============================================================
# The FIR Compiler works with integer coefficients.
# We need to scale our float coefficients to fill the
# 18-bit signed integer range [-131072, +131071] as fully
# as possible to maximize precision.
#
# Strategy: find the largest absolute coefficient value,
# then scale so that value maps to the max 18-bit integer.

max_signed_value = 2 ** (COEFF_BIT_WIDTH - 1) - 1  # 131071 for 18-bit
max_abs_coeff = np.max(np.abs(filter_coefficients))
scale_factor = max_signed_value / max_abs_coeff

# Multiply all coefficients by the scale factor, then round to integers
quantized_coeffs = np.round(filter_coefficients * scale_factor).astype(int)

# Clip to valid range (safety check — shouldn't be needed after scaling)
min_signed_value = -(2 ** (COEFF_BIT_WIDTH - 1))  # -131072 for 18-bit
quantized_coeffs = np.clip(quantized_coeffs, min_signed_value, max_signed_value)

print("\n" + "=" * 50)
print("Step 2: Quantization")
print("=" * 50)
print(f"Max absolute coefficient: {max_abs_coeff:.6f}")
print(f"Scale factor:            {scale_factor:.2f}")
print(f"18-bit signed range:     [{min_signed_value}, {max_signed_value}]")
print(f"Quantized range:         [{quantized_coeffs.min()}, {quantized_coeffs.max()}]")
print(f"Still symmetric:         {np.array_equal(quantized_coeffs, quantized_coeffs[::-1])}")

# ============================================================
# Step 3: Measure quantization error
# ============================================================
# Convert back to float and compare with original to see
# how much precision we lost in the quantization.

reconstructed = quantized_coeffs / scale_factor
max_error = np.max(np.abs(filter_coefficients - reconstructed))
print(f"\nMax quantization error:   {max_error:.8f}")

# Compare frequency response of float vs quantized
w_float, h_float = signal.freqz(filter_coefficients, worN=8192, fs=SAMPLE_RATE)
w_quant, h_quant = signal.freqz(quantized_coeffs / scale_factor, worN=8192, fs=SAMPLE_RATE)

mag_float = 20 * np.log10(np.abs(h_float) + 1e-12)
mag_quant = 20 * np.log10(np.abs(h_quant) + 1e-12)

idx_3db = np.where(mag_float <= -3)[0]
if len(idx_3db) > 0:
    print(f"Float -3dB frequency:    {w_float[idx_3db[0]]:.0f} Hz")

idx_3db_q = np.where(mag_quant <= -3)[0]
if len(idx_3db_q) > 0:
    print(f"Quantized -3dB freq:     {w_quant[idx_3db_q[0]]:.0f} Hz")

print(f"Max response difference: {np.max(np.abs(mag_float - mag_quant)):.2f} dB")

# ============================================================
# Step 4: Write the COE file
# ============================================================
# COE file format for Vivado FIR Compiler:
#   - radix: number base (10 = decimal, 16 = hex)
#   - coefdata: comma-separated list of integer coefficients
#   - last coefficient ends with semicolon instead of comma

coe_filename = "lpf_coeffs.coe"

with open(coe_filename, "w") as f:
    # Header comments (ignored by Vivado, useful for documentation)
    f.write("; FIR Low-Pass Filter Coefficients\n")
    f.write(f"; Sample rate: {SAMPLE_RATE} Hz\n")
    f.write(f"; Cutoff: {LOW_PASS_CUTOFF_HZ} Hz\n")
    f.write(f"; Normalized cutoff: {normalized_cutoff:.4f}\n")
    f.write(f"; Taps: {num_filter_taps}\n")
    f.write(f"; Window: Hamming\n")
    f.write(f"; Bit width: {COEFF_BIT_WIDTH}-bit signed\n")
    f.write(f"; Scale factor: {scale_factor:.2f}\n")

    # Radix declaration (10 = decimal)
    f.write("radix=10;\n")

    # Coefficient data — comma separated, semicolon at the end
    f.write("coefdata=\n")
    f.write(",\n".join(str(c) for c in quantized_coeffs))
    f.write(";\n")

print(f"Written to: {coe_filename}")