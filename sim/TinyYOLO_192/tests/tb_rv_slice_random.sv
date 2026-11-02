`timescale 1ns/1ps
module tb_rv_slice_random;
    localparam integer WIDTH = 171;
    localparam integer QUEUE_DEPTH = 4096;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;
    reg s_valid = 1'b0;
    wire s_ready;
    reg [WIDTH-1:0] s_data = {WIDTH{1'b0}};
    wire m_valid;
    reg m_ready = 1'b0;
    wire [WIDTH-1:0] m_data;
    wire empty;

    reg [WIDTH-1:0] expected [0:QUEUE_DEPTH-1];
    integer rd = 0;
    integer wr = 0;
    integer queued = 0;
    integer accepted = 0;
    integer delivered = 0;
    integer cycles = 0;
    integer seed = 32'h5eed_180;
    integer drain_cycles;
    reg source_was_stalled = 1'b0;
    reg output_was_stalled = 1'b0;
    reg [WIDTH-1:0] held_source_data;
    reg [WIDTH-1:0] held_output_data;

    tinyyolo_rv_slice #(.WIDTH(WIDTH)) dut (
        .clk(clk), .rst_n(rst_n), .s_valid(s_valid), .s_ready(s_ready),
        .s_data(s_data), .m_valid(m_valid), .m_ready(m_ready),
        .m_data(m_data), .empty(empty)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            rd = 0;
            wr = 0;
            queued = 0;
            accepted = 0;
            delivered = 0;
            cycles = 0;
            source_was_stalled = 1'b0;
            output_was_stalled = 1'b0;
        end else begin
            if (source_was_stalled &&
                (!s_valid || s_data !== held_source_data))
                $fatal(1, "source changed payload while backpressured");
            if (output_was_stalled &&
                (!m_valid || m_data !== held_output_data))
                $fatal(1, "output changed payload while backpressured");

            source_was_stalled = s_valid && !s_ready;
            if (source_was_stalled)
                held_source_data = s_data;
            output_was_stalled = m_valid && !m_ready;
            if (output_was_stalled)
                held_output_data = m_data;

            if (m_valid && m_ready) begin
                if (queued == 0)
                    $fatal(1, "output produced without an accepted input");
                if (m_data !== expected[rd])
                    $fatal(1, "payload mismatch at item %0d", delivered);
                rd = (rd + 1) % QUEUE_DEPTH;
                queued = queued - 1;
                delivered = delivered + 1;
            end

            if (s_valid && s_ready) begin
                if (queued == QUEUE_DEPTH)
                    $fatal(1, "scoreboard overflow");
                expected[wr] = s_data;
                wr = (wr + 1) % QUEUE_DEPTH;
                queued = queued + 1;
                accepted = accepted + 1;
            end
            cycles = cycles + 1;
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Random source bubbles and sink backpressure exercise both skid
        // slots while the scoreboard checks ordering and exactly-once delivery.
        repeat (6000) begin
            @(posedge clk);
            if (!s_valid || s_ready) begin
                if (($urandom(seed) % 4) != 0) begin
                    s_valid <= 1'b1;
                    s_data <= s_data + 1'b1;
                end else begin
                    s_valid <= 1'b0;
                end
            end
            m_ready <= (($urandom(seed) % 3) != 0);
        end

        @(posedge clk);
        s_valid <= 1'b0;
        m_ready <= 1'b1;
        drain_cycles = 0;
        @(negedge clk);
        while (!empty && drain_cycles < 100) begin
            @(negedge clk);
            drain_cycles = drain_cycles + 1;
        end
        if (!empty)
            $fatal(1, "pipeline failed to drain");
        if (queued != 0 || accepted != delivered)
            $fatal(1, "drain mismatch queued=%0d accepted=%0d delivered=%0d",
                   queued, accepted, delivered);
        $display("RV_SLICE_PASS width=%0d cycles=%0d accepted=%0d delivered=%0d",
                 WIDTH, cycles, accepted, delivered);
        $finish;
    end
endmodule
