`timescale 1ns / 1ps
`include "../include/types.sv"
import types::*;

module i2s_master_tx #(
    parameter int WORD_BITS = types::PCM_W
)(
    input  logic clk,
    input  logic rst,
    input  logic signed [WORD_BITS-1:0] left_pcm,
    input  logic signed [WORD_BITS-1:0] right_pcm,
    output logic sample_tick,
    output logic i2s_bclk,
    output logic i2s_ws,
    output logic i2s_sd
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

    always_comb begin
        bclk_phase_next = bclk_phase + BCLK_STEP;
        bclk_next = bclk_phase_next[ACC_BITS-1];
        bclk_fall = (i2s_bclk == 1'b1) && !bclk_next;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            bclk_phase <= '0;
            i2s_bclk <= 1'b0;
            i2s_ws <= 1'b0;
            i2s_sd <= 1'b0;
            in_right <= 1'b0;
            in_delay <= 1'b1;
            bit_index <= WORD_BITS - 1;
            sample_tick <= 1'b0;
        end else begin
            sample_tick <= 1'b0;

            bclk_phase <= bclk_phase_next;
            i2s_bclk <= bclk_next;

            if (bclk_fall) begin
                if (in_delay) begin
                    // Philips I2S: one bit-clock delay after WS transition before MSB.
                    in_delay <= 1'b0;
                    bit_index <= WORD_BITS - 1;
                end else begin
                    if (!in_right) begin
                        i2s_sd <= left_pcm[bit_index];
                    end else begin
                        i2s_sd <= right_pcm[bit_index];
                    end

                    if (bit_index == 0) begin
                        // Toggle WS at word boundary; next BCLK is the MSB of the next word.
                        in_right <= ~in_right;
                        i2s_ws <= ~in_right;
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

endmodule