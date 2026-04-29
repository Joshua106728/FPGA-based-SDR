`timescale 1ns/1ps

`ifndef DE_EMPHASIS_IF
`define DE_EMPHASIS_IF

`include "../include/types.sv"
import types::*;

interface de_emphasis_if;

    // INPUT — from fm_demodulate (16-bit audio, matches fm_demodulate_if o_audio)
    logic signed [15:0] audio_in;
    logic audio_valid;

    // OUTPUT — to i2s_master_tx (18-bit to match i2s_if sample_q18)
    logic signed [PCM_IN_W-1:0] audio_out;
    logic audio_out_valid;

    modport de_emphasis_inst (
        input  audio_in, audio_valid,
        output audio_out, audio_out_valid
    );

    modport de_emphasis_tb (
        input  audio_out, audio_out_valid,
        output audio_in, audio_valid
    );

endinterface

`endif
