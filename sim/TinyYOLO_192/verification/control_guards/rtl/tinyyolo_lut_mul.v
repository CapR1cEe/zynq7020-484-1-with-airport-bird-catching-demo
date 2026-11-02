`timescale 1ns/1ps
// Seven-clock unsigned LUT multiplier for stable setup dimensions.
// Register one-bit AND rows, then one addition per balanced tree stage.
// Explicit widths keep every carry chain shorter than a full 43-bit sum.
module tinyyolo_lut_mul #(parameter AW=18,BW=11)(
    input wire clk,rst_n,input wire [AW-1:0] a,input wire [BW-1:0] b,
    output reg [42:0] product
);
    (* DONT_TOUCH="TRUE" *) reg [AW-1:0] operand_a;
    (* DONT_TOUCH="TRUE" *) reg [BW-1:0] operand_b;
    wire [31:0] padded_a={{(32-AW){1'b0}},operand_a};
    (* use_dsp="no", EXTRACT_RESET="NO" *) reg [BW-1:0] row[0:31];
    (* use_dsp="no" *) reg [BW+1:0] pair_sum[0:15];
    (* use_dsp="no" *) reg [BW+3:0] quad_sum[0:7];
    (* use_dsp="no" *) reg [BW+7:0] oct_sum[0:3];
    (* use_dsp="no" *) reg [BW+15:0] half_sum[0:1];
    integer i;
    always @(posedge clk)begin
        operand_a<=a;operand_b<=b;
        for(i=0;i<32;i=i+1)row[i]<=operand_b & {BW{padded_a[i]}};
        for(i=0;i<16;i=i+1)
            pair_sum[i]<={2'd0,row[2*i]}+{1'd0,row[2*i+1],1'd0};
        for(i=0;i<8;i=i+1)
            quad_sum[i]<={2'd0,pair_sum[2*i]}+{pair_sum[2*i+1],2'd0};
        for(i=0;i<4;i=i+1)
            oct_sum[i]<={4'd0,quad_sum[2*i]}+{quad_sum[2*i+1],4'd0};
        for(i=0;i<2;i=i+1)
            half_sum[i]<={8'd0,oct_sum[2*i]}+{oct_sum[2*i+1],8'd0};
        product<=!rst_n?43'd0:
            ({{(27-BW){1'b0}},half_sum[0]}+{half_sum[1],16'd0});
    end
endmodule
