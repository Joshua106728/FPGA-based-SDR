
`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/lpf_wrapper_if.vh"
import types::*;

module lpf_wrapper_tb;

    parameter PERIOD = 10;
    logic clk = 0, n_rst;

    // clocks
    always #(PERIOD/2) clk = ~clk;

    lpf_wrapper_if lpfif();

    // DUT
    lpf_wrapper DUT(clk, n_rst, lpfif);

    // test program
    lpf_wrapper_test PROG (
        clk, n_rst,
        lpfif
    );

endmodule

program lpf_wrapper_test (
    input logic clk, 
    output logic n_rst,
    lpf_wrapper_if.lpf_wrapper_tb lpfif
);

    string test_name;
    integer i;

    initial begin
        lpfif.corr_i = '0;
        lpfif.corr_q = '0;
        lpfif.corr_valid = 1'b0;
        n_rst = 1'b0;
        repeat (2) @(negedge clk);
        n_rst = 1'b1;
        repeat (2) @(negedge clk);
        
        // ************************************************************************
        // Test Case 1: Test DC Constant 1024
        // ************************************************************************
        test_name = "Test DC Constant 1024";
        $display("%s", test_name);

        while (!lpfif.lpf_ready) @(negedge clk);

        // first few samples are not accurate
        for (i = 0; i < 100; i++) begin
            lpfif.corr_i = 18'sd1024;
            lpfif.corr_q = 18'sd1024;
            lpfif.corr_valid = 1'b1;
            @(negedge clk);

            lpfif.corr_valid = 1'b0;
            repeat (399) @(negedge clk); // FIR Compiler expected input freq of 250kHz
        end

        // ************************************************************************
        // Test Case 2: Test 120 kHz Sine Wave
        // ************************************************************************
        test_name = "Test 120 kHz Sine Wave";
        $display("%s", test_name);

        while (!lpfif.lpf_ready) @(negedge clk);

        for (i = 0; i < 100; i++) begin
            if (i % 2 == 0) begin
                lpfif.corr_i = 18'sd16384;
                lpfif.corr_q = 18'sd16384;
            end else begin
                lpfif.corr_i = -18'sd16384;
                lpfif.corr_q = -18'sd16384;
            end
            lpfif.corr_valid = 1'b1;
            @(negedge clk);
            lpfif.corr_valid = 1'b0;
            repeat (399) @(negedge clk);
        end

        repeat (4000) @(negedge clk);
        $finish;

    end

endprogram