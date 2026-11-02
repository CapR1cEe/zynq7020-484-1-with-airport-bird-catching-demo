`timescale 1ns/1ps
// Modulo-2^32 event count with four local byte incrementers. Predictive
// carries describe the current lower bytes and remain valid across stalls.
module tinyyolo_counter32 (
    input wire clk,rst_n,clear,enable,
    output reg [31:0] value
);
    reg carry8,carry16,carry24;
    // Keep the wide reductions independent of the event input. Otherwise
    // LUT absorption can put enable ahead of several reduction levels.
    (* KEEP="TRUE" *) wire next_low_bit=value[0]^enable;
    (* KEEP="TRUE" *) wire upper8_ones=&value[7:1];
    (* KEEP="TRUE" *) wire upper16_ones=&value[15:1];
    (* KEEP="TRUE" *) wire upper24_ones=&value[23:1];
    always @(posedge clk) begin
        if(!rst_n || clear)begin
            value<=32'd0;
            carry8<=1'b0;carry16<=1'b0;carry24<=1'b0;
        end else begin
            if(enable)begin
                value[7:0]<=value[7:0]+8'd1;
                value[15:8]<=value[15:8]+carry8;
                value[23:16]<=value[23:16]+carry16;
                value[31:24]<=value[31:24]+carry24;
            end
            // Predict all-ones for value+enable without an enable-selected
            // pair of wide reductions. Stalls keep the exact same invariant.
            carry8<=upper8_ones && next_low_bit;
            carry16<=upper16_ones && next_low_bit;
            carry24<=upper24_ones && next_low_bit;
        end
    end
endmodule

// Loadable form used when a head publishes its completed output count.
// Load initializes predictive carries from the loaded value, so an immediate
// next-cycle enable correctly handles every byte boundary, including wrap.
module tinyyolo_counter32_load (
    input wire clk,rst_n,clear,load,enable,
    input wire [31:0] load_value,
    (* EXTRACT_ENABLE="NO" *) output reg [31:0] value
);
    reg carry8,carry16,carry24;
    (* KEEP="TRUE" *) wire next_low_bit=value[0]^enable;
    (* KEEP="TRUE" *) wire upper8_ones=&value[7:1];
    (* KEEP="TRUE" *) wire upper16_ones=&value[15:1];
    (* KEEP="TRUE" *) wire upper24_ones=&value[23:1];
    always @(posedge clk)
        if(!rst_n || clear)begin
            value<=32'd0;carry8<=1'b0;carry16<=1'b0;carry24<=1'b0;
        end else if(load)begin
            value<=load_value;
            carry8<=(&load_value[7:0]);
            carry16<=(&load_value[15:0]);
            carry24<=(&load_value[23:0]);
        end else begin
            if(enable)begin
                value[7:0]<=value[7:0]+8'd1;
                value[15:8]<=value[15:8]+{7'd0,carry8};
                value[23:16]<=value[23:16]+{7'd0,carry16};
                value[31:24]<=value[31:24]+{7'd0,carry24};
            end
            carry8<=upper8_ones && next_low_bit;
            carry16<=upper16_ones && next_low_bit;
            carry24<=upper24_ones && next_low_bit;
        end
endmodule
