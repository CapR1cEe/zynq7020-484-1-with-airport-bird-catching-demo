`timescale 1ns/1ps
// Exact INT32 x UINT36 round-to-nearest-even. Four DSP48E1 multipliers,
// fourteen clocks from IN_VALID to OUT_VALID, initiation interval one.
// Coefficients are unsigned; SHIFT is 1..62. A caller must validate these
// model bounds before launch. Private datapath registers are overwritten
// before their valid token; reset flushes every token and tag atomically.
module tinyyolo_requant36_stream #(
    parameter TAG_BITS=4
) (
    input wire clk, input wire rst_n, input wire in_valid,
    input wire signed [31:0] accumulator,
    input wire [35:0] multiplier,
    input wire [5:0] shift,
    input wire signed [7:0] zero_point,
    input wire [TAG_BITS-1:0] in_tag,
    output wire out_valid,
    output reg signed [7:0] result,
    output wire [TAG_BITS-1:0] out_tag
);
    reg [13:0] valid_pipe;
    reg [13:0] negative_pipe;
    reg [5:0] shift_pipe[0:10];
    reg signed [7:0] zp_pipe[0:11];
    reg [TAG_BITS-1:0] tag_pipe[0:13];
    reg [16:0] magnitude_low;
    reg [15:0] magnitude_high;
    reg [31:0] magnitude;
    reg [35:0] multiplier0,multiplier1;
    wire signed [42:0] partial[0:3];
    reg [15:0] row_bottom[0:1],row_top[0:1];
    reg [18:0] row_middle[0:1];
    reg [49:0] row_product[0:1];
    reg [17:0] product_bottom,product_top,product_bottom1,product_top1;
    reg [16:0] middle_low,middle_high,middle_join;
    reg [15:0] product_middle_bottom;
    reg [67:0] product,shift_low,quotient,remainder,half;
    reg [3:0] remainder_gt,remainder_eq;
    wire above_half=remainder_gt[3] ||
        (remainder_eq[3] && remainder_gt[2]) ||
        ((&remainder_eq[3:2]) && remainder_gt[1]) ||
        ((&remainder_eq[3:1]) && remainder_gt[0]);
    wire signed [8:0] signed_zp={zp_pipe[11][7],zp_pipe[11]};
    wire [8:0] positive_limit=9'sd127-signed_zp;
    wire [8:0] negative_limit=9'sd128+signed_zp;
    wire [7:0] limit=negative_pipe[11]?negative_limit[7:0]:positive_limit[7:0];
    reg large_quotient,above_limit,at_limit,round_up;
    reg [7:0] result_base;
    genvar row,col;
    generate for(row=0;row<2;row=row+1)begin: coefficient_half
        for(col=0;col<2;col=col+1)begin: magnitude_half
            (* DONT_TOUCH="TRUE" *) reg dsp_reset;
            always @(posedge clk) dsp_reset<=!rst_n;
            tinyyolo_dsp_mul #(.INPUT_REG(1)) mul(
                .clk(clk),.rst_n(!dsp_reset),
                .a({7'd0,multiplier1[row*18+:18]}),
                .b({2'd0,magnitude[col*16+:16]}),
                .product(partial[row*2+col]));
        end
    end endgenerate
    assign out_valid=valid_pipe[13];
    assign out_tag=tag_pipe[13];
    integer i;
    always @(posedge clk)begin
        if(!rst_n)begin valid_pipe<=0;negative_pipe<=0;end
        else begin
            valid_pipe<={valid_pipe[12:0],in_valid};
            negative_pipe<={negative_pipe[12:0],accumulator[31]};
        end
        tag_pipe[0]<=in_tag;
        for(i=1;i<14;i=i+1)tag_pipe[i]<=tag_pipe[i-1];
        shift_pipe[0]<=shift;zp_pipe[0]<=zero_point;
        for(i=1;i<12;i=i+1)begin
            if(i<11)shift_pipe[i]<=shift_pipe[i-1];zp_pipe[i]<=zp_pipe[i-1];
        end
        // S0/S1: absolute value includes INT32_MIN without signed overflow.
        magnitude_low<={1'b0,accumulator[15:0]^{16{accumulator[31]}}}+
            {16'd0,accumulator[31]};
        magnitude_high<=accumulator[31:16]^{16{accumulator[31]}};
        multiplier0<=multiplier;multiplier1<=multiplier0;
        magnitude<={magnitude_high+{15'd0,magnitude_low[16]},magnitude_low[15:0]};
        // S2..S4 live in the physical DSP input, multiply and output registers.
        // S5/S6: assemble two exact unsigned 32x18 products.
        for(i=0;i<2;i=i+1)begin
            row_bottom[i]<=partial[2*i][15:0];
            row_middle[i]<={1'b0,partial[2*i][33:16]}+
                {1'b0,partial[2*i+1][17:0]};
            row_top[i]<=partial[2*i+1][33:18];
            row_product[i]<={row_top[i]+{15'd0,row_middle[i][18]},
                row_middle[i][17:0],row_bottom[i]};
        end
        // S7..S9: split the 32-bit overlap into independent sixteen-bit sums.
        product_bottom<=row_product[0][17:0];
        product_top<=row_product[1][49:32];
        middle_low<={1'b0,row_product[0][33:18]}+{1'b0,row_product[1][15:0]};
        middle_high<={1'b0,row_product[0][49:34]}+{1'b0,row_product[1][31:16]};
        middle_join<=middle_high+{16'd0,middle_low[16]};
        product_middle_bottom<=middle_low[15:0];
        // Low/top words need a second register to match the carry join.
        product_bottom1<=product_bottom;product_top1<=product_top;
        product<={product_top1+{17'd0,middle_join[16]},middle_join[15:0],
            product_middle_bottom,product_bottom1};
        // S10/S11: two barrel-shift stages and short, parallel comparisons.
        shift_low<=product>>shift_pipe[9][2:0];
        remainder<=product & ~({68{1'b1}}<<shift_pipe[9]);
        half<=68'd1<<(shift_pipe[9]-6'd1);
        quotient<=shift_low>>{shift_pipe[10][5:3],3'd0};
        for(i=0;i<4;i=i+1)begin
            remainder_gt[i]<=remainder[i*17+:17]>half[i*17+:17];
            remainder_eq[i]<=remainder[i*17+:17]==half[i*17+:17];
        end
        // S12/S13: rounding and saturation retain all discarded product bits.
        large_quotient<=|quotient[67:8];
        above_limit<=quotient[7:0]>limit;at_limit<=quotient[7:0]==limit;
        round_up<=above_half || ((&remainder_eq) && quotient[0]);
        result_base<=negative_pipe[11]?zp_pipe[11]-quotient[7:0]:
            zp_pipe[11]+quotient[7:0];
        result<=large_quotient || above_limit || (at_limit && round_up)?
            (negative_pipe[12]?8'h80:8'h7f):
            (negative_pipe[12]?result_base-{7'd0,round_up}:result_base+{7'd0,round_up});
    end
endmodule
