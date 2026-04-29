`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/dc_offset_if.vh"
`include "../include/lpf_wrapper_if.vh"
`include "../include/decimation_if.vh"
`include "../include/fm_demodulate_if.vh"
`include "../include/de_emphasis_if.vh"

module pipeline_tb;
    import types::*;

    // 100 MHz clock and SDR sample spacing
    localparam CLK_PERIOD  = 10;
    localparam SDR_PERIOD  = 453;
    localparam NUM_SAMPLES = 5000;

    logic clk, n_rst;

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // pipeline interfaces
    dc_offset_if     dcif();
    lpf_wrapper_if   lpfif();
    decimation_if    decimif();
    fm_demodulate_if fdif();
    de_emphasis_if   deif();

    // connect pipeline stages
    assign lpfif.corr_i      = dcif.corr_i;
    assign lpfif.corr_q      = dcif.corr_q;
    assign lpfif.corr_valid  = dcif.corr_valid;

    assign decimif.lpf_i     = lpfif.lpf_i;
    assign decimif.lpf_q     = lpfif.lpf_q;
    assign decimif.lpf_valid = lpfif.lpf_valid;

    assign fdif.i_i          = decimif.decim_i;
    assign fdif.i_q          = decimif.decim_q;
    assign fdif.i_valid      = decimif.decim_valid;

    assign deif.audio_in     = fdif.o_audio;
    assign deif.audio_valid  = fdif.o_valid;

    // DUT stages
    dc_offset u_dc_offset (
        .clk(clk),
        .n_rst(n_rst),
        .dcif(dcif)
    );

    lpf_wrapper u_lpf_wrapper (
        .clk(clk),
        .n_rst(n_rst),
        .lpfif(lpfif)
    );

    decimation #(.DECIM_FACTOR(6)) u_decimation (
        .clk(clk),
        .n_rst(n_rst),
        .decimif(decimif)
    );

    fm_demodulate u_fm_demodulate (
        .clk(clk),
        .n_rst(n_rst),
        .fdif(fdif)
    );

    de_emphasis u_de_emphasis (
        .clk(clk),
        .n_rst(n_rst),
        .deif(deif)
    );

    // packed samples: [15:8] = I, [7:0] = Q
    logic [15:0] iq_mem [0:NUM_SAMPLES-1];

    initial $readmemh("iq_samples.hex", iq_mem);

    integer rtl_out_file;
    integer rtl_demod_file;

    integer sample_idx;

    initial begin
        rtl_out_file   = $fopen("rtl_output.txt", "w");
        rtl_demod_file = $fopen("rtl_demod_output.txt", "w");

        if (rtl_out_file == 0)
            $fatal(1, "Could not open rtl_output.txt");

        if (rtl_demod_file == 0)
            $fatal(1, "Could not open rtl_demod_output.txt");

        // reset everything before sending samples
        n_rst             <= 1'b0;
        dcif.sample_i     <= '0;
        dcif.sample_q     <= '0;
        dcif.sample_valid <= 1'b0;

        repeat(10) @(posedge clk);
        n_rst <= 1'b1;
        repeat(5) @(posedge clk);

        // send one I/Q sample at the SDR rate
        for (sample_idx = 0; sample_idx < NUM_SAMPLES; sample_idx++) begin
            @(posedge clk);

            dcif.sample_i     <= iq_mem[sample_idx][15:8];
            dcif.sample_q     <= iq_mem[sample_idx][7:0];
            dcif.sample_valid <= 1'b1;

            @(posedge clk);
            dcif.sample_valid <= 1'b0;

            repeat(SDR_PERIOD - 2) @(posedge clk);
        end

        // give the pipeline time to flush
        repeat(SDR_PERIOD * 10) @(posedge clk);

        $fclose(rtl_out_file);
        $fclose(rtl_demod_file);

        $display("[TB] Simulation complete. Check rtl_output.txt and rtl_demod_output.txt");
        $finish;
    end

    // final audio output
    always_ff @(posedge clk) begin
        if (deif.audio_out_valid)
            $fdisplay(rtl_out_file, "%0d", $signed(deif.audio_out));
    end

    // demod output for stage-level debug
    always_ff @(posedge clk) begin
        if (fdif.o_valid)
            $fdisplay(rtl_demod_file, "%0d", $signed(fdif.o_audio));
    end

    // catch sims that get stuck
    initial begin
        #(CLK_PERIOD * SDR_PERIOD * (NUM_SAMPLES + 100));
        $fatal(1, "[TB] Watchdog timeout, simulation took too long");
    end

endmodule
