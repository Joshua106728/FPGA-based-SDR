
`timescale 1ns/1ps

`ifndef FM_DEMODULATE_IF
`define FM_DEMODULATE_IF

`include "../include/types.sv"
import types::*;

interface fm_demodulate_if;

    // INPUT
    logic signed [DATA_DW-1:0] lpf_i, lpf_q;
    logic lpf_valid;

    // OUTPUT
    logic signed [DATA_DW-1:0] demod_sample;
    logic demod_valid;

    modport fm_demodulate_inst (
        input lpf_i, lpf_q, lpf_valid,
        output demod_sample, demod_valid
    );

    modport fm_demodulate_tb (
        input demod_sample, demod_valid,
        output lpf_i, lpf_q, lpf_valid
    );
    
endinterface

`endif