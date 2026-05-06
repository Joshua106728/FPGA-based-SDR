`timescale 1ns/1ps

`ifndef DECIMATION_IF
`define DECIMATION_IF

`include "../include/types.sv"
import types::*;

interface decimation_if;

    // INPUT — from demodulation (18-bit DATA_DW)
    logic signed [DATA_DW-1:0] demod_sample;
    logic demod_valid;

    // OUTPUT — to de-emphasis (18-bit to match fm_demodulate_if)
    logic signed [DATA_DW-1:0] decim_sample;
    logic decim_valid;

    modport decimation_inst (
        input  demod_sample, demod_valid,
        output decim_sample, decim_valid
    );

    modport decimation_tb (
        input  decim_sample, decim_valid,
        output demod_sample, demod_valid
    );

endinterface

`endif
