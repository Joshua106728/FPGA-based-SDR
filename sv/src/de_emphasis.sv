`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/de_emphasis_if.vh"

module de_emphasis
import types::*;
(
    input logic clk,
    input logic n_rst,
    de_emphasis_if.de_emphasis_inst deif
);
    // Q0.16 coeffs for y[n] = a*y[n-1] + (1-a)*x[n]
    localparam logic [15:0] ALPHA_FP        = 16'd65518;
    localparam logic [15:0] ONE_MINUS_ALPHA = 16'd18;

    // state + math — all 18-bit to match DATA_DW throughout the pipeline
    logic signed [DATA_DW-1:0] y_prev;  // y[n-1]
    logic signed [35:0]        acc;     // {1'b0,coeff}(17) x data(18) = 35-bit each; sum needs 36-bit
    logic signed [DATA_DW-1:0] y_curr;  // y[n]

    // compute next sample
    always_comb begin
        acc = ($signed({1'b0, ALPHA_FP})        * $signed(y_prev))
            + ($signed({1'b0, ONE_MINUS_ALPHA}) * $signed(deif.audio_in));

        // drop the 16 Q0.16 fractional bits → 18-bit result
        y_curr = acc[33:16];
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
                y_prev         <= y_curr;
                deif.audio_out <= y_curr; 
            end
        end
    end

endmodule
