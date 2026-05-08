
`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/fm_demodulate_if.vh"

module fm_demodulate 
import types::*;
(
    input logic clk, n_rst,
    fm_demodulate_if.fm_demodulate_inst fmif
);
    // Internal Signals
    logic signed [DATA_DW-1:0] prev_i, prev_q, curr_i, curr_q;
    logic demod_val, div_val;
    logic signed [36:0] num_sub, denom_add;
    logic signed [35:0] num_i, num_q, denom_i, denom_q;
    logic signed [31:0] num;
    logic signed [23:0] denom;

    logic div_done;
    logic signed [55:0] div_result;
    // logic signed [31:0] div_result;
    logic signed [49:0] scaled_result;

    always_ff @(posedge clk, negedge n_rst) begin : latchLPF
        if (~n_rst) begin
            prev_i <= '0;
            prev_q <= '0;
            curr_i <= '0;
            curr_q <= '0;
            demod_val <= 1'b0;
        end else if (fmif.lpf_valid) begin
            prev_i <= curr_i;
            prev_q <= curr_q;
            curr_i <= fmif.lpf_i;
            curr_q <= fmif.lpf_q;
            demod_val <= 1'b1;
        end else begin
            demod_val <= 1'b0;
        end
    end

    always_comb begin : calculateNumDenom
        num = '0;
        denom = '0;
        div_val = 1'b0;

        if (demod_val) begin
            // find the numerator
            num_i = curr_i * prev_q;
            num_q = curr_q * prev_i;
            num_sub = num_i - num_q;
            // num_sub = num_q - num_i;
            num = num_sub[36:5];

            // find the denominator
            denom_i = curr_i * curr_i;
            denom_q = curr_q * curr_q;
            denom_add = denom_i + denom_q + 1;
            denom = {2'b0, denom_add[36:15]}; // upper 22 bits, pad 2 bits

            div_val = 1'b1;
        end
    end

    div u_div (
        .aclk(clk),                         // input wire aclk
        .aresetn(n_rst),                    // input wire aresetn
        .s_axis_divisor_tvalid(div_val),    // input wire s_axis_divisor_tvalid
        .s_axis_divisor_tready(),           // output wire s_axis_divisor_tready
        .s_axis_divisor_tdata(denom),       // input wire [23 : 0] s_axis_divisor_tdata
        .s_axis_dividend_tvalid(div_val),   // input wire s_axis_dividend_tvalid
        .s_axis_dividend_tready(),          // output wire s_axis_dividend_tready
        .s_axis_dividend_tdata(num),        // input wire [31 : 0] s_axis_dividend_tdata
        .m_axis_dout_tvalid(div_done),      // output wire m_axis_dout_tvalid
        .m_axis_dout_tdata(div_result)      // output wire [31 : 0] m_axis_dout_tdata
    );

    always_comb begin : scaleOutput
        if (div_done) begin
            // scaled_result = div_result * SCALE_OUT;
            // fmif.demod_sample = scaled_result[27:10];
            scaled_result = div_result[55:24] * SCALE_OUT;
            fmif.demod_sample = scaled_result[27:10];
            fmif.demod_valid = 1'b1;
        end else begin
            fmif.demod_sample = '0;
            fmif.demod_valid = 1'b0;
        end
        
    end
endmodule
