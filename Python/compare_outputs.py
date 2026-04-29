"""
compare_outputs.py
==================
Compares the RTL testbench output against the Python golden reference.
Plots both signals overlaid and reports max/RMS error.

Usage:
    python compare_outputs.py
    python compare_outputs.py --rtl rtl_output.txt --golden golden_output.txt

Files expected (all in current directory):
    golden_output.txt     — written by fpga_pipeline_sim.py
    golden_demod.txt      — written by fpga_pipeline_sim.py (per-stage debug)
    rtl_output.txt        — written by pipeline_tb.sv
    rtl_demod_output.txt  — written by pipeline_tb.sv (per-stage debug)
"""

import argparse
import numpy as np
import matplotlib.pyplot as plt

def load(path: str) -> np.ndarray:
    try:
        return np.loadtxt(path, dtype=np.int64)
    except FileNotFoundError:
        print(f"[Compare] ERROR: {path} not found.")
        raise

def compare(golden: np.ndarray, rtl: np.ndarray, label: str) -> dict:
    """Trim to same length and compute error metrics."""
    n = min(len(golden), len(rtl))
    if n == 0:
        print(f"[Compare] WARNING: one of the {label} files is empty.")
        return {}

    g = golden[:n].astype(np.float64)
    r = rtl[:n].astype(np.float64)
    diff = g - r

    max_err = np.max(np.abs(diff))
    rms_err = np.sqrt(np.mean(diff ** 2))
    max_val = np.max(np.abs(g))
    rel_err = (max_err / max_val * 100) if max_val > 0 else 0.0

    print(f"\n[{label}]")
    print(f"  Samples compared : {n}")
    print(f"  Max error        : {max_err:.1f} LSBs")
    print(f"  RMS error        : {rms_err:.4f} LSBs")
    print(f"  Max signal value : {max_val:.1f}")
    print(f"  Relative error   : {rel_err:.4f} %")
    print(f"  {'PASS ✓' if max_err <= 2 else 'FAIL ✗  (max error > 2 LSBs)'}")

    return {"n": n, "golden": g, "rtl": r, "diff": diff,
            "max_err": max_err, "rms_err": rms_err}

def plot_comparison(results_deemph: dict, results_demod: dict) -> None:
    fig, axes = plt.subplots(3, 1, figsize=(13, 9))
    fig.suptitle("RTL vs Python Golden Reference — RF Raiders (Team 16)", fontsize=13)

    # ---- De-emphasis output comparison ----
    ax = axes[0]
    n = results_deemph["n"]
    t = np.arange(n)
    ax.plot(t, results_deemph["golden"], label="Python golden", lw=1.2, color="steelblue")
    ax.plot(t, results_deemph["rtl"],    label="RTL output",    lw=0.8,
            color="tomato", linestyle="--")
    ax.set_title("Stage 6 — De-emphasis Output (18-bit)")
    ax.set_xlabel("Sample index")
    ax.set_ylabel("Amplitude (LSBs)")
    ax.legend()
    ax.grid(True)

    # ---- De-emphasis error ----
    ax = axes[1]
    ax.plot(t, results_deemph["diff"], lw=0.8, color="darkorange")
    ax.axhline(0, color="black", lw=0.5)
    ax.axhline( 2, color="red", lw=0.5, linestyle="--", label="±2 LSB threshold")
    ax.axhline(-2, color="red", lw=0.5, linestyle="--")
    ax.set_title(f"De-emphasis Error (max={results_deemph['max_err']:.1f} LSBs, "
                 f"RMS={results_deemph['rms_err']:.4f})")
    ax.set_xlabel("Sample index")
    ax.set_ylabel("Error (LSBs)")
    ax.legend()
    ax.grid(True)

    # ---- FM demod output comparison ----
    ax = axes[2]
    if results_demod:
        nd = results_demod["n"]
        td = np.arange(nd)
        ax.plot(td, results_demod["golden"], label="Python golden", lw=1.2, color="steelblue")
        ax.plot(td, results_demod["rtl"],    label="RTL output",    lw=0.8,
                color="tomato", linestyle="--")
        ax.set_title(f"Stage 5 — FM Demod Output (16-bit), "
                     f"max err={results_demod['max_err']:.1f} LSBs")
    else:
        ax.set_title("Stage 5 — FM Demod (files not found, skipped)")
    ax.set_xlabel("Sample index")
    ax.set_ylabel("Amplitude (LSBs)")
    ax.legend()
    ax.grid(True)

    plt.tight_layout()
    plt.savefig("comparison_plot.png", dpi=150)
    print("\n[Compare] Plot saved → comparison_plot.png")
    plt.show()

def main():
    parser = argparse.ArgumentParser(description="Compare RTL vs Python golden outputs")
    parser.add_argument("--rtl",          default="rtl_output.txt")
    parser.add_argument("--golden",       default="golden_output.txt")
    parser.add_argument("--rtl-demod",    default="rtl_demod_output.txt")
    parser.add_argument("--golden-demod", default="golden_demod.txt")
    args = parser.parse_args()

    print("=" * 55)
    print("  RTL vs Golden Comparison — RF Raiders (Team 16)")
    print("=" * 55)

    # Main comparison — de-emphasis output
    golden  = load(args.golden)
    rtl     = load(args.rtl)
    results_deemph = compare(golden, rtl, "De-emphasis output")

    # Per-stage debug — fm_demodulate output
    results_demod = {}
    try:
        golden_demod = load(args.golden_demod)
        rtl_demod    = load(args.rtl_demod)
        results_demod = compare(golden_demod, rtl_demod, "FM Demod output")
    except FileNotFoundError:
        print("[Compare] Demod comparison files not found, skipping per-stage debug.")

    plot_comparison(results_deemph, results_demod)

    print("=" * 55)

if __name__ == "__main__":
    main()