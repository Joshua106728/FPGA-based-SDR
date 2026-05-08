
`timescale 1ns / 10ps
`include "../include/types.sv"
`include "../include/dc_offset_if.vh"
`include "../include/lpf_wrapper_if.vh"
`include "../include/fm_demodulate_if.vh"
`include "../include/decim_if.vh"
`include "../include/de_emphasis_if.vh"
`include "../include/i2s_if.vh"

module top
import types::*;
(
    // FPGA Interface
    input logic fpga_clk,
    input logic n_rst,

    // RF Interface
    input logic rf_ws,
    input logic rf_sck,
    input logic rf_sd,

    // Random LED
    output logic led1,
    output logic led2,
    output logic led3,
    output logic led4,

    // Bluetooth Interface
    output logic bt_ws,
    output logic bt_sck,
    output logic bt_sd
);
    // ---- Interface instantiations ----

    // Stage 1: Sin Wave Generator (TEST MODE - replace with rf_cdc for real RF)
    logic [SAMPLE_DW-1:0] test_sample_i, test_sample_q;
    logic test_sample_valid;

    // Stage 2: DC Offset
    dc_offset_if dcif();
    assign dcif.sample_i     = test_sample_i;
    assign dcif.sample_q     = test_sample_q;
    assign dcif.sample_valid = test_sample_valid;

    // Stage 3: Low Pass Filter
    lpf_wrapper_if lpfif();
    assign lpfif.corr_i     = dcif.corr_i;
    assign lpfif.corr_q     = dcif.corr_q;
    assign lpfif.corr_valid = dcif.corr_valid;

    // Stage 4: FM Demodulate
    fm_demodulate_if fmif();
    assign fmif.lpf_i     = lpfif.lpf_i;
    assign fmif.lpf_q     = lpfif.lpf_q;
    assign fmif.lpf_valid = lpfif.lpf_valid;

    // Stage 5: Decimation (220500 → 36750 Hz)
    decim_if decimif();
    assign decimif.demod_sample = fmif.demod_sample;
    assign decimif.demod_valid = fmif.demod_valid;

    // Stage 6: De-emphasis
    de_emphasis_if deif();
    assign deif.audio_in    = decimif.decim_sample;
    assign deif.audio_valid = decimif.decim_valid;

    // Stage 7: I2S TX
    i2s_if i2sif();
    assign i2sif.sample_q18   = deif.audio_out;
    assign i2sif.sample_valid = deif.audio_out_valid;

    assign bt_ws  = i2sif.i2s_ws;
    assign bt_sck = i2sif.i2s_bclk;
    assign bt_sd  = i2sif.i2s_sd;

    // LEDs
    assign led1 = rf_sd;
    assign led2 = bt_sd;
    assign led3 = 1'b0;
    assign led4 = 1'b1;

    // ---- Sin Wave Generation (inline - TEST MODE) ----
    // 220 samples per cycle: 220.5 kHz / 220 ≈ 1.002 kHz
    localparam int TABLE_SIZE = 220;
    localparam int PHASE_BITS = $clog2(TABLE_SIZE);

    // Precomputed sine lookup table (220 samples)
    logic [SAMPLE_DW-1:0] sin_table [0:219];

    logic [PHASE_BITS-1:0] phase = 0;

    // Initialize sine lookup table
    initial begin
        sin_table[0]   = 8'd128; sin_table[1]   = 8'd131; sin_table[2]   = 8'd135; sin_table[3]   = 8'd138;
        sin_table[4]   = 8'd142; sin_table[5]   = 8'd145; sin_table[6]   = 8'd149; sin_table[7]   = 8'd152;
        sin_table[8]   = 8'd156; sin_table[9]   = 8'd159; sin_table[10]  = 8'd163; sin_table[11]  = 8'd166;
        sin_table[12]  = 8'd170; sin_table[13]  = 8'd173; sin_table[14]  = 8'd177; sin_table[15]  = 8'd180;
        sin_table[16]  = 8'd184; sin_table[17]  = 8'd187; sin_table[18]  = 8'd191; sin_table[19]  = 8'd194;
        sin_table[20]  = 8'd198; sin_table[21]  = 8'd201; sin_table[22]  = 8'd204; sin_table[23]  = 8'd208;
        sin_table[24]  = 8'd211; sin_table[25]  = 8'd214; sin_table[26]  = 8'd217; sin_table[27]  = 8'd220;
        sin_table[28]  = 8'd224; sin_table[29]  = 8'd227; sin_table[30]  = 8'd230; sin_table[31]  = 8'd233;
        sin_table[32]  = 8'd236; sin_table[33]  = 8'd239; sin_table[34]  = 8'd242; sin_table[35]  = 8'd245;
        sin_table[36]  = 8'd248; sin_table[37]  = 8'd250; sin_table[38]  = 8'd253; sin_table[39]  = 8'd255;
        sin_table[40]  = 8'd255; sin_table[41]  = 8'd255; sin_table[42]  = 8'd254; sin_table[43]  = 8'd252;
        sin_table[44]  = 8'd250; sin_table[45]  = 8'd248; sin_table[46]  = 8'd245; sin_table[47]  = 8'd242;
        sin_table[48]  = 8'd239; sin_table[49]  = 8'd236; sin_table[50]  = 8'd233; sin_table[51]  = 8'd230;
        sin_table[52]  = 8'd227; sin_table[53]  = 8'd224; sin_table[54]  = 8'd220; sin_table[55]  = 8'd217;
        sin_table[56]  = 8'd214; sin_table[57]  = 8'd211; sin_table[58]  = 8'd208; sin_table[59]  = 8'd204;
        sin_table[60]  = 8'd201; sin_table[61]  = 8'd198; sin_table[62]  = 8'd194; sin_table[63]  = 8'd191;
        sin_table[64]  = 8'd187; sin_table[65]  = 8'd184; sin_table[66]  = 8'd180; sin_table[67]  = 8'd177;
        sin_table[68]  = 8'd173; sin_table[69]  = 8'd170; sin_table[70]  = 8'd166; sin_table[71]  = 8'd163;
        sin_table[72]  = 8'd159; sin_table[73]  = 8'd156; sin_table[74]  = 8'd152; sin_table[75]  = 8'd149;
        sin_table[76]  = 8'd145; sin_table[77]  = 8'd142; sin_table[78]  = 8'd138; sin_table[79]  = 8'd135;
        sin_table[80]  = 8'd131; sin_table[81]  = 8'd128; sin_table[82]  = 8'd124; sin_table[83]  = 8'd120;
        sin_table[84]  = 8'd117; sin_table[85]  = 8'd113; sin_table[86]  = 8'd110; sin_table[87]  = 8'd106;
        sin_table[88]  = 8'd103; sin_table[89]  = 8'd99;  sin_table[90]  = 8'd96;  sin_table[91]  = 8'd92;
        sin_table[92]  = 8'd89;  sin_table[93]  = 8'd85;  sin_table[94]  = 8'd82;  sin_table[95]  = 8'd78;
        sin_table[96]  = 8'd75;  sin_table[97]  = 8'd71;  sin_table[98]  = 8'd68;  sin_table[99]  = 8'd65;
        sin_table[100] = 8'd61;  sin_table[101] = 8'd58;  sin_table[102] = 8'd54;  sin_table[103] = 8'd51;
        sin_table[104] = 8'd48;  sin_table[105] = 8'd44;  sin_table[106] = 8'd41;  sin_table[107] = 8'd38;
        sin_table[108] = 8'd35;  sin_table[109] = 8'd31;  sin_table[110] = 8'd28;  sin_table[111] = 8'd25;
        sin_table[112] = 8'd22;  sin_table[113] = 8'd19;  sin_table[114] = 8'd16;  sin_table[115] = 8'd12;
        sin_table[116] = 8'd9;   sin_table[117] = 8'd6;   sin_table[118] = 8'd3;   sin_table[119] = 8'd1;
        sin_table[120] = 8'd0;   sin_table[121] = 8'd0;   sin_table[122] = 8'd0;   sin_table[123] = 8'd1;
        sin_table[124] = 8'd3;   sin_table[125] = 8'd6;   sin_table[126] = 8'd9;   sin_table[127] = 8'd12;
        sin_table[128] = 8'd16;  sin_table[129] = 8'd19;  sin_table[130] = 8'd22;  sin_table[131] = 8'd25;
        sin_table[132] = 8'd28;  sin_table[133] = 8'd31;  sin_table[134] = 8'd35;  sin_table[135] = 8'd38;
        sin_table[136] = 8'd41;  sin_table[137] = 8'd44;  sin_table[138] = 8'd48;  sin_table[139] = 8'd51;
        sin_table[140] = 8'd54;  sin_table[141] = 8'd58;  sin_table[142] = 8'd61;  sin_table[143] = 8'd65;
        sin_table[144] = 8'd68;  sin_table[145] = 8'd71;  sin_table[146] = 8'd75;  sin_table[147] = 8'd78;
        sin_table[148] = 8'd82;  sin_table[149] = 8'd85;  sin_table[150] = 8'd89;  sin_table[151] = 8'd92;
        sin_table[152] = 8'd96;  sin_table[153] = 8'd99;  sin_table[154] = 8'd103; sin_table[155] = 8'd106;
        sin_table[156] = 8'd110; sin_table[157] = 8'd113; sin_table[158] = 8'd117; sin_table[159] = 8'd120;
        sin_table[160] = 8'd124; sin_table[161] = 8'd128; sin_table[162] = 8'd131; sin_table[163] = 8'd135;
        sin_table[164] = 8'd138; sin_table[165] = 8'd142; sin_table[166] = 8'd145; sin_table[167] = 8'd149;
        sin_table[168] = 8'd152; sin_table[169] = 8'd156; sin_table[170] = 8'd159; sin_table[171] = 8'd163;
        sin_table[172] = 8'd166; sin_table[173] = 8'd170; sin_table[174] = 8'd173; sin_table[175] = 8'd177;
        sin_table[176] = 8'd180; sin_table[177] = 8'd184; sin_table[178] = 8'd187; sin_table[179] = 8'd191;
        sin_table[180] = 8'd194; sin_table[181] = 8'd198; sin_table[182] = 8'd201; sin_table[183] = 8'd204;
        sin_table[184] = 8'd208; sin_table[185] = 8'd211; sin_table[186] = 8'd214; sin_table[187] = 8'd217;
        sin_table[188] = 8'd220; sin_table[189] = 8'd224; sin_table[190] = 8'd227; sin_table[191] = 8'd230;
        sin_table[192] = 8'd233; sin_table[193] = 8'd236; sin_table[194] = 8'd239; sin_table[195] = 8'd242;
        sin_table[196] = 8'd245; sin_table[197] = 8'd248; sin_table[198] = 8'd250; sin_table[199] = 8'd253;
        sin_table[200] = 8'd255; sin_table[201] = 8'd255; sin_table[202] = 8'd255; sin_table[203] = 8'd254;
        sin_table[204] = 8'd252; sin_table[205] = 8'd250; sin_table[206] = 8'd248; sin_table[207] = 8'd245;
        sin_table[208] = 8'd242; sin_table[209] = 8'd239; sin_table[210] = 8'd236; sin_table[211] = 8'd233;
        sin_table[212] = 8'd230; sin_table[213] = 8'd227; sin_table[214] = 8'd224; sin_table[215] = 8'd220;
        sin_table[216] = 8'd217; sin_table[217] = 8'd214; sin_table[218] = 8'd211; sin_table[219] = 8'd208;
    end

    always_ff @(posedge fpga_clk) begin
        if (~n_rst) begin
            phase <= 0;
            test_sample_valid <= 1'b0;
            test_sample_i <= 8'd128;
            test_sample_q <= 8'd128;
        end else begin
            test_sample_i <= sin_table[phase];
            // 90 degree phase shift: 220/4 = 55 samples
            test_sample_q <= sin_table[(phase + 55) % TABLE_SIZE];
            test_sample_valid <= 1'b1;
            phase <= (phase == TABLE_SIZE - 1) ? 0 : phase + 1;
        end
    end

    // ---- Module instantiations ----
    dc_offset u_dc_offset (.clk(fpga_clk), .n_rst(n_rst), .dcif(dcif));
    lpf_wrapper u_lpf_wrapper (.clk(fpga_clk), .n_rst(n_rst), .lpfif(lpfif));
    fm_demodulate u_fm_demodulate (.clk(fpga_clk), .n_rst(n_rst), .fmif(fmif));
    decim u_decimation (.clk(fpga_clk), .n_rst(n_rst), .decimif(decimif));
    de_emphasis u_de_emphasis (.clk(fpga_clk), .n_rst(n_rst), .deif(deif));
    i2s_master_tx u_i2s_master_tx (.clk(fpga_clk), .n_rst(n_rst), .i2sif(i2sif));

endmodule