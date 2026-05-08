
// `timescale 1ns / 1ps
// `include "../include/types.sv"
// `include "../include/rf_cdc_if.vh"

// module rf_cdc 
// import types::*;
// (
//     input logic fpga_clk, n_rst,
//     rf_cdc_if.rf_cdc_inst rfif
// );
//     // declare internal signals
//     typedef struct packed {
//         logic ws_clk;
//         logic bit_clk;
//     } rf_sync;

//     // ASYNC_REG keeps both FFs physically adjacent and prevents retiming across them
//     (* ASYNC_REG = "TRUE" *) rf_sync ff2, ff3;

//     logic pending_frame, new_frame, can_sample;
//     logic [SHIFT_LEN-1:0] shift, next_shift;

//     // ************************************************************************
//     // START THE CODE
//     // ************************************************************************
//     always_ff @(posedge fpga_clk, negedge n_rst) begin : IN_TO_FF2
//         if (~n_rst) ff2 <= '0;
//         else begin
//             ff2.ws_clk  <= rfif.ws;
//             ff2.bit_clk <= rfif.sck;
//         end
//     end

//     always_ff @(posedge fpga_clk, negedge n_rst) begin : FF2_TO_FF3
//         if (~n_rst) ff3 <= '0;
//         else        ff3 <= ff2;
//     end

//     // Edge detection (rising)
//     assign can_sample = ff2.bit_clk & ~ff3.bit_clk;

//     always_ff @(posedge fpga_clk, negedge n_rst) begin : whenToClear
//         if (~n_rst) begin
//             pending_frame <= 1'b0;
//             new_frame <= 1'b0;
//         end
//         else if (~ff2.ws_clk & ff3.ws_clk) begin
//             pending_frame <= 1'b1;
//             new_frame <= 1'b0;
//         end
//         else if (pending_frame & can_sample) begin
//             pending_frame <= 1'b0;
//             new_frame <= 1'b1;
//         end
//         else begin
//             pending_frame <= pending_frame;
//             new_frame <= 1'b0;
//         end
//     end

//     // SIPO Shift Register
//     always_ff @(posedge fpga_clk, negedge n_rst) begin : sipoNextLogic
//         if (~n_rst) begin
//             rfif.sample_i <= '0;
//             rfif.sample_q <= '0;
//             rfif.sample_valid <= 1'b0;
//             shift <= '0;
//         end
//         else if (new_frame) begin
//             rfif.sample_i <= shift[SHIFT_LEN-1:SHIFT_LEN/2];
//             rfif.sample_q <= shift[SHIFT_LEN/2-1:0];
//             rfif.sample_valid <= 1'b1;
//             shift <= {15'b0, rfif.sd};
//         end
//         else begin
//             rfif.sample_i <= '0;
//             rfif.sample_q <= '0;
//             rfif.sample_valid <= 1'b0;
//             shift <= next_shift;
//         end
//     end

//     always_comb begin : sipoShift
//         next_shift = shift;
//         if (can_sample) next_shift = {next_shift[SHIFT_LEN-2:0], rfif.sd};
//     end

// endmodule

`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/rf_cdc_if.vh"

// ============================================================
// rf_cdc.sv — Philips I2S Receiver
// ============================================================
// Receives 8-bit stereo I/Q samples from the ESP32 over I2S.
//
// ESP32 I2S configuration (from main.c):
//   Format    : Philips I2S (I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG)
//   Bit width : 8-bit per channel
//   Mode      : Stereo (I = Left channel, Q = Right channel)
//   Sample rate: 250 kHz
//   BCLK      : 16 x 250 kHz = 4 MHz
//   WS        : LOW  = Left  channel (I)
//               HIGH = Right channel (Q)
//
// Philips I2S timing:
//   - WS transitions ONE BCLK BEFORE the MSB of the new word
//   - Data is clocked in on RISING edge of BCLK
//   - MSB first
//   - 8 data bits per channel, remaining bits are 0 (padding)
//
// Frame format (16 BCLK cycles total per stereo sample):
//   WS=LOW  : 8 bits of I (left)  — bits [15:8] in shift register
//   WS=HIGH : 8 bits of Q (right) — bits [7:0]  in shift register
//   After 16 bits: output I[7:0] and Q[7:0], assert sample_valid
//
// Clock domain crossing:
//   BCLK from ESP32 (~4 MHz) is asynchronous to FPGA clock (100 MHz).
//   Double flip-flop synchronizers on WS and BCLK prevent metastability.
//   ASYNC_REG attribute keeps both FFs physically adjacent in Vivado.
// ============================================================

module rf_cdc
import types::*;
(
    input logic fpga_clk,
    input logic n_rst,
    rf_cdc_if.rf_cdc_inst rfif
);

    // --------------------------------------------------------
    // Double flip-flop synchronizers for async inputs
    // --------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) logic ff2_ws,   ff3_ws;
    (* ASYNC_REG = "TRUE" *) logic ff2_bclk, ff3_bclk;
    (* ASYNC_REG = "TRUE" *) logic ff2_sd,   ff3_sd;

    always_ff @(posedge fpga_clk, negedge n_rst) begin : sync_stage1
        if (~n_rst) begin
            ff2_ws   <= 1'b0;
            ff2_bclk <= 1'b0;
            ff2_sd   <= 1'b0;
        end else begin
            ff2_ws   <= rfif.ws;
            ff2_bclk <= rfif.sck;
            ff2_sd   <= rfif.sd;
        end
    end

    always_ff @(posedge fpga_clk, negedge n_rst) begin : sync_stage2
        if (~n_rst) begin
            ff3_ws   <= 1'b0;
            ff3_bclk <= 1'b0;
            ff3_sd   <= 1'b0;
        end else begin
            ff3_ws   <= ff2_ws;
            ff3_bclk <= ff2_bclk;
            ff3_sd   <= ff2_sd;
        end
    end

    // --------------------------------------------------------
    // Edge detection
    // Rising edge of BCLK: sample SD
    // Falling edge of WS:  end of right (Q) channel / start of left (I)
    // Rising edge of WS:   end of left (I) / start of right (Q)
    // --------------------------------------------------------
    logic bclk_rise;   // rising edge of BCLK — when to sample SD
    logic ws_fall;     // falling edge of WS  — left channel starting
    logic ws_rise;     // rising edge of WS   — right channel starting

    assign bclk_rise = ff2_bclk & ~ff3_bclk;
    assign ws_fall   = ~ff2_ws  &  ff3_ws;
    assign ws_rise   =  ff2_ws  & ~ff3_ws;

    // --------------------------------------------------------
    // Shift register — 16 bits wide (8 I + 8 Q)
    // Shifts in SD on each BCLK rising edge, MSB first
    // --------------------------------------------------------
    logic [15:0] shift_reg;

    always_ff @(posedge fpga_clk, negedge n_rst) begin : shift_in
        if (~n_rst) begin
            shift_reg <= '0;
        end else if (bclk_rise) begin
            shift_reg <= {shift_reg[14:0], ff3_sd};
        end
    end

    // --------------------------------------------------------
    // WS-based frame detection
    //
    // In Philips I2S:
    //   WS falling edge → MSB of LEFT  (I) channel appears one BCLK later
    //   WS rising  edge → MSB of RIGHT (Q) channel appears one BCLK later
    //
    // Strategy: capture shift_reg on the WS FALLING edge (start of new
    // left channel). At that moment shift_reg contains the PREVIOUS full
    // stereo frame: [I_prev[7:0], Q_prev[7:0]] ... but wait — we need to
    // be more careful.
    //
    // After 16 BCLK edges (8 left + 8 right), shift_reg contains:
    //   [14:8] = last 7 bits shifted through left channel + first bit of right
    //
    // Simpler approach: use ws_fall to latch the completed frame.
    // At ws_fall:
    //   The 8 right-channel (Q) bits just finished clocking in.
    //   shift_reg[15:8] = I (left, clocked during WS=LOW)
    //   shift_reg[7:0]  = Q (right, clocked during WS=HIGH)
    //
    // Note: Philips I2S shifts the MSB one cycle AFTER WS transitions, so
    // there is a 1-bit delay. We account for this by latching on ws_fall
    // AFTER the Q bits have been shifted in — this happens at the start of
    // the NEXT WS=LOW period, which is exactly when ws_fall fires.
    // --------------------------------------------------------
    always_ff @(posedge fpga_clk, negedge n_rst) begin : output_latch
        if (~n_rst) begin
            rfif.sample_i     <= '0;
            rfif.sample_q     <= '0;
            rfif.sample_valid <= 1'b0;
        end else if (ws_fall) begin
            // Latch completed stereo frame
            // shift_reg[15:8] = I (left channel, WS was LOW)
            // shift_reg[7:0]  = Q (right channel, WS was HIGH)
            rfif.sample_i     <= shift_reg[15:8];
            rfif.sample_q     <= shift_reg[7:0];
            rfif.sample_valid <= 1'b1;
        end else begin
            rfif.sample_valid <= 1'b0;
        end
    end

endmodule
