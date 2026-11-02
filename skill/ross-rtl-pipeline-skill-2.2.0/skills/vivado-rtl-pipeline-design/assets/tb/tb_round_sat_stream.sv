`timescale 1ns/1ps
`default_nettype none

module tb_round_sat_stream #(
    parameter int IN_WIDTH = 8,
    parameter int OUT_WIDTH = 4,
    parameter int FRACTION_BITS = 3
);
    localparam int TAG_WIDTH = 8;
    localparam int VALUE_COUNT = 1 << IN_WIDTH;
    localparam int EXHAUSTIVE_END = VALUE_COUNT + 3;
    localparam int RANDOM_END = EXHAUSTIVE_END + 1500;
    logic clk = 0, rst = 1;
    logic s_valid = 0, s_ready, m_valid, m_ready = 0;
    logic signed [IN_WIDTH-1:0] s_value = '0;
    logic signed [OUT_WIDTH-1:0] m_value;
    logic [TAG_WIDTH-1:0] s_tag = '0, m_tag;
    logic s_last = 0, m_last, m_overflow;
    longint signed expected_value [0:16383];
    bit expected_overflow [0:16383];
    logic [TAG_WIDTH-1:0] expected_tag [0:16383];
    bit expected_last [0:16383];
    int accepted_edge [0:16383];
    bit exhaustive_seen [0:VALUE_COUNT-1];
    int write_index = 0, read_index = 0, edge_number = 0;
    int total_sent = 0, total_received = 0, flushed = 0;
    int no_stall_checked = 0, stall_checked = 0, exhaustive_checked = 0;
    int sequence_id = 0, stimulus_cycle = 0;
    int unsigned random_state = 32'hb4918ac7;
    bit input_was_stalled = 0, output_was_stalled = 0;
    logic signed [OUT_WIDTH-1:0] held_value;
    logic held_overflow, held_last;
    logic [TAG_WIDTH-1:0] held_tag;
    longint signed reference_rounded;

    always #5 clk = ~clk;
    round_sat_stream #(.IN_WIDTH(IN_WIDTH), .OUT_WIDTH(OUT_WIDTH),
                       .FRACTION_BITS(FRACTION_BITS), .TAG_WIDTH(TAG_WIDTH)) dut (.*);

    // Independent oracle: sign/magnitude integer division and remainder, rather
    // than the DUT's negative floor, guard/sticky bits or register state.
    function automatic longint signed nearest_even(input longint signed raw);
        longint signed magnitude, quotient, remainder, scale;
        begin
            scale = 64'sd1 << FRACTION_BITS;
            magnitude = (raw < 0) ? -raw : raw;
            quotient = magnitude / scale;
            remainder = magnitude % scale;
            if (2*remainder > scale ||
                (2*remainder == scale && quotient % 2 != 0))
                quotient = quotient + 1;
            nearest_even = (raw < 0) ? -quotient : quotient;
        end
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
                if (!m_valid || m_value !== held_value || m_overflow !== held_overflow ||
                    m_tag !== held_tag || m_last !== held_last)
                    $fatal(1, "round/sat output or metadata changed while stalled");
                stall_checked = stall_checked + 1;
            end
            if (s_valid && s_ready) begin
                if (write_index >= 16384)
                    $fatal(1, "round/sat scoreboard capacity exceeded");
                reference_rounded = nearest_even(longint'(s_value));
                expected_overflow[write_index] = 0;
                if (reference_rounded > (64'sd1 << (OUT_WIDTH-1))-1) begin
                    reference_rounded = (64'sd1 << (OUT_WIDTH-1))-1;
                    expected_overflow[write_index] = 1;
                end else if (reference_rounded < -(64'sd1 << (OUT_WIDTH-1))) begin
                    reference_rounded = -(64'sd1 << (OUT_WIDTH-1));
                    expected_overflow[write_index] = 1;
                end
                expected_value[write_index] = reference_rounded;
                expected_tag[write_index] = s_tag;
                expected_last[write_index] = s_last;
                accepted_edge[write_index] = edge_number;
                write_index = write_index + 1;
                total_sent = total_sent + 1;
                if (stimulus_cycle < EXHAUSTIVE_END)
                    exhaustive_seen[int'($unsigned(s_value))] = 1;
            end
            if (m_valid && m_ready) begin
                if (read_index >= write_index)
                    $fatal(1, "round/sat unsolicited or duplicate output");
                if (longint'(m_value) !== expected_value[read_index] ||
                    m_overflow !== expected_overflow[read_index] ||
                    m_tag !== expected_tag[read_index] || m_last !== expected_last[read_index])
                    $fatal(1, "round/sat value/overflow/tag/last mismatch at token %0d", read_index);
                if (stimulus_cycle >= 5 && stimulus_cycle < EXHAUSTIVE_END) begin
                    if (edge_number - accepted_edge[read_index] != 2)
                        $fatal(1, "round/sat capture-stage latency must be two");
                    no_stall_checked = no_stall_checked + 1;
                end
                read_index = read_index + 1;
                total_received = total_received + 1;
            end
            if (stimulus_cycle >= 5 && stimulus_cycle < EXHAUSTIVE_END &&
                !(s_valid && s_ready && m_valid && m_ready))
                $fatal(1, "round/sat continuous II must be one");
            input_was_stalled = s_valid && !s_ready;
            output_was_stalled = m_valid && !m_ready;
            held_value = m_value;
            held_overflow = m_overflow;
            held_tag = m_tag;
            held_last = m_last;
        end
    end

    initial begin
        if (IN_WIDTH < 2 || IN_WIDTH > 12 || OUT_WIDTH < 2 || OUT_WIDTH > IN_WIDTH ||
            FRACTION_BITS < 0 || FRACTION_BITS >= IN_WIDTH)
            $fatal(1, "unsupported bench parameters");
        foreach (exhaustive_seen[i]) exhaustive_seen[i] = 0;
        for (int cycle = 0; cycle < RANDOM_END + 100; cycle++) begin
            @(negedge clk);
            stimulus_cycle = cycle;
            rst = cycle < 3 || cycle == EXHAUSTIVE_END+28 || cycle == EXHAUSTIVE_END+29;
            random_state = random_state * 32'd1664525 + 32'd1013904223;
            if (rst) begin
                s_valid = 0;
                m_ready = 0;
            end else begin
                // First enumerate every signed bit pattern without stalls, then
                // fill/stall/reset in flight and independently randomize traffic.
                m_ready = cycle < EXHAUSTIVE_END+10 || cycle >= RANDOM_END ||
                          (cycle >= EXHAUSTIVE_END+40 && random_state[5:3] != 0);
                if (!input_was_stalled) begin
                    s_valid = cycle < RANDOM_END &&
                              (cycle < EXHAUSTIVE_END+40 || random_state[1:0] != 0);
                    s_value = IN_WIDTH'(sequence_id);
                    s_tag = TAG_WIDTH'(sequence_id);
                    s_last = sequence_id % 17 == 16;
                    sequence_id = sequence_id + 1;
                end
            end
        end
        @(negedge clk);
        foreach (exhaustive_seen[i]) begin
            if (!exhaustive_seen[i])
                $fatal(1, "round/sat exhaustive input %0d was not accepted", i);
            exhaustive_checked = exhaustive_checked + 1;
        end
        if (write_index != read_index || total_sent != total_received + flushed)
            $fatal(1, "round/sat drain/reset accounting mismatch");
        if (flushed != 2 || stall_checked < 20 || no_stall_checked < VALUE_COUNT-2)
            $fatal(1, "round/sat required coverage missing");
        $display("PASS ROUND in=%0d out=%0d frac=%0d exhaustive=%0d accepted=%0d received=%0d reset_flushed=%0d stages=2 II=1 ii_checks=%0d stall_checks=%0d",
                 IN_WIDTH, OUT_WIDTH, FRACTION_BITS, exhaustive_checked, total_sent,
                 total_received, flushed, no_stall_checked, stall_checked);
        $finish;
    end
endmodule

`default_nettype wire
