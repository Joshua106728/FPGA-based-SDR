// incldue

`timescale 1 ns / 1 ns

module fm_demodulate_tb();
    // import types::*;

    parameter PERIOD = 20;
    logic CLK = 0;
    logic nRST;
    always #(PERIOD/2) CLK++;
    fm_demodulate_if fdif();

    fm_demodulate DUT (
        .clk(CLK),
        .n_rst(nRST),
        .fdif(fdif.fd)
    );

    test PROG(CLK, nRST, fdif);

    always_ff @(posedge CLK) begin
        if (fdif.o_valid) begin
            $display(
                "time=%0t | o_audio=%0d",
                $time,
                fdif.o_audio
            );
        end
    end

endmodule

program test (
    input logic CLK,
    output logic nRST,
    fm_demodulate_if.tb fdif
);
    // import types::*;
    string curr = "";
    localparam IN_W = 16;

    task reset; 
    begin  
        nRST = 0; 
        @(posedge CLK);
        @(negedge CLK);
        nRST = 1;
        @(posedge CLK);
        @(negedge CLK);
    end
    endtask

    task send_sample(
        input logic signed [IN_W-1:0] sample_i,
        input logic signed [IN_W-1:0] sample_q
    );
        begin
            @(posedge CLK);
            fdif.i_valid = 1'b1;
            fdif.i_i     = sample_i;
            fdif.i_q     = sample_q;
        end
    endtask

    task idle_cycle();
        begin
            @(posedge CLK);
            fdif.i_valid = 1'b0;
            fdif.i_i     = '0;
            fdif.i_q     = '0;
        end
    endtask

    

    initial begin
        // Initialize inputs
        nRST   = 1'b0;
        fdif.i_valid = 1'b0;
        fdif.i_i     = '0;
        fdif.i_q     = '0;
        reset();
        $display("Starting FM demodulator test...");

        // ========================================================
        // Test 1: constant I/Q input
        //
        // If the phase is not changing, the FM demodulated output
        // should be close to zero after the pipeline fills.
        // ========================================================
        $display("\nTest 1: Constant I/Q samples");

        repeat (10) begin
            send_sample(16'sd10000, 16'sd0);
        end

        repeat (10) idle_cycle();

        // ========================================================
        // Test 2: rotating I/Q samples
        //
        // These samples approximate a rotating phasor.
        // Since the phase changes every sample, the discriminator
        // should produce nonzero output.
        // ========================================================
        $display("\nTest 2: Rotating I/Q samples");

        send_sample(16'sd10000,  16'sd0);
        send_sample(16'sd9239,   16'sd3827);
        send_sample(16'sd7071,   16'sd7071);
        send_sample(16'sd3827,   16'sd9239);
        send_sample(16'sd0,      16'sd10000);
        send_sample(-16'sd3827,  16'sd9239);
        send_sample(-16'sd7071,  16'sd7071);
        send_sample(-16'sd9239,  16'sd3827);
        send_sample(-16'sd10000, 16'sd0);
        send_sample(-16'sd9239, -16'sd3827);
        send_sample(-16'sd7071, -16'sd7071);
        send_sample(-16'sd3827, -16'sd9239);
        send_sample(16'sd0,     -16'sd10000);
        send_sample(16'sd3827,  -16'sd9239);
        send_sample(16'sd7071,  -16'sd7071);
        send_sample(16'sd9239,  -16'sd3827);
        send_sample(16'sd10000, 16'sd0);

        repeat (15) idle_cycle();

        // ========================================================
        // Test 3: small denominator case
        //
        // This checks that EPSILON protection prevents divide-by-zero.
        // ========================================================
        $display("\nTest 3: Near-zero I/Q samples");

        send_sample(16'sd0, 16'sd0);
        send_sample(16'sd1, 16'sd0);
        send_sample(16'sd0, 16'sd1);
        send_sample(16'sd0, 16'sd0);


        curr = "finished";
        $display(curr);
        $finish;
    end

endprogram
