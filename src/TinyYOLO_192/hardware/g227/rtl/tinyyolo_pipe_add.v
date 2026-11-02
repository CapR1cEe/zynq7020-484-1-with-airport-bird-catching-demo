`timescale 1ns/1ps

// Two-clock modulo-2^WIDTH adder. The first clock adds the two halves
// independently; the second joins only the registered low carry. A new
// operand pair is accepted on every clock, with no combinational path
// spanning the complete result width. Validity is carried by the caller.
module tinyyolo_pipe_add #(
    parameter integer WIDTH = 18,
    parameter integer LOW_WIDTH = 8
) (
    input wire clk,
    input wire [WIDTH-1:0] a,
    input wire [WIDTH-1:0] b,
    output reg [WIDTH-1:0] y
);
    localparam integer HIGH_WIDTH = WIDTH - LOW_WIDTH;
    reg [LOW_WIDTH:0] low_q;
    reg [HIGH_WIDTH-1:0] high_q;

    always @(posedge clk) begin
        low_q <= {1'b0, a[LOW_WIDTH-1:0]} + {1'b0, b[LOW_WIDTH-1:0]};
        high_q <= a[WIDTH-1:LOW_WIDTH] + b[WIDTH-1:LOW_WIDTH];
        y[LOW_WIDTH-1:0] <= low_q[LOW_WIDTH-1:0];
        y[WIDTH-1:LOW_WIDTH] <= high_q +
            {{(HIGH_WIDTH-1){1'b0}}, low_q[LOW_WIDTH]};
    end
endmodule
