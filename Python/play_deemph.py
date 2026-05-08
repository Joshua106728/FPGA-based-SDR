"""
play_deemph.py
==============
Reads a de-emphasis stage CSV (Sample_Index,Value) and plays it as audio.
Optionally saves a WAV file.

Usage:
    python play_deemph.py ../sv/hw_stage5_deemphasis.csv
    python play_deemph.py ../IQ_Samples/fpga_stage5_deemphasis.csv
    python play_deemph.py ../sv/hw_stage5_deemphasis.csv --save hw_audio.wav
    python play_deemph.py ../sv/hw_stage5_deemphasis.csv --skip 100
"""

import argparse
import numpy as np
import pandas as pd
import sounddevice as sd
import soundfile as sf

AUDIO_SAMPLE_RATE = 250000 / 6   # must match DECIM_FACTOR in types.sv / fpga_pipeline_sim.py

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("csv", help="Path to stage5 de-emphasis CSV")
    parser.add_argument("--save", default=None, help="Save output as WAV (e.g. out.wav)")
    parser.add_argument("--skip", type=int, default=0,
                        help="Skip first N samples (drop pipeline warmup)")
    args = parser.parse_args()

    df = pd.read_csv(args.csv, skipinitialspace=True)
    samples = df["Value"].to_numpy(dtype=np.int32)

    if args.skip:
        samples = samples[args.skip:]
        print(f"[play] Skipped first {args.skip} samples (warmup)")

    peak = np.max(np.abs(samples))
    if peak == 0:
        print("[play] Audio is silent — nothing to play.")
        return

    norm = (samples / peak * 0.9).astype(np.float32)
    duration = len(norm) / AUDIO_SAMPLE_RATE
    print(f"[play] {len(norm):,} samples, {duration:.2f}s @ {AUDIO_SAMPLE_RATE} Hz")
    print(f"[play] Peak raw value: {peak}  ({args.csv})")

    if args.save:
        sf.write(args.save, norm, AUDIO_SAMPLE_RATE)
        print(f"[play] Saved → {args.save}")

    print("[play] Playing...")
    sd.play(norm, samplerate=AUDIO_SAMPLE_RATE)
    sd.wait()
    print("[play] Done.")

if __name__ == "__main__":
    main()