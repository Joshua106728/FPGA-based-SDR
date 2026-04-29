
`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/lpf_wrapper_if.vh"

module lpf_wrapper 
import types::*;
(
    input logic clk, n_rst,
    lpf_wrapper_if.lpf_wrapper_inst lpfif
);
    // FIR Compiler Inputs
    logic i_ready, q_ready;
    logic i_valid, q_valid;
    logic signed [23:0] i_data_padded, q_data_padded;

    // FIR Compiler Outputs
    logic lpf_i_valid, lpf_q_valid;
    logic signed [23:0] lpf_i_data, lpf_q_data;

    low_pass_filter lpf_i (
        .aclk(clk),                         // input wire aclk
        .s_axis_data_tvalid(i_valid),       // input wire s_axis_data_tvalid
        .s_axis_data_tready(i_ready),       // output wire s_axis_data_tready
        .s_axis_data_tdata(i_data_padded),  // input wire [23 : 0] s_axis_data_tdata
        .m_axis_data_tvalid(lpf_i_valid),   // output wire m_axis_data_tvalid
        .m_axis_data_tdata(lpf_i_data)      // output wire [23 : 0] m_axis_data_tdata
    );

    low_pass_filter lpf_q (
        .aclk(clk),                         // input wire aclk
        .s_axis_data_tvalid(q_valid),       // input wire s_axis_data_tvalid
        .s_axis_data_tready(q_ready),       // output wire s_axis_data_tready
        .s_axis_data_tdata(q_data_padded),  // input wire [23 : 0] s_axis_data_tdata
        .m_axis_data_tvalid(lpf_q_valid),   // output wire m_axis_data_tvalid
        .m_axis_data_tdata(lpf_q_data)      // output wire [23 : 0] m_axis_data_tdata
    );

    // if tready is low
    always_ff @(posedge clk, negedge n_rst) begin : i_tready_logc
        if (~n_rst) begin
            i_valid <= 1'b0;
            i_data_padded  <= '0;
        end else if (i_valid && !i_ready) begin
            // tready is low — hold data and valid until accepted
            i_valid <= i_valid;
            i_data_padded  <= i_data_padded;
        end else begin
            i_valid <= lpfif.corr_valid;
            i_data_padded  <= {{6{lpfif.corr_i[DATA_DW-1]}}, lpfif.corr_i};
        end
    end

    // if tready is low
    always_ff @(posedge clk, negedge n_rst) begin : q_tready_logc
        if (~n_rst) begin
            q_valid <= 1'b0;
            q_data_padded  <= '0;
        end else if (q_valid && !q_ready) begin
            // tready is low — hold data and valid until accepted
            q_valid <= q_valid;
            q_data_padded  <= q_data_padded;
        end else begin
            q_valid <= lpfif.corr_valid;
            q_data_padded  <= {{6{lpfif.corr_q[DATA_DW-1]}}, lpfif.corr_q};
        end
    end

    // Outputs
    assign lpfif.lpf_i     = lpf_i_data[DATA_DW-1:0];
    assign lpfif.lpf_q     = lpf_q_data[DATA_DW-1:0];
    assign lpfif.lpf_valid = lpf_i_valid & lpf_q_valid;
    assign lpfif.lpf_ready = i_ready & q_ready;

endmodule
