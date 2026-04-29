`timescale 1ns / 10ps
`include "../include/types.sv"
`include "../include/rf_cdc_if.vh"
`include "../include/dc_offset_if.vh"
`include "../include/lpf_wrapper_if.vh"
`include "../include/decimation_if.vh"
`include "../include/fm_demodulate_if.vh"
`include "../include/de_emphasis_if.vh"
`include "../include/i2s_if.vh"

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
    // ---- Internal connections ----

    // RF Front End
    rf_cdc_if rfif();
    assign rfif.ws = rf_ws;
    assign rfif.sck = rf_sck;
    assign rfif.sd = rf_sd;

    // DC Offset
    dc_offset_if dcif();
    assign dcif.sample_i = rfif.sample_i;
    assign dcif.sample_q = rfif.sample_q;
    assign dcif.sample_valid = rfif.sample_valid;

    // Low Pass Filter
    lpf_wrapper_if lpfif();
    assign lpfif.corr_i = dcif.corr_i;
    assign lpfif.corr_q = dcif.corr_q;
    assign lpfif.corr_valid = dcif.corr_valid;

    // Decimation
    decimation_if decimif();
    assign decimif.lpf_i = lpfif.lpf_i;
    assign decimif.lpf_q = lpfif.lpf_q;
    assign decimif.lpf_valid = lpfif.lpf_valid;

    // FM Demodulate
    fm_demodulate_if fdif();
    assign fdif.i_i = decimif.decim_i;
    assign fdif.i_q = decimif.decim_q;
    assign fdif.i_valid = decimif.decim_valid;

    // De-emphasis
    de_emphasis_if deif();
    assign deif.audio_in = fdif.o_audio;
    assign deif.audio_valid = fdif.o_valid;

    // I2S TX
    i2s_if i2sif();
    assign i2sif.sample_q18 = deif.audio_out;
    assign i2sif.sample_valid = deif.audio_out_valid;

    assign bt_ws  = i2sif.i2s_ws;
    assign bt_sck = i2sif.i2s_bclk;
    assign bt_sd  = i2sif.i2s_sd;

    // Random LED
    assign led1 = rf_sd;
    assign led2 = bt_sd;
    assign led3 = 1'b0;
    assign led4 = 1'b1;

    // Debugging RF --> FPGA
    // KEEP prevents synthesis from merging these back into the port/IBUF nets.
    // Registered into fpga_clk domain so the ILA has a clean FF net to tap.
    // (* mark_debug = "true", KEEP = "TRUE" *) logic dbg_rf_ws;
    // (* mark_debug = "true", KEEP = "TRUE" *) logic dbg_rf_sck;
    // (* mark_debug = "true", KEEP = "TRUE" *) logic dbg_rf_sd;

    // (* mark_debug = "true", KEEP = "TRUE" *) logic [SAMPLE_DW-1:0] dbg_sample_i;
    // (* mark_debug = "true", KEEP = "TRUE" *) logic [SAMPLE_DW-1:0] dbg_sample_q;
    // (* mark_debug = "true", KEEP = "TRUE" *) logic dbg_sample_valid;

    // always_ff @(posedge fpga_clk) begin
    //     dbg_rf_ws  <= rf_ws;
    //     dbg_rf_sck <= rf_sck;
    //     dbg_rf_sd  <= rf_sd;
    // end

    // assign dbg_sample_i     = rfif.sample_i;
    // assign dbg_sample_q     = rfif.sample_q;
    // assign dbg_sample_valid = rfif.sample_valid;

    // ---- Modules ----

    // RF Front End
    rf_cdc u_rf_cdc (.fpga_clk(fpga_clk), .n_rst(n_rst), .rfif(rfif));

    // DC Offset
    dc_offset u_dc_offset (.clk(fpga_clk), .n_rst(n_rst), .dcif(dcif));

    // Low Pass Filter
    lpf_wrapper u_lpf_wrapper (.clk(fpga_clk), .n_rst(n_rst), .lpfif(lpfif));

    // Decimation
    decimation #(.DECIM_FACTOR(6)) u_decimation (.clk(fpga_clk), .n_rst(n_rst), .decimif(decimif));

    // FM Demodulate
    fm_demodulate u_fm_demodulate (.clk(fpga_clk), .n_rst(n_rst), .fdif(fdif));

    // De-emphasis
    de_emphasis u_de_emphasis (.clk(fpga_clk), .n_rst(n_rst), .deif(deif));

    // I2S TX
    i2s_master_tx u_i2s_master_tx (.clk(fpga_clk), .n_rst(n_rst), .i2sif(i2sif));

endmodule
