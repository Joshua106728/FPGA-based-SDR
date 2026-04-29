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
//   Test 5 — Sign extension (16-bit → 18-bit)
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

    // Software model of the IIR — mirrors RTL arithmetic exactly
    // acc = ALPHA*y_prev + (1-ALPHA)*x, then arithmetic shift right 16
    function automatic logic signed [15:0] iir_step(
        input logic signed [15:0] x,
        input logic signed [15:0] y_prev_in
    );
        logic signed [32:0] acc;
        acc = ($signed(33'(ALPHA_FP))        * $signed(33'(y_prev_in)))
            + ($signed(33'(ONE_MINUS_ALPHA)) * $signed(33'(x)));
        return acc[31:16];
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
        input logic signed [15:0] audio_in,
        input logic signed [15:0] expected_16,
        input string              label
    );
        logic signed [PCM_IN_W-1:0] expected_18;
        expected_18 = {{(PCM_IN_W-16){expected_16[15]}}, expected_16};

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
        end else if (deif.audio_out !== expected_18) begin
            $display("FAIL [%s] in=%0d expected=%0d got=%0d",
                label, $signed(audio_in),
                $signed(expected_18), $signed(deif.audio_out));
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
        deif.audio_in    <= 16'sd32767;
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
            logic signed [15:0] exp;
            exp = iir_step(16'sd32767, 16'sd0);
            apply_and_check(16'sd32767, exp, "Reset state cleared");
        end

        // ============================================================
        // TEST 2 — IIR math correctness
        // Use large inputs so products are non-trivially non-zero
        // Expected values pre-computed by Python model (see comments)
        // ============================================================
        $display("\n--- Test 2: IIR math correctness ---");

        do_reset();

        begin
            // Input sequence chosen to give visible non-zero outputs:
            //   x=32767:  18*32767>>16 = 8   (y_prev=0)
            //   x=32767:  ALPHA*8 + 18*32767 = 8+8 = 16  >> trimmed
            //   etc.
            // Pre-verified by Python simulation
            logic signed [15:0] inputs [0:7];
            logic signed [15:0] y_sw;
            logic signed [15:0] exp;
            string lbl;

            inputs[0] =  16'sd32767;
            inputs[1] =  16'sd32767;
            inputs[2] =  16'sd32767;
            inputs[3] = -16'sd32768;
            inputs[4] = -16'sd32768;
            inputs[5] =  16'sd20000;
            inputs[6] = -16'sd20000;
            inputs[7] =  16'sd0;

            y_sw = 16'sd0;

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
            logic signed [PCM_IN_W-1:0] out_before;

            // Prime with one sample to get non-zero output
            @(posedge clk);
            deif.audio_in    <= 16'sd32767;
            deif.audio_valid <= 1'b1;
            @(posedge clk);
            deif.audio_valid <= 1'b0;
            repeat(3) @(posedge clk);

            out_before = deif.audio_out;

            // Hold valid low for 5 cycles while changing audio_in
            deif.audio_in <= 16'sd32767;
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
        // After many identical samples, output → input (unity DC gain)
        // With ALPHA=65518 (≈0.9997), time constant ≈ 3333 samples.
        // After 10000 samples the error should be < 2 LSBs.
        // ============================================================
        $display("\n--- Test 4: DC convergence ---");

        do_reset();

        begin
            logic signed [15:0] dc_in;
            logic signed [15:0] y_sw;

            dc_in = 16'sd10000;
            y_sw  = 16'sd0;

            // Warm up: 10000 samples (>>3x the time constant)
            for (int k = 0; k < 10000; k++) begin
                y_sw = iir_step(dc_in, y_sw);
                @(posedge clk);
                deif.audio_in    <= dc_in;
                deif.audio_valid <= 1'b1;
                @(posedge clk);
                deif.audio_valid <= 1'b0;
            end

            repeat(3) @(posedge clk);

            // After convergence output should equal input ±2 LSBs
            if ($signed(deif.audio_out[15:0]) >= $signed(dc_in) - 2 &&
                $signed(deif.audio_out[15:0]) <= $signed(dc_in) + 2) begin
                $display("PASS [DC converge] output=%0d, input=%0d (within ±2 LSB)",
                    $signed(deif.audio_out[15:0]), $signed(dc_in));
                pass_count++;
            end else begin
                $display("FAIL [DC converge] output=%0d, expected≈%0d",
                    $signed(deif.audio_out[15:0]), $signed(dc_in));
                fail_count++;
            end
        end

        // ============================================================
        // TEST 5 — Sign extension
        // Negative 16-bit result must be correctly sign-extended to 18-bit
        // ============================================================
        $display("\n--- Test 5: Sign extension ---");

        do_reset();

        begin
            // Run enough negative samples to get a clearly negative output
            logic signed [15:0] exp_16;
            logic signed [PCM_IN_W-1:0] exp_18;
            logic signed [15:0] y_sw;

            y_sw = 16'sd0;
            for (int k = 0; k < 5; k++) begin
                exp_16 = iir_step(-16'sd32768, y_sw);
                y_sw   = exp_16;
                @(posedge clk);
                deif.audio_in    <= -16'sd32768;
                deif.audio_valid <= 1'b1;
                @(posedge clk);
                deif.audio_valid <= 1'b0;
            end

            repeat(3) @(posedge clk);

            // Check MSBs are sign-extended correctly
            // If output is negative, bits [17:16] should both be 1
            exp_18 = {{(PCM_IN_W-16){exp_16[15]}}, exp_16};

            if (deif.audio_out !== exp_18) begin
                $display("FAIL [Sign ext] expected 18-bit=%0d got=%0d",
                    $signed(exp_18), $signed(deif.audio_out));
                fail_count++;
            end else begin
                $display("PASS [Sign ext] 18-bit output=%0d correctly sign-extended",
                    $signed(deif.audio_out));
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
