`ifndef FM_DEMODULATE_IF_VH
`define FM_DEMODULATE_IF_VH

// all types
// `include "types.sv"

interface fm_demodulate_if;
  // import types
//   import types::*;

  // inputs
  logic i_valid;
  logic [15:0] i_i, i_q;
//   logic [IN_W-1:0] i_i, i_q;  

  // outputs
  logic o_valid;
  logic [15:0] o_audio;
//   logic [OUT_W-1:0] o_audio;

  // ports
  modport fd (
    input   i_valid, i_i, i_q,
    output  o_valid, o_audio
  );
  // tb
  modport tb (
    output  i_valid, i_i, i_q,
    input   o_valid, o_audio
  );
endinterface

`endif //FM_DEMODULATE_IF_VH