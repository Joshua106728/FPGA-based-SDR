
`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/i2s_if.vh"
import types::*;

module i2s_master_tx #(
    parameter int WORD_BITS = types::PCM_W,
    // When set, ignore DSP input and transmit a fixed repeating pattern.
    // This is useful to verify I2S wiring + framing end-to-end on the ESP32.
    parameter bit USE_TEST_PATTERN = 1'b0
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
    logic [$clog2(WORD_BITS)-1:0] bit_index = '0;
    logic sample_tick;
    logic signed [WORD_BITS-1:0] pcm16 = '0;

    // Simple pseudo-sine pattern (same value sent on L and R).
    // Values are 16-bit signed. Sequence repeats.
    localparam int PATTERN_LEN = 8;
    logic [$clog2(PATTERN_LEN)-1:0] pattern_idx = '0;
    logic signed [WORD_BITS-1:0] pattern_val;
    always_comb begin
        unique case (pattern_idx)
            3'd0: pattern_val = '0;
            3'd1: pattern_val = 16'sh2000;
            3'd2: pattern_val = 16'sh4000;
            3'd3: pattern_val = 16'sh2000;
            3'd4: pattern_val = '0;
            3'd5: pattern_val = -16'sh2000;
            3'd6: pattern_val = -16'sh4000;
            default: pattern_val = -16'sh2000; // 3'd7
        endcase
    end

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
            bit_index <= WORD_BITS - 1;
            sample_tick <= 1'b0;
        end else begin
            sample_tick <= 1'b0;

            bclk_phase <= bclk_phase_next;
            i2sif.i2s_bclk <= bclk_next;

            if (bclk_fall) begin
                i2sif.i2s_sd <= pcm16[bit_index];

                if (bit_index == 0) begin
                    // WS transitions on LSB clock; MSB of next word appears one BCLK later (Philips I2S).
                    in_right <= ~in_right;
                    i2sif.i2s_ws <= ~in_right;
                    bit_index <= WORD_BITS - 1;

                    if (in_right) begin
                        sample_tick <= 1'b1;
                    end
                end else begin
                    bit_index <= bit_index - 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (~n_rst) begin
            pcm16 <= '0;
            pattern_idx <= '0;
        end else if (sample_tick && i2sif.sample_valid) begin
            if (USE_TEST_PATTERN) begin
                pcm16 <= pattern_val;
                pattern_idx <= pattern_idx + 1'b1;
            end else begin
                pcm16 <= i2sif.sample_q18 >>> (PCM_IN_W - WORD_BITS);
            end
        end
    end

endmodule