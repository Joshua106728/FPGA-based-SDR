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
    localparam SCALE_OUT = 18'b00_0011_1010_1001_1000; // 15000 ~ 32767 * Fs/(2*pi*75kHz)
    localparam DECIM_FACTOR = 5;  // Changed from 6: 220.5 kHz / 5 = 44.1 kHz (was 36.75 kHz)

    // i2s output
    parameter int PCM_IN_W = 18;
    parameter int PCM_W = 16;

endpackage

`endif 