import numpy as np
from scipy import signal

coeffs_float = signal.firwin(64, 90000/125000, window="hamming")
max_abs = np.max(np.abs(coeffs_float))
scale = 131071.0 / max_abs
coeffs_int = np.round(coeffs_float * scale).astype(int)

# Simulate: 100 samples of input = 1024
input_signal = np.ones(100) * 1024
output = signal.lfilter(coeffs_int, 1, input_signal)

# The steady-state output (after 64 samples)
print(f"Coefficient sum: {coeffs_int.sum()}")
print(f"Full precision output: {int(1024 * coeffs_int.sum())}")
print(f"Steady-state output[-1]: {output[-1]:.0f}")

# Now simulate what the FIR Compiler's truncation does
# Full precision is 42 bits, output is 18 bits
# Check what bit shift gives us 445
full = int(1024 * coeffs_int.sum())
for shift in range(0, 30):
    truncated = full >> shift
    if abs(truncated - 445) < 5:
        print(f"Shift by {shift} gives {truncated} (close to 445)")