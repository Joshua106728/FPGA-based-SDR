`timescale 1ns / 1ps
`include "../include/types.sv"
import types::*;

module AFC(
    input  logic clk,
    input  logic rst,
    input  logic signed [PCM_IN_W-1:0] sample_q18,
    output logic sample_tick,
    output logic i2s_bclk,
    output logic i2s_ws,
    output logic i2s_sd
);
    logic signed [PCM_W-1:0] pcm16;

    always_ff @(posedge clk) begin
        if (rst) begin
            pcm16 <= '0;
        end else if (sample_tick) begin
            pcm16 <= sample_q18 >>> 2;
        end
    end

    i2s_master_tx tx (
        .clk(clk),
        .rst(rst),
        .left_pcm(pcm16),
        .right_pcm(pcm16),
        .sample_tick(sample_tick),
        .i2s_bclk(i2s_bclk),
        .i2s_ws(i2s_ws),
        .i2s_sd(i2s_sd)
    );

endmodule