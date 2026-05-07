
`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/dc_offset_if.vh"
`include "../include/lpf_wrapper_if.vh"
`include "../include/decim_if.vh"
`include "../include/fm_demodulate_if.vh"
`include "../include/de_emphasis_if.vh"

module top_tb;
    import types::*;

    localparam CLK_PERIOD  = 10;
    localparam SDR_PERIOD  = 453;
    localparam NUM_SAMPLES = 5000;

    logic clk, n_rst;

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // Stage 1 (input): DC Offset
    dc_offset_if dcif();

    // Stage 2: Low Pass Filter
    lpf_wrapper_if lpfif();
    assign lpfif.corr_i     = dcif.corr_i;
    assign lpfif.corr_q     = dcif.corr_q;
    assign lpfif.corr_valid = dcif.corr_valid;

    // Stage 3: FM Demodulate
    fm_demodulate_if fmif();
    assign fmif.lpf_i     = lpfif.lpf_i;
    assign fmif.lpf_q     = lpfif.lpf_q;
    assign fmif.lpf_valid = lpfif.lpf_valid;

    // Stage 4: Decimation (220500 → 36750 Hz)
    decim_if decimif();
    assign decimif.demod_sample = fmif.demod_sample;
    assign decimif.demod_valid  = fmif.demod_valid;

    // Stage 5: De-emphasis
    de_emphasis_if deif();
    assign deif.audio_in    = decimif.decim_sample;
    assign deif.audio_valid = decimif.decim_valid;

    // DUT stages
    dc_offset     u_dc_offset     (.clk(clk), .n_rst(n_rst), .dcif(dcif));
    lpf_wrapper   u_lpf_wrapper   (.clk(clk), .n_rst(n_rst), .lpfif(lpfif));
    fm_demodulate u_fm_demodulate (.clk(clk), .n_rst(n_rst), .fmif(fmif));
    decim         u_decimation    (.clk(clk), .n_rst(n_rst), .decimif(decimif));
    de_emphasis   u_de_emphasis   (.clk(clk), .n_rst(n_rst), .deif(deif));

    // packed samples: [15:8] = I, [7:0] = Q
    logic [15:0] iq_mem [0:NUM_SAMPLES-1];
    initial $readmemh("iq_samples.hex", iq_mem);

    // ============================================================
    // Per-stage CSV output files.
    // Headers/format match fpga_pipeline_sim.py::save_stage_csv()
    // exactly so you can diff against the fpga_stage*_*.csv files.
    // ============================================================
    integer f_dc, f_lpf, f_demod, f_decim, f_deemph;

    // Independent sample counters per stage — each stage has its own
    // valid cadence (e.g. decimation only fires every 6th demod sample),
    // so each gets its own Sample_Index starting at 0.
    integer idx_dc, idx_lpf, idx_demod, idx_decim, idx_deemph;

    integer sample_idx;

    initial begin
        f_dc     = $fopen("hw_stage1_dc_offset.csv",  "w");
        f_lpf    = $fopen("hw_stage2_lpf.csv",        "w");
        f_demod  = $fopen("hw_stage3_demod.csv",      "w");
        f_decim  = $fopen("hw_stage4_decimated.csv",  "w");
        f_deemph = $fopen("hw_stage5_deemphasis.csv", "w");

        if (f_dc == 0 || f_lpf == 0 || f_demod == 0 ||
            f_decim == 0 || f_deemph == 0)
            $fatal(1, "Could not open one or more stage CSV files");

        // CSV headers — must match Python's save_stage_csv() output
        $fdisplay(f_dc,     "Sample_Index,col0,col1");
        $fdisplay(f_lpf,    "Sample_Index,col0,col1");
        $fdisplay(f_demod,  "Sample_Index,Value");
        $fdisplay(f_decim,  "Sample_Index,Value");
        $fdisplay(f_deemph, "Sample_Index,Value");

        idx_dc     = 0;
        idx_lpf    = 0;
        idx_demod  = 0;
        idx_decim  = 0;
        idx_deemph = 0;

        // reset before driving
        n_rst             = 1'b0;
        dcif.sample_i     = '0;
        dcif.sample_q     = '0;
        dcif.sample_valid = 1'b0;

        repeat(10) @(negedge clk);
        n_rst = 1'b1;
        repeat(5) @(negedge clk);

        // drive one I/Q sample per SDR period
        for (sample_idx = 0; sample_idx < NUM_SAMPLES; sample_idx++) begin
            @(negedge clk);
            dcif.sample_i     = iq_mem[sample_idx][15:8];
            dcif.sample_q     = iq_mem[sample_idx][7:0];
            dcif.sample_valid = 1'b1;

            @(negedge clk);
            dcif.sample_valid = 1'b0;

            repeat(SDR_PERIOD - 2) @(negedge clk);
        end

        // flush the pipeline (LPF taps + decimation + de-emphasis settling)
        repeat(SDR_PERIOD * 10) @(negedge clk);

        $fclose(f_dc);
        $fclose(f_lpf);
        $fclose(f_demod);
        $fclose(f_decim);
        $fclose(f_deemph);

        $display("[TB] Done. Wrote hw_stage{1..5}_*.csv");
        $display("[TB] Counts -> dc=%0d lpf=%0d demod=%0d decim=%0d deemph=%0d",
                 idx_dc, idx_lpf, idx_demod, idx_decim, idx_deemph);
        $finish;
    end

    // ============================================================
    // Stage capture — fires once per valid pulse on each interface.
    // $signed() ensures the CSV holds two's-complement signed ints,
    // which is what np.savetxt(fmt="%d") produces on the Python side.
    // ============================================================

    // Stage 1: dc_offset → Q7.10, 18-bit signed I/Q
    always_ff @(posedge clk) begin
        if (n_rst && dcif.corr_valid) begin
            $fdisplay(f_dc, "%0d,%0d,%0d", idx_dc,
                      $signed(dcif.corr_i), $signed(dcif.corr_q));
            idx_dc <= idx_dc + 1;
        end
    end

    // Stage 2: lpf_wrapper → 18-bit signed I/Q
    always_ff @(posedge clk) begin
        if (n_rst && lpfif.lpf_valid) begin
            $fdisplay(f_lpf, "%0d,%0d,%0d", idx_lpf,
                      $signed(lpfif.lpf_i), $signed(lpfif.lpf_q));
            idx_lpf <= idx_lpf + 1;
        end
    end

    // Stage 3: fm_demodulate → 16-bit signed mono @ SDR rate
    always_ff @(posedge clk) begin
        if (n_rst && fmif.demod_valid) begin
            $fdisplay(f_demod, "%0d,%0d", idx_demod,
                      $signed(fmif.demod_sample));
            idx_demod <= idx_demod + 1;
        end
    end

    // Stage 4: decimation → 16-bit signed mono @ 36750 Hz
    always_ff @(posedge clk) begin
        if (n_rst && decimif.decim_valid) begin
            $fdisplay(f_decim, "%0d,%0d", idx_decim,
                      $signed(decimif.decim_sample));
            idx_decim <= idx_decim + 1;
        end
    end

    // Stage 5: de_emphasis → 18-bit signed final audio
    always_ff @(posedge clk) begin
        if (n_rst && deif.audio_out_valid) begin
            $fdisplay(f_deemph, "%0d,%0d", idx_deemph,
                      $signed(deif.audio_out));
            idx_deemph <= idx_deemph + 1;
        end
    end

    // watchdog
    initial begin
        #(CLK_PERIOD * SDR_PERIOD * (NUM_SAMPLES + 100));
        $fatal(1, "[TB] Watchdog timeout, simulation took too long");
    end

endmodule