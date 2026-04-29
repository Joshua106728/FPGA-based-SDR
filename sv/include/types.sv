`timescale 1ns / 1ps

`ifndef TYPES
`define TYPES

package types;
    // rf front end
    localparam SAMPLE_DW = 8;
    localparam SHIFT_LEN = 16; // SAMPLE_DW * 2

    // fpga processing
    localparam DATA_DW = 18;
    localparam FRACTIONAL_BITS = 10;
    localparam RUNNING_SUM_ALPHA = 11;

    // i2s output
    parameter int PCM_IN_W = 18;
    parameter int PCM_W = 16;

endpackage

`endif 