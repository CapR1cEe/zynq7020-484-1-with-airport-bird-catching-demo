`timescale 1ns/1ps

// G228 Pipe2: configurable 22-INT8-convolution DDR -> gather -> MAC -> DDR
// closed loop with two serial control/HP0 register slices per direction.
// Native PS7 HP0 AXI3; no internal responder or reference-output storage.
module tinyyolo_allconv_closed_loop (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s00_axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s00_axi_aclk, ASSOCIATED_BUSIF s00_axi:m_axi, ASSOCIATED_RESET s00_axi_aresetn, FREQ_HZ 240000000" *)
    input wire s00_axi_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s00_axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s00_axi_aresetn, POLARITY ACTIVE_LOW" *)
    input wire s00_axi_aresetn,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s00_axi AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s00_axi, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 8, READ_WRITE_MODE READ_WRITE, FREQ_HZ 240000000" *)
    input wire [7:0] s00_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s00_axi AWVALID" *)
    input wire s00_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s00_axi AWREADY" *)
    output wire s00_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s00_axi WDATA" *)
    input wire [31:0] s00_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s00_axi WSTRB" *)
    input wire [3:0] s00_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s00_axi WVALID" *)
    input wire s00_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s00_axi WREADY" *)
    output wire s00_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s00_axi BRESP" *)
    output wire [1:0] s00_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s00_axi BVALID" *)
    output wire s00_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s00_axi BREADY" *)
    input wire s00_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s00_axi ARADDR" *)
    input wire [7:0] s00_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s00_axi ARVALID" *)
    input wire s00_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s00_axi ARREADY" *)
    output wire s00_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s00_axi RDATA" *)
    output wire [31:0] s00_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s00_axi RRESP" *)
    output wire [1:0] s00_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s00_axi RVALID" *)
    output wire s00_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s00_axi RREADY" *)
    input wire s00_axi_rready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWID" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axi, PROTOCOL AXI3, DATA_WIDTH 64, ADDR_WIDTH 32, ID_WIDTH 6, READ_WRITE_MODE READ_WRITE, MAX_BURST_LENGTH 16, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, FREQ_HZ 240000000" *)
    output wire [5:0] m_axi_awid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWADDR" *)
    output wire [31:0] m_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWLEN" *)
    output wire [3:0] m_axi_awlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWSIZE" *)
    output wire [2:0] m_axi_awsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWBURST" *)
    output wire [1:0] m_axi_awburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWLOCK" *)
    output wire [1:0] m_axi_awlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWCACHE" *)
    output wire [3:0] m_axi_awcache,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWPROT" *)
    output wire [2:0] m_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWQOS" *)
    output wire [3:0] m_axi_awqos,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWVALID" *)
    output wire m_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWREADY" *)
    input wire m_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WID" *)
    output wire [5:0] m_axi_wid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WDATA" *)
    output wire [63:0] m_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WSTRB" *)
    output wire [7:0] m_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WLAST" *)
    output wire m_axi_wlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WVALID" *)
    output wire m_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WREADY" *)
    input wire m_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi BID" *)
    input wire [5:0] m_axi_bid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi BRESP" *)
    input wire [1:0] m_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi BVALID" *)
    input wire m_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi BREADY" *)
    output wire m_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARID" *)
    output wire [5:0] m_axi_arid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARADDR" *)
    output wire [31:0] m_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARLEN" *)
    output wire [3:0] m_axi_arlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARSIZE" *)
    output wire [2:0] m_axi_arsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARBURST" *)
    output wire [1:0] m_axi_arburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARLOCK" *)
    output wire [1:0] m_axi_arlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARCACHE" *)
    output wire [3:0] m_axi_arcache,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARPROT" *)
    output wire [2:0] m_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARQOS" *)
    output wire [3:0] m_axi_arqos,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARVALID" *)
    output wire m_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARREADY" *)
    input wire m_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RID" *)
    input wire [5:0] m_axi_rid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RDATA" *)
    input wire [63:0] m_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RRESP" *)
    input wire [1:0] m_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RLAST" *)
    input wire m_axi_rlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RVALID" *)
    input wire m_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RREADY" *)
    output wire m_axi_rready
);
    // The control/HP0 boundary is intentionally split into two elastic
    // register stages in each direction.  Keep the controller-side names
    // separate from the HP0-side names so the timing report can identify the
    // new pipeline endpoints directly.
    wire ctrl_req_valid, ctrl_req_ready, ctrl_req_write;
    wire [31:0] ctrl_req_addr;
    wire [63:0] ctrl_req_wdata;
    wire [7:0] ctrl_req_wstrb;
    wire [1:0] ctrl_req_kind;
    wire [31:0] ctrl_req_low, ctrl_req_high;
    wire ctrl_rsp_valid, ctrl_rsp_ready, ctrl_rsp_error;
    wire [63:0] ctrl_rsp_data;
    wire hp_req_valid, hp_req_ready, hp_req_write;
    wire [31:0] hp_req_addr;
    wire [63:0] hp_req_wdata;
    wire [7:0] hp_req_wstrb;
    wire [1:0] hp_req_kind;
    wire [31:0] hp_req_low, hp_req_high;
    wire hp_rsp_valid, hp_rsp_ready, hp_rsp_error;
    wire [63:0] hp_rsp_data;
    wire ctrl_cache_invalidate, hp_cache_invalidate;
    reg [1:0] cache_invalidate_pipe;
    wire hp_idle, hp_engine_idle, pipe_empty;
    wire [31:0] hp_bursts, hp_beats, hp_input_hits, hp_weight_hits, hp_misses;
    wire profile_busy, profile_start, profile_clear, profile_read_enable;
    wire [63:0] profile_state;
    wire [31:0] profile_rdata;
    assign m_axi_awid = 6'd0;
    assign m_axi_awlen = 4'd0;
    assign m_axi_awsize = 3'd3;
    assign m_axi_awburst = 2'b01;
    assign m_axi_awlock = 2'b00;
    assign m_axi_awcache = 4'b0000;
    assign m_axi_awprot = 3'b000;
    assign m_axi_awqos = 4'd0;
    assign m_axi_wid = 6'd0;
    assign m_axi_wlast = 1'b1;
    assign m_axi_arid = 6'd0;
    assign m_axi_arsize = 3'd3;
    assign m_axi_arburst = 2'b01;
    assign m_axi_arlock = 2'b00;
    assign m_axi_arcache = 4'b0000;
    assign m_axi_arprot = 3'b000;
    assign m_axi_arqos = 4'd0;

    tinyyolo_allconv_control u_control (
        .clk(s00_axi_aclk), .rst_n(s00_axi_aresetn),
        .s_awaddr(s00_axi_awaddr), .s_awvalid(s00_axi_awvalid), .s_awready(s00_axi_awready),
        .s_wdata(s00_axi_wdata), .s_wstrb(s00_axi_wstrb),
        .s_wvalid(s00_axi_wvalid), .s_wready(s00_axi_wready),
        .s_bresp(s00_axi_bresp), .s_bvalid(s00_axi_bvalid), .s_bready(s00_axi_bready),
        .s_araddr(s00_axi_araddr), .s_arvalid(s00_axi_arvalid), .s_arready(s00_axi_arready),
        .s_rdata(s00_axi_rdata), .s_rresp(s00_axi_rresp),
        .s_rvalid(s00_axi_rvalid), .s_rready(s00_axi_rready),
        .req_valid(ctrl_req_valid), .req_ready(ctrl_req_ready), .req_write(ctrl_req_write), .req_addr(ctrl_req_addr),
        .req_wdata(ctrl_req_wdata), .req_wstrb(ctrl_req_wstrb),
        .rsp_valid(ctrl_rsp_valid), .rsp_ready(ctrl_rsp_ready), .rsp_data(ctrl_rsp_data), .rsp_error(ctrl_rsp_error),
        .cache_invalidate(ctrl_cache_invalidate), .req_kind(ctrl_req_kind), .req_low(ctrl_req_low), .req_high(ctrl_req_high),
        .hp_bursts(hp_bursts), .hp_beats(hp_beats), .hp_input_hits(hp_input_hits),
        .hp_weight_hits(hp_weight_hits), .hp_misses(hp_misses), .hp_idle(hp_idle),
        .profile_rdata(profile_rdata), .profile_busy(profile_busy),
        .profile_start(profile_start), .profile_clear(profile_clear), .profile_state(profile_state),
        .profile_read_enable(profile_read_enable)
    );
    tinyyolo_cycle_profile u_profile (
        .clk(s00_axi_aclk), .rst_n(s00_axi_aresetn),
        .active(profile_busy), .start(profile_start), .clear(profile_clear), .state(profile_state),
        .req_valid(ctrl_req_valid), .req_ready(ctrl_req_ready),
        .arvalid(m_axi_arvalid), .arready(m_axi_arready),
        .rvalid(m_axi_rvalid), .rready(m_axi_rready),
        .awvalid(m_axi_awvalid), .awready(m_axi_awready),
        .wvalid(m_axi_wvalid), .wready(m_axi_wready),
        .bvalid(m_axi_bvalid), .bready(m_axi_bready),
        .read_enable(profile_read_enable), .read_addr(s00_axi_araddr[6:2]), .read_data(profile_rdata)
    );
    // Delay the invalidate pulse independently of the request payload.  The
    // HP0 cache latches it as a pending invalidate, so a two-cycle pulse
    // delay remains lossless even if the cache is finishing a prior response.
    always @(posedge s00_axi_aclk) begin
        if (!s00_axi_aresetn)
            cache_invalidate_pipe <= 2'b00;
        else
            cache_invalidate_pipe <= {cache_invalidate_pipe[0], ctrl_cache_invalidate};
    end
    assign hp_cache_invalidate = cache_invalidate_pipe[1];
    // DMA buffers remain owned until payload, response and invalidate drain.
    assign hp_idle = hp_engine_idle && pipe_empty &&
        !(|cache_invalidate_pipe) && !ctrl_cache_invalidate;

    tinyyolo_ctrl_hp0_pipe2 u_ctrl_hp0_pipe2 (
        .clk(s00_axi_aclk), .rst_n(s00_axi_aresetn),
        .req_in_valid(ctrl_req_valid), .req_in_ready(ctrl_req_ready),
        .req_in_write(ctrl_req_write), .req_in_addr(ctrl_req_addr),
        .req_in_wdata(ctrl_req_wdata), .req_in_wstrb(ctrl_req_wstrb),
        .req_in_kind(ctrl_req_kind), .req_in_low(ctrl_req_low), .req_in_high(ctrl_req_high),
        .req_out_valid(hp_req_valid), .req_out_ready(hp_req_ready),
        .req_out_write(hp_req_write), .req_out_addr(hp_req_addr),
        .req_out_wdata(hp_req_wdata), .req_out_wstrb(hp_req_wstrb),
        .req_out_kind(hp_req_kind), .req_out_low(hp_req_low), .req_out_high(hp_req_high),
        .rsp_in_valid(hp_rsp_valid), .rsp_in_ready(hp_rsp_ready),
        .rsp_in_data(hp_rsp_data), .rsp_in_error(hp_rsp_error),
        .rsp_out_valid(ctrl_rsp_valid), .rsp_out_ready(ctrl_rsp_ready),
        .rsp_out_data(ctrl_rsp_data), .rsp_out_error(ctrl_rsp_error), .empty(pipe_empty)
    );

    tinyyolo_hp0_burst_cache u_hp0 (
        .clk(s00_axi_aclk), .rst_n(s00_axi_aresetn),
        .invalidate(hp_cache_invalidate), .req_kind(hp_req_kind), .req_low(hp_req_low), .req_high(hp_req_high),
        .idle(hp_engine_idle), .read_bursts(hp_bursts), .read_beats(hp_beats),
        .input_hits(hp_input_hits), .weight_hits(hp_weight_hits), .read_misses(hp_misses),
        .req_valid(hp_req_valid), .req_ready(hp_req_ready), .req_write(hp_req_write), .req_addr(hp_req_addr),
        .req_wdata(hp_req_wdata), .req_wstrb(hp_req_wstrb),
        .rsp_valid(hp_rsp_valid), .rsp_ready(hp_rsp_ready), .rsp_data(hp_rsp_data), .rsp_error(hp_rsp_error),
        .araddr(m_axi_araddr), .arlen(m_axi_arlen), .arvalid(m_axi_arvalid), .arready(m_axi_arready),
        .rdata(m_axi_rdata), .rid(m_axi_rid), .rresp(m_axi_rresp), .rlast(m_axi_rlast),
        .rvalid(m_axi_rvalid), .rready(m_axi_rready),
        .awaddr(m_axi_awaddr), .awvalid(m_axi_awvalid), .awready(m_axi_awready),
        .wdata(m_axi_wdata), .wstrb(m_axi_wstrb), .wvalid(m_axi_wvalid), .wready(m_axi_wready),
        .bid(m_axi_bid), .bresp(m_axi_bresp), .bvalid(m_axi_bvalid), .bready(m_axi_bready)
    );
endmodule
