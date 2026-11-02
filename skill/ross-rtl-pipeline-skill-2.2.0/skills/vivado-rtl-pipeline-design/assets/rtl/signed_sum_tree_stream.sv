`timescale 1ns/1ps
`default_nettype none

// Exact signed reduction for INPUTS >= 1, DATA_WIDTH >= 2, TAG_WIDTH >= 1.
// 无背压时 II=1；capture stages=max(1,ceil(log2(INPUTS)))。rst 同步清空在途 token。
// One global advance makes the handwritten schedule easy to inspect. It also
// creates a shared enable and m_ready -> s_ready path; inspect fanout when scaling.
module signed_sum_tree_stream #(
    parameter int INPUTS = 5,
    parameter int DATA_WIDTH = 8,
    parameter int TAG_WIDTH = 8
) (
    input  wire logic clk,
    input  wire logic rst,
    input  wire logic s_valid,
    output logic s_ready,
    input  wire logic [INPUTS-1:0][DATA_WIDTH-1:0] s_values,
    input  wire logic [TAG_WIDTH-1:0] s_tag,
    output logic m_valid,
    input  wire logic m_ready,
    output logic signed [DATA_WIDTH+$clog2(INPUTS)-1:0] m_sum,
    output logic [TAG_WIDTH-1:0] m_tag
);
    localparam int SUM_WIDTH = DATA_WIDTH + $clog2(INPUTS);
    localparam int LEVELS = (INPUTS > 1) ? $clog2(INPUTS) : 1;
    logic [LEVELS-1:0] stage_valid;
    logic [TAG_WIDTH-1:0] stage_tag [0:LEVELS-1];
    logic advance;

    // 冻结整条流水线时，数值、tag、valid 一起保持。空输出允许流水线继续前进。
    assign advance = !stage_valid[LEVELS-1] || m_ready;
    assign s_ready = !rst && advance;
    assign m_valid = !rst && stage_valid[LEVELS-1];
    assign m_tag = stage_tag[LEVELS-1];

    always_ff @(posedge clk) begin
        if (rst) begin
            stage_valid <= '0;
        end else if (advance) begin
            stage_valid[0] <= s_valid;
            if (s_valid)
                stage_tag[0] <= s_tag;
            for (int level = 1; level < LEVELS; level++) begin
                stage_valid[level] <= stage_valid[level-1];
                if (stage_valid[level-1])
                    stage_tag[level] <= stage_tag[level-1];
            end
        end
    end

    // Only the topology repeats. Named generate levels retain a traceable
    // hierarchy; no generated node IDs or opaque scheduler are needed.
    for (genvar level = 0; level <= LEVELS; level++) begin : gen_level
        localparam int NODE_COUNT = (INPUTS + (2**level) - 1) / (2**level);
        wire signed [SUM_WIDTH-1:0] node [0:NODE_COUNT-1];

        if (level == 0) begin : gen_inputs
            for (genvar lane = 0; lane < INPUTS; lane++) begin : gen_lane
                // Cast before addition: widening an already truncated sum
                // cannot recover its sign/carry. Final width is exact for all lanes.
                assign node[lane] = SUM_WIDTH'($signed(s_values[lane]));
            end
        end else begin : gen_registered_level
            localparam int PREVIOUS_COUNT = (INPUTS + (2**(level-1)) - 1) / (2**(level-1));
            for (genvar pair = 0; pair < NODE_COUNT; pair++) begin : gen_pair
                logic signed [SUM_WIDTH-1:0] partial_sum;
                wire incoming_valid;
                if (level == 1) begin : gen_first_valid
                    assign incoming_valid = s_valid;
                end else begin : gen_later_valid
                    assign incoming_valid = stage_valid[level-2];
                end

                if (2*pair+1 < PREVIOUS_COUNT) begin : gen_add
                    always_ff @(posedge clk) begin
                        if (!rst && advance && incoming_valid)
                            partial_sum <= gen_level[level-1].node[2*pair] +
                                           gen_level[level-1].node[2*pair+1];
                    end
                end else begin : gen_unpaired
                    // 奇数尾项也要经过寄存器；直接旁路会让它与另一半错一拍。
                    always_ff @(posedge clk) begin
                        if (!rst && advance && incoming_valid)
                            partial_sum <= gen_level[level-1].node[2*pair];
                    end
                end
                assign node[pair] = partial_sum;
            end
        end
    end
    assign m_sum = gen_level[LEVELS].node[0];
endmodule

`default_nettype wire
