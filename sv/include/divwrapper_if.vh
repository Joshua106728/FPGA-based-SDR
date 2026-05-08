
`timescale 1ns/1ps

`ifndef DIVWRAPPER_IF
`define DIVWRAPPER_IF

`include "../include/types.sv"
import types::*;

interface divwrapper_if;

    // inputs
    logic dividend_valid, divisor_valid, 
    logic [31:0] dividend_data;
    logic [24:0] divisor_data;

    // outputs
    logic out_valid, div_ready1, div_ready2;
    logic [DATA_DW-1:0] out_data;

    modport div (
        input dividend_valid, divisor_valid, dividend_data, divisor_data,
        output out_valid, div_ready1, div_ready2, out_data
    );

    modport div_tb (
        output dividend_valid, divisor_valid, dividend_data, divisor_data,
        input out_valid, div_ready1, div_ready2, out_data
    );
    
endinterface

`endif

/*

Input: dividend_valid, divisor_valid, dividend_data, divisor_data,

Output: out_valid, out_data

*/