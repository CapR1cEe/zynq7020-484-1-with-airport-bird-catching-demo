`timescale 1ns/1ps
`default_nettype none

// Buffered two-way broadcast: each accepted input is delivered once per branch.
// One capture stage, no-stall II=1. DATA_WIDTH/TAG_WIDTH must be positive.
// rst flushes each branch's still-pending copy; an already delivered copy is not undone.
module stream_fork2 #(
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
    output logic [1:0] m_valid,
    input  wire logic [1:0] m_ready,
    output logic [DATA_WIDTH-1:0] m_data,
    output logic [TAG_WIDTH-1:0] m_tag,
    output logic m_last
);
    logic [1:0] pending;
    logic [DATA_WIDTH-1:0] held_data;
    logic [TAG_WIDTH-1:0] held_tag;
    logic held_last;
    logic all_copies_retire;

    // 每个分支只观察自己的 pending 位，不能只把同一个 valid 接到两个出口。
    // Once a fast branch accepts, its valid drops until the next input token.
    assign m_valid = {2{!rst}} & pending;
    assign m_data = held_data;
    assign m_tag = held_tag;
    assign m_last = held_last;

    // Retire the old token and replace it on the same edge for continuous II=1.
    // This deliberate ready path is combinational. Add per-branch buffering if
    // it becomes critical; the shared slot alone cannot isolate ready timing.
    assign all_copies_retire = &(~pending | m_ready);
    assign s_ready = !rst && all_copies_retire;

    always_ff @(posedge clk) begin
        if (rst) begin
            pending <= 2'b00;
        end else if (s_valid && s_ready) begin
            held_data <= s_data;
            held_tag <= s_tag;
            held_last <= s_last;
            pending <= 2'b11;
        end else begin
            // Only accepted copies retire. Never re-enable a completed branch
            // while its partner stalls on this same token.
            pending <= pending & ~m_ready;
        end
    end
endmodule

`default_nettype wire
