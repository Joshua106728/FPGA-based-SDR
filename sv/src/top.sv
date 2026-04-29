`timescale 1ns / 10ps
`include "../include/types.sv"
`include "../include/rf_cdc_if.vh"
`include "../include/dc_offset_if.vh"
`include "../include/lpf_wrapper_if.vh"
`include "../include/fm_demodulate_if.vh"
`include "../include/decimation_if.vh"
`include "../include/de_emphasis_if.vh"
`include "../include/i2s_if.vh"

// ============================================================
// top.sv
// ============================================================
// Full pipeline (correct order):
//   RF tuner → rf_cdc → dc_offset → lpf_wrapper
//           → fm_demodulate → decimation → de_emphasis
//           → i2s_master_tx → ESP32
// ============================================================

module top
import types::*;
(
    // FPGA Interface
    input logic fpga_clk,
    input logic n_rst,

    // RF Interface
    input logic rf_ws,
    input logic rf_sck,
    input logic rf_sd,

    // Random LED
    output logic led1,
    output logic led2,
    output logic led3,
    output logic led4,

    // Bluetooth Interface
    output logic bt_ws,
    output logic bt_sck,
    output logic bt_sd
);

    // ---- Interface instantiations ----

    // Stage 1: RF CDC
    rf_cdc_if rfif();
    assign rfif.ws  = rf_ws;
    assign rfif.sck = rf_sck;
    assign rfif.sd  = rf_sd;

    // Stage 2: DC Offset
    dc_offset_if dcif();
    assign dcif.sample_i     = rfif.sample_i;
    assign dcif.sample_q     = rfif.sample_q;
    assign dcif.sample_valid = rfif.sample_valid;

    // Stage 3: Low Pass Filter
    lpf_wrapper_if lpfif();
    assign lpfif.corr_i     = dcif.corr_i;
    assign lpfif.corr_q     = dcif.corr_q;
    assign lpfif.corr_valid = dcif.corr_valid;

    // Stage 4: FM Demodulate
    // Truncate 18-bit LPF output to 16-bit for fm_demodulate_if
    fm_demodulate_if fdif();
    assign fdif.i_i     = lpfif.lpf_i[DATA_DW-1 -: 16];
    assign fdif.i_q     = lpfif.lpf_q[DATA_DW-1 -: 16];
    assign fdif.i_valid = lpfif.lpf_valid;

    // Stage 5: Decimation (220500 → 36750 Hz)
    // FM demod outputs mono audio — feed into decimation audio_in
    decimation_if decimif();
    assign decimif.demod_sample       = fdif.o_audio;
    assign decimif.demod_valid = fdif.o_valid;

    // Stage 6: De-emphasis
    de_emphasis_if deif();
    assign deif.audio_in    = decimif.decim_sample;
    assign deif.audio_valid = decimif.decim_valid;

    // Stage 7: I2S TX
    i2s_if i2sif();
    assign i2sif.sample_q18   = deif.audio_out;
    assign i2sif.sample_valid = deif.audio_out_valid;

    assign bt_ws  = i2sif.i2s_ws;
    assign bt_sck = i2sif.i2s_bclk;
    assign bt_sd  = i2sif.i2s_sd;

    // LEDs
    assign led1 = rf_sd;
    assign led2 = bt_sd;
    assign led3 = 1'b0;
    assign led4 = 1'b1;

    // ---- Module instantiations ----

    rf_cdc u_rf_cdc (
        .fpga_clk(fpga_clk), .n_rst(n_rst), .rfif(rfif)
    );

    dc_offset u_dc_offset (
        .clk(fpga_clk), .n_rst(n_rst), .dcif(dcif)
    );

    lpf_wrapper u_lpf_wrapper (
        .clk(fpga_clk), .n_rst(n_rst), .lpfif(lpfif)
    );

    fm_demodulate u_fm_demodulate (
        .clk(fpga_clk), .n_rst(n_rst), .fdif(fdif)
    );

    decimation u_decimation (
        .clk(fpga_clk), .n_rst(n_rst), .decimif(decimif)
    );

    de_emphasis u_de_emphasis (
        .clk(fpga_clk), .n_rst(n_rst), .deif(deif)
    );

    i2s_master_tx u_i2s_master_tx (
        .clk(fpga_clk), .n_rst(n_rst), .i2sif(i2sif)
    );

endmodule
