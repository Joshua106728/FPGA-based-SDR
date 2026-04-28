
`timescale 1ns / 10ps
`include "../include/types.sv"
`include "../include/rf_cdc_if.vh"
`include "../include/dc_offset_if.vh"
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
    // dc_offset_if dcif();
    // assign dcif.sample_i = rfif.sample_i;
    // assign dcif.sample_q = rfif.sample_q;
    // assign dcif.sample_valid = rfif.sample_valid;

    // // Low Pass Filter
    // lpf_wrapper_if lpfif();
    // assign lpfif.corr_i = dcif.corr_i;
    // assign lpfif.corr_q = dcif.corr_q;
    // assign lpfif.corr_valid = dcif.corr_valid;

    // Random LED
    assign led1 = bt_ws;
    assign led2 = bt_sck;
    assign led3 = bt_sd;
    assign led4 = 1'b1;

    // Debugging RF --> FPGA
    // KEEP prevents synthesis from merging these back into the port/IBUF nets.
    // Registered into fpga_clk domain so the ILA has a clean FF net to tap.
    (* mark_debug = "true", KEEP = "TRUE" *) logic dbg_rf_ws;
    (* mark_debug = "true", KEEP = "TRUE" *) logic dbg_rf_sck;
    (* mark_debug = "true", KEEP = "TRUE" *) logic dbg_rf_sd;

    (* mark_debug = "true", KEEP = "TRUE" *) logic [SAMPLE_DW-1:0] dbg_sample_i;
    (* mark_debug = "true", KEEP = "TRUE" *) logic [SAMPLE_DW-1:0] dbg_sample_q;
    (* mark_debug = "true", KEEP = "TRUE" *) logic dbg_sample_valid;

    always_ff @(posedge fpga_clk) begin
        dbg_rf_ws  <= rf_ws;
        dbg_rf_sck <= rf_sck;
        dbg_rf_sd  <= rf_sd;
    end

    assign dbg_sample_i     = rfif.sample_i;
    assign dbg_sample_q     = rfif.sample_q;
    assign dbg_sample_valid = rfif.sample_valid;

    // BT outputs unused until I2S TX is wired in
    assign bt_ws  = 1'b0;
    assign bt_sck = 1'b0;
    assign bt_sd  = 1'b0;

    // // I2S TX
    // i2s_if i2sif();
    // assign bt_ws  = i2sif.i2s_ws;
    // assign bt_sck = i2sif.i2s_bclk;
    // assign bt_sd  = i2sif.i2s_sd;

    // // Debugging FPGA --> Bluetooth
    // (* mark_debug = "true" *) logic signed [PCM_IN_W-1:0] dbg_sample_q18;
    // (* mark_debug = "true" *) logic dbg_sample_valid_bt;

    // (* mark_debug = "true" *) logic dbg_bt_ws;
    // (* mark_debug = "true" *) logic dbg_bt_sck;
    // (* mark_debug = "true" *) logic dbg_bt_sd;

    // assign dbg_sample_q18  = i2sif.sample_q18;
    // assign dbg_sample_valid_bt = i2sif.sample_valid;
    // assign dbg_bt_ws  = bt_ws;
    // assign dbg_bt_sck = bt_sck;
    // assign dbg_bt_sd  = bt_sd;

    // ---- Modules ----
    // RF Front End
    rf_cdc u_rf_cdc (.fpga_clk(fpga_clk), .n_rst(n_rst), .rfif(rfif));
     
    // DC Offset
    // dc_offset u_dc_offset (.clk(fpga_clk), .n_rst(n_rst), .dcif(dcif));

    // Low Pass Filter
    // lpf_wrapper u_lpf_wrapper (.clk(fpga_clk), .n_rst(n_rst), .lpfif(lpfif));

    // I2S TX
    // i2s_master_tx u_i2s_master_tx (.clk(fpga_clk), .n_rst(n_rst), .i2sif(i2sif));

endmodule