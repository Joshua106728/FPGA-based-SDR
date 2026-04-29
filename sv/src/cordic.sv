`timescale 1ns / 1ps

// ============================================================
// cordic.sv
// ============================================================
// Fully pipelined CORDIC atan2 in vectoring mode.
//
// Computes z = atan2(y_in, x_in) in Q3.16 fixed-point angle:
//   1 LSB = pi / 2^16 radians
//   Range: [-pi, pi] = [-65536, 65535] in Q3.16 units
//
// Algorithm (vectoring mode):
//   For each iteration i = 0..N_ITER-1:
//     d      = (y >= 0) ? -1 : +1
//     x_next = x - d * (y >> i)
//     y_next = y + d * (x >> i)
//     z_next = z - d * atan(2^-i)
//   After N_ITER iterations: z ≈ atan2(y_in, x_in)
//
// Atan table (Q3.16, 1 LSB = pi/2^16):
//   atan(2^-i) * 2^16/pi for i = 0..15
//   [16384, 9672, 5110, 2594, 1302, 652, 326, 163,
//     81,   41,   20,   10,    5,   3,   1,   1]
//
// Parameters:
//   XY_W    — width of x/y inputs (default 24)
//   ANGLE_W — width of angle output (default 17, for Q3.16)
//   N_ITER  — number of CORDIC iterations (default 16)
//
// Latency: N_ITER clock cycles (fully pipelined, 1 output/cycle)
// ============================================================

module cordic #(
    parameter int XY_W    = 24,   // input data width
    parameter int ANGLE_W = 17,   // output angle width (Q3.16 signed)
    parameter int N_ITER  = 16    // number of iterations = pipeline depth
)(
    input  logic                      clk,
    input  logic                      n_rst,
    input  logic                      i_valid,
    input  logic signed [XY_W-1:0]   x_in,
    input  logic signed [XY_W-1:0]   y_in,
    output logic                      o_valid,
    output logic signed [ANGLE_W-1:0] angle_out
);

    // --------------------------------------------------------
    // Atan lookup table — Q3.16 fixed point
    // atan(2^-i) * 65536 / pi for i = 0..15
    // --------------------------------------------------------
    localparam logic signed [ANGLE_W-1:0] ATAN_TABLE [0:15] = '{
        17'sd16384,  // atan(2^0)  = pi/4
        17'sd9672,   // atan(2^-1)
        17'sd5110,   // atan(2^-2)
        17'sd2594,   // atan(2^-3)
        17'sd1302,   // atan(2^-4)
        17'sd652,    // atan(2^-5)
        17'sd326,    // atan(2^-6)
        17'sd163,    // atan(2^-7)
        17'sd81,     // atan(2^-8)
        17'sd41,     // atan(2^-9)
        17'sd20,     // atan(2^-10)
        17'sd10,     // atan(2^-11)
        17'sd5,      // atan(2^-12)
        17'sd3,      // atan(2^-13)
        17'sd1,      // atan(2^-14)
        17'sd1       // atan(2^-15)
    };

    // --------------------------------------------------------
    // Pipeline stage data — one entry per iteration
    // x and y grow by at most 1 bit per iteration due to shifts
    // --------------------------------------------------------
    localparam int PIPE_XY_W = XY_W + N_ITER;  // guard bits

    logic signed [PIPE_XY_W-1:0] x_pipe [0:N_ITER];
    logic signed [PIPE_XY_W-1:0] y_pipe [0:N_ITER];
    logic signed [ANGLE_W-1:0]   z_pipe [0:N_ITER];
    logic                         v_pipe [0:N_ITER];

    // --------------------------------------------------------
    // Stage 0: feed inputs into pipeline
    // --------------------------------------------------------
    assign x_pipe[0] = PIPE_XY_W'($signed(x_in));
    assign y_pipe[0] = PIPE_XY_W'($signed(y_in));
    assign z_pipe[0] = '0;
    assign v_pipe[0] = i_valid;

    // --------------------------------------------------------
    // Generate N_ITER pipeline stages
    // --------------------------------------------------------
    generate
        genvar i;
        for (i = 0; i < N_ITER; i++) begin : cordic_stage

            logic signed [PIPE_XY_W-1:0] x_next, y_next;
            logic signed [ANGLE_W-1:0]   z_next;
            logic                         d;      // rotation direction

            // d = -1 if y >= 0, +1 if y < 0
            assign d = ~y_pipe[i][PIPE_XY_W-1];  // MSB=0 means y>=0 → d=1 (rotate CW)

            always_comb begin
                if (d) begin
                    // y >= 0: rotate clockwise
                    x_next = x_pipe[i] + (y_pipe[i] >>> i);
                    y_next = y_pipe[i] - (x_pipe[i] >>> i);
                    z_next = z_pipe[i] + ATAN_TABLE[i];
                end else begin
                    // y < 0: rotate counter-clockwise
                    x_next = x_pipe[i] - (y_pipe[i] >>> i);
                    y_next = y_pipe[i] + (x_pipe[i] >>> i);
                    z_next = z_pipe[i] - ATAN_TABLE[i];
                end
            end

            always_ff @(posedge clk, negedge n_rst) begin
                if (~n_rst) begin
                    x_pipe[i+1] <= '0;
                    y_pipe[i+1] <= '0;
                    z_pipe[i+1] <= '0;
                    v_pipe[i+1] <= 1'b0;
                end else begin
                    x_pipe[i+1] <= x_next;
                    y_pipe[i+1] <= y_next;
                    z_pipe[i+1] <= z_next;
                    v_pipe[i+1] <= v_pipe[i];
                end
            end

        end
    endgenerate

    // --------------------------------------------------------
    // Output — z after N_ITER iterations = atan2(y_in, x_in)
    // --------------------------------------------------------
    assign angle_out = z_pipe[N_ITER];
    assign o_valid   = v_pipe[N_ITER];

endmodule
