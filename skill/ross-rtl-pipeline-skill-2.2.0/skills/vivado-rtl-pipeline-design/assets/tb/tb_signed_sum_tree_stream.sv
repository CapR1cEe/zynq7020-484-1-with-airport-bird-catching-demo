`timescale 1ns/1ps
`default_nettype none

module tb_signed_sum_tree_stream #(
    parameter int INPUTS = 5,
    parameter int DATA_WIDTH = 8
);
    localparam int TAG_WIDTH = 8;
    localparam int SUM_WIDTH = DATA_WIDTH + $clog2(INPUTS);
    localparam int CAPTURE_STAGES = (INPUTS > 1) ? $clog2(INPUTS) : 1;
    logic clk = 0, rst = 1;
    logic s_valid = 0, s_ready, m_valid, m_ready = 0;
    logic [INPUTS-1:0][DATA_WIDTH-1:0] s_values = '0;
    logic [TAG_WIDTH-1:0] s_tag = '0, m_tag;
    logic signed [SUM_WIDTH-1:0] m_sum;
    longint signed expected_sum [0:4095];
    logic [TAG_WIDTH-1:0] expected_tag [0:4095];
    int accepted_edge [0:4095];
    int write_index = 0, read_index = 0, edge_number = 0;
    int total_sent = 0, total_received = 0, flushed = 0;
    int no_stall_checked = 0, stall_checked = 0, sequence_id = 0;
    int stimulus_cycle = 0;
    int unsigned random_state = 32'h7654abcd;
    bit input_was_stalled = 0, output_was_stalled = 0;
    logic signed [SUM_WIDTH-1:0] held_sum;
    logic [TAG_WIDTH-1:0] held_tag;
    longint signed reference_sum;

    always #5 clk = ~clk;
    signed_sum_tree_stream #(.INPUTS(INPUTS), .DATA_WIDTH(DATA_WIDTH), .TAG_WIDTH(TAG_WIDTH)) dut (.*);

    // Reference is a wide sequential software sum, independent of the RTL tree
    // topology. Odd-lane pass-through errors cannot be shared by both models.
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
                    $fatal(1, "tree output changed while stalled");
                stall_checked = stall_checked + 1;
            end
            if (s_valid && s_ready) begin
                reference_sum = 0;
                for (int lane = 0; lane < INPUTS; lane++)
                    reference_sum = reference_sum + longint'($signed(s_values[lane]));
                expected_sum[write_index] = reference_sum;
                expected_tag[write_index] = s_tag;
                accepted_edge[write_index] = edge_number;
                write_index = write_index + 1;
                total_sent = total_sent + 1;
            end
            if (m_valid && m_ready) begin
                if (read_index >= write_index)
                    $fatal(1, "tree unsolicited/duplicate output");
                if (longint'(m_sum) !== expected_sum[read_index] || m_tag !== expected_tag[read_index])
                    $fatal(1, "tree signed sum/tag/order mismatch at token %0d", read_index);
                if (stimulus_cycle >= 12 && stimulus_cycle < 99) begin
                    if (edge_number - accepted_edge[read_index] != CAPTURE_STAGES)
                        $fatal(1, "tree capture stage latency mismatch");
                    no_stall_checked = no_stall_checked + 1;
                end
                read_index = read_index + 1;
                total_received = total_received + 1;
            end
            if (stimulus_cycle >= 12 && stimulus_cycle < 99 &&
                !(s_valid && s_ready && m_valid && m_ready))
                $fatal(1, "tree continuous II must be one");
            input_was_stalled = s_valid && !s_ready;
            output_was_stalled = m_valid && !m_ready;
            held_sum = m_sum;
            held_tag = m_tag;
        end
    end

    initial begin
        for (int cycle = 0; cycle < 1800; cycle++) begin
            @(negedge clk);
            stimulus_cycle = cycle;
            rst = cycle < 3 || cycle == 180 || cycle == 181 || cycle == 700 || cycle == 701;
            random_state = random_state * 32'd1664525 + 32'd1013904223;
            if (rst) begin
                s_valid = 0;
                m_ready = 0;
            end else begin
                m_ready = cycle < 100 || cycle >= 1600 ||
                          (cycle >= 190 && cycle < 680 && random_state[4:2] != 0) ||
                          (cycle >= 710 && cycle < 1600 && random_state[4:2] != 0);
                if (!input_was_stalled) begin
                    s_valid = cycle < 1600 && (cycle < 100 || random_state[1:0] != 0);
                    s_tag = TAG_WIDTH'(sequence_id);
                    for (int lane = 0; lane < INPUTS; lane++) begin
                        case (sequence_id % 4)
                            0: s_values[lane] = {1'b1, {(DATA_WIDTH-1){1'b0}}};
                            1: s_values[lane] = {1'b0, {(DATA_WIDTH-1){1'b1}}};
                            2: s_values[lane] = DATA_WIDTH'((lane % 2) ? -1 : 1);
                            default: s_values[lane] = DATA_WIDTH'(sequence_id*13 + lane*31);
                        endcase
                    end
                    sequence_id = sequence_id + 1;
                end
            end
        end
        @(negedge clk);
        if (write_index != read_index || total_sent != total_received + flushed)
            $fatal(1, "tree drain/reset accounting mismatch");
        if (flushed == 0 || no_stall_checked < 80 || stall_checked < 20)
            $fatal(1, "tree required coverage phases missing");
        $display("PASS TREE inputs=%0d width=%0d accepted=%0d received=%0d reset_flushed=%0d stages=%0d II=1 stall_checks=%0d",
                 INPUTS, DATA_WIDTH, total_sent, total_received, flushed, CAPTURE_STAGES, stall_checked);
        $finish;
    end
endmodule

`default_nettype wire
