
`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/fm_demodulate_if.vh"
import types::*;

module fm_demodulate_tb;

    parameter PERIOD = 10;
    logic clk = 1, n_rst;

    always #(PERIOD/2) clk = ~clk;

    fm_demodulate_if fmif();

    fm_demodulate DUT(clk, n_rst, fmif);

    fm_demodulate_test PROG (clk, n_rst, fmif);

    always @(posedge clk) begin
        if (fmif.demod_valid)
            $display("  [t=%4t] demod_sample = %6d", $time, $signed(fmif.demod_sample));
    end

endmodule

program fm_demodulate_test (
    input  logic clk,
    output logic n_rst,
    fm_demodulate_if.fm_demodulate_tb fmif
);
    // A = 64.0 in Q8.10 -> integer = 64 * 2^10 = 65536 = 18'h10000
    // -A in 18-bit two's complement: 2^18 - 65536 = 196608 = 18'h30000
    localparam logic [DATA_DW-1:0] A     = 18'h10000;
    localparam logic [DATA_DW-1:0] NEG_A = 18'h30000;

    task automatic sendSample (
        input logic [DATA_DW-1:0] i_sample,
        input logic [DATA_DW-1:0] q_sample
    );
        fmif.lpf_i    = i_sample;
        fmif.lpf_q    = q_sample;
        fmif.lpf_valid = 1'b1;
        @(negedge clk);
        fmif.lpf_valid = 1'b0;
        @(negedge clk);
    endtask

    task automatic resetDUT;
        n_rst = 1'b0;
        repeat(2) @(negedge clk);
        n_rst = 1'b1;
        repeat(2) @(negedge clk);
    endtask

    initial begin
        fmif.lpf_i    = '0;
        fmif.lpf_q    = '0;
        fmif.lpf_valid = 1'b0;
        resetDUT();

        // ----------------------------------------------------------------
        // Test 1: DC -- same phasor repeated -> delta_theta = 0 -> output = 0
        //   num = Q[n]*I[n-1] - I[n]*Q[n-1] = A*0 - A*0 = 0
        //   expect: demod_sample = 0
        // ----------------------------------------------------------------
        $display("\n[Test 1] DC / zero frequency (expect 0)");
        sendSample(A, 18'h0);
        sendSample(A, 18'h0);
        repeat(60) @(negedge clk);
        resetDUT();

        // ----------------------------------------------------------------
        // Test 2: +90 deg rotation -> maximum positive frequency
        //   num = Q[n]*I[n-1] - I[n]*Q[n-1] = A*A - 0*0 = A^2
        //   denom = I[n]^2 + Q[n]^2 = 0 + A^2 = A^2
        //   quotient = 1 -> Q0.10 integer = 1024
        //   expect: demod_sample = 1024 * 15000 >> 10 = 15000
        // ----------------------------------------------------------------
        $display("\n[Test 2] +90 deg rotation (expect +15000)");
        sendSample(A,     18'h0);
        sendSample(18'h0, A    );
        repeat(60) @(negedge clk);
        resetDUT();

        // ----------------------------------------------------------------
        // Test 3: -90 deg rotation -> maximum negative frequency
        //   num = Q[n]*I[n-1] - I[n]*Q[n-1] = (-A)*A - 0*0 = -A^2
        //   denom = 0 + A^2 = A^2
        //   quotient = -1 -> Q0.10 integer = -1024
        //   expect: demod_sample = -1024 * 15000 >> 10 = -15000
        // ----------------------------------------------------------------
        $display("\n[Test 3] -90 deg rotation (expect -15000)");
        sendSample(A,     18'h0 );
        sendSample(18'h0, NEG_A );
        repeat(60) @(negedge clk);

        $display("\nDone.");
        $finish;
    end

endprogram
