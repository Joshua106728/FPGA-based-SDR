`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/i2s_if.vh"
import types::*;

module i2s_master_tx #(
    parameter int WORD_BITS = types::PCM_W
)(
    input  logic clk,
    input  logic n_rst,
    i2s_if.i2s_master_tx_inst i2sif
);
    localparam int ACC_BITS = 32;
    localparam longint unsigned BCLK_STEP = 32'd60610578;

    logic [ACC_BITS-1:0] bclk_phase = '0;
    logic [ACC_BITS-1:0] bclk_phase_next;
    logic bclk_next;
    logic bclk_fall;
    logic in_right = 1'b0;
    logic in_delay = 1'b1;
    logic [$clog2(WORD_BITS)-1:0] bit_index = '0;
    logic sample_tick;
    logic signed [WORD_BITS-1:0] pcm16 = '0;

    always_comb begin
        bclk_phase_next = bclk_phase + BCLK_STEP;
        bclk_next = bclk_phase_next[ACC_BITS-1];
        bclk_fall = (i2sif.i2s_bclk == 1'b1) && !bclk_next;
    end

    always_ff @(posedge clk) begin
        if (~n_rst) begin
            bclk_phase <= '0;
            i2sif.i2s_bclk <= 1'b0;
            i2sif.i2s_ws <= 1'b0;
            i2sif.i2s_sd <= 1'b0;
            in_right <= 1'b0;
            in_delay <= 1'b1;
            bit_index <= WORD_BITS - 1;
            sample_tick <= 1'b0;
        end else begin
            sample_tick <= 1'b0;

            bclk_phase <= bclk_phase_next;
            i2sif.i2s_bclk <= bclk_next;

            if (bclk_fall) begin
                if (in_delay) begin
                    // Philips I2S: one bit-clock delay after WS transition before MSB.
                    in_delay <= 1'b0;
                    bit_index <= WORD_BITS - 1;
                end else begin
                    i2sif.i2s_sd <= pcm16[bit_index];

                    if (bit_index == 0) begin
                        // Toggle WS at word boundary; next BCLK is the MSB of the next word.
                        in_right <= ~in_right;
                        i2sif.i2s_ws <= ~in_right;
                        in_delay <= 1'b1;

                        if (in_right) begin
                            sample_tick <= 1'b1;
                        end
                    end else begin
                        bit_index <= bit_index - 1'b1;
                    end
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (~n_rst) begin
            pcm16 <= '0;
        end else if (sample_tick && i2sif.sample_valid) begin
            pcm16 <= i2sif.sample_q18 >>> (PCM_IN_W - WORD_BITS);
        end
    end

endmodule