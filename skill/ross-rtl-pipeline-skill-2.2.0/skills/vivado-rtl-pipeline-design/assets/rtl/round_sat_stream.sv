`timescale 1ns/1ps
`default_nettype none

// Signed fixed-point x / 2**FRACTION_BITS -> signed integer, nearest-even then clamp.
// 批注：先舍入再饱和；overflow 只表示舍入结果越界，不表示丢失了小数位。
// Legal: IN_WIDTH >= 2; 2 <= OUT_WIDTH <= IN_WIDTH; 0 <= FRACTION_BITS < IN_WIDTH;
// TAG_WIDTH >= 1. Two capture stages, no-stall II=1. rst flushes pending tokens.
// This is a globally stalled pipeline: m_ready -> s_ready remains combinational.
// Wider instances still need mapping/routing; two stages do not promise a MHz.
module round_sat_stream #(
    parameter int IN_WIDTH = 8,
    parameter int OUT_WIDTH = 4,
    parameter int FRACTION_BITS = 3,
    parameter int TAG_WIDTH = 8
) (
    input  wire logic clk,
    input  wire logic rst,
    input  wire logic s_valid,
    output logic s_ready,
    input  wire logic signed [IN_WIDTH-1:0] s_value,
    input  wire logic [TAG_WIDTH-1:0] s_tag,
    input  wire logic s_last,
    output logic m_valid,
    input  wire logic m_ready,
    output logic signed [OUT_WIDTH-1:0] m_value,
    output logic m_overflow,
    output logic [TAG_WIDTH-1:0] m_tag,
    output logic m_last
);
    localparam logic signed [IN_WIDTH:0] WIDE_ONE = {{IN_WIDTH{1'b0}}, 1'b1};
    localparam logic signed [IN_WIDTH:0] OUTPUT_MAX =
        (WIDE_ONE <<< (OUT_WIDTH-1)) - WIDE_ONE;
    localparam logic signed [IN_WIDTH:0] OUTPUT_MIN =
        -(WIDE_ONE <<< (OUT_WIDTH-1));
    logic advance, output_valid, round_valid;
    logic signed [IN_WIDTH:0] floor_value, rounded_value, round_value;
    logic increment_round;
    logic [TAG_WIDTH-1:0] round_tag;
    logic round_last;

    assign advance = !output_valid || m_ready;
    assign s_ready = !rst && advance;
    assign m_valid = !rst && output_valid;

    // S1: arithmetic shift gives floor even for x < 0. The discarded low bits
    // encode r=x-floor*2**F in [0,2**F-1]; no negative-remainder special case.
    // 先扩一位再加舍入进位，避免正数在钳位比较之前翻成负数。
    assign floor_value = $signed({s_value[IN_WIDTH-1], s_value}) >>> FRACTION_BITS;
    if (FRACTION_BITS == 0) begin : gen_integer_input
        assign increment_round = 1'b0;
    end else if (FRACTION_BITS == 1) begin : gen_single_fraction_bit
        // At an exact half, increment only an odd floor so the result is even.
        assign increment_round = s_value[0] && floor_value[0];
    end else begin : gen_guard_and_sticky
        assign increment_round = s_value[FRACTION_BITS-1] &&
                                 ((|s_value[FRACTION_BITS-2:0]) || floor_value[0]);
    end
    assign rounded_value = floor_value + (increment_round ? WIDE_ONE : '0);

    // All fields share advance, including valid and overflow. A downstream stall
    // freezes S1 and S2 together; empty earlier slots cannot advance independently.
    always_ff @(posedge clk) begin
        if (rst) begin
            round_valid <= 1'b0;
            output_valid <= 1'b0;
        end else if (advance) begin
            round_valid <= s_valid;
            output_valid <= round_valid;
            if (s_valid) begin
                round_value <= rounded_value;
                round_tag <= s_tag;
                round_last <= s_last;
            end
            if (round_valid) begin
                // S2: compare at the wide signed width, then narrow the result.
                // Reset only validity: payload/overflow are unobservable if !m_valid.
                m_overflow <= 1'b0;
                if (round_value > OUTPUT_MAX) begin
                    m_value <= OUT_WIDTH'(OUTPUT_MAX);
                    m_overflow <= 1'b1;
                end else if (round_value < OUTPUT_MIN) begin
                    m_value <= OUT_WIDTH'(OUTPUT_MIN);
                    m_overflow <= 1'b1;
                end else begin
                    m_value <= OUT_WIDTH'(round_value);
                end
                m_tag <= round_tag;
                m_last <= round_last;
            end
        end
    end
endmodule

`default_nettype wire
