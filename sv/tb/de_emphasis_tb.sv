`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/de_emphasis_if.vh"

// ============================================================
// de_emphasis_tb.sv
// ============================================================
// Verifies de_emphasis.sv across 5 tests:
//   Test 1 — Reset behaviour
//   Test 2 — IIR math correctness (sample-by-sample comparison)
//   Test 3 — Valid gating (output frozen when valid=0)
//   Test 4 — DC convergence (unity DC gain check)
//   Test 5 — Negative 18-bit output (sign bit propagates correctly)
// ============================================================

module de_emphasis_tb;
    import types::*;

    localparam CLK_PERIOD = 10;
    logic clk, n_rst;
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    de_emphasis_if deif();

    de_emphasis u_dut (
        .clk(clk),
        .n_rst(n_rst),
        .deif(deif)
    );

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
        @(posedge clk);
        deif.audio_in    <= audio_in;
        deif.audio_valid <= 1'b1;

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

    task do_reset();
        n_rst            <= 1'b0;
        deif.audio_in    <= '0;
        deif.audio_valid <= 1'b0;
        repeat(5) @(posedge clk);
        n_rst <= 1'b1;
        repeat(2) @(posedge clk);
    endtask

    initial begin
        $display("========================================");
        $display("  de_emphasis_tb starting");
        $display("========================================");

        do_reset();

        // ============================================================
        // TEST 1 — Reset behaviour
        // ============================================================
        $display("\n--- Test 1: Reset behaviour ---");

        // Drive a large sample to get non-zero state
        @(posedge clk);
        deif.audio_in    <= 18'sd32767;
        deif.audio_valid <= 1'b1;
        @(posedge clk);
        deif.audio_valid <= 1'b0;
        repeat(3) @(posedge clk);

        // Assert reset
        n_rst <= 1'b0;
        @(posedge clk);
        @(posedge clk);

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
            end
        end

        // ============================================================
        // TEST 3 — Valid gating
        // Output must not update when audio_valid=0
        // ============================================================
        $display("\n--- Test 3: Valid gating ---");

        do_reset();

        begin
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
        // After many identical samples, output → steady state.
        // With truncating integer arithmetic the IIR converges to
        // floor(ONE_MINUS_ALPHA * dc_in / ONE_MINUS_ALPHA) not dc_in.
        // We find the true converged value from the software model
        // and compare against that within ±1 LSB.
        // ============================================================
        $display("\n--- Test 4: DC convergence ---");

        do_reset();

        begin
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
                @(posedge clk);
                deif.audio_in    <= dc_in;
                deif.audio_valid <= 1'b1;
                @(posedge clk);
                deif.audio_valid <= 1'b0;
            end

            repeat(3) @(posedge clk);

            if ($signed(deif.audio_out) >= $signed(y_sw) - 1 &&
                $signed(deif.audio_out) <= $signed(y_sw) + 1) begin
                $display("PASS [DC converge] DUT=%0d matches model=%0d (±1 LSB)",
                    $signed(deif.audio_out), $signed(y_sw));
                pass_count++;
            end else begin
                $display("FAIL [DC converge] DUT=%0d, model=%0d",
                    $signed(deif.audio_out), $signed(y_sw));
                fail_count++;
            end
        end

        // ============================================================
        // TEST 5 — Negative 18-bit output
        // Drive negative samples and verify the sign bit propagates
        // correctly through the 18-bit accumulator and output register.
        // ============================================================
        $display("\n--- Test 5: Negative 18-bit output ---");

        do_reset();

        begin
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
                pass_count++;
            end
        end

        // ============================================================
        // Summary
        // ============================================================
        $display("\n========================================");
        $display("  Results: %0d passed, %0d failed",
            pass_count, fail_count);
        if (fail_count == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  SOME TESTS FAILED");
        $display("========================================");

        $finish;
    end

    // Watchdog — Test 4 runs 10000 samples so needs a long timeout
    initial begin
        #(CLK_PERIOD * 10_000 * 3);
        $fatal(1, "[TB] Watchdog timeout");
    end

endmodule
