`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/de_emphasis_if.vh"

// ============================================================
// de_emphasis.sv
// ============================================================
// Applies FM de-emphasis to undo the pre-emphasis boost added
// at the transmitter, restoring a flat frequency response.
//
// Pipeline position:
//   fm_demodulate → [de_emphasis] → i2s_master_tx
//
// The de-emphasis filter is a first-order IIR low-pass filter
// defined by the standard 75 µs time constant (North America):
//
//   y[n] = alpha * y[n-1] + (1 - alpha) * x[n]
//
// where:
//   alpha = exp(-1 / (tau * fs))
//         = exp(-1 / (75e-6 * 44100))
//         ≈ 0.9997
//
// Python equivalent:
//   decay = np.exp(-1.0 / (DE_EMPHASIS_TIME_CONSTANT * sample_rate))
//   b = [1.0 - decay]
//   a = [1.0, -decay]
//   audio_out = signal.lfilter(b, a, audio_in)
//
// Fixed-point implementation:
//   tau    = 75e-6 s
//   fs     = 44100 Hz
//   alpha  = exp(-1/(75e-6 * 44100)) ≈ 0.99970
//
//   We represent alpha in Q0.16 fixed point:
//     ALPHA_FP = round(0.99970 * 2^16) = 65518
//     ONE_MINUS_ALPHA_FP = 2^16 - ALPHA_FP = 18
//
//   Each cycle (when input is valid):
//     acc[n] = ALPHA_FP * y[n-1] + ONE_MINUS_ALPHA_FP * x[n]
//     y[n]   = acc[n] >> 16   (remove Q0.16 scale factor)
//
// Bit-width note:
//   Input  — 16-bit signed from fm_demodulate (audio_in)
//   Internal accumulator — 16 + 16 + 1 = 33 bits to prevent overflow
//   Output — 18-bit signed (PCM_IN_W) to match i2s_if sample_q18
//             sign-extended from 16-bit after shift, then padded to 18
// ============================================================

module de_emphasis
import types::*;
(
    input  logic clk,
    input  logic n_rst,
    de_emphasis_if.de_emphasis_inst deif
);

    // --------------------------------------------------------
    // Fixed-point alpha coefficients (Q0.16 format)
    // alpha           = exp(-1 / (75e-6 * 44100)) ≈ 0.999697
    // ALPHA_FP        = floor(0.999697 * 65536)   = 65518
    // ONE_MINUS_ALPHA = 65536 - 65518             = 18
    // --------------------------------------------------------
    localparam logic [15:0] ALPHA_FP        = 16'd65518;
    localparam logic [15:0] ONE_MINUS_ALPHA = 16'd18;

    // --------------------------------------------------------
    // Internal signals
    // acc is wide enough to hold the full product before shifting:
    //   16-bit coeff * 16-bit signal = 32 bits, plus 1 for addition
    // --------------------------------------------------------
    logic signed [15:0]  y_prev;          // previous output y[n-1], 16-bit
    logic signed [32:0]  acc;             // full-width accumulator
    logic signed [15:0]  y_curr;          // current output before width extension

    // --------------------------------------------------------
    // Combinational: compute y[n] = alpha*y[n-1] + (1-alpha)*x[n]
    //
    // Both multiplications are unsigned coefficient * signed signal.
    // We cast carefully to preserve sign through the multiply.
    // --------------------------------------------------------
    always_comb begin : deEmphasisMath
        // alpha * y[n-1]: 16-bit coeff * 16-bit signed → 32-bit signed
        // (1-alpha) * x[n]: 16-bit coeff * 16-bit signed → 32-bit signed
        // sum is 33-bit to hold carry
        acc = ($signed({1'b0, ALPHA_FP})        * $signed(y_prev))
            + ($signed({1'b0, ONE_MINUS_ALPHA}) * $signed(deif.audio_in));

        // Shift right 16 to remove Q0.16 scale factor → back to 16-bit signal
        y_curr = acc[31:16];
    end

    // --------------------------------------------------------
    // Sequential: register y[n-1] and drive outputs
    // Output is only updated and valid when input is valid,
    // matching the single-cycle pulse convention of other modules.
    // --------------------------------------------------------
    always_ff @(posedge clk, negedge n_rst) begin : deEmphasisReg
        if (~n_rst) begin
            y_prev                 <= '0;
            deif.audio_out         <= '0;
            deif.audio_out_valid   <= 1'b0;
        end else begin
            deif.audio_out_valid <= deif.audio_valid;
            if (deif.audio_valid) begin
                y_prev         <= y_curr;
                // Sign-extend 16-bit result to PCM_IN_W (18-bit) for i2s_master_tx
                deif.audio_out <= {{(PCM_IN_W-16){y_curr[15]}}, y_curr};
            end
        end
    end

endmodule
