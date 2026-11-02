`timescale 1ns/1ps
// Three-stage, II=1 unsigned right shift with exact sticky-bit jamming.
// Metadata travels with the operand; the owner qualifies the result after
// three rising edges. Private pipeline registers intentionally have no reset.
module tinyyolo_shift56_jam #(parameter RESULT_WIDTH=56) (
    input wire clk, input wire [55:0] value, input wire [10:0] distance,
    output reg [RESULT_WIDTH-1:0] result
);
    reg [55:0] shift_1_2,shift_4_8;
    reg [8:0] distance_middle;
    reg [55:0] low_shift;
    reg [13:0] jam_blocks;
    wire [14:0] jam_prefix;
    // Stage one reduces four-bit blocks; stage two combines at most fourteen
    // registered blocks. No wide sticky reduction remains in stage three.
    genvar block_index;
    generate for(block_index=0;block_index<14;block_index=block_index+1)begin:sticky_blocks
        always @(posedge clk)jam_blocks[block_index]<=|low_shift[4*block_index+:4];
        if(block_index==0)assign jam_prefix[block_index]=shift_1_2[0];
        else assign jam_prefix[block_index]=(|jam_blocks[block_index-1:0])|shift_1_2[4*block_index];
    end endgenerate
    assign jam_prefix[14]=|jam_blocks;
    (* KEEP = "true" *) reg [4:0] high_select;
    reg [4:0] high_sticky;
    wire [55:0] high_data=({56{high_select[0]}}&shift_4_8)
                        |({56{high_select[1]}}&(shift_4_8>>16))
                        |({56{high_select[2]}}&(shift_4_8>>32))
                        |({56{high_select[3]}}&(shift_4_8>>48));
    wire [RESULT_WIDTH-1:0] final_shift=
        (high_data[RESULT_WIDTH-1:0]&{{(RESULT_WIDTH-1){1'b1}},1'b0})
        |{{(RESULT_WIDTH-1){1'b0}},|(high_select&high_sticky)};
    always @* begin
        case(distance[1:0])
            2'd0:low_shift=value;
            2'd1:low_shift={1'b0,value[55:1]}|{55'd0,value[0]};
            2'd2:low_shift={2'd0,value[55:2]}|{55'd0,|value[1:0]};
            2'd3:low_shift={3'd0,value[55:3]}|{55'd0,|value[2:0]};
        endcase
    end
    always @(posedge clk) begin
        shift_1_2<=low_shift;
        distance_middle<=distance[10:2];
        high_select[0]<=distance_middle[8:2]==7'd0;
        high_select[1]<=distance_middle[8:2]==7'd1;
        high_select[2]<=distance_middle[8:2]==7'd2;
        high_select[3]<=distance_middle[8:2]==7'd3;
        high_select[4]<=|distance_middle[8:4];
        case(distance_middle[1:0])
            2'd0:begin
                shift_4_8<=shift_1_2;
                high_sticky<={jam_prefix[14],jam_prefix[12],jam_prefix[8],jam_prefix[4],jam_prefix[0]};
            end
            2'd1:begin
                shift_4_8<={4'd0,shift_1_2[55:5],jam_prefix[1]};
                high_sticky<={jam_prefix[14],jam_prefix[13],jam_prefix[9],jam_prefix[5],jam_prefix[1]};
            end
            2'd2:begin
                shift_4_8<={8'd0,shift_1_2[55:9],jam_prefix[2]};
                high_sticky<={jam_prefix[14],jam_prefix[14],jam_prefix[10],jam_prefix[6],jam_prefix[2]};
            end
            2'd3:begin
                shift_4_8<={12'd0,shift_1_2[55:13],jam_prefix[3]};
                high_sticky<={jam_prefix[14],jam_prefix[14],jam_prefix[11],jam_prefix[7],jam_prefix[3]};
            end
        endcase
        result<=final_shift;
    end
endmodule
