
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

    assign led1 = 1'b1;

    // Debug
    (* mark_debug = "true" *) logic dbg_rf_ws;
    (* mark_debug = "true" *) logic dbg_rf_sck;
    (* mark_debug = "true" *) logic dbg_rf_sd;

    (* mark_debug = "true" *) logic [SAMPLE_DW-1:0] dbg_sample_i;
    (* mark_debug = "true" *) logic [SAMPLE_DW-1:0] dbg_sample_q;
    (* mark_debug = "true" *) logic dbg_sample_valid;

    assign dbg_rf_ws = rf_ws;
    assign dbg_rf_sck = rf_sck;
    assign dbg_rf_sd = rf_sd;

    assign dbg_sample_i = rfif.sample_i;
    assign dbg_sample_q = rfif.sample_q;
    assign dbg_sample_valid = rfif.sample_valid;

    // I2S TX
    i2s_if i2sif();
    // assign i2sif.sample_q18 = dcif.sample_q;
    // assign i2sif.sample_valid = dcif.sample_valid;

    // ---- Modules ----
    // RF Front End
    rf_cdc u_rf_cdc (.fpga_clk(fpga_clk), .n_rst(n_rst), .rfif(rfif));
     
    // DC Offset
    // dc_offset u_dc_offset (.clk(fpga_clk), .n_rst(n_rst), .dcif(dcif));

    // I2S TX
    i2s_master_tx u_i2s_master_tx (.clk(fpga_clk), .n_rst(n_rst), .i2sif(i2sif));

endmodule