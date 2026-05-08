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
    // FM+LTF chain runs at rf_cdc IQ rate (ESP I2S stereo IQ word rate).
    // REQUIRED: ESP must send 220500 IQ pairs/s so decim / DECIM_FACTOR hits 44100 Hz exactly
    // (see RF_ESP32 SDR_USB_IQ_RATE_HZ 882000 / DECIMATION_FACTOR 4).
    // i2s_master_tx BCLK_STEP targets ~44.1 kHz; Bluetooth path expects 44100 as well.
    // Any IQ rate mismatch -> audio_latch vs sample_tick cadence beats -> pulsing / zipper static.
    localparam DECIM_FACTOR = 5;

    // i2s output
    parameter int PCM_IN_W = 18;
    parameter int PCM_W = 16;

endpackage

`endif 