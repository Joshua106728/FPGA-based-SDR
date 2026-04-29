`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/de_emphasis_if.vh"

module de_emphasis
import types::*;
(
    input  logic clk,
    input  logic n_rst,
    de_emphasis_if.de_emphasis_inst deif
);

    // Q0.16 coeffs for y[n] = a*y[n-1] + (1-a)*x[n]
    localparam logic [15:0] ALPHA_FP        = 16'd65518;
    localparam logic [15:0] ONE_MINUS_ALPHA = 16'd18;

    // state + math
    logic signed [15:0] y_prev;   // y[n-1]
    logic signed [32:0] acc;      // mult + add
    logic signed [15:0] y_curr;   // y[n]

    // compute next sample
    always_comb begin
        acc = ($signed({1'b0, ALPHA_FP})        * $signed(y_prev))
            + ($signed({1'b0, ONE_MINUS_ALPHA}) * $signed(deif.audio_in));

        // back to 16-bit (drop frac)
        y_curr = acc[31:16];
    end

    // update state + outputs
    always_ff @(posedge clk, negedge n_rst) begin
        if (~n_rst) begin
            y_prev               <= '0;
            deif.audio_out       <= '0;
            deif.audio_out_valid <= 1'b0;
        end else begin
            deif.audio_out_valid <= deif.audio_valid;

            if (deif.audio_valid) begin
                y_prev <= y_curr;

                // sign extend 16b → PCM width
                deif.audio_out <= {{(PCM_IN_W-16){y_curr[15]}}, y_curr};
            end
        end
    end

endmodule
