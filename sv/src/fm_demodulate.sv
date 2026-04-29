// `include "fm_demodulate_if.vh"

// module fm_demodulate #(
//     // ============================================================
//     // User-tunable parameters
//     // ============================================================
//     parameter int IN_W        = 16,   // width of input I/Q samples
//     parameter int OUT_W       = 16,   // width of output audio sample
//     parameter int SCALE_W     = 16,   // width of constant post-scale factor
//     parameter int EPSILON     = 16,   // minimum denominator to avoid divide-by-zero

//     // Fixed-point gain after demodulation.
//     // This corresponds to the Python line:
//     //   recovered_audio *= SDR_SAMPLE_RATE / (2 * np.pi * MAX_FREQUENCY_DEVIATION)
//     //
//     // In real hardware this should be a fixed-point constant chosen carefully.
//     parameter logic signed [SCALE_W-1:0] SCALE_CONST = 16'sd1 // needs to be tuned to smth
// )(
//     input clk, n_rst,
//     fm_demodulate_if.fd fdif
// );

//     // ============================================================
//     // Derived widths
//     // ============================================================
//     localparam int DIFF_W   = IN_W + 1;           // subtraction may grow by 1 bit
//     localparam int SQ_W     = 2 * IN_W;           // I*I or Q*Q
//     localparam int PROD_W   = IN_W + DIFF_W;      // I*dQ or Q*dI
//     localparam int NUM_W    = PROD_W + 1;         // subtraction of two products
//     localparam int DEN_W    = SQ_W + 1;           // I^2 + Q^2
//     localparam int QUOT_W   = NUM_W;              // quotient width chosen same as numerator
//     localparam int SCALE_OUT_W = QUOT_W + SCALE_W;

//     // ============================================================
//     // Stage 0 registers: previous input samples
//     // These implement the memory needed for np.diff(...)
//     // ============================================================
//     logic signed [IN_W-1:0] prev_i_r, prev_q_r;

//     // ============================================================
//     // Stage 1: delta computation
//     //
//     // Python correlation:
//     //   i_channel = iq_filtered.real.copy()
//     //   q_channel = iq_filtered.imag.copy()
//     //
//     //   delta_i = np.diff(i_channel, prepend=i_channel[0])
//     //   delta_q = np.diff(q_channel, prepend=q_channel[0])
//     //
//     // In streaming RTL, prepend behavior is approximated by initializing
//     // prev_i_r and prev_q_r to zero on reset. On the first valid sample:
//     //   dI = I[0] - 0
//     //   dQ = Q[0] - 0
//     // If you want exact Python prepend behavior, you can special-case the
//     // first sample so dI=dQ=0.
//     // ============================================================

//     // Stage 1 combinational signals
//     logic                        s1_valid_c;
//     logic signed [IN_W-1:0]      s1_i_c, s1_q_c;
//     logic signed [DIFF_W-1:0]    s1_dI_c, s1_dQ_c;

//     // Stage 1 registered signals
//     logic                        s1_valid_r;
//     logic signed [IN_W-1:0]      s1_i_r, s1_q_r;
//     logic signed [DIFF_W-1:0]    s1_dI_r, s1_dQ_r;

//     always_comb begin
//         s1_valid_c = fdif.i_valid;
//         s1_i_c     = fdif.i_i;
//         s1_q_c     = fdif.i_q;

//         // delta_i = current I - previous I
//         // delta_q = current Q - previous Q
//         s1_dI_c    = $signed(fdif.i_i) - $signed(prev_i_r);
//         s1_dQ_c    = $signed(fdif.i_i) - $signed(prev_q_r);
//     end

//     // ============================================================
//     // Stage 2: numerator and denominator
//     //
//     // Python correlation:
//     //   numerator   = i_channel * delta_q - q_channel * delta_i
//     //   denominator = i_channel**2 + q_channel**2
//     //
//     // This is the heart of the FM IQ discriminator:
//     //   y = (I*dQ - Q*dI) / (I^2 + Q^2)
//     // ============================================================

//     // Stage 2 combinational signals
//     logic                        s2_valid_c;
//     logic signed [NUM_W-1:0]     s2_num_c;
//     logic        [DEN_W-1:0]     s2_den_c;

//     logic signed [PROD_W-1:0]    s2_mult_idq_c;
//     logic signed [PROD_W-1:0]    s2_mult_qdi_c;
//     logic        [SQ_W-1:0]      s2_sq_i_c;
//     logic        [SQ_W-1:0]      s2_sq_q_c;

//     // Stage 2 registered signals
//     logic                        s2_valid_r;
//     logic signed [NUM_W-1:0]     s2_num_r;
//     logic        [DEN_W-1:0]     s2_den_r;

//     always_comb begin
//         s2_valid_c = s1_valid_r;

//         // numerator = I*dQ - Q*dI
//         s2_mult_idq_c = $signed(s1_i_r) * $signed(s1_dQ_r);
//         s2_mult_qdi_c = $signed(s1_q_r) * $signed(s1_dI_r);
//         s2_num_c      = $signed(s2_mult_idq_c) - $signed(s2_mult_qdi_c);

//         // denominator = I^2 + Q^2
//         s2_sq_i_c     = $unsigned($signed(s1_i_r) * $signed(s1_i_r));
//         s2_sq_q_c     = $unsigned($signed(s1_q_r) * $signed(s1_q_r));
//         s2_den_c      = s2_sq_i_c + s2_sq_q_c;
//     end

//     // ============================================================
//     // Stage 3: denominator clamp
//     //
//     // Python correlation:
//     //   denominator = np.where(denominator < 1e-10, 1e-10, denominator)
//     //
//     // Hardware version:
//     //   if denominator < EPSILON, force denominator = EPSILON
//     // ============================================================

//     // Stage 3 combinational signals
//     logic                        s3_valid_c;
//     logic signed [NUM_W-1:0]     s3_num_c;
//     logic        [DEN_W-1:0]     s3_den_c;

//     // Stage 3 registered signals
//     logic                        s3_valid_r;
//     logic signed [NUM_W-1:0]     s3_num_r;
//     logic        [DEN_W-1:0]     s3_den_r;

//     always_comb begin
//         s3_valid_c = s2_valid_r;
//         s3_num_c   = s2_num_r;

//         if (s2_den_r < EPSILON)
//             s3_den_c = EPSILON;
//         else
//             s3_den_c = s2_den_r;
//     end

//     // ============================================================
//     // Stage 4: division
//     //
//     // Python correlation:
//     //   recovered_audio = numerator / denominator
//     //
//     // IMPORTANT:
//     // This uses '/' for clarity. In a production FPGA/ASIC design,
//     // replace this stage with:
//     //   - pipelined divider IP, or
//     //   - reciprocal approximation
//     //
//     // If you replace it with a divider IP of latency N cycles, then
//     // you must delay valid by N cycles as well.
//     // ============================================================

//     // Stage 4 combinational signals
//     logic                        s4_valid_c;
//     logic signed [QUOT_W-1:0]    s4_quot_c;

//     // Stage 4 registered signals
//     logic                        s4_valid_r;
//     logic signed [QUOT_W-1:0]    s4_quot_r;

//     always_comb begin
//         s4_valid_c = s3_valid_r;

//         // Cast denominator to signed positive before division
//         s4_quot_c  = s3_num_r / $signed({1'b0, s3_den_r}); // replace w/ divider block here
//     end

//     // ============================================================
//     // Stage 5: fixed gain scaling
//     //
//     // Python correlation:
//     //   recovered_audio *= SDR_SAMPLE_RATE / (2 * np.pi * MAX_FREQUENCY_DEVIATION)
//     //
//     // This RTL version uses a fixed-point constant SCALE_CONST.
//     // ============================================================

//     // Stage 5 combinational signals
//     logic                        s5_valid_c;
//     logic signed [SCALE_OUT_W-1:0] s5_scaled_c;

//     // Stage 5 registered signals
//     logic                        s5_valid_r;
//     logic signed [SCALE_OUT_W-1:0] s5_scaled_r;

//     always_comb begin
//         s5_valid_c  = s4_valid_r;
//         // s5_scaled_c = s4_quot_r * SCALE_CONST;
//         s5_scaled_c = (s4_quot_r >> 5) * 15;
//     end

//     // ============================================================
//     // Stage 6: rounding/truncation + saturation to OUT_W
//     //
//     // Python correlation:
//     //   return recovered_audio
//     //
//     // The Python code later does block normalization:
//     //   loudest_peak = np.max(np.abs(recovered_audio))
//     //   recovered_audio = recovered_audio / loudest_peak * 0.80
//     //
//     // That block normalization is NOT naturally streaming RTL, so it is
//     // intentionally omitted here.
//     //
//     // This stage simply converts the scaled internal value into the desired
//     // output width.
//     // ============================================================

//     logic                        s6_valid_c;
//     logic signed [OUT_W-1:0]     s6_audio_c;

//     // Temporary values for saturation
//     logic signed [QUOT_W-1:0]    s6_shifted_c;
//     logic signed [OUT_W-1:0]     sat_max_c, sat_min_c;

//     always_comb begin
//         s6_valid_c = s5_valid_r;

//         // Saturation bounds for signed OUT_W
//         sat_max_c = {1'b0, {(OUT_W-1){1'b1}}};   //  0111...111
//         sat_min_c = {1'b1, {(OUT_W-1){1'b0}}};   //  1000...000

//         // Simple bit extraction / rescaling:
//         // pick a centered slice from the scaled result
//         //
//         // Depending on your chosen fixed-point convention, this slice may
//         // need adjustment. This is one of the main tuning points in real DSP RTL.
//         s6_shifted_c = s5_scaled_r[SCALE_OUT_W-2 -: QUOT_W];

//         // Saturate to output width
//         if (s6_shifted_c > $signed(sat_max_c))
//             s6_audio_c = sat_max_c;
//         else if (s6_shifted_c < $signed(sat_min_c))
//             s6_audio_c = sat_min_c;
//         else
//             s6_audio_c = s6_shifted_c[OUT_W-1:0];
//     end

//     // ============================================================
//     // Sequential pipeline registers
//     // ============================================================
//     always_ff @(posedge clk or negedge n_rst) begin
//         if (!n_rst) begin
//             // Previous-sample memory
//             prev_i_r   <= '0;
//             prev_q_r   <= '0;

//             // Stage 1 regs
//             s1_valid_r <= 1'b0;
//             s1_i_r     <= '0;
//             s1_q_r     <= '0;
//             s1_dI_r    <= '0;
//             s1_dQ_r    <= '0;

//             // Stage 2 regs
//             s2_valid_r <= 1'b0;
//             s2_num_r   <= '0;
//             s2_den_r   <= '0;

//             // Stage 3 regs
//             s3_valid_r <= 1'b0;
//             s3_num_r   <= '0;
//             s3_den_r   <= '0;

//             // Stage 4 regs
//             s4_valid_r <= 1'b0;
//             s4_quot_r  <= '0;

//             // Stage 5 regs
//             s5_valid_r  <= 1'b0;
//             s5_scaled_r <= '0;

//             // Output regs
//             fdif.o_valid    <= 1'b0;
//             fdif.o_audio    <= '0;
//         end
//         else begin
//             // ----------------------------------------------------
//             // Previous-sample storage
//             // Used by Stage 1 to compute dI and dQ
//             // ----------------------------------------------------
//             if (fdif.i_valid) begin
//                 prev_i_r <= fdif.i_i;
//                 prev_q_r <= fdif.i_q;
//             end

//             // ----------------------------------------------------
//             // Register Stage 1 outputs
//             // Corresponds to:
//             //   delta_i = np.diff(i_channel, prepend=i_channel[0])
//             //   delta_q = np.diff(q_channel, prepend=q_channel[0])
//             // ----------------------------------------------------
//             s1_valid_r <= s1_valid_c;
//             s1_i_r     <= s1_i_c;
//             s1_q_r     <= s1_q_c;
//             s1_dI_r    <= s1_dI_c;
//             s1_dQ_r    <= s1_dQ_c;

//             // ----------------------------------------------------
//             // Register Stage 2 outputs
//             // Corresponds to:
//             //   numerator   = i_channel * delta_q - q_channel * delta_i
//             //   denominator = i_channel**2 + q_channel**2
//             // ----------------------------------------------------
//             s2_valid_r <= s2_valid_c;
//             s2_num_r   <= s2_num_c;
//             s2_den_r   <= s2_den_c;

//             // ----------------------------------------------------
//             // Register Stage 3 outputs
//             // Corresponds to:
//             //   denominator = np.where(denominator < 1e-10, 1e-10, denominator)
//             // ----------------------------------------------------
//             s3_valid_r <= s3_valid_c;
//             s3_num_r   <= s3_num_c;
//             s3_den_r   <= s3_den_c;

//             // ----------------------------------------------------
//             // Register Stage 4 outputs
//             // Corresponds to:
//             //   recovered_audio = numerator / denominator
//             // ----------------------------------------------------
//             s4_valid_r <= s4_valid_c;
//             s4_quot_r  <= s4_quot_c;

//             // ----------------------------------------------------
//             // Register Stage 5 outputs
//             // Corresponds to:
//             //   recovered_audio *= SDR_SAMPLE_RATE / (2 * np.pi * MAX_FREQUENCY_DEVIATION)
//             // ----------------------------------------------------
//             s5_valid_r  <= s5_valid_c;
//             s5_scaled_r <= s5_scaled_c;

//             // ----------------------------------------------------
//             // Register final output
//             // Corresponds to final returned demodulated sample
//             // ----------------------------------------------------
//             fdif.o_valid <= s6_valid_c;
//             fdif.o_audio <= s6_audio_c;
//         end
//     end

// endmodule

// `timescale 1ns / 1ps
// `include "fm_demodulate_if.vh"

// // ============================================================
// // fm_demodulate.sv
// // ============================================================
// // FM IQ discriminator — recovers audio from FM-modulated I/Q samples.
// //
// // Pipeline position:
// //   lpf_wrapper → [fm_demodulate] → decimation
// //
// // Algorithm (IQ discriminator):
// //   audio = (I*dQ - Q*dI) / (I^2 + Q^2) * K
// //
// // where K = round(32767 * SDR_RATE / (2*pi*MAX_DEV))
// //         = round(32767 * 220500 / (2*pi*75000))
// //         = 15332
// //
// // Python equivalent (from fm_sdr_prototype.py):
// //   dI = np.diff(I); dQ = np.diff(Q)
// //   num = I*dQ - Q*dI
// //   den = I^2 + Q^2
// //   den = np.where(den < EPSILON, EPSILON, den)
// //   audio = (num * K) / den
// //
// // IMPORTANT: we scale the NUMERATOR before dividing (num*K / den),
// // NOT (num/den)*K. The latter loses precision because integer division
// // of num/den floors to [-1, 0, 1] for typical FM signals.
// //
// // Pipeline stages:
// //   Stage 0: register previous I/Q (for delta computation)
// //   Stage 1: compute dI, dQ (registered)
// //   Stage 2: compute num = I*dQ - Q*dI, den = I^2 + Q^2 (registered)
// //   Stage 3: clamp den >= EPSILON (registered)
// //   Stage 4: scale num: num_scaled = num * K (registered)
// //   Stage 5: divide: quot = num_scaled / den (registered)
// //   Stage 6: saturate to OUT_W (registered output)
// //
// // Bit widths:
// //   IN_W    = 16  (I/Q input)
// //   DIFF_W  = 17  (dI, dQ = 16-bit subtraction can grow 1 bit)
// //   PROD_W  = 33  (I*dQ or Q*dI = 16*17)
// //   NUM_W   = 34  (I*dQ - Q*dI)
// //   SQ_W    = 32  (I*I or Q*Q = 16*16, treated unsigned)
// //   DEN_W   = 33  (I^2 + Q^2)
// //   K_W     = 15  (K=15332 fits in 15 bits unsigned)
// //   SNUM_W  = 49  (NUM_W + K_W = 34+15)
// //   QUOT_W  = 49  (same as SNUM_W, quotient of 49-bit / 33-bit)
// //   OUT_W   = 16
// // ============================================================

// module fm_demodulate #(
//     parameter int IN_W      = 16,
//     parameter int OUT_W     = 16,
//     parameter int EPSILON   = 16,    // minimum denominator (avoids div-by-zero)

//     // K = round(32767 * SDR_RATE / (2*pi*MAX_DEV))
//     //   = round(32767 * 220500 / (2*pi*75000))
//     //   = 15332
//     parameter int K         = 15332
// )(
//     input logic clk,
//     input logic n_rst,
//     fm_demodulate_if.fd fdif
// );

//     // --------------------------------------------------------
//     // Derived widths
//     // --------------------------------------------------------
//     localparam int DIFF_W  = IN_W + 1;          // 17
//     localparam int PROD_W  = IN_W + DIFF_W;     // 33
//     localparam int NUM_W   = PROD_W + 1;        // 34  (subtraction)
//     localparam int SQ_W    = 2 * IN_W;          // 32
//     localparam int DEN_W   = SQ_W + 1;          // 33
//     localparam int K_W     = 15;                // K=15332 < 2^15
//     localparam int SNUM_W  = NUM_W + K_W;       // 49  (num * K)
//     localparam int QUOT_W  = SNUM_W;            // 49  (quot = num_scaled / den)

//     // --------------------------------------------------------
//     // Stage 0: store previous I/Q samples
//     // --------------------------------------------------------
//     logic signed [IN_W-1:0] prev_i_r, prev_q_r;

//     // --------------------------------------------------------
//     // Stage 1: delta computation
//     //   dI = I[n] - I[n-1]
//     //   dQ = Q[n] - Q[n-1]
//     // --------------------------------------------------------
//     logic                     s1_valid_c, s1_valid_r;
//     logic signed [IN_W-1:0]   s1_i_c,    s1_i_r;
//     logic signed [IN_W-1:0]   s1_q_c,    s1_q_r;
//     logic signed [DIFF_W-1:0] s1_dI_c,   s1_dI_r;
//     logic signed [DIFF_W-1:0] s1_dQ_c,   s1_dQ_r;

//     always_comb begin
//         s1_valid_c = fdif.i_valid;
//         s1_i_c     = fdif.i_i;
//         s1_q_c     = fdif.i_q;
//         s1_dI_c    = $signed(fdif.i_i) - $signed(prev_i_r);
//         s1_dQ_c    = $signed(fdif.i_q) - $signed(prev_q_r); // was fdif.i_i — bug fixed
//     end

//     // --------------------------------------------------------
//     // Stage 2: numerator and denominator
//     //   num = I*dQ - Q*dI
//     //   den = I^2  + Q^2
//     // --------------------------------------------------------
//     logic                      s2_valid_c, s2_valid_r;
//     logic signed [NUM_W-1:0]   s2_num_c,   s2_num_r;
//     logic        [DEN_W-1:0]   s2_den_c,   s2_den_r;

//     logic signed [PROD_W-1:0]  s2_idq_c, s2_qdi_c;
//     logic        [SQ_W-1:0]    s2_sq_i_c, s2_sq_q_c;

//     always_comb begin
//         s2_valid_c = s1_valid_r;
//         s2_idq_c   = $signed(s1_i_r) * $signed(s1_dQ_r);
//         s2_qdi_c   = $signed(s1_q_r) * $signed(s1_dI_r);
//         s2_num_c   = $signed(s2_idq_c) - $signed(s2_qdi_c);
//         s2_sq_i_c  = $unsigned($signed(s1_i_r) * $signed(s1_i_r));
//         s2_sq_q_c  = $unsigned($signed(s1_q_r) * $signed(s1_q_r));
//         s2_den_c   = s2_sq_i_c + s2_sq_q_c;
//     end

//     // --------------------------------------------------------
//     // Stage 3: denominator clamp
//     //   if den < EPSILON → den = EPSILON  (avoids division by zero)
//     // --------------------------------------------------------
//     logic                    s3_valid_c, s3_valid_r;
//     logic signed [NUM_W-1:0] s3_num_c,   s3_num_r;
//     logic        [DEN_W-1:0] s3_den_c,   s3_den_r;

//     always_comb begin
//         s3_valid_c = s2_valid_r;
//         s3_num_c   = s2_num_r;
//         s3_den_c   = (s2_den_r < DEN_W'(EPSILON)) ? DEN_W'(EPSILON) : s2_den_r;
//     end

//     // --------------------------------------------------------
//     // Stage 4: scale numerator by K
//     //   num_scaled = num * K
//     //
//     // This is done BEFORE division to preserve precision.
//     // Integer division of num/den would floor to [-2,-1,0,1,2]
//     // for typical FM signals, losing all fine detail.
//     // Scaling first: (num * K) / den gives full 16-bit resolution.
//     // --------------------------------------------------------
//     logic                      s4_valid_c,  s4_valid_r;
//     logic signed [SNUM_W-1:0]  s4_snum_c,   s4_snum_r;
//     logic        [DEN_W-1:0]   s4_den_c,    s4_den_r;

//     always_comb begin
//         s4_valid_c = s3_valid_r;
//         s4_snum_c  = $signed(s3_num_r) * $signed(SNUM_W'(K));
//         s4_den_c   = s3_den_r;
//     end

//     // --------------------------------------------------------
//     // Stage 5: divide
//     //   quot = num_scaled / den
//     //
//     // Note: Xilinx synthesis will infer a multi-cycle divider here.
//     // For timing closure you may want to replace this with a Xilinx
//     // Divider Generator IP (use_dsp=yes, latency=~34 cycles) and
//     // delay valid by the same latency using a shift register.
//     // --------------------------------------------------------
//     logic                     s5_valid_c, s5_valid_r;
//     logic signed [QUOT_W-1:0] s5_quot_c,  s5_quot_r;

//     always_comb begin
//         s5_valid_c = s4_valid_r;
//         s5_quot_c  = $signed(s4_snum_r) / $signed({1'b0, s4_den_r});
//     end

//     // --------------------------------------------------------
//     // Stage 6: saturate to OUT_W
//     //   Quotient range for FM broadcast: ~[-15332, 15332]
//     //   which fits in 16-bit signed [-32768, 32767].
//     //   Saturation guards against edge cases (silence, noise bursts).
//     // --------------------------------------------------------
//     localparam logic signed [OUT_W-1:0] SAT_MAX = {1'b0, {(OUT_W-1){1'b1}}}; //  32767
//     localparam logic signed [OUT_W-1:0] SAT_MIN = {1'b1, {(OUT_W-1){1'b0}}}; // -32768

//     logic                    s6_valid_c;
//     logic signed [OUT_W-1:0] s6_audio_c;

//     always_comb begin
//         s6_valid_c = s5_valid_r;
//         if ($signed(s5_quot_r) > $signed({{(QUOT_W-OUT_W){SAT_MAX[OUT_W-1]}}, SAT_MAX}))
//             s6_audio_c = SAT_MAX;
//         else if ($signed(s5_quot_r) < $signed({{(QUOT_W-OUT_W){SAT_MIN[OUT_W-1]}}, SAT_MIN}))
//             s6_audio_c = SAT_MIN;
//         else
//             s6_audio_c = s5_quot_r[OUT_W-1:0];
//     end

//     // --------------------------------------------------------
//     // Sequential pipeline registers
//     // --------------------------------------------------------
//     always_ff @(posedge clk or negedge n_rst) begin
//         if (!n_rst) begin
//             prev_i_r   <= '0;
//             prev_q_r   <= '0;

//             s1_valid_r <= '0; s1_i_r  <= '0; s1_q_r  <= '0;
//             s1_dI_r    <= '0; s1_dQ_r <= '0;

//             s2_valid_r <= '0; s2_num_r <= '0; s2_den_r <= '0;
//             s3_valid_r <= '0; s3_num_r <= '0; s3_den_r <= '0;
//             s4_valid_r <= '0; s4_snum_r <= '0; s4_den_r <= '0;
//             s5_valid_r <= '0; s5_quot_r <= '0;

//             fdif.o_valid <= 1'b0;
//             fdif.o_audio <= '0;
//         end else begin
//             // Stage 0: latch prev samples only on valid input
//             if (fdif.i_valid) begin
//                 prev_i_r <= fdif.i_i;
//                 prev_q_r <= fdif.i_q;
//             end

//             // Stage 1
//             s1_valid_r <= s1_valid_c;
//             s1_i_r     <= s1_i_c;
//             s1_q_r     <= s1_q_c;
//             s1_dI_r    <= s1_dI_c;
//             s1_dQ_r    <= s1_dQ_c;

//             // Stage 2
//             s2_valid_r <= s2_valid_c;
//             s2_num_r   <= s2_num_c;
//             s2_den_r   <= s2_den_c;

//             // Stage 3
//             s3_valid_r <= s3_valid_c;
//             s3_num_r   <= s3_num_c;
//             s3_den_r   <= s3_den_c;

//             // Stage 4
//             s4_valid_r <= s4_valid_c;
//             s4_snum_r  <= s4_snum_c;
//             s4_den_r   <= s4_den_c;

//             // Stage 5
//             s5_valid_r <= s5_valid_c;
//             s5_quot_r  <= s5_quot_c;

//             // Stage 6 → output
//             fdif.o_valid <= s6_valid_c;
//             fdif.o_audio <= s6_audio_c;
//         end
//     end

// endmodule

/////////////////////////////////////////// PIPELINED

`timescale 1ns / 1ps
`include "fm_demodulate_if.vh"

// ============================================================
// fm_demodulate.sv  (CORDIC-based, fully pipelined)
// ============================================================
// FM IQ discriminator — recovers audio from FM-modulated I/Q.
//
// Pipeline position:
//   lpf_wrapper → [fm_demodulate] → decimation
//
// Algorithm:
//   The instantaneous frequency deviation is proportional to the
//   phase difference between consecutive I/Q samples:
//
//     phi_diff = atan2(Q[n]*I[n-1] - I[n]*Q[n-1],
//                      I[n]*I[n-1] + Q[n]*Q[n-1])
//
//   This is atan2(Im(s[n]*conj(s[n-1])), Re(s[n]*conj(s[n-1])))
//   which gives the true phase difference in [-pi, pi], valid as
//   long as |dphi| < pi, i.e. max_dev < SDR_RATE/2 = 110250 Hz.
//   For FM broadcast (max_dev = 75 kHz), this is satisfied.
//
//   audio = phi_diff * K_num >> K_SHIFT
//   where K_num = round(32767 * SDR_RATE / (2 * MAX_DEV * 2^16))
//               = 6165439,  K_SHIFT = 23
//
// Why CORDIC instead of cross-product discriminator:
//   The cross-product approach gives sin(dphi) not dphi itself.
//   For large deviations sin(dphi) ≠ dphi (e.g. at 75 kHz:
//   dphi = 2.14 rad, sin(2.14) = 0.84 — 21% error).
//   CORDIC gives the true angle with no division and runs at
//   full clock rate with fixed, predictable latency.
//
// Pipeline stages:
//   Stage 0  : register prev I/Q                      (1 cycle)
//   Stage 1  : compute cross, dot; clamp dot           (1 cycle)
//   Stage 2  : right-shift cross/dot for CORDIC input  (1 cycle)
//   Stage 3..N_ITER+2: CORDIC iterations (pipelined)  (N_ITER cycles)
//   Stage N_ITER+3: multiply phi_diff * K_num          (1 cycle)
//   Stage N_ITER+4: shift right + saturate → output    (1 cycle)
//   Total latency: N_ITER + 4 = 20 cycles
//
// Resource usage (vs old divider-based design):
//   Old: 1× large combinational divider (~50 ns, dominates timing)
//   New: N_ITER shift-add stages + 1× multiplier — fully pipelined,
//        no combinational paths longer than one adder.
//
// Parameters (match Python prototype):
//   SDR_RATE  = 220500 Hz
//   MAX_DEV   = 75000 Hz
//   K_num     = round(32767 * 220500 / (2 * 75000 * 65536)) = 6165439
//   K_SHIFT   = 23
//   EPSILON   = minimum dot product value (avoids atan2(0,0))
// ============================================================

module fm_demodulate #(
    parameter int IN_W    = 16,    // I/Q input width
    parameter int OUT_W   = 16,    // audio output width
    parameter int N_ITER  = 16,    // CORDIC iterations = pipeline depth
    parameter int EPSILON = 256,   // min dot product after >>CROSSDOT_SHIFT
    parameter int K_NUM   = 6165439, // audio scale numerator
    parameter int K_SHIFT = 23     // audio scale right-shift
)(
    input  logic clk,
    input  logic n_rst,
    fm_demodulate_if.fd fdif
);

    // --------------------------------------------------------
    // Derived widths
    // --------------------------------------------------------
    localparam int PROD_W      = 2 * IN_W;       // 32  cross/dot products
    localparam int CROSSDOT_W  = PROD_W + 1;     // 33  sum of two products
    localparam int CORDIC_XY_W = 24;             // CORDIC input width (after shift)
    localparam int ANGLE_W     = 17;             // Q3.16 angle (signed 17-bit)
    localparam int SCALED_W    = ANGLE_W + 23;   // phi * K_NUM before shift

    // Right-shift applied to cross/dot before CORDIC input
    // Prevents overflow: cross/dot are 33-bit, CORDIC input is 24-bit
    // 33 - 24 = 9 bit shift (keep top 24 bits)
    localparam int CROSSDOT_SHIFT = 9;

    // --------------------------------------------------------
    // Stage 0: register previous I/Q
    // --------------------------------------------------------
    logic signed [IN_W-1:0] prev_i_r, prev_q_r;

    // --------------------------------------------------------
    // Stage 1: compute cross and dot products
    //   cross = Q[n]*I[n-1] - I[n]*Q[n-1]   (Im of conjugate product)
    //   dot   = I[n]*I[n-1] + Q[n]*Q[n-1]   (Re of conjugate product)
    // --------------------------------------------------------
    logic signed [CROSSDOT_W-1:0] s1_cross_c, s1_dot_c;
    logic signed [CROSSDOT_W-1:0] s1_cross_r, s1_dot_r;
    logic                          s1_valid_c, s1_valid_r;

    always_comb begin
        s1_valid_c = fdif.i_valid;
        s1_cross_c = $signed(fdif.i_q) * $signed(prev_i_r)
                   - $signed(fdif.i_i) * $signed(prev_q_r);
        s1_dot_c   = $signed(fdif.i_i) * $signed(prev_i_r)
                   + $signed(fdif.i_q) * $signed(prev_q_r);
    end

    // --------------------------------------------------------
    // Stage 2: clamp dot (avoid atan2(0,0)), shift for CORDIC
    // --------------------------------------------------------
    logic signed [CORDIC_XY_W-1:0] s2_cross_c, s2_dot_c;
    logic signed [CORDIC_XY_W-1:0] s2_cross_r, s2_dot_r;
    logic                            s2_valid_c, s2_valid_r;

    always_comb begin
        s2_valid_c = s1_valid_r;
        // Clamp dot to EPSILON before shift to prevent atan2(0,0)
        s2_dot_c   = (s1_dot_r >>> CROSSDOT_SHIFT < CORDIC_XY_W'($signed(EPSILON)))
                     ? CORDIC_XY_W'($signed(EPSILON))
                     : CORDIC_XY_W'(s1_dot_r >>> CROSSDOT_SHIFT);
        s2_cross_c = CORDIC_XY_W'(s1_cross_r >>> CROSSDOT_SHIFT);
    end

    // --------------------------------------------------------
    // Stage 3..N_ITER+2: CORDIC atan2 (pipelined)
    // Input:  dot  → x (real part, always positive for converging)
    //         cross → y (imaginary part)
    // Output: phi_diff = atan2(cross, dot)  in Q3.16
    // --------------------------------------------------------
    logic                      cordic_valid_out;
    logic signed [ANGLE_W-1:0] phi_diff;

    cordic #(
        .XY_W   (CORDIC_XY_W),
        .ANGLE_W(ANGLE_W),
        .N_ITER (N_ITER)
    ) u_cordic (
        .clk      (clk),
        .n_rst    (n_rst),
        .i_valid  (s2_valid_r),
        .x_in     (s2_dot_r),
        .y_in     (s2_cross_r),
        .o_valid  (cordic_valid_out),
        .angle_out(phi_diff)
    );

    // --------------------------------------------------------
    // Stage N_ITER+3: scale phi_diff to audio range
    //   audio_raw = phi_diff * K_NUM
    // --------------------------------------------------------
    logic signed [SCALED_W-1:0] s_scaled_c, s_scaled_r;
    logic                        s_scaled_valid_c, s_scaled_valid_r;

    always_comb begin
        s_scaled_valid_c = cordic_valid_out;
        s_scaled_c       = $signed(phi_diff) * $signed(SCALED_W'(K_NUM));
    end

    // --------------------------------------------------------
    // Stage N_ITER+4: right-shift + saturate to OUT_W
    //   audio = audio_raw >> K_SHIFT, clipped to [-32768, 32767]
    // --------------------------------------------------------
    localparam logic signed [OUT_W-1:0] SAT_MAX = {1'b0, {(OUT_W-1){1'b1}}};
    localparam logic signed [OUT_W-1:0] SAT_MIN = {1'b1, {(OUT_W-1){1'b0}}};

    logic signed [SCALED_W-1:0] s6_shifted_c;
    logic signed [OUT_W-1:0]    s6_audio_c;
    logic                        s6_valid_c;

    always_comb begin
        s6_valid_c   = s_scaled_valid_r;
        s6_shifted_c = s_scaled_r >>> K_SHIFT;

        if (s6_shifted_c > $signed({{(SCALED_W-OUT_W){SAT_MAX[OUT_W-1]}}, SAT_MAX}))
            s6_audio_c = SAT_MAX;
        else if (s6_shifted_c < $signed({{(SCALED_W-OUT_W){SAT_MIN[OUT_W-1]}}, SAT_MIN}))
            s6_audio_c = SAT_MIN;
        else
            s6_audio_c = s6_shifted_c[OUT_W-1:0];
    end

    // --------------------------------------------------------
    // Sequential registers
    // --------------------------------------------------------
    always_ff @(posedge clk, negedge n_rst) begin
        if (~n_rst) begin
            prev_i_r <= '0;
            prev_q_r <= '0;

            s1_valid_r <= 1'b0;
            s1_cross_r <= '0;
            s1_dot_r   <= '0;

            s2_valid_r <= 1'b0;
            s2_cross_r <= '0;
            s2_dot_r   <= '0;

            s_scaled_valid_r <= 1'b0;
            s_scaled_r       <= '0;

            fdif.o_valid <= 1'b0;
            fdif.o_audio <= '0;
        end else begin
            // Stage 0
            if (fdif.i_valid) begin
                prev_i_r <= fdif.i_i;
                prev_q_r <= fdif.i_q;
            end

            // Stage 1
            s1_valid_r <= s1_valid_c;
            s1_cross_r <= s1_cross_c;
            s1_dot_r   <= s1_dot_c;

            // Stage 2
            s2_valid_r <= s2_valid_c;
            s2_cross_r <= s2_cross_c;
            s2_dot_r   <= s2_dot_c;

            // Stage N_ITER+3
            s_scaled_valid_r <= s_scaled_valid_c;
            s_scaled_r       <= s_scaled_c;

            // Stage N_ITER+4 → output
            fdif.o_valid <= s6_valid_c;
            fdif.o_audio <= s6_audio_c;
        end
    end

endmodule
