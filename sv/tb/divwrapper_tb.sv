
`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/divwrapper_if.vh"
import types::*;

module divwrapper_tb;

    parameter PERIOD = 10;
    logic clk = 1, nRST;

    // clock
    always #(PERIOD/2) clk++;

    divwrapper_if divif();

    // test program
    divTest PROG (
        clk,
        nRST,
        divif
    );

    // DUT
    divwrapper DUT(clk, nRST, divif);

endmodule

program divTest (
    input logic clk, 
    output logic nRST,
    divwrapper_if.div_tb divif
);

    task sendDiv (input logic [DATA_DW-1:0] dividend_in, input logic [DATA_DW-1:0] divisor_in);
        begin
            divif.dividend_valid = 1'b1;
            divif.dividend_data  = dividend_in;
            divif.divisor_valid  = 1'b1;
            divif.divisor_data   = divisor_in;
            @(negedge clk);
        end
    endtask

    string test_name;
    initial begin

        nRST = 1'b0;
        repeat (2) @(negedge clk);
        nRST = 1'b1;
        repeat (2) @(negedge clk);
        
        // ************************************************************************
        // Test Case 1: Fully Pipelined Divisions
        // ************************************************************************
        test_name = "Fully Pipelined Divisions";
        $display("%s", test_name);

        sendDiv(18'h2800, 18'hA00); // 5 / 1.25 = 4
        sendDiv(18'h800, 18'h400); // 1 / 0.5 = 2
        sendDiv(18'h1000, 18'h1000); // 2 / 2 = 1
        sendDiv(18'h400, 18'h1000); // 0.5 / 2 = 0.25

        sendDiv(18'h400, 18'h3F000); // 0.5 / -2 = -0.25
        sendDiv(18'h3FC00, 18'h1000); // -0.5 / 2 = -0.25
        sendDiv(18'h3100, 18'h1100); // 7 / 3 = 2.3333
        sendDiv(18'h1C000, 18'hF00); // 56 / 1.875 = 29.8666
        sendDiv(18'h20800, 18'h01333); // -63 / 2.4 = -26.25
        
        divif.dividend_valid = 1'b0;
        divif.divisor_valid  = 1'b0;
        repeat (24) @(negedge clk);
        $display("=================================");
        assert (divif.out_data == 18'h2000) $display ("Correct output value"); // 5 / 1.25 = 4
            else $display ("Incorrect output value ERROR");
        @(negedge clk);
        assert (divif.out_data == 18'h1000) $display ("Correct output value"); // 1 / 0.5 = 2
            else $display ("Incorrect output value ERROR");
        @(negedge clk);
        assert (divif.out_data == 18'h800) $display ("Correct output value"); // 2 / 2 = 1
            else $display ("Incorrect output value ERROR");
        @(negedge clk);
        assert (divif.out_data == 18'h200) $display ("Correct output value"); // 0.5 / 2 = 0.25
            else $display ("Incorrect output value ERROR");
        @(negedge clk);

        assert (divif.out_data == 18'h3FE00) $display ("Correct output value"); // 0.5 / -2 = -0.25
            else $display ("Incorrect output value ERROR");
        @(negedge clk);
        assert (divif.out_data == 18'h3FE00) $display ("Correct output value"); // -0.5 / 2 = -0.25
            else $display ("Incorrect output value ERROR");
        @(negedge clk);
        assert (divif.out_data == 18'h012AA) $display ("Correct output value (output repeating)"); // 7 / 3 = 2.3333
            else $display ("Incorrect output value (output repeating) ERROR");
        @(negedge clk);
        assert (divif.out_data == 18'h0EEEE) $display ("Correct output value (output repeating)"); // 56 / 1.875 = 29.8666
            else $display ("Incorrect output value (output repeating) ERROR");
        @(negedge clk);
        assert (divif.out_data == 18'h32E00) $display ("Correct output value (input repeating)"); // -63 / 2.4 = -26.25
            else $display ("Incorrect output value (input repeating) ERROR");
        $display("");

        repeat (15) @(negedge clk);
        $finish;

    end

endprogram
