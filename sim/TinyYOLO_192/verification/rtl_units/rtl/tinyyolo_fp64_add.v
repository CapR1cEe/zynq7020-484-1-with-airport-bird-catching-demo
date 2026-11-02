`timescale 1ns/1ps
// Sequential binary64 RNE adder for finite normal numbers and signed zero.
// The head table generator verifies this domain. Underflow, overflow and
// non-finite operands fail explicitly; no flush-to-zero arithmetic is used.
module tinyyolo_fp64_add (
    input wire clk, input wire rst_n, input wire start,
    input wire [63:0] a, input wire [63:0] b,
    output reg done, output reg error, output reg [63:0] result
);
    localparam [3:0] IDLE=0,ORDER=1,ALIGN0=2,ALIGN1=3,ADD=4,
        NORMALIZE=5,ROUND=6,PACK=7,RETURN=8,SELECT=9,NORM_SCAN=10,ADD_JOIN=11,ALIGN2=12,ADD_FINAL=13;
    reg [13:0] state;
    reg [63:0] aa,bb;
    reg [2:0] greater,equal;
    reg operand_bad,a_zero,b_zero;
    wire a_larger=greater[2] || (equal[2] && greater[1]) ||
        (equal[2] && equal[1] && (greater[0] || equal[0]));
    reg sign_big,subtract;
    reg [10:0] exponent,difference;
    reg [55:0] big,mantissa_source;
    wire [55:0] mantissa_small;
    tinyyolo_shift56_jam alignment(.clk(clk),.value(mantissa_source),
        .distance(difference),.result(mantissa_small));
    reg [56:0] magnitude;
    reg [14:0] add_word[0:3];
    reg [2:1] add_propagate;
    wire carry14=add_word[0][14];
    wire carry28=add_word[1][14] || (add_propagate[1] && carry14);
    wire carry42=add_word[2][14] || (add_propagate[2] && carry28);
    reg [2:0] carry_join;
    reg [13:0] join_word[0:2];
    reg [14:0] join_high;
    wire [13:0] joined1=subtract?join_word[1][13:0]-carry_join[0]:join_word[1][13:0]+carry_join[0];
    wire [13:0] joined2=subtract?join_word[2][13:0]-carry_join[1]:join_word[2][13:0]+carry_join[1];
    wire [14:0] joined3=subtract?join_high-carry_join[2]:join_high+carry_join[2];
    reg [53:0] rounded;
    reg norm_zero,norm_carry,norm_ready,norm_small,norm_shift8;
    reg [63:0] result_candidate;
    (* DONT_TOUCH="TRUE" *) reg result_pending;
    wire pack_bad=exponent>=11'd2047 || (exponent==11'd2046 && rounded[53]);
    // Producer decode terminates at a single flag. Clock the private mux
    // unconditionally and publish only in RETURN, alongside DONE, so a wide
    // result CE no longer includes the FSM, zero tests and overflow guards.
    always @(posedge clk)begin
        result_candidate<=state[SELECT]?
            ((a_zero && b_zero)?{aa[63]&bb[63],63'd0}:(a_zero?bb:aa)):
            (norm_zero?64'd0:
             (rounded[53]?{sign_big,exponent+11'd1,rounded[52:1]}:
                          {sign_big,exponent,rounded[51:0]}));
        if(!rst_n)begin result_pending<=1'b0;result<=64'd0;end
        else begin
            result_pending<=(state[SELECT] && !operand_bad && (a_zero || b_zero)) ||
                (state[NORMALIZE] && norm_zero) || (state[PACK] && !pack_bad);
            if(result_pending)result<=result_candidate;
        end
    end
    // Four independent 14-bit add/subtract words. Carry/borrow propagate
    // flags are compared in parallel, then joined on the following cycle.
    genvar word_id;
    generate for(word_id=0;word_id<4;word_id=word_id+1)begin: add_slice
        always @(posedge clk)begin
            add_word[word_id]<=subtract?
                ({1'b0,big[word_id*14+:14]}-{1'b0,mantissa_small[word_id*14+:14]}):
                ({1'b0,big[word_id*14+:14]}+{1'b0,mantissa_small[word_id*14+:14]});
        end
        if(word_id<3)begin: join_low
            always @(posedge clk)join_word[word_id]<=add_word[word_id][13:0];
        end else begin: join_top
            always @(posedge clk)join_high<=add_word[word_id];
        end
        if(word_id==1 || word_id==2)begin: propagate
            always @(posedge clk)
                add_propagate[word_id]<=subtract?
                    big[word_id*14+:14]==mantissa_small[word_id*14+:14]:
                    (&(big[word_id*14+:14]^mantissa_small[word_id*14+:14]));
        end
    end endgenerate
    always @(posedge clk) begin
        if(!rst_n) begin
            state<=14'b1<<IDLE;done<=1'b0;error<=1'b0;
            greater<=0;equal<=0;operand_bad<=0;a_zero<=0;b_zero<=0;
            aa<=0;bb<=0;sign_big<=0;subtract<=0;exponent<=0;
            difference<=0;big<=0;mantissa_source<=0;magnitude<=0;rounded<=0;
            norm_zero<=0;norm_carry<=0;norm_ready<=0;norm_small<=0;norm_shift8<=0;
        end else begin
            done<=1'b0;
            (* parallel_case *) case(1'b1)
                state[IDLE]:if(start) begin aa<=a;bb<=b;error<=0;state<=14'b1<<ORDER;end
                state[ORDER]:begin
                    greater<={aa[62:42]>bb[62:42],aa[41:21]>bb[41:21],aa[20:0]>bb[20:0]};
                    equal<={aa[62:42]==bb[62:42],aa[41:21]==bb[41:21],aa[20:0]==bb[20:0]};
                    operand_bad<=aa[62:52]==11'h7ff || bb[62:52]==11'h7ff ||
                        (aa[62:52]==0 && aa[51:0]!=0) || (bb[62:52]==0 && bb[51:0]!=0);
                    a_zero<=aa[62:0]==0;b_zero<=bb[62:0]==0;state<=14'b1<<SELECT;
                end
                state[SELECT]:begin
                    if(operand_bad) begin error<=1;state<=14'b1<<RETURN;
                    end else if(a_zero && b_zero) begin
                        state<=14'b1<<RETURN;
                    end else if(a_zero) state<=14'b1<<RETURN;
                    else if(b_zero) state<=14'b1<<RETURN;
                    else begin
                        subtract<=aa[63]^bb[63];
                        if(a_larger) begin
                            sign_big<=aa[63];exponent<=aa[62:52];
                            difference<=aa[62:52]-bb[62:52];
                            big<={1'b1,aa[51:0],3'd0};mantissa_source<={1'b1,bb[51:0],3'd0};
                        end else begin
                            sign_big<=bb[63];exponent<=bb[62:52];
                            difference<=bb[62:52]-aa[62:52];
                            big<={1'b1,bb[51:0],3'd0};mantissa_source<={1'b1,aa[51:0],3'd0};
                        end
                        state<=14'b1<<ALIGN0;
                    end
                end
                state[ALIGN0]:state<=14'b1<<ALIGN1;
                state[ALIGN1]:state<=14'b1<<ALIGN2;
                state[ALIGN2]:state<=14'b1<<ADD;
                state[ADD]:state<=14'b1<<ADD_JOIN;
                state[ADD_JOIN]:begin
                    carry_join<={carry42,carry28,carry14};
                    state<=14'b1<<ADD_FINAL;
                end
                state[ADD_FINAL]:begin
                    magnitude<={joined3,joined2,joined1,join_word[0][13:0]};
                    state<=14'b1<<NORM_SCAN;
                end
                state[NORM_SCAN]:begin
                    norm_zero<=magnitude==0;norm_carry<=magnitude[56];
                    norm_ready<=magnitude[55];norm_small<=exponent<=11'd1;
                    norm_shift8<=magnitude[55:48]==0 && exponent>11'd8;
                    state<=14'b1<<NORMALIZE;
                end
                state[NORMALIZE]:begin
                    if(norm_zero)state<=14'b1<<RETURN;
                    else if(norm_carry) begin
                        magnitude<={1'b0,magnitude[56:2],magnitude[1]|magnitude[0]};
                        exponent<=exponent+11'd1;state<=14'b1<<ROUND;
                    end else if(norm_ready) state<=14'b1<<ROUND;
                    else if(norm_small) begin error<=1;state<=14'b1<<RETURN;end
                    else if(norm_shift8) begin
                        magnitude<=magnitude<<8;exponent<=exponent-11'd8;state<=14'b1<<NORM_SCAN;
                    end else begin magnitude<=magnitude<<1;exponent<=exponent-11'd1;state<=14'b1<<NORM_SCAN;end
                end
                state[ROUND]:begin
                    rounded<={1'b0,magnitude[55:3]}+
                        {53'd0,(magnitude[2] && (magnitude[1] || magnitude[0] || magnitude[3]))};
                    state<=14'b1<<PACK;
                end
                state[PACK]:begin
                    if(pack_bad)error<=1;
                    state<=14'b1<<RETURN;
                end
                state[RETURN]:begin done<=1'b1;state<=14'b1<<IDLE;end
                default:begin error<=1;state<=14'b1<<RETURN;end
            endcase
        end
    end
endmodule
