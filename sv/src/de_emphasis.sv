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

    // Fixed-point coefficients (Q0.16)
    // alpha ≈ 0.9997 → 65518, (1 - alpha) → 18
    localparam logic [15:0] ALPHA_FP        = 16'd65518;
    localparam logic [15:0] ONE_MINUS_ALPHA = 16'd18;

    // Internal signals
    logic signed [15:0]  y_prev;  // Previous output y[n-1]
    logic signed [32:0]  acc;     // Accumulator (wide for multiply + add)
    logic signed [15:0]  y_curr;  // Current output y[n]

    // Combinational de-emphasis filter:
    // y[n] = alpha*y[n-1] + (1-alpha)*x[n]
    always_comb begin : deEmphasisMath
        acc = ($signed({1'b0, ALPHA_FP})        * $signed(y_prev))          // alpha * y[n-1]
            + ($signed({1'b0, ONE_MINUS_ALPHA}) * $signed(deif.audio_in));  // (1-alpha) * x[n]

        y_curr = acc[31:16];  // Remove Q0.16 scaling
    end

    // Sequential logic: update state and outputs
    always_ff @(posedge clk, negedge n_rst) begin : deEmphasisReg
        if (~n_rst) begin
            y_prev               <= '0;    
            deif.audio_out       <= '0;    
            deif.audio_out_valid <= 1'b0;  
        end else begin
            deif.audio_out_valid <= deif.audio_valid;  

            if (deif.audio_valid) begin
                y_prev <= y_curr;  // Store current output for next cycle

                // Sign-extend 16-bit result to PCM_IN_W (18-bit)
                deif.audio_out <= {{(PCM_IN_W-16){y_curr[15]}}, y_curr};
            end
        end
    end

endmodule