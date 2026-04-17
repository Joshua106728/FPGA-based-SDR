import numpy as np
from scipy import signal

fs_in = 256000
num_taps = 64
# targetting output of 48kHz (for speaker)?
# Nyquist limit 24khzm --> 20khz to give a little leeway
cutoff_hz = 20000 

# 1. Generate Taps
taps = signal.firwin(num_taps, cutoff_hz, fs=fs_in)

# 2. Quantize to 16-bit integers for the Arty-7 DSP slices
quantized_taps = np.round(taps / np.max(np.abs(taps)) * 131071).astype(int)

# 3. Write COE file
with open("sdr_decimator.coe", "w") as f:
    f.write("radix=10;\n") # this needs to be "radix" specifically because that is what Vivado is looking for
    f.write("coefdata=\n") # same for coefdata
    for i, val in enumerate(quantized_taps):
        f.write(f"{val}{';' if i == num_taps-1 else ','}\n")