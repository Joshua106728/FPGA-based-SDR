`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/decimation_if.vh"

module decimation
import types::*;
#(
    parameter int DECIM_FACTOR = 6
)(
    input  logic clk,
    input  logic n_rst,
    decimation_if.decimation_inst decimif
);

    // simple mod-N counter for decimation
    logic [2:0] count, next_count;

    // only pass every Nth valid sample
    logic keep;
    assign keep = decimif.demod_valid && (count == 3'd0);

    // next count: increment on valid, wrap at DECIM_FACTOR
    always_comb begin
        next_count = count;

        if (decimif.demod_valid) begin
            if (count == DECIM_FACTOR - 1)
                next_count = 3'd0;
            else
                next_count = count + 3'd1;
        end
    end

    // counter register
    always_ff @(posedge clk, negedge n_rst) begin
        if (!n_rst)
            count <= 3'd0;
        else
            count <= next_count;
    end

    // output logic: latch only when we keep the sample
    always_ff @(posedge clk, negedge n_rst) begin
        if (!n_rst) begin
            decimif.decim_sample <= '0;
            decimif.decim_valid <= 1'b0;
        end else begin
            decimif.decim_valid <= keep;

            if (keep) begin
                // drop 2 LSBs → 18b to 16b
                decimif.decim_sample <= decimif.demod_sample[DATA_DW-1 -: 16];
            end
        end
    end

endmodule
