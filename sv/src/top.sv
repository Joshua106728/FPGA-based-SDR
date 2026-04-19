
`timescale 1ns / 10ps
`include "../include/types.sv"
`include "../include/rf_cdc_if.vh"

module top
import types::*;
(
    // FPGA Interface
    input  logic fpga_clk,
    input  logic n_rst

    // // RF Interface
    // input  logic rf_ws,
    // input  logic rf_sck,
    // input  logic rf_sd,

    // // Bluetooth Interface
    // output logic dac_mclk,
    // output logic dac_nrst,
    // input  logic dac_fclk,
    // input  logic dac_bclk,
    // output logic dac_data
);
    // ---- Internal connections ----
    // RF Front End
    rf_cdc_if rfif();
    // assign rfif.ws = rf_ws;
    // assign rfif.sck = rf_sck;
    // assign rfif.sd = rf_sd;

    // DC Offset
    dc_offset_if dcif();
    // assign dcif.sample_i = rfif.sample_i;
    // assign dcif.sample_q = rfif.sample_q;
    // assign dcif.sample_valid = rfif.sample_valid;

    // ---- Modules ----
    // RF Front End
    rf_cdc u_rf_cdc (.fpga_clk(fpga_clk), .n_rst(n_rst), .rfif(rfif));
     
     // DC Offset
    dc_offset u_dc_offset (.clk(fpga_clk), .n_rst(n_rst), .dcif(dcif));

endmodule