`timescale 1ns/1ps
`default_nettype none

module tb_stream_fork2;
    localparam int DATA_WIDTH = 32;
    localparam int TAG_WIDTH = 8;
    logic clk = 0, rst = 1;
    logic s_valid = 0, s_ready;
    logic [DATA_WIDTH-1:0] s_data = '0, m_data;
    logic [TAG_WIDTH-1:0] s_tag = '0, m_tag;
    logic s_last = 0, m_last;
    logic [1:0] m_valid, m_ready = '0;
    logic [DATA_WIDTH+TAG_WIDTH:0] expected [0:4095];
    int accepted_edge [0:4095];
    int write_index = 0, read_index [0:1] = '{0,0};
    int total_sent = 0, total_received [0:1] = '{0,0}, flushed [0:1] = '{0,0};
    int no_stall_checked = 0, stall_checked = 0, partial_reset_checked = 0;
    int asymmetric_checked = 0, edge_number = 0, stimulus_cycle = 0, sequence_id = 0;
    int unsigned random_state = 32'h12349abc;
    bit input_was_stalled = 0;
    logic [1:0] output_was_stalled = '0;
    logic [DATA_WIDTH+TAG_WIDTH:0] held_token;

    always #5 clk = ~clk;
    stream_fork2 #(.DATA_WIDTH(DATA_WIDTH), .TAG_WIDTH(TAG_WIDTH)) dut (.*);

    // Each output has its own cursor. A shared output count would miss a fast
    // branch accepting the same token twice while its partner remains blocked.
    always @(posedge clk) begin
        edge_number = edge_number + 1;
        if (rst) begin
            if (read_index[0] != read_index[1])
                partial_reset_checked = partial_reset_checked + 1;
            for (int branch = 0; branch < 2; branch++) begin
                flushed[branch] = flushed[branch] + write_index - read_index[branch];
                read_index[branch] = 0;
            end
            write_index = 0;
            input_was_stalled = 0;
            output_was_stalled = '0;
        end else begin
            if (s_valid && s_ready) begin
                expected[write_index] = {s_last, s_tag, s_data};
                accepted_edge[write_index] = edge_number;
                write_index = write_index + 1;
                total_sent = total_sent + 1;
            end
            for (int branch = 0; branch < 2; branch++) begin
                if (output_was_stalled[branch]) begin
                    if (!m_valid[branch] || {m_last,m_tag,m_data} !== held_token)
                        $fatal(1, "fork stalled branch %0d changed token/valid", branch);
                    stall_checked = stall_checked + 1;
                end
                if (m_valid[branch] && m_ready[branch]) begin
                    if (read_index[branch] >= write_index)
                        $fatal(1, "fork unsolicited/duplicate branch %0d", branch);
                    if ({m_last,m_tag,m_data} !== expected[read_index[branch]])
                        $fatal(1, "fork branch %0d data/tag/last/order mismatch", branch);
                    if (stimulus_cycle >= 12 && stimulus_cycle < 99 &&
                        edge_number - accepted_edge[read_index[branch]] != 1)
                        $fatal(1, "fork no-stall capture stage must be one");
                    read_index[branch] = read_index[branch] + 1;
                    total_received[branch] = total_received[branch] + 1;
                end
            end
            if (read_index[0] != read_index[1])
                asymmetric_checked = asymmetric_checked + 1;
            if (stimulus_cycle >= 12 && stimulus_cycle < 99) begin
                if (!(s_valid && s_ready && (&m_valid) && (&m_ready)))
                    $fatal(1, "fork continuous II must be one on both branches");
                no_stall_checked = no_stall_checked + 1;
            end
            input_was_stalled = s_valid && !s_ready;
            output_was_stalled = m_valid & ~m_ready;
            held_token = {m_last,m_tag,m_data};
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
                m_ready = '0;
            end else begin
                if (cycle < 100 || cycle >= 1600)
                    m_ready = 2'b11;
                else if (cycle < 190)
                    m_ready = 2'b01; // Branch 0 completes; branch 1 stays blocked through reset.
                else if (cycle >= 680 && cycle < 710)
                    m_ready = 2'b10; // Exercise the other direction and another partial reset.
                else
                    m_ready = {random_state[4:2] != 0, random_state[7:5] != 0};
                if (!input_was_stalled) begin
                    s_valid = cycle < 1600 && (cycle < 100 || random_state[1:0] != 0);
                    s_data = 32'(sequence_id*997+31);
                    s_tag = TAG_WIDTH'(sequence_id);
                    s_last = sequence_id % 7 == 6;
                    sequence_id = sequence_id + 1;
                end
            end
        end
        @(negedge clk);
        for (int branch = 0; branch < 2; branch++) begin
            if (write_index != read_index[branch] ||
                total_sent != total_received[branch] + flushed[branch])
                $fatal(1, "fork per-branch drain/reset accounting mismatch");
        end
        if (partial_reset_checked < 2 || asymmetric_checked < 50 ||
            no_stall_checked < 80 || stall_checked < 20)
            $fatal(1, "fork required coverage phases missing");
        $display("PASS FORK accepted=%0d received0=%0d received1=%0d flushed0=%0d flushed1=%0d stages=1 II=1 partial_resets=%0d asymmetric_cycles=%0d stall_checks=%0d",
                 total_sent,total_received[0],total_received[1],flushed[0],flushed[1],
                 partial_reset_checked,asymmetric_checked,stall_checked);
        $finish;
    end
endmodule

`default_nettype wire
