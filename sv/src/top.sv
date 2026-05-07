
`timescale 1ns / 10ps
`include "../include/types.sv"
`include "../include/rf_cdc_if.vh"
`include "../include/dc_offset_if.vh"
`include "../include/lpf_wrapper_if.vh"
`include "../include/fm_demodulate_if.vh"
`include "../include/decim_if.vh"
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
    fm_demodulate_if fmif();
    assign fmif.lpf_i     = lpfif.lpf_i;
    assign fmif.lpf_q     = lpfif.lpf_q;
    assign fmif.lpf_valid = lpfif.lpf_valid;

    // Stage 5: Decimation (220500 → 36750 Hz)
    decim_if decimif();
    assign decimif.demod_sample = fmif.demod_sample;
    assign decimif.demod_valid = fmif.demod_valid;

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
    rf_cdc u_rf_cdc (.fpga_clk(fpga_clk), .n_rst(n_rst), .rfif(rfif));
    dc_offset u_dc_offset (.clk(fpga_clk), .n_rst(n_rst), .dcif(dcif));
    lpf_wrapper u_lpf_wrapper (.clk(fpga_clk), .n_rst(n_rst), .lpfif(lpfif));
    fm_demodulate u_fm_demodulate (.clk(fpga_clk), .n_rst(n_rst), .fmif(fmif));
    decim u_decimation (.clk(fpga_clk), .n_rst(n_rst), .decimif(decimif));
    de_emphasis u_de_emphasis (.clk(fpga_clk), .n_rst(n_rst), .deif(deif));
    // Enable a deterministic test pattern on the I2S output for bring-up/debug.
    // Set USE_TEST_PATTERN=0 to revert to streaming the DSP pipeline output.
    i2s_master_tx #(.USE_TEST_PATTERN(1'b1)) u_i2s_master_tx (.clk(fpga_clk), .n_rst(n_rst), .i2sif(i2sif));

    // ---- ILA debug wires (one per inter-stage interface) ----
    logic [SAMPLE_DW-1:0] dbg_sample_i, dbg_sample_q;
    logic                 dbg_sample_valid;
    logic [DATA_DW-1:0]   dbg_corr_i, dbg_corr_q;
    logic                 dbg_corr_valid;
    logic [DATA_DW-1:0]   dbg_demod_sample;
    logic                 dbg_demod_valid;
    logic [DATA_DW-1:0]   dbg_audio_out;
    logic                 dbg_audio_out_valid;

    assign dbg_sample_i        = rfif.sample_i;
    assign dbg_sample_q        = rfif.sample_q;
    assign dbg_sample_valid    = rfif.sample_valid;
    assign dbg_corr_i          = dcif.corr_i;
    assign dbg_corr_q          = dcif.corr_q;
    assign dbg_corr_valid      = dcif.corr_valid;
    assign dbg_demod_sample    = fmif.demod_sample;
    assign dbg_demod_valid     = fmif.demod_valid;
    assign dbg_audio_out       = deif.audio_out;
    assign dbg_audio_out_valid = deif.audio_out_valid;

    // probe0  [2:0]  — {rf_ws, rf_sck, rf_sd}       raw RF pins
    // probe1  [7:0]  — sample_i                       RF CDC out
    // probe2  [7:0]  — sample_q                       RF CDC out
    // probe3  [0:0]  — sample_valid                   RF CDC out
    // probe4  [17:0] — corr_i                         DC offset out
    // probe5  [17:0] — corr_q                         DC offset out
    // probe6  [0:0]  — corr_valid                     DC offset out
    // probe7  [17:0] — demod_sample                   FM demod out
    // probe8  [0:0]  — demod_valid                    FM demod out
    // probe9  [17:0] — audio_out                      de-emphasis out
    // probe10 [0:0]  — audio_out_valid                de-emphasis out
    // probe11 [2:0]  — {bt_ws, bt_sck, bt_sd}         raw BT pins
    ila_debug u_ila (
        .clk     (fpga_clk),
        .probe0  ({rf_ws, rf_sck, rf_sd}),
        .probe1  (dbg_sample_i),
        .probe2  (dbg_sample_q),
        .probe3  (dbg_sample_valid),
        .probe4  (dbg_corr_i),
        .probe5  (dbg_corr_q),
        .probe6  (dbg_corr_valid),
        .probe7  (dbg_demod_sample),
        .probe8  (dbg_demod_valid),
        .probe9  (dbg_audio_out),
        .probe10 (dbg_audio_out_valid),
        .probe11 ({bt_ws, bt_sck, bt_sd})
    );

endmodule
