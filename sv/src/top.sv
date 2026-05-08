
`timescale 1ns / 10ps
`include "../include/types.sv"
`include "../include/i2s_if.vh"

module top
import types::*;
(
    // FPGA Interface
    input logic fpga_clk,
    input logic n_rst,

    // RF Interface
    input logic rf_ws,
    input logic rf_sck,
    input logic rf_sd,

    // Random LED
    output logic led1,
    output logic led2,
    output logic led3,
    output logic led4,

    // Bluetooth Interface
    output logic bt_ws,
    output logic bt_sck,
    output logic bt_sd
);
    localparam int TONE_DIVIDER = 2268;

    localparam logic signed [PCM_IN_W-1:0] TONE_LUT [0:31] = '{
        18'sd0,      18'sd6393,   18'sd12539,  18'sd18204,
        18'sd23170,  18'sd27245,  18'sd30273,  18'sd32137,
        18'sd32767,  18'sd32137,  18'sd30273,  18'sd27245,
        18'sd23170,  18'sd18204,  18'sd12539,  18'sd6393,
        18'sd0,     -18'sd6393,  -18'sd12539, -18'sd18204,
        -18'sd23170, -18'sd27245, -18'sd30273, -18'sd32137,
        -18'sd32768, -18'sd32137, -18'sd30273, -18'sd27245,
        -18'sd23170, -18'sd18204, -18'sd12539, -18'sd6393
    };

    logic [11:0] tone_div = '0;
    logic [4:0] tone_index = '0;
    logic signed [PCM_IN_W-1:0] tone_sample = TONE_LUT[0];

    i2s_if i2sif();
    assign i2sif.sample_q18  = tone_sample;
    assign i2sif.sample_valid = 1'b1;

    assign bt_ws  = i2sif.i2s_ws;
    assign bt_sck = i2sif.i2s_bclk;
    assign bt_sd  = i2sif.i2s_sd;

    assign led1 = tone_index[0];
    assign led2 = bt_sd;
    assign led3 = 1'b0;
    assign led4 = 1'b1;

    always_ff @(posedge fpga_clk) begin
        if (~n_rst) begin
            tone_div <= '0;
            tone_index <= '0;
            tone_sample <= TONE_LUT[0];
        end else if (tone_div == TONE_DIVIDER - 1) begin
            tone_div <= '0;
            if (tone_index == 5'd31) begin
                tone_index <= '0;
                tone_sample <= TONE_LUT[0];
            end else begin
                tone_index <= tone_index + 1'b1;
                tone_sample <= TONE_LUT[tone_index + 1'b1];
            end
        end else begin
            tone_div <= tone_div + 1'b1;
        end
    end

    i2s_master_tx u_i2s_master_tx (.clk(fpga_clk), .n_rst(n_rst), .i2sif(i2sif));

endmodule