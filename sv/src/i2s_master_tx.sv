
`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/i2s_if.vh"
import types::*;

module i2s_master_tx 
(
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
    logic [$clog2(PCM_W)-1:0] bit_index = '0;
    logic sample_tick;
    logic signed [PCM_W-1:0] pcm16 = '0;

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
            bit_index <= PCM_W - 1;
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
                    bit_index <= PCM_W - 1;

                    if (in_right) begin
                        sample_tick <= 1'b1;
                    end
                end else begin
                    bit_index <= bit_index - 1'b1;
                end
            end
        end
    end

    // DSP `sample_valid` is timed off the RF ESP32 I2S stream (via rf_cdc); `sample_tick`
    // is timed off this FPGA's DDS BCLK. Same nominal 44.1 kHz, different timebases →
    // beats, repeated/skipped samples, and pulsing static if we only latch into pcm16.
    localparam int AFIFO_DEPTH = 16;
    localparam int AFIFO_PTR_W = $clog2(AFIFO_DEPTH);

    function automatic logic [AFIFO_PTR_W-1:0] afifo_inc(input logic [AFIFO_PTR_W-1:0] p);
        return (p == AFIFO_DEPTH - 1) ? '0 : (p + 1'b1);
    endfunction

    logic signed [PCM_W-1:0] afifo_mem[AFIFO_DEPTH];
    logic [AFIFO_PTR_W-1:0] afifo_wp, afifo_rp;
    logic [$clog2(AFIFO_DEPTH + 1) - 1:0] afifo_cnt;

    logic signed [PCM_W-1:0] afifo_din;
    assign afifo_din = i2sif.sample_q18[PCM_IN_W-1:2];

    always_ff @(posedge clk) begin
        if (~n_rst) begin
            afifo_wp <= '0;
            afifo_rp <= '0;
            afifo_cnt <= '0;
            pcm16 <= '0;
        end else begin
            case ({i2sif.sample_valid, sample_tick})
                2'b00: ;
                2'b10: begin
                    if (afifo_cnt < AFIFO_DEPTH) begin
                        afifo_mem[afifo_wp] <= afifo_din;
                        afifo_wp <= afifo_inc(afifo_wp);
                        afifo_cnt <= afifo_cnt + 1'b1;
                    end else begin
                        afifo_rp <= afifo_inc(afifo_rp);
                        afifo_mem[afifo_wp] <= afifo_din;
                        afifo_wp <= afifo_inc(afifo_wp);
                    end
                end
                2'b01: begin
                    if (afifo_cnt > 0) begin
                        pcm16 <= afifo_mem[afifo_rp];
                        afifo_rp <= afifo_inc(afifo_rp);
                        afifo_cnt <= afifo_cnt - 1'b1;
                    end
                end
                2'b11: begin
                    if (afifo_cnt > 0) begin
                        pcm16 <= afifo_mem[afifo_rp];
                        afifo_mem[afifo_wp] <= afifo_din;
                        afifo_rp <= afifo_inc(afifo_rp);
                        afifo_wp <= afifo_inc(afifo_wp);
                    end else begin
                        pcm16 <= afifo_din;
                    end
                end
            endcase
        end
    end

endmodule