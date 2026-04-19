
`timescale 1ns/1ps

`ifndef RF_CDC_IF
`define RF_CDC_IF

`include "../include/types.sv"
import types::*;

interface rf_cdc_if;

    // INPUT (I2S protocol from RF Front-end)
    logic ws, sck, sd;

    // OUTPUT
    logic [SAMPLE_DW-1:0] sample_i, sample_q;
    logic sample_valid;

    modport rf_cdc_inst (
        input ws, sck, sd,
        output sample_i, sample_q, sample_valid
    );

    modport rf_cdc_tb (
        input sample_i, sample_q, sample_valid,
        output ws, sck, sd
    );
    
endinterface

`endif