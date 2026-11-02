`timescale 1ns/1ps
`default_nettype none

// Internal timing characterization only: registered launch, reduction and sink
// share the full top-level clock network. This is not a board pin/interface plan.
// Traffic is deterministic and continuously ready; protocol tests live in the TB.
module registered_tree_benchmark (
    input wire logic clk,
    output logic [10:0] checksum
);
    logic [3:0] startup_count = '0;
    logic [31:0] stimulus = 32'h12345678;
    logic reset_active, s_ready, m_valid;
    logic [4:0][7:0] s_values;
    logic signed [10:0] m_sum;
    logic [7:0] m_tag;

    // Startup initialization is a deliberate FPGA benchmark assumption. The
    // reusable core instead receives its reset from the surrounding application.
    assign reset_active = !(&startup_count);
    always_ff @(posedge clk) begin
        if (!(&startup_count))
            startup_count <= startup_count + 4'd1;
        if (reset_active)
            stimulus <= 32'h12345678;
        else if (s_ready)
            stimulus <= {stimulus[30:0], stimulus[31]^stimulus[21]^stimulus[1]^stimulus[0]};
        if (reset_active)
            checksum <= '0;
        else if (m_valid)
            checksum <= checksum ^ m_sum ^ {3'b000,m_tag};
    end
    for (genvar lane = 0; lane < 5; lane++) begin : gen_source_lane
        assign s_values[lane] = stimulus[(lane*5) +: 8];
    end
    signed_sum_tree_stream #(.INPUTS(5),.DATA_WIDTH(8),.TAG_WIDTH(8)) reduction (
        .clk(clk), .rst(reset_active),
        .s_valid(!reset_active), .s_ready(s_ready), .s_values(s_values), .s_tag(stimulus[7:0]),
        .m_valid(m_valid), .m_ready(1'b1), .m_sum(m_sum), .m_tag(m_tag)
    );
endmodule

`default_nettype wire
