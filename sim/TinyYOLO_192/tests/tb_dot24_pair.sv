`timescale 1ns/1ps

// Bit-exact and protocol check for the 24-lane INT8 dot-product pair.
// The test deliberately includes reset bubbles and arbitrary valid/last
// patterns so the extra registered final-add stage cannot hide a misalignment.
module tb_dot24_pair;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg valid = 1'b0;
    reg last = 1'b0;
    reg [191:0] a = 192'd0;
    reg [191:0] w0 = 192'd0;
    reg [191:0] w1 = 192'd0;
    wire out_valid, out_last;
    wire signed [20:0] sum0, sum1;

    always #2.083333333 clk = ~clk; // 240 MHz

    tinyyolo_dot24_pair dut (
        .clk(clk), .rst_n(rst_n), .valid(valid), .last(last),
        .a(a), .w0(w0), .w1(w1),
        .out_valid(out_valid), .out_last(out_last), .sum0(sum0), .sum1(sum1)
    );

    integer expected0 [0:12000];
    integer expected1 [0:12000];
    reg expected_last [0:12000];
    integer head = 0;
    integer tail = 0;
    integer checked = 0;
    integer i;
    integer e0;
    integer e1;
    reg [14:0] valid_pipe = 0;
    reg [14:0] last_pipe = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            head = 0;
            tail = 0;
            valid_pipe = 0;
            last_pipe = 0;
        end else begin
            valid_pipe = {valid_pipe[13:0], valid};
            last_pipe = {last_pipe[13:0], last};
            if (valid) begin
                e0 = 0;
                e1 = 0;
                for (i = 0; i < 24; i = i + 1) begin
                    e0 = e0 + $signed(a[i*8 +: 8]) * $signed(w0[i*8 +: 8]);
                    e1 = e1 + $signed(a[i*8 +: 8]) * $signed(w1[i*8 +: 8]);
                end
                expected0[tail] = e0;
                expected1[tail] = e1;
                expected_last[tail] = last;
                tail = tail + 1;
            end
            // Allow nonblocking assignments in the DUT to settle.
            #0.01;
            if (out_valid !== valid_pipe[14] || out_last !== last_pipe[14])
                $fatal(1, "DOT24 latency mismatch: expected 15 clocks");
            if (out_valid) begin
                if (head >= tail || $signed(sum0) !== expected0[head] ||
                    $signed(sum1) !== expected1[head] ||
                    out_last !== expected_last[head]) begin
                    $fatal(1, "DOT24 mismatch checked=%0d head=%0d got=%0d,%0d,%0d expect=%0d,%0d,%0d",
                           checked, head, $signed(sum0), $signed(sum1), out_last,
                           expected0[head], expected1[head], expected_last[head]);
                end
                head = head + 1;
                checked = checked + 1;
            end
        end
    end

    integer n;
    integer j;
    initial begin
        // Keep reset asserted through the DSP reset pipeline and the
        // simulator's 100 ns global-startup reset (glbl).
        repeat (70) @(negedge clk);
        rst_n = 1'b1;
        for (n = 0; n < 5000; n = n + 1) begin
            @(negedge clk);
            valid = ($urandom_range(0, 4) != 0);
            last = ($urandom_range(0, 10) == 0);
            for (j = 0; j < 24; j = j + 1) begin
                a[j*8 +: 8] = $urandom;
                w0[j*8 +: 8] = $urandom;
                w1[j*8 +: 8] = $urandom;
                // Directed signed extremes at the start of the run.
                if (n < 8) begin
                    a[j*8 +: 8] = n[0] ? 8'h80 : 8'h7f;
                    w0[j*8 +: 8] = n[1] ? 8'h80 : 8'h7f;
                    w1[j*8 +: 8] = n[2] ? 8'h80 : 8'h7f;
                    valid = 1'b1;
                end
            end
            // Reset while traffic is active; this must flush both valid and
            // arithmetic state without leaking a stale result afterward.
            if (n != 0 && (n % 997) == 900) begin
                rst_n = 1'b0;
                valid = 1'b0;
                last = 1'b0;
            end else if (n != 0 && (n % 997) == 905) begin
                rst_n = 1'b1;
            end
        end
        @(negedge clk);
        valid = 1'b0;
        last = 1'b0;
        repeat (20) @(negedge clk);
        if (head != tail)
            $fatal(1, "DOT24 undrained pipeline head=%0d tail=%0d", head, tail);
        $display("DOT24_PAIR_PASS vectors=%0d reset_bubbles=PASS clock_MHz=240", checked);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "DOT24 timeout");
    end
endmodule
