
`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/dc_offset_if.vh"
import types::*;

module dc_offset_tb;

    parameter PERIOD = 10;
    logic clk = 1, n_rst;

    // clocks
    always #(PERIOD/2) clk = ~clk;

    dc_offset_if dcif();

    // DUT
    dc_offset DUT(clk, n_rst, dcif);

    // test program
    dc_offset_test PROG (
        clk, n_rst,
        dcif
    );

endmodule

program dc_offset_test (
    input logic clk, 
    output logic n_rst,
    dc_offset_if.dc_offset_tb dcif
);

    task automatic sendSample (
        input logic [SAMPLE_DW-1:0] i_sample,
        input logic [SAMPLE_DW-1:0] q_sample
    );
        dcif.sample_i = i_sample;
        dcif.sample_q = q_sample;
        dcif.sample_valid = 1'b1;
        @(negedge clk);
        dcif.sample_valid = 1'b0;
        @(negedge clk);
    endtask

    string test_name;
    integer i;
    integer log_file;

    initial begin
        dcif.sample_i = '0;
        dcif.sample_q = '0;
        dcif.sample_valid = 1'b0;
        n_rst = 1'b0;
        repeat (2) @(negedge clk);
        n_rst = 1'b1;
        repeat (2) @(negedge clk);
        
        // ************************************************************************
        // Test Case 1: Constantly send in unsigned 200
        // ************************************************************************
        test_name = "Constantly send in unsigned 200";
        $display("%s", test_name);

        // unsigned 200 = signed 72
        // in S7.10 format, 72 << 10 = 73728 (0x12000)
        // mean should converge to 73728 & corrected output should converge to 0

        for (i = 0; i < 12000; i++) begin
            sendSample(8'd200, 8'd200);
        end

        $display("Final mean_i = %0d (expected ~73728)", DUT.mean_i);
        $display("Final mean_q = %0d (expected ~73728)", DUT.mean_q);
        $display("Final corr_i = %0d (expected ~0)", dcif.corr_i);
        $display("Final corr_q = %0d (expected ~0)", dcif.corr_q);

        n_rst = 1'b0;
        repeat (2) @(negedge clk);
        n_rst = 1'b1;
        repeat (2) @(negedge clk);
        // ************************************************************************
        // Test Case 2: Alternate between unsigned 200 and unsigned 0
        // ************************************************************************
        test_name = "Alternate between unsigned 200 and unsigned 0";
        $display("%s", test_name);

        // unsigned 200 = signed 72, unsigned 0 = signed -128
        // average = -28, so mean should converge to -28 << 10 = -28672 (0xF8A000)
        // signed 72 << 10 = 73728, signed -128 << 10 = -131072
        // corrected 200 = 73728 - (-28672) = 102400
        // corrected 0 = -131072 - (-28672) = -102400

        for (i = 0; i < 12000; i++) begin
            sendSample(8'd200, 8'd200);
            sendSample(8'd0, 8'd0);
        end

        sendSample(8'd200, 8'd200);
        $display("Final mean_i = %0d (expected ~-28672)", DUT.mean_i);
        $display("Final mean_q = %0d (expected ~-28672)", DUT.mean_q);
        $display("Final corr_i = %0d (expected ~102400)", dcif.corr_i);
        $display("Final corr_q = %0d (expected ~102400)", dcif.corr_q);

        sendSample(8'd0, 8'd0);
        $display("Final mean_i = %0d (expected ~-28672)", DUT.mean_i);
        $display("Final mean_q = %0d (expected ~-28672)", DUT.mean_q);
        $display("Final corr_i = %0d (expected ~-102400)", dcif.corr_i);
        $display("Final corr_q = %0d (expected ~-102400)", dcif.corr_q);

        repeat (15) @(negedge clk);
        $finish;

    end

endprogram