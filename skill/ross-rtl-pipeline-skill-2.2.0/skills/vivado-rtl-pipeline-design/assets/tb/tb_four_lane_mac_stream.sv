`timescale 1ns/1ps
`default_nettype none

module tb_four_lane_mac_stream #(
    parameter int DATA_WIDTH = 8
);
    localparam int TAG_WIDTH = 8;
    localparam int SUM_WIDTH = 2 * DATA_WIDTH + 2;
    logic clk = 0, rst = 1;
    logic s_valid = 0, s_ready, m_valid, m_ready = 0;
    logic signed [DATA_WIDTH-1:0] a0, b0, a1, b1, a2, b2, a3, b3;
    logic [TAG_WIDTH-1:0] s_tag, m_tag;
    logic signed [SUM_WIDTH-1:0] m_sum;
    longint signed expected_sum [0:4095];
    logic [TAG_WIDTH-1:0] expected_tag [0:4095];
    int accepted_edge [0:4095];
    int write_index = 0, read_index = 0, edge_number = 0;
    int total_sent = 0, total_received = 0, flushed = 0;
    int no_stall_checked = 0, stall_checked = 0, sequence_id = 0;
    int stimulus_cycle = 0;
    int unsigned random_state = 32'h1234abcd;
    logic input_was_stalled = 0, output_was_stalled = 0;
    logic signed [SUM_WIDTH-1:0] held_sum;
    logic [TAG_WIDTH-1:0] held_tag;

    always #5 clk = ~clk;
    four_lane_mac_stream #(.DATA_WIDTH(DATA_WIDTH), .TAG_WIDTH(TAG_WIDTH)) dut (.*);

    function automatic logic signed [DATA_WIDTH-1:0] operand(input int value);
        return DATA_WIDTH'(value);
    endfunction

    always @(posedge clk) begin
        edge_number = edge_number + 1;
        if (rst) begin
            flushed = flushed + write_index - read_index;
            write_index = 0;
            read_index = 0;
            input_was_stalled = 0;
            output_was_stalled = 0;
        end else begin
            if (output_was_stalled) begin
                if (!m_valid || m_sum !== held_sum || m_tag !== held_tag)
                    $fatal(1, "stalled output changed or withdrew valid");
                stall_checked = stall_checked + 1;
            end
            if (s_valid && s_ready) begin
                expected_sum[write_index] =
                    longint'(a0)*longint'(b0) + longint'(a1)*longint'(b1) +
                    longint'(a2)*longint'(b2) + longint'(a3)*longint'(b3);
                expected_tag[write_index] = s_tag;
                accepted_edge[write_index] = edge_number;
                write_index = write_index + 1;
                total_sent = total_sent + 1;
            end
            if (m_valid && m_ready) begin
                if (read_index >= write_index)
                    $fatal(1, "unsolicited or duplicated output");
                if (longint'(m_sum) !== expected_sum[read_index] || m_tag !== expected_tag[read_index])
                    $fatal(1, "arithmetic/tag/order mismatch at %0d", read_index);
                if (stimulus_cycle >= 12 && stimulus_cycle < 99) begin
                    if (edge_number - accepted_edge[read_index] != 3)
                        $fatal(1, "expected three capture stages");
                    no_stall_checked = no_stall_checked + 1;
                end
                read_index = read_index + 1;
                total_received = total_received + 1;
            end
            if (stimulus_cycle >= 12 && stimulus_cycle < 99 &&
                !(s_valid && s_ready && m_valid && m_ready))
                $fatal(1, "continuous no-stall II must be one");
            input_was_stalled = s_valid && !s_ready;
            output_was_stalled = m_valid && !m_ready;
            held_sum = m_sum;
            held_tag = m_tag;
        end
    end

    initial begin
        a0=0; b0=0; a1=0; b1=0; a2=0; b2=0; a3=0; b3=0; s_tag=0;
        for (int cycle = 0; cycle < 1200; cycle++) begin
            @(negedge clk);
            stimulus_cycle = cycle;
            rst = cycle < 3 || cycle == 180 || cycle == 181 || cycle == 700 || cycle == 701;
            random_state = random_state * 32'd1664525 + 32'd1013904223;
            if (rst) begin
                s_valid = 0;
                m_ready = 0;
            end else begin
                m_ready = cycle < 100 || cycle >= 1100 ||
                          (cycle >= 190 && cycle < 680 && random_state[4:2] != 0) ||
                          (cycle >= 710 && cycle < 1100 && random_state[4:2] != 0);
                if (!input_was_stalled) begin
                    s_valid = cycle < 1100 && (cycle < 100 || random_state[1:0] != 0);
                    s_tag = TAG_WIDTH'(sequence_id);
                    if (sequence_id % 16 == 0) begin
                        a0 = {1'b1, {(DATA_WIDTH-1){1'b0}}}; b0=a0;
                        a1=a0; b1=a0; a2=a0; b2=a0; a3=a0; b3=a0;
                    end else if (sequence_id % 16 == 1) begin
                        a0 = {1'b1, {(DATA_WIDTH-1){1'b0}}};
                        b0 = {1'b0, {(DATA_WIDTH-1){1'b1}}};
                        a1=b0; b1=a0; a2=-1; b2=-1; a3=b0; b3=b0;
                    end else begin
                        a0=operand(sequence_id*13+9); b0=operand(sequence_id*7-31);
                        a1=operand(sequence_id*19+5); b1=operand(sequence_id*11+3);
                        a2=operand(sequence_id*3-99); b2=operand(sequence_id*23-61);
                        a3=operand(sequence_id*29-101); b3=operand(sequence_id*17+71);
                    end
                    sequence_id = sequence_id + 1;
                end
            end
        end
        @(negedge clk);
        s_valid = 0;
        if (write_index != read_index || total_sent != total_received + flushed)
            $fatal(1, "drain/reset accounting failed");
        if (flushed == 0 || no_stall_checked < 80 || stall_checked < 20)
            $fatal(1, "coverage phases were not exercised");
        $display("PASS MAC width=%0d: accepted=%0d received=%0d reset_flushed=%0d latency=3 II=1 stall_checks=%0d",
                 DATA_WIDTH,total_sent,total_received,flushed,stall_checked);
        $finish;
    end
    initial begin
        repeat (1400) @(posedge clk);
        $fatal(1, "timeout");
    end
endmodule

`default_nettype wire
