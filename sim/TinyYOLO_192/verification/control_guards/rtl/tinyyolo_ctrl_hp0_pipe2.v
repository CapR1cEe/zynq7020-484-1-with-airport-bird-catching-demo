`timescale 1ns/1ps
// Two serial register slices per direction: registered READY and VALID/data.
// Each stage has one output and one skid slot; unstalled latency = 2 clocks.
module tinyyolo_ctrl_hp0_pipe2 (
    input wire clk, input wire rst_n,
    input wire req_in_valid, output wire req_in_ready,
    input wire req_in_write, input wire [31:0] req_in_addr,
    input wire [63:0] req_in_wdata, input wire [7:0] req_in_wstrb,
    input wire [1:0] req_in_kind, input wire [31:0] req_in_low, req_in_high,
    output wire req_out_valid, input wire req_out_ready,
    output wire req_out_write, output wire [31:0] req_out_addr,
    output wire [63:0] req_out_wdata, output wire [7:0] req_out_wstrb,
    output wire [1:0] req_out_kind, output wire [31:0] req_out_low, req_out_high,
    input wire rsp_in_valid, output wire rsp_in_ready,
    input wire [63:0] rsp_in_data, input wire rsp_in_error,
    output wire rsp_out_valid, input wire rsp_out_ready,
    output wire [63:0] rsp_out_data, output wire rsp_out_error,
    output wire empty
);
    wire [170:0] req_payload = {req_in_write,req_in_addr,req_in_wdata,
        req_in_wstrb,req_in_kind,req_in_low,req_in_high};
    wire [170:0] req_mid, req_result;
    wire [64:0] rsp_mid, rsp_result;
    wire req_v, req_r, rsp_v, rsp_r;
    wire [3:0] stage_empty;
    assign {req_out_write,req_out_addr,req_out_wdata,req_out_wstrb,
        req_out_kind,req_out_low,req_out_high} = req_result;
    assign {rsp_out_error,rsp_out_data} = rsp_result;
    assign empty = &stage_empty;
    tinyyolo_rv_slice #(.WIDTH(171)) req0 (
        .clk(clk),.rst_n(rst_n),.s_valid(req_in_valid),.s_ready(req_in_ready),
        .s_data(req_payload),.m_valid(req_v),.m_ready(req_r),.m_data(req_mid),.empty(stage_empty[0]));
    tinyyolo_rv_slice #(.WIDTH(171)) req1 (
        .clk(clk),.rst_n(rst_n),.s_valid(req_v),.s_ready(req_r),
        .s_data(req_mid),.m_valid(req_out_valid),.m_ready(req_out_ready),.m_data(req_result),.empty(stage_empty[1]));
    tinyyolo_rv_slice #(.WIDTH(65)) rsp0 (
        .clk(clk),.rst_n(rst_n),.s_valid(rsp_in_valid),.s_ready(rsp_in_ready),
        .s_data({rsp_in_error,rsp_in_data}),.m_valid(rsp_v),.m_ready(rsp_r),.m_data(rsp_mid),.empty(stage_empty[2]));
    tinyyolo_rv_slice #(.WIDTH(65)) rsp1 (
        .clk(clk),.rst_n(rst_n),.s_valid(rsp_v),.s_ready(rsp_r),
        .s_data(rsp_mid),.m_valid(rsp_out_valid),.m_ready(rsp_out_ready),.m_data(rsp_result),.empty(stage_empty[3]));
endmodule

module tinyyolo_rv_slice #(parameter integer WIDTH=8) (
    input wire clk, input wire rst_n,
    input wire s_valid, output reg s_ready, input wire [WIDTH-1:0] s_data,
    output reg m_valid, input wire m_ready,
    (* EXTRACT_ENABLE="NO" *) output reg [WIDTH-1:0] m_data,
    output wire empty
);
    reg skid_valid;
    reg [WIDTH-1:0] skid_data;
    wire ready_next = m_ready || (!skid_valid && (!m_valid || !s_valid));
    assign empty = !m_valid && !skid_valid;
    // Payloads are private until their VALID flag is set. Keeping synchronous
    // reset out of these wide enables isolates reset and READY fanout.
    always @(posedge clk) begin
        if(s_ready)skid_data<=s_data;
        if(!m_valid || m_ready)m_data<=s_ready?s_data:skid_data;
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            s_ready<=1'b0; m_valid<=1'b0; skid_valid<=1'b0;
        end else begin
            s_ready<=ready_next;
            if (s_ready) begin
                // The skid payload is private until skid_valid is asserted.
                // Sampling on every accepted input slot removes downstream
                // READY from the wide skid register enable.
                if (m_ready || !m_valid) begin
                    m_valid<=s_valid;
                    // VALID qualifies the payload. An empty writable slot
                    // may sample invalid data; excluding s_valid here keeps
                    // controller FSM decode off the wide output clock enable.
                end else begin
                    skid_valid<=s_valid;
                    // skid_valid qualifies this payload. Capturing data even
                    // when s_valid is low is harmless and keeps the wide
                    // skid-data register enable independent of controller
                    // state and request-valid fanout.
                end
            end else if (m_ready) begin
                m_valid<=skid_valid; skid_valid<=1'b0;
            end
        end
    end
endmodule
