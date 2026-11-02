`timescale 1ns/1ps

// Two signed INT8 dot products share an activation vector and packed DSPs.
// Every reduction uses a two-clock split adder; VALID/LAST have the same
// 15-clock delay. The pipe accepts a new vector on every clock.
module tinyyolo_dot24_pair (
    input wire clk,rst_n,valid,last,
    input wire [191:0] a,w0,w1,
    output wire out_valid,out_last,
    output wire signed [20:0] sum0,sum1
);
    wire signed [42:0] product[0:23];
    reg signed [15:0] p0[0:23],p1[0:23];
    reg [14:0] v,l;
    wire signed [16:0] s10[0:11];
    wire signed [16:0] s11[0:11];
    wire signed [17:0] s20[0:5];
    wire signed [17:0] s21[0:5];
    wire signed [18:0] s30[0:2];
    wire signed [18:0] s31[0:2];
    wire signed [19:0] s40[0:1];
    wire signed [19:0] s41[0:1];
    wire signed [20:0] s50[0:0];
    wire signed [20:0] s51[0:0];
    genvar lane;
    generate for(lane=0;lane<24;lane=lane+1)begin: mul_lane
        wire signed [8:0] upper=$signed({w1[lane*8+7],w1[lane*8+:8]})-
            $signed({8'd0,w0[lane*8+7]});
        wire signed [24:0] packed_weight={upper,{8{w0[lane*8+7]}},w0[lane*8+:8]};
        reg signed [24:0] packed_q;
        // Preserve a byte register beside each physical DSP. Sharing these
        // identical registers across eight compute islands creates a long
        // route to the hard DSP B inputs at 240 MHz.
        (* DONT_TOUCH="TRUE" *) reg signed [7:0] activation_q;
        // Weight/activation packing gives the reset one local clock to
        // release before the first useful DSP operand is sampled.
        (* DONT_TOUCH="TRUE" *) reg dsp_reset;
        always @(posedge clk)begin
            dsp_reset<=!rst_n;
            packed_q<=packed_weight;
            activation_q<=a[lane*8+:8];
        end
        tinyyolo_dsp_mul #(.INPUT_REG(1)) mul(.clk(clk),.rst_n(!dsp_reset),
            .a(packed_q),.b({{10{activation_q[7]}},activation_q}),.product(product[lane]));
        always @(posedge clk)begin
            p0[lane]<=product[lane][15:0];
            p1[lane]<=product[lane][31:16]+{15'd0,product[lane][15]};
        end
    end endgenerate
    genvar level1;
    generate for(level1=0;level1<12;level1=level1+1) begin: tree_level1
        tinyyolo_pipe_add #(.WIDTH(17)) add0 (
            .clk(clk),
            .a({p0[2*level1][15],p0[2*level1]}),
            .b({p0[2*level1+1][15],p0[2*level1+1]}),
            .y(s10[level1]));
        // Eight low sum/carry bits fit two CARRY4s. Keep the same two-clock
        // adder latency while reducing the product-to-low-carry path.
        tinyyolo_pipe_add #(.WIDTH(17), .LOW_WIDTH(7)) add1 (
            .clk(clk),
            .a({p1[2*level1][15],p1[2*level1]}),
            .b({p1[2*level1+1][15],p1[2*level1+1]}),
            .y(s11[level1]));
    end endgenerate
    genvar level2;
    generate for(level2=0;level2<6;level2=level2+1) begin: tree_level2
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
    generate for(level3=0;level3<3;level3=level3+1) begin: tree_level3
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
    // Match the two clocks in the sibling reduction branch.
    (* SHREG_EXTRACT="NO" *) reg signed [19:0] bypass40_q,bypass40_qq;
    always @(posedge clk) begin
        bypass40_q <= {s30[2][18],s30[2]};
        bypass40_qq <= bypass40_q;
    end
    assign s40[1] = bypass40_qq;
    // Match the two clocks in the sibling reduction branch.
    (* SHREG_EXTRACT="NO" *) reg signed [19:0] bypass41_q,bypass41_qq;
    always @(posedge clk) begin
        bypass41_q <= {s31[2][18],s31[2]};
        bypass41_qq <= bypass41_q;
    end
    assign s41[1] = bypass41_qq;
    genvar level5;
    generate for(level5=0;level5<1;level5=level5+1) begin: tree_level5
        tinyyolo_pipe_add #(.WIDTH(21)) add0 (
            .clk(clk),
            .a({s40[2*level5][19],s40[2*level5]}),
            .b({s40[2*level5+1][19],s40[2*level5+1]}),
            .y(s50[level5]));
        tinyyolo_pipe_add #(.WIDTH(21)) add1 (
            .clk(clk),
            .a({s41[2*level5][19],s41[2*level5]}),
            .b({s41[2*level5+1][19],s41[2*level5+1]}),
            .y(s51[level5]));
    end endgenerate
    assign sum0=s50[0];
    assign sum1=s51[0];
    assign out_valid=v[14];
    assign out_last=l[14];
    always @(posedge clk) begin
        if(!rst_n) begin v<=0;l<=0;end
        else begin
            v<={v[13:0],valid};
            l<={l[13:0],last};
        end
    end
endmodule
