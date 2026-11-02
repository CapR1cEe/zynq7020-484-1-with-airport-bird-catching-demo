`timescale 1ns/1ps
// Fully registered signed dot product. One independent vector per clock.
module tinyyolo_dot16 (
    input wire clk, input wire rst_n, input wire valid, input wire last,
    input wire [127:0] a, input wire [127:0] w,
    output wire out_valid, output wire out_last, output wire signed [19:0] sum
);
    wire signed [42:0] dsp_product[0:15];
    wire signed [15:0] p[0:15];
    genvar lane;
    generate for(lane=0;lane<16;lane=lane+1) begin: mul_lane
        tinyyolo_dsp_mul #(.INPUT_REG(1)) mul(.clk(clk),.rst_n(rst_n),
            .a({{17{a[lane*8+7]}},a[lane*8+:8]}),
            .b({{10{w[lane*8+7]}},w[lane*8+:8]}),.product(dsp_product[lane]));
        assign p[lane]=dsp_product[lane][15:0];
    end endgenerate
    reg signed [16:0] s1[0:7];
    reg signed [17:0] s2[0:3];
    reg signed [18:0] s3[0:1];
    reg signed [19:0] s4;
    reg [6:0] v, l;
    integer i;
    assign out_valid=v[6];
    assign out_last=l[6];
    assign sum=s4;
    always @(posedge clk) begin
        if (!rst_n) begin
            v<=7'd0; l<=7'd0;
        end else begin
            v<={v[5:0],valid}; l<={l[5:0],last};
        end
        // VALID/LAST alone reset the pipeline. Every arithmetic stage is
        // overwritten before its next valid vector reaches the output.
        // Avoid a reset-derived clock enable on all private adder registers.
            for(i=0;i<8;i=i+1)
                s1[i]<=$signed({p[2*i][15],p[2*i]})+$signed({p[2*i+1][15],p[2*i+1]});
            for(i=0;i<4;i=i+1)
                s2[i]<=$signed({s1[2*i][16],s1[2*i]})+$signed({s1[2*i+1][16],s1[2*i+1]});
            for(i=0;i<2;i=i+1)
                s3[i]<=$signed({s2[2*i][17],s2[2*i]})+$signed({s2[2*i+1][17],s2[2*i+1]});
            s4<=$signed({s3[0][18],s3[0]})+$signed({s3[1][18],s3[1]});
    end
endmodule
