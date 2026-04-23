
`timescale 1ns/1ps

`ifndef DC_OFFSET_IF
`define DC_OFFSET_IF

`include "../include/types.sv"
import types::*;

interface dc_offset_if;

    // INPUT
    logic [SAMPLE_DW-1:0] sample_i, sample_q;
    logic sample_valid;

    // OUTPUT
    logic signed [DATA_DW-1:0] corr_i, corr_q;
    logic corr_valid;

    modport dc_offset_inst (
        input sample_i, sample_q, sample_valid,
        output corr_i, corr_q, corr_valid
    );

    modport dc_offset_tb (
        input corr_i, corr_q, corr_valid,
        output sample_i, sample_q, sample_valid
    );
    
endinterface

`endif