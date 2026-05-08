`timescale 1ns/1ps

`ifndef DECIM_IF
`define DECIM_IF

`include "../include/types.sv"
import types::*;

interface decim_if;

    // INPUT — from demodulation (18-bit DATA_DW)
    logic signed [DATA_DW-1:0] demod_sample;
    logic demod_valid;

    // OUTPUT — to de-emphasis (18-bit to match fm_demodulate_if)
    logic signed [DATA_DW-1:0] decim_sample;
    logic decim_valid;

    modport decim_inst (
        input  demod_sample, demod_valid,
        output decim_sample, decim_valid
    );

    modport decim_tb (
        input  decim_sample, decim_valid,
        output demod_sample, demod_valid
    );

endinterface

`endif
