
`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/lpf_wrapper_if.vh"

module lpf_wrapper 
import types::*;
(
    input logic clk, n_rst,
    lpf_wrapper_if.lpf_wrapper_inst lpfif
);
    // internal signals
    logic i_ready, q_ready;
    




    logic i_valid, i_ready, lpf_i_valid;
    logic signed [DATA_DW-1:0] i_data, lpf_i_data;

    logic q_valid, q_ready, lpf_q_valid;
    logic signed [DATA_DW-1:0] q_data, lpf_q_data;

    low_pass_filter lpf_i (
        .aresetn(n_rst),                    // input wire aresetn
        .aclk(clk),                         // input wire aclk
        .s_axis_data_tvalid(i_valid),       // input wire s_axis_data_tvalid
        .s_axis_data_tready(i_ready),       // output wire s_axis_data_tready
        .s_axis_data_tdata(i_data),         // input wire [23 : 0] s_axis_data_tdata
        .m_axis_data_tvalid(lpf_i_valid),   // output wire m_axis_data_tvalid
        .m_axis_data_tdata(lpf_i_data)      // output wire [23 : 0] m_axis_data_tdata
    );

    low_pass_filter lpf_q (
        .aresetn(n_rst),                    // input wire aresetn
        .aclk(clk),                         // input wire aclk
        .s_axis_data_tvalid(q_valid),       // input wire s_axis_data_tvalid
        .s_axis_data_tready(q_ready),       // output wire s_axis_data_tready
        .s_axis_data_tdata(q_data),         // input wire [23 : 0] s_axis_data_tdata
        .m_axis_data_tvalid(lpf_q_valid),   // output wire m_axis_data_tvalid
        .m_axis_data_tdata(lpf_q_data)      // output wire [23 : 0] m_axis_data_tdata
    );

    always_comb begin : lpf_I_Inputs
        if (~n_rst) begin
            i_valid = 1'b0;
            i_data = '0;
        end
        else if (i_ready) begin
            i_valid = lpfif.corr_valid;
            i_data = {{6{lpfif.corr_i[DATA_DW-1]}}, lpfif.corr_i}; // sign extend
        end
    end

    always_comb begin : lpf_Q_Inputs
        if (~n_rst) begin
            q_valid = 1'b0;
            q_data = {{6{lpfif.corr_q[DATA_DW-1]}}, lpfif.corr_q}; // sign extend
        end
        else if (q_ready) begin
            q_valid = lpfif.corr_valid;
            q_data = lpfif.corr_q;
        end
    end

    assign lpfif.lpf_i = lpf_i_data[DATA_DW-1:0];
    assign lpfif.lpf_q = lpf_q_data[DATA_DW-1:0];
    assign lpfif.lpf_valid = lpf_i_valid & lpf_q_valid;

endmodule