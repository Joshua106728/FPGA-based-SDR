import pandas as pd
import numpy as np
import sounddevice as sd

# =========================
# Configuration
# =========================
CSV_FILE = "../IQ_Samples/fpga_stage5_deemphasis.csv"   # your CSV file
SAMPLE_RATE = 250_000 / 6        # Hz
VALUE_COLUMN = "Value"     # column containing audio samples

# =========================
# Load CSV
# =========================
df = pd.read_csv(CSV_FILE)

# Extract raw samples exactly as stored
samples = df[VALUE_COLUMN].to_numpy()

# Convert to float32 for playback
# No normalization or scaling is applied
audio = samples.astype(np.float32)

# =========================
# Play audio
# =========================
print(f"Playing {len(audio)} samples at {SAMPLE_RATE} Hz")

sd.play(audio, samplerate=SAMPLE_RATE)
sd.wait()

print("Done")