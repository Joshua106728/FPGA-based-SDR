`timescale 1ns/1ps

`ifndef DECIMATION_IF
`define DECIMATION_IF

`include "../include/types.sv"
import types::*;

interface decimation_if;

    // INPUTS (from LPF wrapper)
    logic signed [DATA_DW-1:0] lpf_i, lpf_q;
    logic lpf_valid, lpf_ready;

    // OUTPUTS (decimated)
    logic signed [DATA_DW-1:0] dec_i, dec_q;
    logic dec_valid;

    modport decimation_inst (
        input  lpf_i, lpf_q, lpf_valid, lpf_ready,
        output dec_i, dec_q, dec_valid
    );

    modport decimation_tb (
        input  dec_i, dec_q, dec_valid,
        output lpf_i, lpf_q, lpf_valid, lpf_ready
    );

endinterface

`endif
