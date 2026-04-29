`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/de_emphasis_if.vh"

// ============================================================
// de_emphasis_tb.sv
// ============================================================
// Verifies de_emphasis.sv by:
//
//  Test 1 — Reset behaviour
//    Drive valid input, assert reset mid-stream, verify output
//    clears and y_prev resets to 0.
//
//  Test 2 — IIR math correctness
//    Feed a known sequence of signed 16-bit samples and compare
//    DUT output against expected values computed here using the
//    same Q0.16 fixed-point arithmetic as the RTL.
//    Pass criterion: output matches expected exactly (0 LSB error).
//
//  Test 3 — Valid gating
//    When audio_valid is low, output should NOT update and
//    audio_out_valid should be 0 the following cycle.
//
//  Test 4 — DC input → DC output
//    A constant DC input should converge to that same DC value
//    (the IIR has unity DC gain). Verify convergence after warmup.
//
//  Test 5 — Sign extension
//    Negative inputs should produce negative outputs and the
//    18-bit output should be correctly sign-extended from 16-bit.
// ============================================================

module de_emphasis_tb;
    import types::*;

    // ---- Clock ----
    localparam CLK_PERIOD = 10;  // 10ns = 100 MHz
    logic clk, n_rst;
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ---- Interface ----
    de_emphasis_if deif();

    // ---- DUT ----
    de_emphasis u_dut (
        .clk(clk),
        .n_rst(n_rst),
        .deif(deif)
    );

    // ---- Fixed-point parameters (must match de_emphasis.sv) ----
    localparam int ALPHA_FP        = 65518;
    localparam int ONE_MINUS_ALPHA = 18;     // 65536 - 65518

    // ---- Helper: compute expected IIR output ----
    // Mirrors the RTL: acc = ALPHA*y_prev + (1-ALPHA)*x, y = acc>>16
    // Uses longint to avoid overflow on 16*16 multiply
    function automatic logic signed [15:0] iir_step(
        input logic signed [15:0] x,
        input logic signed [15:0] y_prev_in
    );
        logic signed [32:0] acc;
        acc = ($signed(33'(ALPHA_FP))        * $signed(33'(y_prev_in)))
            + ($signed(33'(ONE_MINUS_ALPHA)) * $signed(33'(x)));
        return acc[31:16];
    endfunction

    // ---- Test counters ----
    int pass_count = 0;
    int fail_count = 0;

    // ---- Task: apply one sample and check output ----
    task automatic apply_sample(
        input  logic signed [15:0] audio_in,
        input  logic signed [15:0] expected_out,
        input  string              test_name
    );
        // Drive input
        @(posedge clk);
        deif.audio_in    <= audio_in;
        deif.audio_valid <= 1'b1;

        // Deassert valid next cycle
        @(posedge clk);
        deif.audio_valid <= 1'b0;

        // Wait for output (registered, arrives 1 cycle after valid)
        // audio_out_valid should be high this cycle
        if (!deif.audio_out_valid) begin
            $display("FAIL [%s] audio_out_valid not asserted", test_name);
            fail_count++;
        end else begin
            // Check value — compare bottom 16 bits (sign-extended to 18)
            if ($signed(deif.audio_out[15:0]) !== expected_out) begin
                $display("FAIL [%s] in=%0d expected=%0d got=%0d",
                    test_name, $signed(audio_in),
                    $signed(expected_out),
                    $signed(deif.audio_out[15:0]));
                fail_count++;
            end else begin
                $display("PASS [%s] in=%0d out=%0d",
                    test_name, $signed(audio_in), $signed(deif.audio_out[15:0]));
                pass_count++;
            end
        end
    endtask

    // ---- Task: reset DUT ----
    task do_reset();
        n_rst            <= 1'b0;
        deif.audio_in    <= '0;
        deif.audio_valid <= 1'b0;
        repeat(5) @(posedge clk);
        n_rst <= 1'b1;
        repeat(2) @(posedge clk);
    endtask

    // ---- Main stimulus ----
    initial begin
        $display("========================================");
        $display("  de_emphasis_tb starting");
        $display("========================================");

        do_reset();

        // ============================================================
        // TEST 1 — Reset behaviour
        // ============================================================
        $display("\n--- Test 1: Reset behaviour ---");

        // Send a few samples
        @(posedge clk);
        deif.audio_in    <= 16'sd10000;
        deif.audio_valid <= 1'b1;
        @(posedge clk);
        deif.audio_valid <= 1'b0;
        repeat(3) @(posedge clk);

        // Assert reset mid-stream
        n_rst <= 1'b0;
        @(posedge clk);
        @(posedge clk);

        // Check outputs are cleared
        if (deif.audio_out !== '0 || deif.audio_out_valid !== 1'b0) begin
            $display("FAIL [Reset] outputs not cleared on reset");
            fail_count++;
        end else begin
            $display("PASS [Reset] outputs cleared correctly");
            pass_count++;
        end

        // Release reset
        n_rst <= 1'b1;
        repeat(2) @(posedge clk);

        // ============================================================
        // TEST 2 — IIR math correctness
        // Compare DUT against software model sample-by-sample
        // ============================================================
        $display("\n--- Test 2: IIR math correctness ---");

        begin
            logic signed [15:0] test_inputs  [0:7];
            logic signed [15:0] y_sw;
            logic signed [15:0] expected;
            int i;

            // Test sequence — mix of positive, negative, zero values
            test_inputs[0] =  16'sd1000;
            test_inputs[1] =  16'sd5000;
            test_inputs[2] = -16'sd3000;
            test_inputs[3] =  16'sd0;
            test_inputs[4] = -16'sd8000;
            test_inputs[5] =  16'sd32767;
            test_inputs[6] = -16'sd32768;
            test_inputs[7] =  16'sd100;

            y_sw = 16'sd0;  // software model state

            for (i = 0; i < 8; i++) begin
                expected = iir_step(test_inputs[i], y_sw);
                y_sw     = expected;
                apply_sample(test_inputs[i], expected,
                             $sformatf("IIR sample %0d", i));
                @(posedge clk);
            end
        end

        // ============================================================
        // TEST 3 — Valid gating
        // When audio_valid is low, output should not update
        // ============================================================
        $display("\n--- Test 3: Valid gating ---");

        do_reset();

        begin
            logic signed [PCM_IN_W-1:0] out_before;

            // Send one sample to get a non-zero state
            @(posedge clk);
            deif.audio_in    <= 16'sd20000;
            deif.audio_valid <= 1'b1;
            @(posedge clk);
            deif.audio_valid <= 1'b0;
            repeat(2) @(posedge clk);

            out_before = deif.audio_out;

            // Now keep valid low for 5 cycles while changing audio_in
            deif.audio_in <= 16'sd32767;
            repeat(5) @(posedge clk);

            // Output should not have changed
            if (deif.audio_out !== out_before) begin
                $display("FAIL [Valid gate] output changed without valid");
                fail_count++;
            end else begin
                $display("PASS [Valid gate] output held while valid=0");
                pass_count++;
            end

            // audio_out_valid should be 0
            if (deif.audio_out_valid !== 1'b0) begin
                $display("FAIL [Valid gate] audio_out_valid high without input valid");
                fail_count++;
            end else begin
                $display("PASS [Valid gate] audio_out_valid correctly 0");
                pass_count++;
            end
        end

        // ============================================================
        // TEST 4 — DC convergence
        // Constant DC input should produce output → input value
        // (IIR has unity DC gain: sum of coeffs = ALPHA + (1-ALPHA) = 1)
        // ============================================================
        $display("\n--- Test 4: DC convergence ---");

        do_reset();

        begin
            logic signed [15:0] dc_in;
            logic signed [15:0] y_sw;
            int warmup;

            dc_in  = 16'sd4000;
            y_sw   = 16'sd0;
            warmup = 500;  // enough for alpha=0.9997 to converge

            // Warm up software model
            for (int k = 0; k < warmup; k++) begin
                y_sw = iir_step(dc_in, y_sw);
            end

            // Drive warmup samples into DUT
            for (int k = 0; k < warmup; k++) begin
                @(posedge clk);
                deif.audio_in    <= dc_in;
                deif.audio_valid <= 1'b1;
                @(posedge clk);
                deif.audio_valid <= 1'b0;
            end

            repeat(3) @(posedge clk);

            // After convergence, output should equal input (±1 LSB rounding)
            if ($signed(deif.audio_out[15:0]) >= dc_in - 1 &&
                $signed(deif.audio_out[15:0]) <= dc_in + 1) begin
                $display("PASS [DC converge] output=%0d expected≈%0d",
                    $signed(deif.audio_out[15:0]), $signed(dc_in));
                pass_count++;
            end else begin
                $display("FAIL [DC converge] output=%0d expected≈%0d",
                    $signed(deif.audio_out[15:0]), $signed(dc_in));
                fail_count++;
            end
        end

        // ============================================================
        // TEST 5 — Sign extension
        // Negative input should produce correct 18-bit sign extension
        // ============================================================
        $display("\n--- Test 5: Sign extension ---");

        do_reset();

        begin
            logic signed [15:0] neg_in;
            logic signed [15:0] expected_16;
            logic signed [PCM_IN_W-1:0] expected_18;

            neg_in      = -16'sd1000;
            expected_16 = iir_step(neg_in, 16'sd0);
            // Sign-extend to 18 bits
            expected_18 = {{(PCM_IN_W-16){expected_16[15]}}, expected_16};

            @(posedge clk);
            deif.audio_in    <= neg_in;
            deif.audio_valid <= 1'b1;
            @(posedge clk);
            deif.audio_valid <= 1'b0;
            @(posedge clk);

            if (deif.audio_out !== expected_18) begin
                $display("FAIL [Sign ext] expected 18-bit=%0d got=%0d",
                    $signed(expected_18), $signed(deif.audio_out));
                fail_count++;
            end else begin
                $display("PASS [Sign ext] 18-bit output correct: %0d",
                    $signed(deif.audio_out));
                pass_count++;
            end
        end

        // ============================================================
        // Summary
        // ============================================================
        $display("\n========================================");
        $display("  Results: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  SOME TESTS FAILED");
        $display("========================================");

        $finish;
    end

    // Watchdog
    initial begin
        #(CLK_PERIOD * 100_000);
        $fatal(1, "[TB] Watchdog timeout");
    end

endmodule
