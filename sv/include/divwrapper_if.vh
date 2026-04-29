
`timescale 1ns/1ps

`ifndef DIVWRAPPER_IF
`define DIVWRAPPER_IF

`include "../include/types.sv"
import types::*;

interface divwrapper_if;

    logic dividend_valid, divisor_valid, out_valid;
    logic [DATA_DW-1:0] dividend_data, divisor_data, out_data;

    modport div (
        input dividend_valid, divisor_valid, dividend_data, divisor_data,
        output out_valid, out_data
    );

    modport div_tb (
        output dividend_valid, divisor_valid, dividend_data, divisor_data,
        input out_valid, out_data
    );
    
endinterface

`endif

/*

Input: dividend_valid, divisor_valid, dividend_data, divisor_data,

Output: out_valid, out_data

*/