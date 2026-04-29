`include "fm_demodulate_if.vh"

module fm_demodulate #(
    // ============================================================
    // User-tunable parameters
    // ============================================================
    parameter int IN_W        = 16,   // width of input I/Q samples
    parameter int OUT_W       = 16,   // width of output audio sample
    parameter int SCALE_W     = 16,   // width of constant post-scale factor
    parameter int EPSILON     = 16,   // minimum denominator to avoid divide-by-zero

    // Fixed-point gain after demodulation.
    // This corresponds to the Python line:
    //   recovered_audio *= SDR_SAMPLE_RATE / (2 * np.pi * MAX_FREQUENCY_DEVIATION)
    //
    // In real hardware this should be a fixed-point constant chosen carefully.
    parameter logic signed [SCALE_W-1:0] SCALE_CONST = 16'sd1 // needs to be tuned to smth
)(
    input clk, n_rst,
    fm_demodulate_if.fd fdif
);

    // ============================================================
    // Derived widths
    // ============================================================
    localparam int DIFF_W   = IN_W + 1;           // subtraction may grow by 1 bit
    localparam int SQ_W     = 2 * IN_W;           // I*I or Q*Q
    localparam int PROD_W   = IN_W + DIFF_W;      // I*dQ or Q*dI
    localparam int NUM_W    = PROD_W + 1;         // subtraction of two products
    localparam int DEN_W    = SQ_W + 1;           // I^2 + Q^2
    localparam int QUOT_W   = NUM_W;              // quotient width chosen same as numerator
    localparam int SCALE_OUT_W = QUOT_W + SCALE_W;

    // ============================================================
    // Stage 0 registers: previous input samples
    // These implement the memory needed for np.diff(...)
    // ============================================================
    logic signed [IN_W-1:0] prev_i_r, prev_q_r;

    // ============================================================
    // Stage 1: delta computation
    //
    // Python correlation:
    //   i_channel = iq_filtered.real.copy()
    //   q_channel = iq_filtered.imag.copy()
    //
    //   delta_i = np.diff(i_channel, prepend=i_channel[0])
    //   delta_q = np.diff(q_channel, prepend=q_channel[0])
    //
    // In streaming RTL, prepend behavior is approximated by initializing
    // prev_i_r and prev_q_r to zero on reset. On the first valid sample:
    //   dI = I[0] - 0
    //   dQ = Q[0] - 0
    // If you want exact Python prepend behavior, you can special-case the
    // first sample so dI=dQ=0.
    // ============================================================

    // Stage 1 combinational signals
    logic                        s1_valid_c;
    logic signed [IN_W-1:0]      s1_i_c, s1_q_c;
    logic signed [DIFF_W-1:0]    s1_dI_c, s1_dQ_c;

    // Stage 1 registered signals
    logic                        s1_valid_r;
    logic signed [IN_W-1:0]      s1_i_r, s1_q_r;
    logic signed [DIFF_W-1:0]    s1_dI_r, s1_dQ_r;

    always_comb begin
        s1_valid_c = fdif.i_valid;
        s1_i_c     = fdif.i_i;
        s1_q_c     = fdif.i_q;

        // delta_i = current I - previous I
        // delta_q = current Q - previous Q
        s1_dI_c    = $signed(fdif.i_i) - $signed(prev_i_r);
        s1_dQ_c    = $signed(fdif.i_i) - $signed(prev_q_r);
    end

    // ============================================================
    // Stage 2: numerator and denominator
    //
    // Python correlation:
    //   numerator   = i_channel * delta_q - q_channel * delta_i
    //   denominator = i_channel**2 + q_channel**2
    //
    // This is the heart of the FM IQ discriminator:
    //   y = (I*dQ - Q*dI) / (I^2 + Q^2)
    // ============================================================

    // Stage 2 combinational signals
    logic                        s2_valid_c;
    logic signed [NUM_W-1:0]     s2_num_c;
    logic        [DEN_W-1:0]     s2_den_c;

    logic signed [PROD_W-1:0]    s2_mult_idq_c;
    logic signed [PROD_W-1:0]    s2_mult_qdi_c;
    logic        [SQ_W-1:0]      s2_sq_i_c;
    logic        [SQ_W-1:0]      s2_sq_q_c;

    // Stage 2 registered signals
    logic                        s2_valid_r;
    logic signed [NUM_W-1:0]     s2_num_r;
    logic        [DEN_W-1:0]     s2_den_r;

    always_comb begin
        s2_valid_c = s1_valid_r;

        // numerator = I*dQ - Q*dI
        s2_mult_idq_c = $signed(s1_i_r) * $signed(s1_dQ_r);
        s2_mult_qdi_c = $signed(s1_q_r) * $signed(s1_dI_r);
        s2_num_c      = $signed(s2_mult_idq_c) - $signed(s2_mult_qdi_c);

        // denominator = I^2 + Q^2
        s2_sq_i_c     = $unsigned($signed(s1_i_r) * $signed(s1_i_r));
        s2_sq_q_c     = $unsigned($signed(s1_q_r) * $signed(s1_q_r));
        s2_den_c      = s2_sq_i_c + s2_sq_q_c;
    end

    // ============================================================
    // Stage 3: denominator clamp
    //
    // Python correlation:
    //   denominator = np.where(denominator < 1e-10, 1e-10, denominator)
    //
    // Hardware version:
    //   if denominator < EPSILON, force denominator = EPSILON
    // ============================================================

    // Stage 3 combinational signals
    logic                        s3_valid_c;
    logic signed [NUM_W-1:0]     s3_num_c;
    logic        [DEN_W-1:0]     s3_den_c;

    // Stage 3 registered signals
    logic                        s3_valid_r;
    logic signed [NUM_W-1:0]     s3_num_r;
    logic        [DEN_W-1:0]     s3_den_r;

    always_comb begin
        s3_valid_c = s2_valid_r;
        s3_num_c   = s2_num_r;

        if (s2_den_r < EPSILON)
            s3_den_c = EPSILON;
        else
            s3_den_c = s2_den_r;
    end

    // ============================================================
    // Stage 4: division
    //
    // Python correlation:
    //   recovered_audio = numerator / denominator
    //
    // IMPORTANT:
    // This uses '/' for clarity. In a production FPGA/ASIC design,
    // replace this stage with:
    //   - pipelined divider IP, or
    //   - reciprocal approximation
    //
    // If you replace it with a divider IP of latency N cycles, then
    // you must delay valid by N cycles as well.
    // ============================================================

    // Stage 4 combinational signals
    logic                        s4_valid_c;
    logic signed [QUOT_W-1:0]    s4_quot_c;

    // Stage 4 registered signals
    logic                        s4_valid_r;
    logic signed [QUOT_W-1:0]    s4_quot_r;

    always_comb begin
        s4_valid_c = s3_valid_r;

        // Cast denominator to signed positive before division
        s4_quot_c  = s3_num_r / $signed({1'b0, s3_den_r}); // replace w/ divider block here
    end

    // ============================================================
    // Stage 5: fixed gain scaling
    //
    // Python correlation:
    //   recovered_audio *= SDR_SAMPLE_RATE / (2 * np.pi * MAX_FREQUENCY_DEVIATION)
    //
    // This RTL version uses a fixed-point constant SCALE_CONST.
    // ============================================================

    // Stage 5 combinational signals
    logic                        s5_valid_c;
    logic signed [SCALE_OUT_W-1:0] s5_scaled_c;

    // Stage 5 registered signals
    logic                        s5_valid_r;
    logic signed [SCALE_OUT_W-1:0] s5_scaled_r;

    always_comb begin
        s5_valid_c  = s4_valid_r;
        // s5_scaled_c = s4_quot_r * SCALE_CONST;
        s5_scaled_c = (s4_quot_r >> 5) * 15;
    end

    // ============================================================
    // Stage 6: rounding/truncation + saturation to OUT_W
    //
    // Python correlation:
    //   return recovered_audio
    //
    // The Python code later does block normalization:
    //   loudest_peak = np.max(np.abs(recovered_audio))
    //   recovered_audio = recovered_audio / loudest_peak * 0.80
    //
    // That block normalization is NOT naturally streaming RTL, so it is
    // intentionally omitted here.
    //
    // This stage simply converts the scaled internal value into the desired
    // output width.
    // ============================================================

    logic                        s6_valid_c;
    logic signed [OUT_W-1:0]     s6_audio_c;

    // Temporary values for saturation
    logic signed [QUOT_W-1:0]    s6_shifted_c;
    logic signed [OUT_W-1:0]     sat_max_c, sat_min_c;

    always_comb begin
        s6_valid_c = s5_valid_r;

        // Saturation bounds for signed OUT_W
        sat_max_c = {1'b0, {(OUT_W-1){1'b1}}};   //  0111...111
        sat_min_c = {1'b1, {(OUT_W-1){1'b0}}};   //  1000...000

        // Simple bit extraction / rescaling:
        // pick a centered slice from the scaled result
        //
        // Depending on your chosen fixed-point convention, this slice may
        // need adjustment. This is one of the main tuning points in real DSP RTL.
        s6_shifted_c = s5_scaled_r[SCALE_OUT_W-2 -: QUOT_W];

        // Saturate to output width
        if (s6_shifted_c > $signed(sat_max_c))
            s6_audio_c = sat_max_c;
        else if (s6_shifted_c < $signed(sat_min_c))
            s6_audio_c = sat_min_c;
        else
            s6_audio_c = s6_shifted_c[OUT_W-1:0];
    end

    // ============================================================
    // Sequential pipeline registers
    // ============================================================
    always_ff @(posedge clk or negedge n_rst) begin
        if (!n_rst) begin
            // Previous-sample memory
            prev_i_r   <= '0;
            prev_q_r   <= '0;

            // Stage 1 regs
            s1_valid_r <= 1'b0;
            s1_i_r     <= '0;
            s1_q_r     <= '0;
            s1_dI_r    <= '0;
            s1_dQ_r    <= '0;

            // Stage 2 regs
            s2_valid_r <= 1'b0;
            s2_num_r   <= '0;
            s2_den_r   <= '0;

            // Stage 3 regs
            s3_valid_r <= 1'b0;
            s3_num_r   <= '0;
            s3_den_r   <= '0;

            // Stage 4 regs
            s4_valid_r <= 1'b0;
            s4_quot_r  <= '0;

            // Stage 5 regs
            s5_valid_r  <= 1'b0;
            s5_scaled_r <= '0;

            // Output regs
            fdif.o_valid    <= 1'b0;
            fdif.o_audio    <= '0;
        end
        else begin
            // ----------------------------------------------------
            // Previous-sample storage
            // Used by Stage 1 to compute dI and dQ
            // ----------------------------------------------------
            if (fdif.i_valid) begin
                prev_i_r <= fdif.i_i;
                prev_q_r <= fdif.i_q;
            end

            // ----------------------------------------------------
            // Register Stage 1 outputs
            // Corresponds to:
            //   delta_i = np.diff(i_channel, prepend=i_channel[0])
            //   delta_q = np.diff(q_channel, prepend=q_channel[0])
            // ----------------------------------------------------
            s1_valid_r <= s1_valid_c;
            s1_i_r     <= s1_i_c;
            s1_q_r     <= s1_q_c;
            s1_dI_r    <= s1_dI_c;
            s1_dQ_r    <= s1_dQ_c;

            // ----------------------------------------------------
            // Register Stage 2 outputs
            // Corresponds to:
            //   numerator   = i_channel * delta_q - q_channel * delta_i
            //   denominator = i_channel**2 + q_channel**2
            // ----------------------------------------------------
            s2_valid_r <= s2_valid_c;
            s2_num_r   <= s2_num_c;
            s2_den_r   <= s2_den_c;

            // ----------------------------------------------------
            // Register Stage 3 outputs
            // Corresponds to:
            //   denominator = np.where(denominator < 1e-10, 1e-10, denominator)
            // ----------------------------------------------------
            s3_valid_r <= s3_valid_c;
            s3_num_r   <= s3_num_c;
            s3_den_r   <= s3_den_c;

            // ----------------------------------------------------
            // Register Stage 4 outputs
            // Corresponds to:
            //   recovered_audio = numerator / denominator
            // ----------------------------------------------------
            s4_valid_r <= s4_valid_c;
            s4_quot_r  <= s4_quot_c;

            // ----------------------------------------------------
            // Register Stage 5 outputs
            // Corresponds to:
            //   recovered_audio *= SDR_SAMPLE_RATE / (2 * np.pi * MAX_FREQUENCY_DEVIATION)
            // ----------------------------------------------------
            s5_valid_r  <= s5_valid_c;
            s5_scaled_r <= s5_scaled_c;

            // ----------------------------------------------------
            // Register final output
            // Corresponds to final returned demodulated sample
            // ----------------------------------------------------
            fdif.o_valid <= s6_valid_c;
            fdif.o_audio <= s6_audio_c;
        end
    end

endmodule
