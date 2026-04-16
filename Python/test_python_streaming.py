
import numpy as np
import csv
from fm_sdr_prototype import get_audio_source, fm_transmit

def compare_vals(iq_raw, filename="dc_offset_comparison.csv"):
    ref_bi, ref_bq, ref_i, ref_q = test_dc_offset_python(iq_raw)
    hw_bi, hw_bq, hw_i, hw_q = test_dc_offset_hw(iq_raw)

    with open(filename, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow([
            "n",
            "bias_i_ref", "bias_i_hw", "bias_i_abs_diff",
            "bias_q_ref", "bias_q_hw", "bias_q_abs_diff",
            "corr_i_ref", "corr_i_hw", "corr_i_abs_diff",
            "corr_q_ref", "corr_q_hw", "corr_q_abs_diff",
        ])
        for n in range(len(iq_raw)):
            w.writerow([
                n,
                ref_bi[n], hw_bi[n], abs(ref_bi[n] - hw_bi[n]),
                ref_bq[n], hw_bq[n], abs(ref_bq[n] - hw_bq[n]),
                ref_i[n], hw_i[n], abs(ref_i[n] - hw_i[n]),
                ref_q[n], hw_q[n], abs(ref_q[n] - hw_q[n]),
            ])
    print(f"[CSV] Wrote {len(iq_raw)} rows to {filename}")

# Test functions for streaming DC Offset Removal
def test_dc_offset_python(iq_signal):
    dc_bias_i_list = []
    dc_bias_q_list = []
    corrected_i_list = []
    corrected_q_list = []

    for i in range(len(iq_signal)):
        window = iq_signal[:i+1]
        mean_i = np.mean(window.real)
        mean_q = np.mean(window.imag)

        sample = iq_signal[i]
        corrected_i = sample.real - mean_i
        corrected_q = sample.imag - mean_q

        dc_bias_i_list.append(mean_i)
        dc_bias_q_list.append(mean_q)
        corrected_i_list.append(corrected_i)
        corrected_q_list.append(corrected_q)

    return dc_bias_i_list, dc_bias_q_list, corrected_i_list, corrected_q_list

def test_dc_offset_hw(iq_signal):
    dc_bias_i_list = []
    dc_bias_q_list = []
    corrected_i_list = []
    corrected_q_list = []

    running_mean_i = 0.0
    running_mean_q = 0.0

    for i in range(len(iq_signal)):
        signal = iq_signal[i]

        next_mean_i = running_mean_i + (signal.real - running_mean_i) / 2048
        next_mean_q = running_mean_q + (signal.imag - running_mean_q) / 2048

        corrected_i = signal.real - next_mean_i
        corrected_q = signal.imag - next_mean_q

        dc_bias_i_list.append(next_mean_i)
        dc_bias_q_list.append(next_mean_q)
        corrected_i_list.append(corrected_i)
        corrected_q_list.append(corrected_q)

        running_mean_i = next_mean_i
        running_mean_q = next_mean_q

    return dc_bias_i_list, dc_bias_q_list, corrected_i_list, corrected_q_list

# MAIN
source_audio, audio_sample_rate = get_audio_source(use_microphone=True)
iq_raw, time_axis, sdr_sample_rate = fm_transmit(source_audio, audio_sample_rate)
compare_vals(iq_raw, filename="dc_offset_comparison.csv")