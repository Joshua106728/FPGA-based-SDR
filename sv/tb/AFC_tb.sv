`timescale 1ns / 1ps

module AFC_tb;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic signed [17:0] sample_q18 = '0;
    logic sample_tick;
    logic i2s_bclk;
    logic i2s_ws;
    logic i2s_sd;
    logic signed [17:0] samples [0:3] = '{18'sd0, 18'sd6639, 18'sd13260, -18'sd6639};
    int sample_index = 0;

    always #5 clk = ~clk;

    AFC dut (
        .clk(clk),
        .rst(rst),
        .sample_q18(sample_q18),
        .sample_tick(sample_tick),
        .i2s_bclk(i2s_bclk),
        .i2s_ws(i2s_ws),
        .i2s_sd(i2s_sd)
    );



    initial begin
        wait (rst == 1'b0);
        sample_q18 = samples[0];

        forever begin
            @(posedge sample_tick);
            sample_index = (sample_index + 1) % 4;
            sample_q18 = samples[sample_index];
        end
    end

    initial begin
        rst = 1;
        @(posedge clk);
        rst = 0;
        repeat (200000) @(posedge clk);
        $finish;
    end
endmodule