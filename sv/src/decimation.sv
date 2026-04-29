`timescale 1ns / 1ps
`include "../include/types.sv"

module decimation
import types::*;
(
    input  logic                        clk,
    input  logic                        n_rst,

    // From LPF wrapper
    input  logic signed [DATA_DW-1:0]  lpf_i,
    input  logic signed [DATA_DW-1:0]  lpf_q,
    input  logic                        lpf_valid,
    input  logic                        lpf_ready,

    // Decimated outputs
    output logic signed [DATA_DW-1:0]  dec_i,
    output logic signed [DATA_DW-1:0]  dec_q,
    output logic                        dec_valid
);

    localparam int DECIM_FACTOR = 6;

    logic [2:0] sample_cnt;  // 0 -> 5

    always_ff @(posedge clk, negedge n_rst) begin : decim_proc
        if (~n_rst) begin
            sample_cnt <= '0;
            dec_i      <= '0;
            dec_q      <= '0;
            dec_valid  <= 1'b0;
        end else begin
            dec_valid <= 1'b0;

            if (lpf_valid && lpf_ready) begin
                if (sample_cnt == DECIM_FACTOR - 1)
                    sample_cnt <= '0;
                else
                    sample_cnt <= sample_cnt + 1;

                if (sample_cnt == '0) begin
                    dec_i     <= lpf_i;
                    dec_q     <= lpf_q;
                    dec_valid <= 1'b1;
                end
            end
        end
    end

endmodule
