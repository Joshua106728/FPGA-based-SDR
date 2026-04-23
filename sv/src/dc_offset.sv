
`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/dc_offset_if.vh"

module dc_offset 
import types::*;
(
    input logic clk, n_rst,
    dc_offset_if.dc_offset_inst dcif
);
    // Internal Signals
    logic signed [DATA_DW-1:0] sample_i_long, sample_q_long;
    logic signed [DATA_DW-1:0] mean_i, next_mean_i, mean_q, next_mean_q;
    logic signed [DATA_DW:0] diff_i, diff_q;
    logic signed [DATA_DW-1:0] mean_updated_i, mean_updated_q;
    logic signed [DATA_DW-1:0] corrected_i, corrected_q;

    // Convert 8-bit unsigned --> 18-bit Q7.10 format
    assign sample_i_long = {~dcif.sample_i[SAMPLE_DW-1], dcif.sample_i[SAMPLE_DW-2:0], {FRACTIONAL_BITS{'0}}};
    assign sample_q_long = {~dcif.sample_q[SAMPLE_DW-1], dcif.sample_q[SAMPLE_DW-2:0], {FRACTIONAL_BITS{'0}}};

    always_comb begin : runningMeanLogic
        next_mean_i = mean_i;
        next_mean_q = mean_q;

        if (dcif.sample_valid) begin
            // 19-bit from 18-bit subtraction
            diff_i = sample_i_long - mean_i;
            diff_q = sample_q_long - mean_q;

            // truncate back to 18 bits
            mean_updated_i = diff_i >>> RUNNING_SUM_ALPHA; // 2047 = 2^11-1 so closest it can be is 2047 off
            mean_updated_q = diff_q >>> RUNNING_SUM_ALPHA;

            if (mean_updated_i == 0 && diff_i > 0)
                mean_updated_i = 18'b1; // 1
            else if (mean_updated_i == 0 && diff_i < 0)
                mean_updated_i = 18'h3FFFF; // -1
            if (mean_updated_q == 0 && diff_q > 0)
                mean_updated_q = 18'b1; // 1
            else if (mean_updated_q == 0 && diff_q < 0)
                mean_updated_q = 18'h3FFFF; // -1

            // update running mean
            next_mean_i = mean_i + mean_updated_i;
            next_mean_q = mean_q + mean_updated_q;
            
            // apply DC offset correction
            corrected_i = sample_i_long - next_mean_i;
            corrected_q = sample_q_long - next_mean_q;
        end
    end

    always_ff @(posedge clk, negedge n_rst) begin : runningMeanReg
        if (~n_rst) begin
            mean_i <= '0;
            mean_q <= '0;
        end else begin
            mean_i <= next_mean_i;
            mean_q <= next_mean_q;
        end
    end

    always_ff @(posedge clk, negedge n_rst) begin : dcOffsetOutput
        if (~n_rst) begin
            dcif.corr_i <= '0;
            dcif.corr_q <= '0;
            dcif.corr_valid <= 1'b0;
        end else begin
            dcif.corr_i <= corrected_i;
            dcif.corr_q <= corrected_q;
            dcif.corr_valid <= dcif.sample_valid;
        end 
    end

endmodule