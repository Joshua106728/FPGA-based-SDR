`timescale 1ns / 1ps
`include "../include/types.sv"
`include "../include/decimation_if.vh"

module decimation
import types::*;
#(
    parameter int DECIM_FACTOR = 6  // Downsampling factor
)(
    input  logic clk,              
    input  logic n_rst,            
    decimation_if.decimation_inst decimif  
);

    // 3-bit counter (sufficient for DECIM_FACTOR = 6 → counts 0 -> 5)
    logic [2:0] count, next_count;

    // High when we want to keep (forward) the current sample
    logic keep;
    assign keep = decimif.lpf_valid && (count == 3'd0);  // if (valid and 0 --> keep)

    // Next-state logic for counter
    always_comb begin
        next_count = count;  

        if (decimif.lpf_valid) begin  
            if (count == DECIM_FACTOR - 1)
                next_count = 3'd0;    
            else
                next_count = count + 3'd1; 
        end
    end

    // Counter register
    always_ff @(posedge clk, negedge n_rst) begin
        if (!n_rst)
            count <= 3'd0;     
        else
            count <= next_count; 
    end

    // Output register: passes through selected samples
    always_ff @(posedge clk, negedge n_rst) begin
        if (!n_rst) begin
            decimif.decim_i     <= '0;    // Reset I output
            decimif.decim_q     <= '0;    // Reset Q output
            decimif.decim_valid <= 1'b0;  // Reset valid signal
        end else begin
            decimif.decim_valid <= keep;  // output valid

            if (keep) begin
                // Truncate from DATA_DW (18 bits) to 16 bits by dropping 2 LSBs
                decimif.decim_i <= decimif.lpf_i[DATA_DW-1 -: 16];
                decimif.decim_q <= decimif.lpf_q[DATA_DW-1 -: 16];
            end
        end
    end

endmodule