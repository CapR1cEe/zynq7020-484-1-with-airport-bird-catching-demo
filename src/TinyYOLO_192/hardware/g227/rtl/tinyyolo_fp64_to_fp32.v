`timescale 1ns/1ps
// Exact RNE binary64 -> binary32 conversion, including gradual underflow.
module tinyyolo_fp64_to_fp32 (
    input wire clk,input wire rst_n,input wire start,input wire [63:0] value,
    output reg done,output reg error,output reg [31:0] result
);
    localparam IDLE=0,PREPARE=1,ALIGN0=2,ALIGN1=3,ALIGN2=4,
        ROUND=5,PACK=6,RETURN=7;
    reg [7:0] state;
    reg sign_bit;
    reg [10:0] exponent,distance;
    reg [55:0] significand_source;
    wire [27:0] significand;
    reg [24:0] rounded;
    reg [7:0] target_exponent;
    tinyyolo_shift56_jam #(.RESULT_WIDTH(28)) alignment(.clk(clk),.value(significand_source),
        .distance(distance),.result(significand));
    // Private data is overwritten before use. No reset or START qualification
    // is needed on the wide operand registers; the one-hot FSM owns validity.
    always @(posedge clk) begin
        (* parallel_case *) case(1'b1)
            state[IDLE]:begin
                sign_bit<=value[63];exponent<=value[62:52];
                significand_source<={value[62:52]!=0,value[51:0],3'd0};
            end
            state[PREPARE]:begin
                distance<=exponent>=11'd897 ?11'd29:11'd926-exponent;
                target_exponent<=exponent>=11'd897 ?exponent-11'd896:8'd0;
            end
            state[ROUND]:rounded<=significand[27:3]+
                {24'd0,(significand[2] && (significand[1] || significand[0] || significand[3]))};
            default:begin end
        endcase
    end
    always @(posedge clk) begin
        if(!rst_n) begin
            state<=8'b1<<IDLE;done<=0;error<=0;result<=0;
        end else begin
            done<=0;
            (* parallel_case *) case(1'b1)
                state[IDLE]:if(start) begin
                    error<=value[62:52]==11'h7ff;state<=8'b1<<PREPARE;
                end
                state[PREPARE]:begin
                    if(exponent>11'd1150) begin
                        result<={sign_bit,8'hff,23'd0};error<=1;state<=8'b1<<RETURN;
                    end else state<=8'b1<<ALIGN0;
                end
                state[ALIGN0]:state<=8'b1<<ALIGN1;
                state[ALIGN1]:state<=8'b1<<ALIGN2;
                state[ALIGN2]:state<=8'b1<<ROUND;
                state[ROUND]:state<=8'b1<<PACK;
                state[PACK]:begin
                    if(target_exponent==0) result<={sign_bit,7'd0,rounded[23:0]};
                    else if(rounded[24]) begin
                        result<={sign_bit,target_exponent+8'd1,rounded[23:1]};
                        if(target_exponent==8'd254) error<=1;
                    end else result<={sign_bit,target_exponent,rounded[22:0]};
                    state<=8'b1<<RETURN;
                end
                state[RETURN]:begin done<=1;state<=8'b1<<IDLE;end
                default:begin error<=1;state<=8'b1<<RETURN;end
            endcase
        end
    end
endmodule
