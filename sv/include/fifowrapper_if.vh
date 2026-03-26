
`timescale 1ns/1ps

`ifndef FIFOWRAPPER_IF
`define FIFOWRAPPER_IF

`include "../include/types.sv"
import types::*;

interface fifowrapper_if;

    logic [DW-1:0] wr_data, rd_data;
    logic wr_en, rd_en, full, empty, valid, can_read, can_write;

    modport fifo_inst (
        input wr_data, wr_en, rd_en,
        output rd_data, full, empty, valid, can_read, can_write
    );

    modport fifo_tb (
        input rd_data, full, empty, valid, can_read, can_write,
        output wr_data, wr_en, rd_en
    );
    
endinterface

`endif