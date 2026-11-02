`timescale 1ns/1ps

// Two signed INT8 dot products share an activation vector and packed DSPs.
// Every reduction uses a two-clock split adder; VALID/LAST have the same
// 13-clock delay. The pipe accepts a new vector on every clock.
module tinyyolo_dot16_pair (
    input wire clk,rst_n,valid,last,
    input wire [127:0] a,w0,w1,
    output wire out_valid,out_last,
    output wire signed [19:0] sum0,sum1
);
    wire signed [42:0] product[0:15];
    reg signed [15:0] p0[0:15],p1[0:15];
    reg [12:0] v,l;
    wire signed [16:0] s10[0:7];
    wire signed [16:0] s11[0:7];
    wire signed [17:0] s20[0:3];
    wire signed [17:0] s21[0:3];
    wire signed [18:0] s30[0:1];
    wire signed [18:0] s31[0:1];
    wire signed [19:0] s40[0:0];
    wire signed [19:0] s41[0:0];
    genvar lane;
    generate for(lane=0;lane<16;lane=lane+1)begin: mul_lane
        wire signed [8:0] upper=$signed({w1[lane*8+7],w1[lane*8+:8]})-
            $signed({8'd0,w0[lane*8+7]});
        wire signed [24:0] packed_weight={upper,{8{w0[lane*8+7]}},w0[lane*8+:8]};
        reg signed [24:0] packed_q;
        reg signed [17:0] activation_q;
        // Weight/activation packing gives the reset one local clock to
        // release before the first useful DSP operand is sampled.
        (* DONT_TOUCH="TRUE" *) reg dsp_reset;
        always @(posedge clk)begin
            dsp_reset<=!rst_n;
            packed_q<=packed_weight;
            activation_q<={{10{a[lane*8+7]}},a[lane*8+:8]};
        end
        tinyyolo_dsp_mul #(.INPUT_REG(1)) mul(.clk(clk),.rst_n(!dsp_reset),
            .a(packed_q),.b(activation_q),.product(product[lane]));
        always @(posedge clk)begin
            p0[lane]<=product[lane][15:0];
            p1[lane]<=product[lane][31:16]+{15'd0,product[lane][15]};
        end
    end endgenerate
    genvar level1;
    generate for(level1=0;level1<8;level1=level1+1) begin: tree_level1
        tinyyolo_pipe_add #(.WIDTH(17)) add0 (
            .clk(clk),
            .a({p0[2*level1][15],p0[2*level1]}),
            .b({p0[2*level1+1][15],p0[2*level1+1]}),
            .y(s10[level1]));
        tinyyolo_pipe_add #(.WIDTH(17)) add1 (
            .clk(clk),
            .a({p1[2*level1][15],p1[2*level1]}),
            .b({p1[2*level1+1][15],p1[2*level1+1]}),
            .y(s11[level1]));
    end endgenerate
    genvar level2;
    generate for(level2=0;level2<4;level2=level2+1) begin: tree_level2
        tinyyolo_pipe_add #(.WIDTH(18)) add0 (
            .clk(clk),
            .a({s10[2*level2][16],s10[2*level2]}),
            .b({s10[2*level2+1][16],s10[2*level2+1]}),
            .y(s20[level2]));
        tinyyolo_pipe_add #(.WIDTH(18)) add1 (
            .clk(clk),
            .a({s11[2*level2][16],s11[2*level2]}),
            .b({s11[2*level2+1][16],s11[2*level2+1]}),
            .y(s21[level2]));
    end endgenerate
    genvar level3;
    generate for(level3=0;level3<2;level3=level3+1) begin: tree_level3
        tinyyolo_pipe_add #(.WIDTH(19)) add0 (
            .clk(clk),
            .a({s20[2*level3][17],s20[2*level3]}),
            .b({s20[2*level3+1][17],s20[2*level3+1]}),
            .y(s30[level3]));
        tinyyolo_pipe_add #(.WIDTH(19)) add1 (
            .clk(clk),
            .a({s21[2*level3][17],s21[2*level3]}),
            .b({s21[2*level3+1][17],s21[2*level3+1]}),
            .y(s31[level3]));
    end endgenerate
    genvar level4;
    generate for(level4=0;level4<1;level4=level4+1) begin: tree_level4
        tinyyolo_pipe_add #(.WIDTH(20)) add0 (
            .clk(clk),
            .a({s30[2*level4][18],s30[2*level4]}),
            .b({s30[2*level4+1][18],s30[2*level4+1]}),
            .y(s40[level4]));
        tinyyolo_pipe_add #(.WIDTH(20)) add1 (
            .clk(clk),
            .a({s31[2*level4][18],s31[2*level4]}),
            .b({s31[2*level4+1][18],s31[2*level4+1]}),
            .y(s41[level4]));
    end endgenerate
    assign sum0=s40[0];
    assign sum1=s41[0];
    assign out_valid=v[12];
    assign out_last=l[12];
    always @(posedge clk) begin
        if(!rst_n) begin v<=0;l<=0;end
        else begin
            v<={v[11:0],valid};
            l<={l[11:0],last};
        end
    end
endmodule
