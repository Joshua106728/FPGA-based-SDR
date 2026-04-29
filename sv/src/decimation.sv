`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/decimation_if.vh"

// ============================================================
// decimation.sv
// ============================================================
// Downsamples the LPF output from SDR sample rate to audio rate
// by keeping 1 out of every DECIM_FACTOR valid input samples.
//
// Pipeline position:
//   lpf_wrapper → [decimation] → fm_demodulate
//
// The lpf_wrapper has already removed all energy above the audio
// bandwidth, so simply dropping 5 out of 6 samples is safe —
// no aliasing will occur.
//
// Python equivalent:
//   audio_decimated = decimate(demod_filtered, DECIMATION, ftype='fir', zero_phase=True)
//   (the FIR filtering is done by lpf_wrapper; this module only
//    performs the "keep every Nth sample" downsampling step)
//
// Bit-width note:
//   Input  — 18-bit signed (DATA_DW) from lpf_wrapper
//   Output — 16-bit signed to match fm_demodulate_if (i_i, i_q)
//   Truncation drops the 2 LSBs (least significant fractional bits)
//
// Counter width:
//   DECIM_FACTOR = 6, so counter runs 0..5 → 3 bits wide
//   Hardcoded as [2:0] to avoid $clog2
// ============================================================

module decimation
import types::*;
#(
    parameter int DECIM_FACTOR = 6  // 220500 / 36750 = 6
)(
    input  logic clk,
    input  logic n_rst,
    decimation_if.decimation_inst decimif
);

    // --------------------------------------------------------
    // Counter: 3 bits wide to hold values 0..5
    // Counts valid input samples, wraps at DECIM_FACTOR
    // --------------------------------------------------------
    logic [2:0] count, next_count;

    // keep pulses high on the sample we want to pass through
    logic keep;
    assign keep = decimif.lpf_valid && (count == 3'd0);

    always_comb begin : counterNext
        next_count = count;
        if (decimif.lpf_valid) begin
            if (count == DECIM_FACTOR - 1)
                next_count = 3'd0;
            else
                next_count = count + 3'd1;
        end
    end

    always_ff @(posedge clk, negedge n_rst) begin : counterReg
        if (~n_rst)
            count <= 3'd0;
        else
            count <= next_count;
    end

    // --------------------------------------------------------
    // Output register
    // Truncates 18-bit input to 16-bit output by dropping 2 LSBs.
    // decim_valid is a single-cycle pulse, matching the convention
    // used by dc_offset, lpf_wrapper, and rf_cdc.
    // --------------------------------------------------------
    always_ff @(posedge clk, negedge n_rst) begin : outputReg
        if (~n_rst) begin
            decimif.decim_i     <= '0;
            decimif.decim_q     <= '0;
            decimif.decim_valid <= 1'b0;
        end else begin
            decimif.decim_valid <= keep;
            if (keep) begin
                // Drop 2 LSBs: take top 16 bits of 18-bit DATA_DW sample
                decimif.decim_i <= decimif.lpf_i[DATA_DW-1 -: 16];
                decimif.decim_q <= decimif.lpf_q[DATA_DW-1 -: 16];
            end
        end
    end

endmodule
