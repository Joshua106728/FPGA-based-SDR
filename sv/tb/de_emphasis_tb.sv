`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/de_emphasis_if.vh"

// ============================================================
// de_emphasis_tb.sv
// ============================================================
<<<<<<< HEAD
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
=======
// Verifies de_emphasis.sv across 5 tests:
//   Test 1 — Reset behaviour
//   Test 2 — IIR math correctness (sample-by-sample comparison)
//   Test 3 — Valid gating (output frozen when valid=0)
//   Test 4 — DC convergence (unity DC gain check)
//   Test 5 — Negative 18-bit output (sign bit propagates correctly)
>>>>>>> 1cd7d4fc36b4c0d9f5233e21d639811afce1dfed
// ============================================================

module de_emphasis_tb;
    import types::*;

<<<<<<< HEAD
    // ---- Clock ----
    localparam CLK_PERIOD = 10;  // 10ns = 100 MHz
=======
    localparam CLK_PERIOD = 10;
>>>>>>> 1cd7d4fc36b4c0d9f5233e21d639811afce1dfed
    logic clk, n_rst;
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

<<<<<<< HEAD
    // ---- Interface ----
    de_emphasis_if deif();

    // ---- DUT ----
=======
    de_emphasis_if deif();

>>>>>>> 1cd7d4fc36b4c0d9f5233e21d639811afce1dfed
    de_emphasis u_dut (
        .clk(clk),
        .n_rst(n_rst),
        .deif(deif)
    );

<<<<<<< HEAD
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
=======
    // Fixed-point parameters — must match de_emphasis.sv exactly
    localparam int ALPHA_FP        = 65518;
    localparam int ONE_MINUS_ALPHA = 18;

    // Software model of the IIR — mirrors RTL arithmetic exactly.
    // 18-bit I/O, 36-bit accumulator, extract bits [33:16] to drop
    // the 16 Q0.16 fractional bits.
    function automatic logic signed [DATA_DW-1:0] iir_step(
        input logic signed [DATA_DW-1:0] x,
        input logic signed [DATA_DW-1:0] y_prev_in
    );
        logic signed [35:0] acc;
        acc = ($signed({1'b0, 16'(ALPHA_FP)})        * $signed(y_prev_in))
            + ($signed({1'b0, 16'(ONE_MINUS_ALPHA)}) * $signed(x));
        return acc[33:16];
    endfunction

    int pass_count = 0;
    int fail_count = 0;

    // Drive one sample, wait for registered output, check value.
    // Timing:
    //   cycle N  : drive audio_in + audio_valid=1
    //   cycle N+1: deassert audio_valid, output register updates
    //              audio_out_valid goes high here
    //   cycle N+2: sample outputs
    task automatic apply_and_check(
        input logic signed [DATA_DW-1:0] audio_in,
        input logic signed [DATA_DW-1:0] expected,
        input string                      label
    );
        // Cycle N: drive input
>>>>>>> 1cd7d4fc36b4c0d9f5233e21d639811afce1dfed
        @(posedge clk);
        deif.audio_in    <= audio_in;
        deif.audio_valid <= 1'b1;

<<<<<<< HEAD
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
=======
        // Cycle N+1: deassert valid — output register updates this edge
        @(posedge clk);
        deif.audio_valid <= 1'b0;

        // Cycle N+2: outputs are stable, sample them
        @(posedge clk);

        if (!deif.audio_out_valid) begin
            $display("FAIL [%s] audio_out_valid not asserted", label);
            fail_count++;
        end else if (deif.audio_out !== expected) begin
            $display("FAIL [%s] in=%0d expected=%0d got=%0d",
                label, $signed(audio_in),
                $signed(expected), $signed(deif.audio_out));
            fail_count++;
        end else begin
            $display("PASS [%s] in=%0d out=%0d",
                label, $signed(audio_in), $signed(deif.audio_out));
            pass_count++;
        end
    endtask

>>>>>>> 1cd7d4fc36b4c0d9f5233e21d639811afce1dfed
    task do_reset();
        n_rst            <= 1'b0;
        deif.audio_in    <= '0;
        deif.audio_valid <= 1'b0;
        repeat(5) @(posedge clk);
        n_rst <= 1'b1;
        repeat(2) @(posedge clk);
    endtask

<<<<<<< HEAD
    // ---- Main stimulus ----
=======
>>>>>>> 1cd7d4fc36b4c0d9f5233e21d639811afce1dfed
    initial begin
        $display("========================================");
        $display("  de_emphasis_tb starting");
        $display("========================================");

        do_reset();

        // ============================================================
        // TEST 1 — Reset behaviour
        // ============================================================
        $display("\n--- Test 1: Reset behaviour ---");

<<<<<<< HEAD
        // Send a few samples
        @(posedge clk);
        deif.audio_in    <= 16'sd10000;
=======
        // Drive a large sample to get non-zero state
        @(posedge clk);
        deif.audio_in    <= 18'sd32767;
>>>>>>> 1cd7d4fc36b4c0d9f5233e21d639811afce1dfed
        deif.audio_valid <= 1'b1;
        @(posedge clk);
        deif.audio_valid <= 1'b0;
        repeat(3) @(posedge clk);

<<<<<<< HEAD
        // Assert reset mid-stream
=======
        // Assert reset
>>>>>>> 1cd7d4fc36b4c0d9f5233e21d639811afce1dfed
        n_rst <= 1'b0;
        @(posedge clk);
        @(posedge clk);

<<<<<<< HEAD
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
=======
        if (deif.audio_out !== '0) begin
            $display("FAIL [Reset] audio_out not cleared: got %0d",
                $signed(deif.audio_out));
            fail_count++;
        end else begin
            $display("PASS [Reset] audio_out cleared to 0");
            pass_count++;
        end

        if (deif.audio_out_valid !== 1'b0) begin
            $display("FAIL [Reset] audio_out_valid not cleared");
            fail_count++;
        end else begin
            $display("PASS [Reset] audio_out_valid cleared");
            pass_count++;
        end

        n_rst <= 1'b1;
        repeat(2) @(posedge clk);

        // Verify state reset: first sample after reset should match
        // iir_step(x, y_prev=0), not carry over previous state
        begin
            logic signed [DATA_DW-1:0] exp;
            exp = iir_step(18'sd32767, 18'sd0);
            apply_and_check(18'sd32767, exp, "Reset state cleared");
        end

        // ============================================================
        // TEST 2 — IIR math correctness
        // Use large inputs so products are non-trivially non-zero.
        // Expected values computed by the software model above.
        // ============================================================
        $display("\n--- Test 2: IIR math correctness ---");

        do_reset();

        begin
            logic signed [DATA_DW-1:0] inputs [0:7];
            logic signed [DATA_DW-1:0] y_sw;
            logic signed [DATA_DW-1:0] exp;
            string lbl;

            inputs[0] =  18'sd32767;
            inputs[1] =  18'sd32767;
            inputs[2] =  18'sd32767;
            inputs[3] = -18'sd32768;
            inputs[4] = -18'sd32768;
            inputs[5] =  18'sd20000;
            inputs[6] = -18'sd20000;
            inputs[7] =  18'sd0;

            y_sw = 18'sd0;

            for (int i = 0; i < 8; i++) begin
                exp  = iir_step(inputs[i], y_sw);
                y_sw = exp;
                lbl  = $sformatf("IIR[%0d]", i);
                apply_and_check(inputs[i], exp, lbl);
>>>>>>> 1cd7d4fc36b4c0d9f5233e21d639811afce1dfed
            end
        end

        // ============================================================
        // TEST 3 — Valid gating
<<<<<<< HEAD
        // When audio_valid is low, output should not update
=======
        // Output must not update when audio_valid=0
>>>>>>> 1cd7d4fc36b4c0d9f5233e21d639811afce1dfed
        // ============================================================
        $display("\n--- Test 3: Valid gating ---");

        do_reset();

        begin
<<<<<<< HEAD
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
=======
            logic signed [DATA_DW-1:0] out_before;

            // Prime with one sample to get non-zero output
            @(posedge clk);
            deif.audio_in    <= 18'sd32767;
            deif.audio_valid <= 1'b1;
            @(posedge clk);
            deif.audio_valid <= 1'b0;
            repeat(3) @(posedge clk);

            out_before = deif.audio_out;

            // Hold valid low for 5 cycles while changing audio_in
            deif.audio_in <= 18'sd32767;
            repeat(5) @(posedge clk);

            if (deif.audio_out !== out_before) begin
                $display("FAIL [Valid gate] output changed without valid: %0d → %0d",
                    $signed(out_before), $signed(deif.audio_out));
                fail_count++;
            end else begin
                $display("PASS [Valid gate] output held at %0d while valid=0",
                    $signed(out_before));
                pass_count++;
            end

>>>>>>> 1cd7d4fc36b4c0d9f5233e21d639811afce1dfed
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
<<<<<<< HEAD
        // Constant DC input should produce output → input value
        // (IIR has unity DC gain: sum of coeffs = ALPHA + (1-ALPHA) = 1)
=======
        // After many identical samples, output → steady state.
        // With truncating integer arithmetic the IIR converges to
        // floor(ONE_MINUS_ALPHA * dc_in / ONE_MINUS_ALPHA) not dc_in.
        // We find the true converged value from the software model
        // and compare against that within ±1 LSB.
>>>>>>> 1cd7d4fc36b4c0d9f5233e21d639811afce1dfed
        // ============================================================
        $display("\n--- Test 4: DC convergence ---");

        do_reset();

        begin
<<<<<<< HEAD
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
=======
            logic signed [DATA_DW-1:0] dc_in;
            logic signed [DATA_DW-1:0] y_sw;
            logic signed [DATA_DW-1:0] y_prev_sw;

            dc_in = 18'sd10000;
            y_sw  = 18'sd0;

            for (int k = 0; k < 1_000_000; k++) begin
                y_prev_sw = y_sw;
                y_sw      = iir_step(dc_in, y_sw);
                if (y_sw === y_prev_sw) break;
            end

            $display("[DC converge] Software model converged to %0d (input=%0d)",
                $signed(y_sw), $signed(dc_in));

            for (int k = 0; k < 10000; k++) begin
>>>>>>> 1cd7d4fc36b4c0d9f5233e21d639811afce1dfed
                @(posedge clk);
                deif.audio_in    <= dc_in;
                deif.audio_valid <= 1'b1;
                @(posedge clk);
                deif.audio_valid <= 1'b0;
            end

            repeat(3) @(posedge clk);

<<<<<<< HEAD
            // After convergence, output should equal input (±1 LSB rounding)
            if ($signed(deif.audio_out[15:0]) >= dc_in - 1 &&
                $signed(deif.audio_out[15:0]) <= dc_in + 1) begin
                $display("PASS [DC converge] output=%0d expected≈%0d",
                    $signed(deif.audio_out[15:0]), $signed(dc_in));
                pass_count++;
            end else begin
                $display("FAIL [DC converge] output=%0d expected≈%0d",
                    $signed(deif.audio_out[15:0]), $signed(dc_in));
=======
            if ($signed(deif.audio_out) >= $signed(y_sw) - 1 &&
                $signed(deif.audio_out) <= $signed(y_sw) + 1) begin
                $display("PASS [DC converge] DUT=%0d matches model=%0d (±1 LSB)",
                    $signed(deif.audio_out), $signed(y_sw));
                pass_count++;
            end else begin
                $display("FAIL [DC converge] DUT=%0d, model=%0d",
                    $signed(deif.audio_out), $signed(y_sw));
>>>>>>> 1cd7d4fc36b4c0d9f5233e21d639811afce1dfed
                fail_count++;
            end
        end

        // ============================================================
<<<<<<< HEAD
        // TEST 5 — Sign extension
        // Negative input should produce correct 18-bit sign extension
        // ============================================================
        $display("\n--- Test 5: Sign extension ---");
=======
        // TEST 5 — Negative 18-bit output
        // Drive negative samples and verify the sign bit propagates
        // correctly through the 18-bit accumulator and output register.
        // ============================================================
        $display("\n--- Test 5: Negative 18-bit output ---");
>>>>>>> 1cd7d4fc36b4c0d9f5233e21d639811afce1dfed

        do_reset();

        begin
<<<<<<< HEAD
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
=======
            logic signed [DATA_DW-1:0] exp;
            logic signed [DATA_DW-1:0] y_sw;

            y_sw = 18'sd0;
            for (int k = 0; k < 5; k++) begin
                exp  = iir_step(-18'sd32768, y_sw);
                y_sw = exp;
                @(posedge clk);
                deif.audio_in    <= -18'sd32768;
                deif.audio_valid <= 1'b1;
                @(posedge clk);
                deif.audio_valid <= 1'b0;
            end

            repeat(3) @(posedge clk);

            // Verify the full 18-bit signed output matches the model,
            // including both sign bits [17:16] being set for negative values
            if (deif.audio_out !== exp) begin
                $display("FAIL [Neg 18-bit] expected=%0d got=%0d",
                    $signed(exp), $signed(deif.audio_out));
                fail_count++;
            end else begin
                $display("PASS [Neg 18-bit] output=%0d, sign bits[17:16]=%02b",
                    $signed(deif.audio_out), deif.audio_out[17:16]);
>>>>>>> 1cd7d4fc36b4c0d9f5233e21d639811afce1dfed
                pass_count++;
            end
        end

        // ============================================================
        // Summary
        // ============================================================
        $display("\n========================================");
<<<<<<< HEAD
        $display("  Results: %0d passed, %0d failed", pass_count, fail_count);
=======
        $display("  Results: %0d passed, %0d failed",
            pass_count, fail_count);
>>>>>>> 1cd7d4fc36b4c0d9f5233e21d639811afce1dfed
        if (fail_count == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  SOME TESTS FAILED");
        $display("========================================");

        $finish;
    end

<<<<<<< HEAD
    // Watchdog
    initial begin
        #(CLK_PERIOD * 100_000);
=======
    // Watchdog — Test 4 runs 10000 samples so needs a long timeout
    initial begin
        #(CLK_PERIOD * 10_000 * 3);
>>>>>>> 1cd7d4fc36b4c0d9f5233e21d639811afce1dfed
        $fatal(1, "[TB] Watchdog timeout");
    end

endmodule
