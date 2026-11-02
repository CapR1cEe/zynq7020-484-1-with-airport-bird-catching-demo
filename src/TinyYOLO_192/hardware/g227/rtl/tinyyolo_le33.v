`timescale 1ns/1ps
// Register three independent 11-bit comparison chunks, then combine them.
module tinyyolo_le33(input wire clk,input wire [32:0] a,b,output wire le);
    reg [2:0] lt;
    wire [2:0] eq;
    // Register at most three compared bits per equality term. Each term
    // fits a single LUT6; sharing a full 11-bit equality with the magnitude
    // comparator otherwise introduced a routed CARRY4 on the equality path.
    reg [3:0] equal_piece[0:2];
    integer i;
    always @(posedge clk)
        for(i=0;i<3;i=i+1)begin
            lt[i]<=a[i*11+:11]<b[i*11+:11];
            equal_piece[i][0]<=a[i*11+:3]==b[i*11+:3];
            equal_piece[i][1]<=a[i*11+3+:3]==b[i*11+3+:3];
            equal_piece[i][2]<=a[i*11+6+:3]==b[i*11+6+:3];
            equal_piece[i][3]<=a[i*11+9+:2]==b[i*11+9+:2];
        end
    genvar group;
    generate for(group=0;group<3;group=group+1)begin: equality_groups
        assign eq[group]=&equal_piece[group];
    end endgenerate
    assign le=lt[2] || (eq[2] && lt[1]) || ((&eq[2:1]) && (lt[0] || eq[0]));
endmodule
