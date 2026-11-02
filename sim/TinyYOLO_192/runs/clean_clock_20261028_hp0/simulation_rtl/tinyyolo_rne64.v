`timescale 1ns/1ps
// Exact INT32 * UINT64 RNE with all 96 bits retained. Eight unsigned 16x16
// partial products use the physical DSP MREG/PREG registers. Overlap carries
// and quotient shifts have separate stages; all 96 bits survive assembly.
// Legal shift remains 1..62 (checked by control).
module tinyyolo_rne64 (
    input wire clk, input wire rst_n, input wire start,
    input wire signed [31:0] accumulator, input wire [63:0] multiplier,
    input wire [5:0] shift, input wire signed [7:0] zero_point,
    output reg done, output reg signed [7:0] result
);
    localparam [4:0] IDLE=0,MUL0=1,MUL1=2,CHUNKS=3,HALVES=4,
        PRODUCT=5,ROUND=6,INC=7,CLAMP=8,MUL2=9,OUTPUT=10,COMPARE=11,PRODUCT_JOIN=12,ROUND0=13,
        MAGNITUDE=14,HALVES_JOIN=15,CHUNKS_JOIN=16,HALVES_SUM=17,PRODUCT_SUM=18,CHUNKS_SUM=19;
    reg [19:0] state;
    reg [31:0] magnitude_reg;
    reg [16:0] magnitude_low;
    reg [15:0] magnitude_high;
    reg [63:0] multiplier_reg;
    wire signed [42:0] partial[0:7];
    reg [47:0] chunk[0:3];
    reg [15:0] chunk_bottom[0:3],chunk_top[0:3];
    reg [16:0] chunk_middle[0:3];
    reg [8:0] chunk_middle_low[0:3],chunk_middle_high[0:3];
    reg [8:0] chunk_top_low_increment[0:3];
    reg [7:0] chunk_top_high_increment[0:3];
    reg [63:0] product_lo,product_hi;
    reg [15:0] half_bottom[0:1],half_top[0:1];
    reg [16:0] half_middle_low[0:1],half_middle_high[0:1];
    reg [32:0] half_middle[0:1];
    reg [31:0] product_bottom,product_top;
    reg [16:0] product_middle_low,product_middle_high,product_top_low_increment;
    reg [15:0] product_top_high_increment;
    reg [31:0] product_top_increment;
    reg [32:0] product_middle;
    reg [95:0] product,quotient_shift_low,quotient,remainder,half;
    reg [5:0] amount;
    reg negative;
    reg signed [8:0] zp;
    reg round_up;
    // The original 96-bit compare inferred a long carry chain. Compare six
    // independent 16-bit words, then combine their registered lexicographic
    // results. Retain every bit and exact round-to-nearest-even behavior.
    reg [5:0] remainder_greater,remainder_equal;
    wire remainder_above_half=remainder_greater[5] ||
        (remainder_equal[5] && remainder_greater[4]) ||
        ((&remainder_equal[5:4]) && remainder_greater[3]) ||
        ((&remainder_equal[5:3]) && remainder_greater[2]) ||
        ((&remainder_equal[5:2]) && remainder_greater[1]) ||
        ((&remainder_equal[5:1]) && remainder_greater[0]);
    wire [8:0] positive_limit=9'd127-zp;
    wire [8:0] negative_limit=9'd128+zp;
    reg [7:0] clamp_limit,clamp_base;
    reg [7:0] clamp_positive,clamp_negative;
    reg quotient_above_limit,quotient_at_limit;
    reg large_quotient,clamp_large;
    reg [7:0] clamp_value;
    genvar row,col;
    generate for(row=0;row<4;row=row+1) begin: multiplier_chunk
        for(col=0;col<2;col=col+1) begin: magnitude_chunk
            // A private synchronous reset terminates the island-wide reset
            // before the DSP column. Operands are captured in IDLE, so the
            // first useful DSP input arrives after this reset has released.
            (* DONT_TOUCH="TRUE" *) reg dsp_reset;
            always @(posedge clk) dsp_reset<=!rst_n;
            tinyyolo_dsp_mul #(.INPUT_REG(1)) mul(.clk(clk),.rst_n(!dsp_reset),
                .a({9'd0,magnitude_reg[col*16+:16]}),
                .b({2'd0,multiplier_reg[row*16+:16]}),.product(partial[row*2+col]));
        end
    end endgenerate
    integer i;
    // Private arithmetic stages need no reset: the FSM writes each stage
    // before consuming it. Keeping reset off their clock enables removes a
    // long broadcast path without changing DONE/RESULT reset behavior.
    always @(posedge clk) begin
        (* parallel_case *) case(1'b1)
                state[IDLE]:begin
                    // Two local 16-bit words keep the absolute-value carry
                    // off the result-lane to DSP-operand timing boundary.
                    magnitude_low<={1'b0,(accumulator[15:0]^{16{accumulator[31]}})}+
                        {16'd0,accumulator[31]};
                    magnitude_high<=accumulator[31:16]^{16{accumulator[31]}};
                    multiplier_reg<=multiplier;
                    amount<=shift;negative<=accumulator[31];
                    zp<={zero_point[7],zero_point};
                end
                state[MAGNITUDE]:begin
                    magnitude_reg<={magnitude_high+{15'd0,magnitude_low[16]},magnitude_low[15:0]};
                end
                state[MUL0]:begin
                    clamp_limit<=negative?negative_limit[7:0]:positive_limit[7:0];
                end
                state[CHUNKS]:begin
                    for(i=0;i<4;i=i+1)begin
                        chunk_bottom[i]<=partial[2*i][15:0];
                        // Only eight-bit sums follow the DSP P outputs.
                        // Merge their carry on a separate fabric clock.
                        chunk_middle_low[i]<={1'b0,partial[2*i][23:16]}+
                                             {1'b0,partial[2*i+1][7:0]};
                        chunk_middle_high[i]<={1'b0,partial[2*i][31:24]}+
                                              {1'b0,partial[2*i+1][15:8]};
                        chunk_top[i]<=partial[2*i+1][31:16];
                    end
                end
                state[CHUNKS_SUM]:begin
                    for(i=0;i<4;i=i+1)begin
                        chunk_middle[i]<={chunk_middle_high[i]+{8'd0,chunk_middle_low[i][8]},
                                          chunk_middle_low[i][7:0]};
                        // Prepare both halves of top+1 independently of the
                        // middle carry. JOIN then uses only small selectors.
                        chunk_top_low_increment[i]<={1'b0,chunk_top[i][7:0]}+9'd1;
                        chunk_top_high_increment[i]<=chunk_top[i][15:8]+8'd1;
                    end
                end
                state[CHUNKS_JOIN]:begin
                    for(i=0;i<4;i=i+1)begin
                        chunk[i][47:40]<=chunk_middle[i][16] && chunk_top_low_increment[i][8]?
                            chunk_top_high_increment[i]:chunk_top[i][15:8];
                        chunk[i][39:32]<=chunk_middle[i][16]?
                            chunk_top_low_increment[i][7:0]:chunk_top[i][7:0];
                        chunk[i][31:0]<={chunk_middle[i][15:0],chunk_bottom[i]};
                    end
                end
                state[HALVES]:begin
                    for(i=0;i<2;i=i+1)begin
                        half_bottom[i]<=chunk[2*i][15:0];
                        half_middle_low[i]<={1'b0,chunk[2*i][31:16]}+{1'b0,chunk[2*i+1][15:0]};
                        half_middle_high[i]<={1'b0,chunk[2*i][47:32]}+{1'b0,chunk[2*i+1][31:16]};
                        half_top[i]<=chunk[2*i+1][47:32];
                    end
                end
                state[HALVES_SUM]:begin
                    for(i=0;i<2;i=i+1)
                        half_middle[i]<={half_middle_high[i]+{16'd0,half_middle_low[i][16]},
                                         half_middle_low[i][15:0]};
                end
                state[HALVES_JOIN]:begin
                    product_lo<={half_top[0]+{15'd0,half_middle[0][32]},half_middle[0][31:0],half_bottom[0]};
                    product_hi<={half_top[1]+{15'd0,half_middle[1][32]},half_middle[1][31:0],half_bottom[1]};
                end
                state[PRODUCT]:begin
                    // The low word has no overlap. Register independent
                    // 16-bit overlap sums and both halves of top+1. The
                    // next clock joins only local carries; no 32-bit adder
                    // remains on the product overlap or final high word.
                    product_bottom<=product_lo[31:0];
                    product_middle_low<={1'b0,product_hi[15:0]}+{1'b0,product_lo[47:32]};
                    product_middle_high<={1'b0,product_hi[31:16]}+{1'b0,product_lo[63:48]};
                    product_top<=product_hi[63:32];
                    product_top_low_increment<={1'b0,product_hi[47:32]}+17'd1;
                    product_top_high_increment<=product_hi[63:48]+16'd1;
                end
                state[PRODUCT_SUM]:begin
                    product_middle<={product_middle_high+{16'd0,product_middle_low[16]},
                                     product_middle_low[15:0]};
                    product_top_increment<={product_top_low_increment[16]?
                        product_top_high_increment:product_top[31:16],product_top_low_increment[15:0]};
                end
                state[PRODUCT_JOIN]:begin
                    product<={product_middle[32]?product_top_increment:product_top,
                              product_middle[31:0],product_bottom};
                end
                state[ROUND0]:quotient_shift_low<=product>>amount[2:0];
                state[ROUND]:begin
                    quotient<=quotient_shift_low>>{amount[5:3],3'd0};
                    // A shifted all-ones mask avoids a 96-bit subtract chain.
                    remainder<=product&~({96{1'b1}}<<amount);
                    half<=96'd1<<(amount-6'd1);
                end
                state[COMPARE]:begin
                    // Quotient was registered in ROUND. Prepare both byte
                    // branches here; INC only selects the signed result.
                    clamp_positive<=zp[7:0]+quotient[7:0];
                    clamp_negative<=zp[7:0]-quotient[7:0];
                    for(i=0;i<6;i=i+1)begin
                        remainder_greater[i]<=remainder[i*16+:16]>half[i*16+:16];
                        remainder_equal[i]<=remainder[i*16+:16]==half[i*16+:16];
                    end
                end
                state[INC]:begin
                    large_quotient<=|quotient[95:8];
                    round_up<=remainder_above_half || ((&remainder_equal) && quotient[0]);
                    // Compare the unrounded byte in parallel with the RNE
                    // decision. CLAMP no longer adds then compares serially.
                    quotient_above_limit<=quotient[7:0]>clamp_limit;
                    quotient_at_limit<=quotient[7:0]==clamp_limit;
                    clamp_base<=negative?clamp_negative:clamp_positive;
                end
                state[CLAMP]:begin
                    clamp_large<=large_quotient || quotient_above_limit || (quotient_at_limit && round_up);
                    clamp_value<=negative?clamp_base-{7'd0,round_up}:clamp_base+{7'd0,round_up};
                end
                default:begin end
        endcase
    end
    always @(posedge clk) begin
        if(!rst_n)begin state<=20'b1<<IDLE;done<=1'b0;result<=8'sd0;end
        else begin
            done<=1'b0;
            (* parallel_case *) case(1'b1)
                state[IDLE]:if(start)state<=20'b1<<MAGNITUDE;
                state[MAGNITUDE]:state<=20'b1<<MUL0;
                state[MUL0]:state<=20'b1<<MUL1;
                state[MUL1]:state<=20'b1<<MUL2;
                state[MUL2]:state<=20'b1<<CHUNKS;
                state[CHUNKS]:state<=20'b1<<CHUNKS_SUM;
                state[CHUNKS_SUM]:state<=20'b1<<CHUNKS_JOIN;
                state[CHUNKS_JOIN]:state<=20'b1<<HALVES;
                state[HALVES]:state<=20'b1<<HALVES_SUM;
                state[HALVES_SUM]:state<=20'b1<<HALVES_JOIN;
                state[HALVES_JOIN]:state<=20'b1<<PRODUCT;
                state[PRODUCT]:state<=20'b1<<PRODUCT_SUM;
                state[PRODUCT_SUM]:state<=20'b1<<PRODUCT_JOIN;
                state[PRODUCT_JOIN]:state<=20'b1<<ROUND0;
                state[ROUND0]:state<=20'b1<<ROUND;
                state[ROUND]:state<=20'b1<<COMPARE;
                state[COMPARE]:state<=20'b1<<INC;
                state[INC]:state<=20'b1<<CLAMP;
                state[CLAMP]:state<=20'b1<<OUTPUT;
                state[OUTPUT]:begin
                    result<=clamp_large?(negative?8'h80:8'sd127):clamp_value;
                    done<=1'b1;state<=20'b1<<IDLE;
                end
                default:state<=20'b1<<IDLE;
            endcase
        end
    end
endmodule
