`timescale 1ns/1ps
`default_nettype none

module tb_elastic_buffer;
    localparam int DATA_WIDTH = 32, TAG_WIDTH = 8;
    logic clk=0, rst=1, s_valid=0, s_ready, m_valid, m_ready=0;
    logic [DATA_WIDTH-1:0] s_data=0, m_data;
    logic [TAG_WIDTH-1:0] s_tag=0, m_tag;
    logic s_last=0, m_last;
    logic [DATA_WIDTH+TAG_WIDTH:0] expected [0:4095];
    int accepted_edge [0:4095];
    int write_index=0, read_index=0, edge_number=0, sequence_id=0;
    int total_sent=0, total_received=0, flushed=0, peak_pending=0;
    int no_stall_checked=0, stall_checked=0, stimulus_cycle=0;
    int unsigned random_state=32'h5eed1234;
    logic input_was_stalled=0, output_was_stalled=0;
    logic [DATA_WIDTH+TAG_WIDTH:0] held_token;
    always #5 clk = ~clk;
    elastic_buffer #(.DATA_WIDTH(DATA_WIDTH), .TAG_WIDTH(TAG_WIDTH)) dut (.*);

    always @(posedge clk) begin
        edge_number = edge_number + 1;
        if (rst) begin
            flushed = flushed + write_index - read_index;
            write_index=0; read_index=0;
            input_was_stalled=0; output_was_stalled=0;
        end else begin
            if (output_was_stalled) begin
                if (!m_valid || {m_last,m_tag,m_data} !== held_token)
                    $fatal(1, "stalled token changed or withdrew valid");
                stall_checked = stall_checked + 1;
            end
            if (s_valid && s_ready) begin
                expected[write_index] = {s_last,s_tag,s_data};
                accepted_edge[write_index] = edge_number;
                write_index = write_index + 1;
                total_sent = total_sent + 1;
            end
            if (m_valid && m_ready) begin
                if (read_index >= write_index || {m_last,m_tag,m_data} !== expected[read_index])
                    $fatal(1, "loss/duplication/order/sideband mismatch");
                if (stimulus_cycle >= 12 && stimulus_cycle < 99) begin
                    if (edge_number - accepted_edge[read_index] != 1)
                        $fatal(1, "expected one capture stage");
                    no_stall_checked = no_stall_checked + 1;
                end
                read_index = read_index + 1;
                total_received = total_received + 1;
            end
            if (write_index - read_index > peak_pending)
                peak_pending = write_index - read_index;
            if (write_index - read_index > 2)
                $fatal(1, "accepted more tokens than capacity");
            if (stimulus_cycle >= 12 && stimulus_cycle < 99 &&
                !(s_valid && s_ready && m_valid && m_ready))
                $fatal(1, "continuous no-stall II must be one");
            input_was_stalled = s_valid && !s_ready;
            output_was_stalled = m_valid && !m_ready;
            held_token = {m_last,m_tag,m_data};
        end
    end

    initial begin
        for (int cycle=0; cycle<1200; cycle++) begin
            @(negedge clk);
            stimulus_cycle = cycle;
            rst = cycle<3 || cycle==180 || cycle==181 || cycle==700 || cycle==701;
            random_state = random_state * 32'd1664525 + 32'd1013904223;
            if (rst) begin
                s_valid=0; m_ready=0;
            end else begin
                m_ready = cycle<100 || cycle>=1100 ||
                          (cycle>=190 && cycle<680 && random_state[5:2]!=0) ||
                          (cycle>=710 && cycle<1100 && random_state[5:2]!=0);
                if (!input_was_stalled) begin
                    s_valid = cycle<1100 && (cycle<100 || random_state[1:0]!=0);
                    s_data = 32'(sequence_id) ^ (32'(sequence_id)<<17) ^ 32'h8badf00d;
                    s_tag = TAG_WIDTH'(sequence_id);
                    s_last = sequence_id % 17 == 0;
                    sequence_id = sequence_id + 1;
                end
            end
        end
        @(negedge clk);
        s_valid=0;
        if (write_index!=read_index || total_sent!=total_received+flushed)
            $fatal(1, "drain/reset accounting failed");
        if (flushed==0 || peak_pending!=2 || no_stall_checked<80 || stall_checked<20)
            $fatal(1, "coverage phases were not exercised");
        $display("PASS elastic: accepted=%0d received=%0d reset_flushed=%0d peak=2 latency=1 II=1 stall_checks=%0d",
                 total_sent,total_received,flushed,stall_checked);
        $finish;
    end
    initial begin
        repeat (1400) @(posedge clk);
        $fatal(1, "timeout");
    end
endmodule

`default_nettype wire
