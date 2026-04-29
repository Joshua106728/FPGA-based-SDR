"""
csv_to_hex.py
=============
Converts IQ_DATA_1000_*.csv files into a hex file readable by
$readmemh in the SystemVerilog testbench.

Each line in the output hex file is a 16-bit word:
  [15:8] = I sample (uint8)
  [7:0]  = Q sample (uint8)

This matches exactly what rf_cdc.sv outputs after deserializing
the SPI bitstream — the testbench bypasses rf_cdc and injects
samples directly into dc_offset.

Usage:
    python csv_to_hex.py ../IQ_Samples/IQ_DATA_1000_1.csv
    python csv_to_hex.py ../IQ_Samples/IQ_DATA_1000_{1,2,3,4,5}.csv
    (output: iq_samples.hex  in current directory)
"""

import argparse
import numpy as np
import pandas as pd

def main():
    parser = argparse.ArgumentParser(description="Convert CSV IQ to hex for SV testbench")
    parser.add_argument("csv", nargs="+", help="CSV files to convert")
    parser.add_argument("--out", default="iq_samples.hex", help="Output hex filename")
    args = parser.parse_args()

    all_i, all_q = [], []
    for path in args.csv:
        df = pd.read_csv(path, skipinitialspace=True)
        all_i.append(df['I'].to_numpy(dtype=np.uint8))
        all_q.append(df['Q'].to_numpy(dtype=np.uint8))
        print(f"[CSV→HEX] Loaded {len(df)} samples from {path}")

    i_vals = np.concatenate(all_i)
    q_vals = np.concatenate(all_q)

    with open(args.out, 'w') as f:
        for i, q in zip(i_vals, q_vals):
            # Pack I into [15:8] and Q into [7:0]
            word = (int(i) << 8) | int(q)
            f.write(f"{word:04x}\n")

    print(f"[CSV→HEX] Written {len(i_vals)} entries → {args.out}")
    print(f"[CSV→HEX] Copy {args.out} into your sv/ directory before running Vivado sim")

if __name__ == "__main__":
    main()