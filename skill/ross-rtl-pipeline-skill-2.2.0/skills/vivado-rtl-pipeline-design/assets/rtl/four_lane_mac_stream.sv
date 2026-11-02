`timescale 1ns/1ps
`default_nettype none

// Contract: four signed products per token, exact sum, three capture stages.
// s_valid/s_ready accept one tagged input; reset flushes all pending outputs.
// 默认8位乘法不强制DSP映射；资源以综合报告为准。
module four_lane_mac_stream #(
    parameter int DATA_WIDTH = 8,
    parameter int TAG_WIDTH  = 8
) (
    input  wire logic clk,
    input  wire logic rst,

    input  wire logic s_valid,
    output logic s_ready,
    input  wire logic signed [DATA_WIDTH-1:0] a0,
    input  wire logic signed [DATA_WIDTH-1:0] b0,
    input  wire logic signed [DATA_WIDTH-1:0] a1,
    input  wire logic signed [DATA_WIDTH-1:0] b1,
    input  wire logic signed [DATA_WIDTH-1:0] a2,
    input  wire logic signed [DATA_WIDTH-1:0] b2,
    input  wire logic signed [DATA_WIDTH-1:0] a3,
    input  wire logic signed [DATA_WIDTH-1:0] b3,
    input  wire logic [TAG_WIDTH-1:0] s_tag,

    output logic m_valid,
    input  wire logic m_ready,
    output logic signed [(2 * DATA_WIDTH + 2)-1:0] m_sum,
    output logic [TAG_WIDTH-1:0] m_tag
);

    localparam int PRODUCT_WIDTH = 2 * DATA_WIDTH;
    localparam int PAIR_WIDTH = PRODUCT_WIDTH + 1;
    localparam int SUM_WIDTH = PRODUCT_WIDTH + 2;

    // Three capture stages. Short combinational ready chain; buffer long chains.
    logic valid_product;
    logic signed [PRODUCT_WIDTH-1:0] product0_s1, product1_s1;
    logic signed [PRODUCT_WIDTH-1:0] product2_s1, product3_s1;
    logic [TAG_WIDTH-1:0] tag_s1;

    logic valid_pair;
    logic signed [PAIR_WIDTH-1:0] pair0_s2, pair1_s2;
    logic [TAG_WIDTH-1:0] tag_s2;

    logic valid_sum;
    logic signed [SUM_WIDTH-1:0] sum_s3;
    logic [TAG_WIDTH-1:0] tag_s3;

    logic ready_product;
    logic ready_pair;
    logic ready_sum;

    assign ready_sum     = !valid_sum || m_ready;
    // Empty stages may fill while a later stage stalls. Data and tag use these
    // same enables; advancing only valid would silently mix different tokens.
    assign ready_pair    = !valid_pair || ready_sum;
    assign ready_product = !valid_product || ready_pair;
    assign s_ready       = !rst && ready_product;

    assign m_valid = valid_sum;
    assign m_sum   = sum_s3;
    assign m_tag   = tag_s3;

    always_ff @(posedge clk) begin
        if (rst) begin
            // Payload is unobservable while invalid; avoid a wide reset tree.
            valid_product <= 1'b0;
            valid_pair    <= 1'b0;
            valid_sum     <= 1'b0;
        end else begin
            if (ready_sum) begin
                valid_sum <= valid_pair;
                if (valid_pair) begin
                    // Extend each signed pair before adding: 17 + 17 -> 18 bits
                    // in the default configuration, including (-128)*(-128).
                    sum_s3 <= {pair0_s2[PAIR_WIDTH-1], pair0_s2} +
                              {pair1_s2[PAIR_WIDTH-1], pair1_s2};
                    tag_s3 <= tag_s2;
                end
            end

            if (ready_pair) begin
                valid_pair <= valid_product;
                if (valid_product) begin
                    pair0_s2 <= {product0_s1[PRODUCT_WIDTH-1], product0_s1} +
                                {product1_s1[PRODUCT_WIDTH-1], product1_s1};
                    pair1_s2 <= {product2_s1[PRODUCT_WIDTH-1], product2_s1} +
                                {product3_s1[PRODUCT_WIDTH-1], product3_s1};
                    tag_s2 <= tag_s1;
                end
            end

            if (ready_product) begin
                valid_product <= s_valid;
                if (s_valid) begin
                    product0_s1 <= a0 * b0;
                    product1_s1 <= a1 * b1;
                    product2_s1 <= a2 * b2;
                    product3_s1 <= a3 * b3;
                    tag_s1 <= s_tag;
                end
            end
        end
    end

endmodule

`default_nettype wire
