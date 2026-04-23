
`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/rf_cdc_if.vh"

module rf_cdc 
import types::*;
(
    input logic fpga_clk, n_rst,
    rf_cdc_if.rf_cdc_inst rfif
);
    // declare internal signals
    typedef struct packed {
        logic ws_clk;
        logic bit_clk;
    } rf_sync;
    rf_sync ff1, ff2, ff3;

    logic pending_frame, new_frame, can_sample;
    logic [SHIFT_LEN-1:0] shift, next_shift;

    // ************************************************************************
    // START THE CODE
    // ************************************************************************

    // Synchronization
    always_comb begin : assignFF1
        ff1.ws_clk = rfif.ws;
        ff1.bit_clk = rfif.sck;
    end

    always_ff @(posedge fpga_clk, negedge n_rst) begin : FF1_TO_FF2
        if (~n_rst) ff2 <= '0;
        else        ff2 <= ff1;
    end

    always_ff @(posedge fpga_clk, negedge n_rst) begin : FF2_TO_FF3
        if (~n_rst) ff3 <= '0;
        else        ff3 <= ff2;
    end

    // Edge detection
    assign can_sample = ff2.bit_clk & ~ff3.bit_clk;

    always_ff @(posedge fpga_clk, negedge n_rst) begin : whenToClear
        if (~n_rst) begin
            pending_frame <= 1'b0;
            new_frame <= 1'b0;
        end
        else if (~ff2.ws_clk & ff3.ws_clk) begin
            pending_frame <= 1'b1;
            new_frame <= 1'b0;
        end
        else if (pending_frame & can_sample) begin
            pending_frame <= 1'b0;
            new_frame <= 1'b1;
        end
        else begin
            pending_frame <= pending_frame;
            new_frame <= 1'b0;
        end
    end

    // SIPO Shift Register
    always_ff @(posedge fpga_clk, negedge n_rst) begin : sipoNextLogic
        if (~n_rst) begin
            rfif.sample_i <= '0;
            rfif.sample_q <= '0;
            rfif.sample_valid <= 1'b0;
            shift <= '0;
        end
        else if (new_frame) begin
            rfif.sample_i <= shift[SHIFT_LEN-1:SHIFT_LEN/2];
            rfif.sample_q <= shift[SHIFT_LEN/2-1:0];
            rfif.sample_valid <= 1'b1;
            shift <= {15'b0, rfif.sd};
        end
        else begin
            rfif.sample_i <= '0;
            rfif.sample_q <= '0;
            rfif.sample_valid <= 1'b0;
            shift <= next_shift;
        end
    end

    always_comb begin : sipoShift
        next_shift = shift;
        if (can_sample) next_shift = {next_shift[SHIFT_LEN-2:0], rfif.sd};
    end

endmodule