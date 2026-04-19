
`timescale 1ns/1ps

`ifndef LPF_WRAPPER_IF
`define LPF_WRAPPER_IF

`include "../include/types.sv"
import types::*;

interface lpf_wrapper_if;

    // INPUT
    logic [DATA_DW-1:0] corr_i, corr_q;
    logic corr_valid;

    // OUTPUT
    logic signed [DATA_DW-1:0] lpf_i, lpf_q;
    logic lpf_valid;

    modport lpf_wrapper_inst (
        input corr_i, corr_q, corr_valid,
        output lpf_i, lpf_q, logic lpf_i_valid, lpf_q_valid
    );

    modport lpf_wrapper_tb (
        input lpf_i, lpf_q, logic lpf_i_valid, lpf_q_valid,
        output corr_i, corr_q, corr_valid
    );
    
endinterface

`endif