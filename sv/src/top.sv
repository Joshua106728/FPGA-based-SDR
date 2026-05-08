
`timescale 1ns / 10ps
`include "../include/types.sv"
`include "../include/rf_cdc_if.vh"
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
    // Two sine waves: high (220 samples/cycle ≈1kHz) and low (440 samples/cycle ≈500Hz)
    localparam int TABLE_SIZE_HIGH = 220;
    localparam int TABLE_SIZE_LOW  = 440;
    localparam int PHASE_BITS_HIGH = $clog2(TABLE_SIZE_HIGH);
    localparam int PHASE_BITS_LOW  = $clog2(TABLE_SIZE_LOW);
    
    // Selector oscillation: switches every ~5 million cycles (~500ms at 100MHz)
    localparam int SELECTOR_DIV = 32'd50_000_000;

    // Precomputed sine lookup tables
    logic [SAMPLE_DW-1:0] sin_table_high [0:219];
    logic [SAMPLE_DW-1:0] sin_table_low  [0:439];

    // Initialize high-frequency sine table (220 samples, ~1kHz)
    // and low-frequency table (440 samples, ~500Hz) in one block to avoid init-order race
    initial begin
        sin_table_high[0]   = 8'd128; sin_table_high[1]   = 8'd131; sin_table_high[2]   = 8'd135; sin_table_high[3]   = 8'd138;
        sin_table_high[4]   = 8'd142; sin_table_high[5]   = 8'd145; sin_table_high[6]   = 8'd149; sin_table_high[7]   = 8'd152;
        sin_table_high[8]   = 8'd156; sin_table_high[9]   = 8'd159; sin_table_high[10]  = 8'd163; sin_table_high[11]  = 8'd166;
        sin_table_high[12]  = 8'd170; sin_table_high[13]  = 8'd173; sin_table_high[14]  = 8'd177; sin_table_high[15]  = 8'd180;
        sin_table_high[16]  = 8'd184; sin_table_high[17]  = 8'd187; sin_table_high[18]  = 8'd191; sin_table_high[19]  = 8'd194;
        sin_table_high[20]  = 8'd198; sin_table_high[21]  = 8'd201; sin_table_high[22]  = 8'd204; sin_table_high[23]  = 8'd208;
        sin_table_high[24]  = 8'd211; sin_table_high[25]  = 8'd214; sin_table_high[26]  = 8'd217; sin_table_high[27]  = 8'd220;
        sin_table_high[28]  = 8'd224; sin_table_high[29]  = 8'd227; sin_table_high[30]  = 8'd230; sin_table_high[31]  = 8'd233;
        sin_table_high[32]  = 8'd236; sin_table_high[33]  = 8'd239; sin_table_high[34]  = 8'd242; sin_table_high[35]  = 8'd245;
        sin_table_high[36]  = 8'd248; sin_table_high[37]  = 8'd250; sin_table_high[38]  = 8'd253; sin_table_high[39]  = 8'd255;
        sin_table_high[40]  = 8'd255; sin_table_high[41]  = 8'd255; sin_table_high[42]  = 8'd254; sin_table_high[43]  = 8'd252;
        sin_table_high[44]  = 8'd250; sin_table_high[45]  = 8'd248; sin_table_high[46]  = 8'd245; sin_table_high[47]  = 8'd242;
        sin_table_high[48]  = 8'd239; sin_table_high[49]  = 8'd236; sin_table_high[50]  = 8'd233; sin_table_high[51]  = 8'd230;
        sin_table_high[52]  = 8'd227; sin_table_high[53]  = 8'd224; sin_table_high[54]  = 8'd220; sin_table_high[55]  = 8'd217;
        sin_table_high[56]  = 8'd214; sin_table_high[57]  = 8'd211; sin_table_high[58]  = 8'd208; sin_table_high[59]  = 8'd204;
        sin_table_high[60]  = 8'd201; sin_table_high[61]  = 8'd198; sin_table_high[62]  = 8'd194; sin_table_high[63]  = 8'd191;
        sin_table_high[64]  = 8'd187; sin_table_high[65]  = 8'd184; sin_table_high[66]  = 8'd180; sin_table_high[67]  = 8'd177;
        sin_table_high[68]  = 8'd173; sin_table_high[69]  = 8'd170; sin_table_high[70]  = 8'd166; sin_table_high[71]  = 8'd163;
        sin_table_high[72]  = 8'd159; sin_table_high[73]  = 8'd156; sin_table_high[74]  = 8'd152; sin_table_high[75]  = 8'd149;
        sin_table_high[76]  = 8'd145; sin_table_high[77]  = 8'd142; sin_table_high[78]  = 8'd138; sin_table_high[79]  = 8'd135;
        sin_table_high[80]  = 8'd131; sin_table_high[81]  = 8'd128; sin_table_high[82]  = 8'd124; sin_table_high[83]  = 8'd120;
        sin_table_high[84]  = 8'd117; sin_table_high[85]  = 8'd113; sin_table_high[86]  = 8'd110; sin_table_high[87]  = 8'd106;
        sin_table_high[88]  = 8'd103; sin_table_high[89]  = 8'd99;  sin_table_high[90]  = 8'd96;  sin_table_high[91]  = 8'd92;
        sin_table_high[92]  = 8'd89;  sin_table_high[93]  = 8'd85;  sin_table_high[94]  = 8'd82;  sin_table_high[95]  = 8'd78;
        sin_table_high[96]  = 8'd75;  sin_table_high[97]  = 8'd71;  sin_table_high[98]  = 8'd68;  sin_table_high[99]  = 8'd65;
        sin_table_high[100] = 8'd61;  sin_table_high[101] = 8'd58;  sin_table_high[102] = 8'd54;  sin_table_high[103] = 8'd51;
        sin_table_high[104] = 8'd48;  sin_table_high[105] = 8'd44;  sin_table_high[106] = 8'd41;  sin_table_high[107] = 8'd38;
        sin_table_high[108] = 8'd35;  sin_table_high[109] = 8'd31;  sin_table_high[110] = 8'd28;  sin_table_high[111] = 8'd25;
        sin_table_high[112] = 8'd22;  sin_table_high[113] = 8'd19;  sin_table_high[114] = 8'd16;  sin_table_high[115] = 8'd12;
        sin_table_high[116] = 8'd9;   sin_table_high[117] = 8'd6;   sin_table_high[118] = 8'd3;   sin_table_high[119] = 8'd1;
        sin_table_high[120] = 8'd0;   sin_table_high[121] = 8'd0;   sin_table_high[122] = 8'd0;   sin_table_high[123] = 8'd1;
        sin_table_high[124] = 8'd3;   sin_table_high[125] = 8'd6;   sin_table_high[126] = 8'd9;   sin_table_high[127] = 8'd12;
        sin_table_high[128] = 8'd16;  sin_table_high[129] = 8'd19;  sin_table_high[130] = 8'd22;  sin_table_high[131] = 8'd25;
        sin_table_high[132] = 8'd28;  sin_table_high[133] = 8'd31;  sin_table_high[134] = 8'd35;  sin_table_high[135] = 8'd38;
        sin_table_high[136] = 8'd41;  sin_table_high[137] = 8'd44;  sin_table_high[138] = 8'd48;  sin_table_high[139] = 8'd51;
        sin_table_high[140] = 8'd54;  sin_table_high[141] = 8'd58;  sin_table_high[142] = 8'd61;  sin_table_high[143] = 8'd65;
        sin_table_high[144] = 8'd68;  sin_table_high[145] = 8'd71;  sin_table_high[146] = 8'd75;  sin_table_high[147] = 8'd78;
        sin_table_high[148] = 8'd82;  sin_table_high[149] = 8'd85;  sin_table_high[150] = 8'd89;  sin_table_high[151] = 8'd92;
        sin_table_high[152] = 8'd96;  sin_table_high[153] = 8'd99;  sin_table_high[154] = 8'd103; sin_table_high[155] = 8'd106;
        sin_table_high[156] = 8'd110; sin_table_high[157] = 8'd113; sin_table_high[158] = 8'd117; sin_table_high[159] = 8'd120;
        sin_table_high[160] = 8'd124; sin_table_high[161] = 8'd128; sin_table_high[162] = 8'd131; sin_table_high[163] = 8'd135;
        sin_table_high[164] = 8'd138; sin_table_high[165] = 8'd142; sin_table_high[166] = 8'd145; sin_table_high[167] = 8'd149;
        sin_table_high[168] = 8'd152; sin_table_high[169] = 8'd156; sin_table_high[170] = 8'd159; sin_table_high[171] = 8'd163;
        sin_table_high[172] = 8'd166; sin_table_high[173] = 8'd170; sin_table_high[174] = 8'd173; sin_table_high[175] = 8'd177;
        sin_table_high[176] = 8'd180; sin_table_high[177] = 8'd184; sin_table_high[178] = 8'd187; sin_table_high[179] = 8'd191;
        sin_table_high[180] = 8'd194; sin_table_high[181] = 8'd198; sin_table_high[182] = 8'd201; sin_table_high[183] = 8'd204;
        sin_table_high[184] = 8'd208; sin_table_high[185] = 8'd211; sin_table_high[186] = 8'd214; sin_table_high[187] = 8'd217;
        sin_table_high[188] = 8'd220; sin_table_high[189] = 8'd224; sin_table_high[190] = 8'd227; sin_table_high[191] = 8'd230;
        sin_table_high[192] = 8'd233; sin_table_high[193] = 8'd236; sin_table_high[194] = 8'd239; sin_table_high[195] = 8'd242;
        sin_table_high[196] = 8'd245; sin_table_high[197] = 8'd248; sin_table_high[198] = 8'd250; sin_table_high[199] = 8'd253;
        sin_table_high[200] = 8'd255; sin_table_high[201] = 8'd255; sin_table_high[202] = 8'd255; sin_table_high[203] = 8'd254;
        sin_table_high[204] = 8'd252; sin_table_high[205] = 8'd250; sin_table_high[206] = 8'd248; sin_table_high[207] = 8'd245;
        sin_table_high[208] = 8'd242; sin_table_high[209] = 8'd239; sin_table_high[210] = 8'd236; sin_table_high[211] = 8'd233;
        sin_table_high[212] = 8'd230; sin_table_high[213] = 8'd227; sin_table_high[214] = 8'd224; sin_table_high[215] = 8'd220;
        sin_table_high[216] = 8'd217; sin_table_high[217] = 8'd214; sin_table_high[218] = 8'd211; sin_table_high[219] = 8'd208;
        // Derive low-frequency table: duplicate each high sample to halve the frequency (~500Hz)
        for (int i = 0; i < 220; i++) begin
            sin_table_low[2*i]     = sin_table_high[i];
            sin_table_low[2*i + 1] = sin_table_high[i];
        end
    end

    // Phase/selector registers
    logic [PHASE_BITS_HIGH-1:0] phase_high = 0;
    logic [PHASE_BITS_LOW-1:0] phase_low = 0;
    logic [31:0] selector_counter = 0;
    logic select_signal = 0;  // 0=high, 1=low

    always_ff @(posedge fpga_clk) begin
        if (~n_rst) begin
            phase_high <= 0;
            phase_low <= 0;
            selector_counter <= 0;
            select_signal <= 0;
            test_sample_valid <= 1'b0;
            test_sample_i <= 8'd128;
            test_sample_q <= 8'd128;
        end else begin
            // Increment selector counter to switch between frequencies
            selector_counter <= selector_counter + 1;
            if (selector_counter == SELECTOR_DIV - 1) begin
                selector_counter <= 0;
                select_signal <= ~select_signal;
            end

            // Output selected sine wave
            if (select_signal == 1'b0) begin
                // High frequency (1kHz)
                test_sample_i <= sin_table_high[phase_high];
                test_sample_q <= sin_table_high[(phase_high + 55) % TABLE_SIZE_HIGH];
                phase_high <= (phase_high == TABLE_SIZE_HIGH - 1) ? 0 : phase_high + 1;
            end else begin
                // Low frequency (500Hz)
                test_sample_i <= sin_table_low[phase_low];
                test_sample_q <= sin_table_low[(phase_low + 110) % TABLE_SIZE_LOW];
                phase_low <= (phase_low == TABLE_SIZE_LOW - 1) ? 0 : phase_low + 1;
            end

            test_sample_valid <= 1'b1;
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