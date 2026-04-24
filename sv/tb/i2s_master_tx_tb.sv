`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/i2s_if.vh"
import types::*;

module i2s_master_tx_tb;
    parameter PERIOD = 10;

    logic clk = 1'b0;
    logic n_rst;

    i2s_if i2sif();

    always #(PERIOD/2) clk = ~clk;

    i2s_master_tx dut (
        .clk(clk),
        .n_rst(n_rst),
        .i2sif(i2sif)
    );

    i2s_master_tx_test PROG (
        clk, n_rst,
        i2sif
    );

endmodule

program i2s_master_tx_test (
    input logic clk,
    output logic n_rst,
    i2s_if.i2s_tb i2sif
);

    task automatic sendSample(
        input logic signed [PCM_IN_W-1:0] sample_q18
    );
        i2sif.sample_q18 = sample_q18;
        i2sif.sample_valid = 1'b1;
        @(posedge i2sif.i2s_ws);
    endtask

    initial begin
        i2sif.sample_q18 = '0;
        i2sif.sample_valid = 1'b0;
        n_rst = 1'b0;
        repeat (2) @(negedge clk);
        n_rst = 1'b1;
        repeat (2) @(negedge clk);

        i2sif.sample_valid = 1'b1;

        sendSample(18'sd0);
        sendSample(18'sd6639);
        sendSample(18'sd13260);
        sendSample(-18'sd6639);

        repeat (20) @(negedge clk);
        $finish;
    end

endprogram
