`timescale 1ns/1ps

`ifndef DECIMATION_IF
`define DECIMATION_IF

`include "../include/types.sv"
import types::*;

interface decimation_if;

    // INPUT — from lpf_wrapper (18-bit DATA_DW)
    logic signed [DATA_DW-1:0] lpf_i, lpf_q;
    logic lpf_valid;

    // OUTPUT — to fm_demodulate (16-bit to match fm_demodulate_if)
    logic signed [15:0] decim_i, decim_q;
    logic decim_valid;

    modport decimation_inst (
        input  lpf_i, lpf_q, lpf_valid,
        output decim_i, decim_q, decim_valid
    );

    modport decimation_tb (
        input  decim_i, decim_q, decim_valid,
        output lpf_i, lpf_q, lpf_valid
    );

endinterface

`endif
