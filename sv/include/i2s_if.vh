`timescale 1ns/1ps

`ifndef I2S_IF
`define I2S_IF

`include "../include/types.sv"
import types::*;

interface i2s_if;

    // INPUT
    logic signed [PCM_IN_W-1:0] sample_q18;
    logic sample_valid;

    // OUTPUT
    logic i2s_bclk, i2s_ws, i2s_sd;

    modport i2s_master_tx_inst (
        input sample_q18, sample_valid,
        output i2s_bclk, i2s_ws, i2s_sd
    );

    modport i2s_tb (
        input i2s_bclk, i2s_ws, i2s_sd,
        output sample_q18, sample_valid
    );

endinterface

`endif
