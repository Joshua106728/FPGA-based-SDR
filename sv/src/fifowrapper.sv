
`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/fifowrapper_if.vh"

module fifowrapper 
import types::*;
(
    input logic wr_clk, rd_clk, rst,
    fifowrapper_if.fifo_inst fifoif
);
    logic wr_rst_busy, rd_rst_busy;

    fifo your_instance_name (
        .rst(rst),                  // input wire rst
        .wr_clk(wr_clk),            // input wire wr_clk
        .rd_clk(rd_clk),            // input wire rd_clk
        .din(fifoif.wr_data),       // input wire [17 : 0] din
        .wr_en(fifoif.wr_en),       // input wire wr_en
        .rd_en(fifoif.rd_en),       // input wire rd_en
        .dout(fifoif.rd_data),      // output wire [17 : 0] dout
        .full(fifoif.full),         // output wire full
        .empty(fifoif.empty),       // output wire empty
        .valid(fifoif.valid),       // output wire valid
        .wr_rst_busy(wr_rst_busy),  // output wire wr_rst_busy
        .rd_rst_busy(rd_rst_busy)   // output wire rd_rst_busy
    );

    assign fifoif.can_read = ~rd_rst_busy;
    assign fifoif.can_write = ~wr_rst_busy;

endmodule