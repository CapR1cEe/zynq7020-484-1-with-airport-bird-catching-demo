`timescale 1ns/1ps
`default_nettype none

// Two-entry single-clock token FIFO. No combinational m_ready -> s_ready path.
// One capture stage; II=1 when the consumer stays ready. Reset flushes tokens.
module elastic_buffer #(
    parameter int DATA_WIDTH = 32,
    parameter int TAG_WIDTH = 8
) (
    input  wire logic clk,
    input  wire logic rst,
    input  wire logic s_valid,
    output logic s_ready,
    input  wire logic [DATA_WIDTH-1:0] s_data,
    input  wire logic [TAG_WIDTH-1:0] s_tag,
    input  wire logic s_last,
    output logic m_valid,
    input  wire logic m_ready,
    output logic [DATA_WIDTH-1:0] m_data,
    output logic [TAG_WIDTH-1:0] m_tag,
    output logic m_last
);
    localparam int TOKEN_WIDTH = DATA_WIDTH + TAG_WIDTH + 1;
    logic [TOKEN_WIDTH-1:0] slots [0:1];
    logic read_slot, write_slot;
    logic [1:0] used_slots;
    logic push, pop;

    assign s_ready = !rst && (used_slots < 2);
    // Ready depends on stored occupancy, not m_ready. A full buffer therefore
    // waits one cycle after a drain before accepting again; this is intentional.
    assign m_valid = !rst && (used_slots != 0);
    assign {m_last, m_tag, m_data} = slots[read_slot];
    assign push = s_valid && s_ready;
    assign pop = m_valid && m_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            used_slots <= 2'd0;
            read_slot <= 1'b0;
            write_slot <= 1'b0;
        end else begin
            if (push) begin
                slots[write_slot] <= {s_last, s_tag, s_data};
                write_slot <= !write_slot;
            end
            if (pop)
                read_slot <= !read_slot;
            case ({push, pop})
                2'b10: used_slots <= used_slots + 2'd1;
                2'b01: used_slots <= used_slots - 2'd1;
                // Simultaneous push/pop advances both pointers, not occupancy.
                default: ;
            endcase
        end
    end
endmodule

`default_nettype wire
