
`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/fifowrapper_if.vh"
import types::*;

module fifowrapper_tb;

    parameter PERIOD = 10;
    logic clk1 = 1, clk2 = 1, nRST;

    // clocks
    always #(PERIOD/2) clk1 = ~clk1; // clk2 faster 
    always #(PERIOD/6) clk2 = ~clk2; // clk1 slower

    fifowrapper_if fifoif();

    // test program
    test PROG (
        clk1, clk2, rst,
        fifoif
    );

    // DUT
    fifowrapper DUT(clk1, clk2, rst, fifoif);

endmodule

program test (
    input logic clk1, clk2, 
    output logic rst,
    fifowrapper_if.fifo_tb fifoif
);

    task sendWrite (input logic [DW-1:0] data);
        fifoif.wr_data = data;
        fifoif.wr_en   = 1'b1;
        @(negedge clk1);
        fifoif.wr_en   = 1'b0;
    endtask

    task readFIFO ();
        fifoif.rd_en = 1'b1;
        @(negedge clk2);
        fifoif.rd_en = 1'b0;
    endtask

    string test_name;
    integer i;
    initial begin

        rst = 1'b1;
        fifoif.rd_en = 1'b0;
        repeat (2) @(negedge clk1);
        repeat (2) @(negedge clk2);
        rst = 1'b0;
        repeat (2) @(negedge clk1);
        repeat (2) @(negedge clk2);
        
        // ************************************************************************
        // Test Case 1: Fill up FIFO
        // ************************************************************************
        test_name = "Fill up FIFO";
        $display("%s", test_name);

        while (fifoif.can_write !== 1'b1) begin
            @(negedge clk1);
        end

        for (i = 0; i < 15; i++) begin // NOTE: async FIFO must keep one spot empty for full/empty calculations, so if 512 depth, we can only store 511 values
            sendWrite(18'h1000 + i);
        end
        fifoif.wr_data = '0;
        fifoif.wr_en = 1'b0;

        assert (fifoif.full == 1'b1) $display ("Correct full value");
            else $display ("Incorrect full value ERROR");
        @(negedge clk1);

        // ************************************************************************
        // Test Case 2: Empty FIFO
        // ************************************************************************
        test_name = "Empty FIFO";
        $display("%s", test_name);

        while (fifoif.can_read !== 1'b1) begin
            @(negedge clk2);
        end

        for (i = 0; i < 15; i++) begin
            readFIFO();
            assert (fifoif.rd_data == (18'h1000 + i)) $display ("Correct data value read");
                else $display ("Incorrect data value read ERROR");
        end
        fifoif.rd_en = 1'b0;

        assert (fifoif.empty == 1'b1) $display ("Correct empty value");
            else $display ("Incorrect empty value ERROR");
        @(negedge clk2);

        repeat (15) @(negedge clk1);
        $finish;

    end

endprogram