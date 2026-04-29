
`timescale 1ns / 1ps
`include "../include/types.sv"
import types::*;
`include "../include/divwrapper_if.vh"

module divwrapper (
    input logic clk, rst,
    divwrapper_if.div divif
);

    logic s_axis_divisor_tvalid, s_axis_dividend_tvalid, m_axis_dout_tvalid;
    logic [31:0] s_axis_dividend_tdata; // 29 bits for dividend aligned to 32
    logic [23:0] s_axis_divisor_tdata;  // 18 bits for divisor aligned to 24
    logic [55:0] m_axis_dout_tdata;     // 32 bits for quotient + 24 bits for remainder

    div your_instance_name (
        .aclk(clk),                                       // input wire aclk
        .aresetn(~rst),                                   // input wire aresetn (active low)
        .s_axis_divisor_tvalid(s_axis_divisor_tvalid),    // input wire s_axis_divisor_tvalid
        .s_axis_divisor_tdata(s_axis_divisor_tdata),      // input wire [23:0] s_axis_divisor_tdata
        .s_axis_dividend_tvalid(s_axis_dividend_tvalid),  // input wire s_axis_dividend_tvalid
        .s_axis_dividend_tdata(s_axis_dividend_tdata),    // input wire [31:0] s_axis_dividend_tdata
        .m_axis_dout_tvalid(m_axis_dout_tvalid),          // output wire m_axis_dout_tvalid
        .m_axis_dout_tdata(m_axis_dout_tdata)             // output wire [55:0] m_axis_dout_tdata
    );

    always_comb begin : assignInputs
        s_axis_dividend_tvalid = divif.dividend_valid;
        s_axis_divisor_tvalid  = divif.divisor_valid;
        s_axis_dividend_tdata = {{3{divif.dividend_data[DATA_DW-1]}}, divif.dividend_data, {11{1'b0}}}; // sign extend 3 bits, 18 bits data, 11 bits zero shifted
        s_axis_divisor_tdata  = {{6{divif.divisor_data[DATA_DW-1]}}, divif.divisor_data}; // sign extend 6 bits, 18 bits data

        divif.out_valid = m_axis_dout_tvalid;
        divif.out_data  = m_axis_dout_tdata[52:24]; // take the quotient part (29 bits)
    end

endmodule