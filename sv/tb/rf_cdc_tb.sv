
`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/rf_cdc_if.vh"
import types::*;

module rf_cdc_tb;
    // clock periods
    parameter FPGA_PERIOD = 40; // 25 MHz
    parameter WS_PERIOD = 4000; // 250kHz
    parameter BIT_PERIOD = 250; // 4MHz

    logic fpga_clk = 0;
    logic ws_clk = 0;
    logic bit_clk = 0;
    logic n_rst;

    // clocks
    always #(FPGA_PERIOD/2) fpga_clk = ~fpga_clk;
    always #(WS_PERIOD/2) ws_clk = ~ws_clk;
    always #(BIT_PERIOD/2) bit_clk = ~bit_clk;

    rf_cdc_if rfif();

    // DUT
    rf_cdc DUT(fpga_clk, n_rst, rfif);

    // test program
    rf_cdc_test TEST (
        fpga_clk, n_rst,
        rfif
    );

    assign rfif.ws = ws_clk;
    assign rfif.sck = bit_clk;

endmodule

program rf_cdc_test (
    input logic fpga_clk, 
    output logic n_rst,
    rf_cdc_if.rf_cdc_tb rfif
);
    task automatic sendBit (input logic bit_val);
        @(negedge rfif.sck);
        rfif.sd = bit_val;
    endtask

    task automatic sendSample (
        input logic [SAMPLE_DW-1:0] i, 
        input logic [SAMPLE_DW-1:0] q
    );
        @(negedge rfif.ws); // wait for start of frame

        for (int j = SAMPLE_DW-1; j >= 0; j--) begin
            sendBit(i[j]);
        end

        for (int j = SAMPLE_DW-1; j >= 0; j--) begin
            sendBit(q[j]);
        end
    endtask

    string test_name;
    initial begin

        rfif.sd = 1'b0;
        n_rst = 1'b0;
        repeat (2) @(negedge fpga_clk);
        n_rst = 1'b1;
        repeat (2) @(negedge fpga_clk);
        
        // ************************************************************************
        // Test Case 1: Test RF to FPGA
        // ************************************************************************
        test_name = "Test RF to FPGA";
        $display("%s", test_name);

        sendSample(8'hAA, 8'h55);

        @(posedge rfif.sample_valid);
        @(negedge fpga_clk);
        $display("sample_i = 0x%h, sample_q = 0x%h, valid = %b",
                 rfif.sample_i, rfif.sample_q, rfif.sample_valid);

        assert (rfif.sample_i === 8'hAA)
            else $error("Expected I=0xAA, got 0x%h", rfif.sample_i);
        assert (rfif.sample_q === 8'h55)
            else $error("Expected Q=0x55, got 0x%h", rfif.sample_q);
                
        // ****************************************************************
        // Test Case 2: All ones / all zeros
        // ****************************************************************
        test_name = "Test 2: I=0xFF, Q=0x00";
        $display("%s", test_name);

        sendSample(8'hFF, 8'h00);

        @(posedge rfif.sample_valid);
        @(negedge fpga_clk);
        $display("sample_i = 0x%h, sample_q = 0x%h, valid = %b",
                 rfif.sample_i, rfif.sample_q, rfif.sample_valid);

        assert (rfif.sample_i === 8'hFF)
            else $error("Expected I=0xFF, got 0x%h", rfif.sample_i);
        assert (rfif.sample_q === 8'h00)
            else $error("Expected Q=0x00, got 0x%h", rfif.sample_q);

        repeat (15) @(negedge fpga_clk);
        $finish;

    end

endprogram