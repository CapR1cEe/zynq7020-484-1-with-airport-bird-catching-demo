//Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
//Copyright 2022-2025 Advanced Micro Devices, Inc. All Rights Reserved.
//--------------------------------------------------------------------------------
//Tool Version: Vivado v.2025.2 (win64) Build 6299465 Fri Nov 14 19:35:11 GMT 2025
//Date        : Sun Oct 25 17:39:57 2026
//Host        : CaPr1cEe running 64-bit major release  (build 9200)
//Command     : generate_target Tiny_Yolo.bd
//Design      : Tiny_Yolo
//Purpose     : IP block netlist
//--------------------------------------------------------------------------------
`timescale 1 ps / 1 ps

(* CORE_GENERATION_INFO = "Tiny_Yolo,IP_Integrator,{x_ipVendor=xilinx.com,x_ipLibrary=BlockDiagram,x_ipName=Tiny_Yolo,x_ipVersion=1.00.a,x_ipLanguage=VERILOG,numBlks=7,numReposBlks=7,numNonXlnxBlks=0,numHierBlks=0,maxHierDepth=0,numSysgenBlks=0,numHlsBlks=0,numHdlrefBlks=1,numPkgbdBlks=0,bdsource=USER,synth_mode=None}" *) (* HW_HANDOFF = "Tiny_Yolo.hwdef" *) 
module Tiny_Yolo
   (DDR_0_addr,
    DDR_0_ba,
    DDR_0_cas_n,
    DDR_0_ck_n,
    DDR_0_ck_p,
    DDR_0_cke,
    DDR_0_cs_n,
    DDR_0_dm,
    DDR_0_dq,
    DDR_0_dqs_n,
    DDR_0_dqs_p,
    DDR_0_odt,
    DDR_0_ras_n,
    DDR_0_reset_n,
    DDR_0_we_n,
    FIXED_IO_0_ddr_vrn,
    FIXED_IO_0_ddr_vrp,
    FIXED_IO_0_mio,
    FIXED_IO_0_ps_clk,
    FIXED_IO_0_ps_porb,
    FIXED_IO_0_ps_srstb,
    UART_0_rxd,
    UART_0_txd);
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR_0 ADDR" *) (* X_INTERFACE_MODE = "Master" *) (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME DDR_0, AXI_ARBITRATION_SCHEME TDM, BURST_LENGTH 8, CAN_DEBUG false, CAS_LATENCY 11, CAS_WRITE_LATENCY 11, CS_ENABLED true, DATA_MASK_ENABLED true, DATA_WIDTH 8, MEMORY_TYPE COMPONENTS, MEM_ADDR_MAP ROW_COLUMN_BANK, SLOT Single, TIMEPERIOD_PS 1250" *) inout [14:0]DDR_0_addr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR_0 BA" *) inout [2:0]DDR_0_ba;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR_0 CAS_N" *) inout DDR_0_cas_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR_0 CK_N" *) inout DDR_0_ck_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR_0 CK_P" *) inout DDR_0_ck_p;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR_0 CKE" *) inout DDR_0_cke;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR_0 CS_N" *) inout DDR_0_cs_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR_0 DM" *) inout [3:0]DDR_0_dm;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR_0 DQ" *) inout [31:0]DDR_0_dq;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR_0 DQS_N" *) inout [3:0]DDR_0_dqs_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR_0 DQS_P" *) inout [3:0]DDR_0_dqs_p;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR_0 ODT" *) inout DDR_0_odt;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR_0 RAS_N" *) inout DDR_0_ras_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR_0 RESET_N" *) inout DDR_0_reset_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR_0 WE_N" *) inout DDR_0_we_n;
  (* X_INTERFACE_INFO = "xilinx.com:display_processing_system7:fixedio:1.0 FIXED_IO_0 DDR_VRN" *) (* X_INTERFACE_MODE = "Master" *) (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME FIXED_IO_0, CAN_DEBUG false" *) inout FIXED_IO_0_ddr_vrn;
  (* X_INTERFACE_INFO = "xilinx.com:display_processing_system7:fixedio:1.0 FIXED_IO_0 DDR_VRP" *) inout FIXED_IO_0_ddr_vrp;
  (* X_INTERFACE_INFO = "xilinx.com:display_processing_system7:fixedio:1.0 FIXED_IO_0 MIO" *) inout [53:0]FIXED_IO_0_mio;
  (* X_INTERFACE_INFO = "xilinx.com:display_processing_system7:fixedio:1.0 FIXED_IO_0 PS_CLK" *) inout FIXED_IO_0_ps_clk;
  (* X_INTERFACE_INFO = "xilinx.com:display_processing_system7:fixedio:1.0 FIXED_IO_0 PS_PORB" *) inout FIXED_IO_0_ps_porb;
  (* X_INTERFACE_INFO = "xilinx.com:display_processing_system7:fixedio:1.0 FIXED_IO_0 PS_SRSTB" *) inout FIXED_IO_0_ps_srstb;
  (* X_INTERFACE_INFO = "xilinx.com:interface:uart:1.0 UART_0 RxD" *) (* X_INTERFACE_MODE = "Master" *) input UART_0_rxd;
  (* X_INTERFACE_INFO = "xilinx.com:interface:uart:1.0 UART_0 TxD" *) output UART_0_txd;

  wire [14:0]DDR_0_addr;
  wire [2:0]DDR_0_ba;
  wire DDR_0_cas_n;
  wire DDR_0_ck_n;
  wire DDR_0_ck_p;
  wire DDR_0_cke;
  wire DDR_0_cs_n;
  wire [3:0]DDR_0_dm;
  wire [31:0]DDR_0_dq;
  wire [3:0]DDR_0_dqs_n;
  wire [3:0]DDR_0_dqs_p;
  wire DDR_0_odt;
  wire DDR_0_ras_n;
  wire DDR_0_reset_n;
  wire DDR_0_we_n;
  wire FIXED_IO_0_ddr_vrn;
  wire FIXED_IO_0_ddr_vrp;
  wire [53:0]FIXED_IO_0_mio;
  wire FIXED_IO_0_ps_clk;
  wire FIXED_IO_0_ps_porb;
  wire FIXED_IO_0_ps_srstb;
  wire UART_0_rxd;
  wire UART_0_txd;
  wire pl_clk_locked;
  wire pl_clk_out;
  wire [0:0]proc_sys_reset_0_peripheral_aresetn;
  wire processing_system7_0_FCLK_CLK0;
  wire processing_system7_0_FCLK_RESET0_N;
  wire [31:0]processing_system7_0_M_AXI_GP0_ARADDR;
  wire [1:0]processing_system7_0_M_AXI_GP0_ARBURST;
  wire [3:0]processing_system7_0_M_AXI_GP0_ARCACHE;
  wire [11:0]processing_system7_0_M_AXI_GP0_ARID;
  wire [3:0]processing_system7_0_M_AXI_GP0_ARLEN;
  wire [1:0]processing_system7_0_M_AXI_GP0_ARLOCK;
  wire [2:0]processing_system7_0_M_AXI_GP0_ARPROT;
  wire [3:0]processing_system7_0_M_AXI_GP0_ARQOS;
  wire processing_system7_0_M_AXI_GP0_ARREADY;
  wire [2:0]processing_system7_0_M_AXI_GP0_ARSIZE;
  wire processing_system7_0_M_AXI_GP0_ARVALID;
  wire [31:0]processing_system7_0_M_AXI_GP0_AWADDR;
  wire [1:0]processing_system7_0_M_AXI_GP0_AWBURST;
  wire [3:0]processing_system7_0_M_AXI_GP0_AWCACHE;
  wire [11:0]processing_system7_0_M_AXI_GP0_AWID;
  wire [3:0]processing_system7_0_M_AXI_GP0_AWLEN;
  wire [1:0]processing_system7_0_M_AXI_GP0_AWLOCK;
  wire [2:0]processing_system7_0_M_AXI_GP0_AWPROT;
  wire [3:0]processing_system7_0_M_AXI_GP0_AWQOS;
  wire processing_system7_0_M_AXI_GP0_AWREADY;
  wire [2:0]processing_system7_0_M_AXI_GP0_AWSIZE;
  wire processing_system7_0_M_AXI_GP0_AWVALID;
  wire [11:0]processing_system7_0_M_AXI_GP0_BID;
  wire processing_system7_0_M_AXI_GP0_BREADY;
  wire [1:0]processing_system7_0_M_AXI_GP0_BRESP;
  wire processing_system7_0_M_AXI_GP0_BVALID;
  wire [31:0]processing_system7_0_M_AXI_GP0_RDATA;
  wire [11:0]processing_system7_0_M_AXI_GP0_RID;
  wire processing_system7_0_M_AXI_GP0_RLAST;
  wire processing_system7_0_M_AXI_GP0_RREADY;
  wire [1:0]processing_system7_0_M_AXI_GP0_RRESP;
  wire processing_system7_0_M_AXI_GP0_RVALID;
  wire [31:0]processing_system7_0_M_AXI_GP0_WDATA;
  wire [11:0]processing_system7_0_M_AXI_GP0_WID;
  wire processing_system7_0_M_AXI_GP0_WLAST;
  wire processing_system7_0_M_AXI_GP0_WREADY;
  wire [3:0]processing_system7_0_M_AXI_GP0_WSTRB;
  wire processing_system7_0_M_AXI_GP0_WVALID;
  wire [0:0]ps_ctrl_reset_interconnect_aresetn;
  wire [0:0]reset_zero_dout;
  wire [7:0]smartconnect_0_M00_AXI_ARADDR;
  wire smartconnect_0_M00_AXI_ARREADY;
  wire smartconnect_0_M00_AXI_ARVALID;
  wire [7:0]smartconnect_0_M00_AXI_AWADDR;
  wire smartconnect_0_M00_AXI_AWREADY;
  wire smartconnect_0_M00_AXI_AWVALID;
  wire smartconnect_0_M00_AXI_BREADY;
  wire [1:0]smartconnect_0_M00_AXI_BRESP;
  wire smartconnect_0_M00_AXI_BVALID;
  wire [31:0]smartconnect_0_M00_AXI_RDATA;
  wire smartconnect_0_M00_AXI_RREADY;
  wire [1:0]smartconnect_0_M00_AXI_RRESP;
  wire smartconnect_0_M00_AXI_RVALID;
  wire [31:0]smartconnect_0_M00_AXI_WDATA;
  wire smartconnect_0_M00_AXI_WREADY;
  wire [3:0]smartconnect_0_M00_AXI_WSTRB;
  wire smartconnect_0_M00_AXI_WVALID;
  wire [31:0]tinyyolo_accel_0_m_axi_ARADDR;
  wire [1:0]tinyyolo_accel_0_m_axi_ARBURST;
  wire [3:0]tinyyolo_accel_0_m_axi_ARCACHE;
  wire [5:0]tinyyolo_accel_0_m_axi_ARID;
  wire [3:0]tinyyolo_accel_0_m_axi_ARLEN;
  wire [1:0]tinyyolo_accel_0_m_axi_ARLOCK;
  wire [2:0]tinyyolo_accel_0_m_axi_ARPROT;
  wire [3:0]tinyyolo_accel_0_m_axi_ARQOS;
  wire tinyyolo_accel_0_m_axi_ARREADY;
  wire [2:0]tinyyolo_accel_0_m_axi_ARSIZE;
  wire tinyyolo_accel_0_m_axi_ARVALID;
  wire [31:0]tinyyolo_accel_0_m_axi_AWADDR;
  wire [1:0]tinyyolo_accel_0_m_axi_AWBURST;
  wire [3:0]tinyyolo_accel_0_m_axi_AWCACHE;
  wire [5:0]tinyyolo_accel_0_m_axi_AWID;
  wire [3:0]tinyyolo_accel_0_m_axi_AWLEN;
  wire [1:0]tinyyolo_accel_0_m_axi_AWLOCK;
  wire [2:0]tinyyolo_accel_0_m_axi_AWPROT;
  wire [3:0]tinyyolo_accel_0_m_axi_AWQOS;
  wire tinyyolo_accel_0_m_axi_AWREADY;
  wire [2:0]tinyyolo_accel_0_m_axi_AWSIZE;
  wire tinyyolo_accel_0_m_axi_AWVALID;
  wire [5:0]tinyyolo_accel_0_m_axi_BID;
  wire tinyyolo_accel_0_m_axi_BREADY;
  wire [1:0]tinyyolo_accel_0_m_axi_BRESP;
  wire tinyyolo_accel_0_m_axi_BVALID;
  wire [63:0]tinyyolo_accel_0_m_axi_RDATA;
  wire [5:0]tinyyolo_accel_0_m_axi_RID;
  wire tinyyolo_accel_0_m_axi_RLAST;
  wire tinyyolo_accel_0_m_axi_RREADY;
  wire [1:0]tinyyolo_accel_0_m_axi_RRESP;
  wire tinyyolo_accel_0_m_axi_RVALID;
  wire [63:0]tinyyolo_accel_0_m_axi_WDATA;
  wire [5:0]tinyyolo_accel_0_m_axi_WID;
  wire tinyyolo_accel_0_m_axi_WLAST;
  wire tinyyolo_accel_0_m_axi_WREADY;
  wire [7:0]tinyyolo_accel_0_m_axi_WSTRB;
  wire tinyyolo_accel_0_m_axi_WVALID;

  Tiny_Yolo_pl_clk_0 pl_clk
       (.clk_in1(processing_system7_0_FCLK_CLK0),
        .clk_out1(pl_clk_out),
        .locked(pl_clk_locked),
        .resetn(processing_system7_0_FCLK_RESET0_N));
  Tiny_Yolo_proc_sys_reset_0_0 proc_sys_reset_0
       (.aux_reset_in(reset_zero_dout),
        .dcm_locked(pl_clk_locked),
        .ext_reset_in(processing_system7_0_FCLK_RESET0_N),
        .mb_debug_sys_rst(reset_zero_dout),
        .peripheral_aresetn(proc_sys_reset_0_peripheral_aresetn),
        .slowest_sync_clk(pl_clk_out));
  Tiny_Yolo_processing_system7_0_0 processing_system7_0
       (.DDR_Addr(DDR_0_addr),
        .DDR_BankAddr(DDR_0_ba),
        .DDR_CAS_n(DDR_0_cas_n),
        .DDR_CKE(DDR_0_cke),
        .DDR_CS_n(DDR_0_cs_n),
        .DDR_Clk(DDR_0_ck_p),
        .DDR_Clk_n(DDR_0_ck_n),
        .DDR_DM(DDR_0_dm),
        .DDR_DQ(DDR_0_dq),
        .DDR_DQS(DDR_0_dqs_p),
        .DDR_DQS_n(DDR_0_dqs_n),
        .DDR_DRSTB(DDR_0_reset_n),
        .DDR_ODT(DDR_0_odt),
        .DDR_RAS_n(DDR_0_ras_n),
        .DDR_VRN(FIXED_IO_0_ddr_vrn),
        .DDR_VRP(FIXED_IO_0_ddr_vrp),
        .DDR_WEB(DDR_0_we_n),
        .FCLK_CLK0(processing_system7_0_FCLK_CLK0),
        .FCLK_RESET0_N(processing_system7_0_FCLK_RESET0_N),
        .MIO(FIXED_IO_0_mio),
        .M_AXI_GP0_ACLK(processing_system7_0_FCLK_CLK0),
        .M_AXI_GP0_ARADDR(processing_system7_0_M_AXI_GP0_ARADDR),
        .M_AXI_GP0_ARBURST(processing_system7_0_M_AXI_GP0_ARBURST),
        .M_AXI_GP0_ARCACHE(processing_system7_0_M_AXI_GP0_ARCACHE),
        .M_AXI_GP0_ARID(processing_system7_0_M_AXI_GP0_ARID),
        .M_AXI_GP0_ARLEN(processing_system7_0_M_AXI_GP0_ARLEN),
        .M_AXI_GP0_ARLOCK(processing_system7_0_M_AXI_GP0_ARLOCK),
        .M_AXI_GP0_ARPROT(processing_system7_0_M_AXI_GP0_ARPROT),
        .M_AXI_GP0_ARQOS(processing_system7_0_M_AXI_GP0_ARQOS),
        .M_AXI_GP0_ARREADY(processing_system7_0_M_AXI_GP0_ARREADY),
        .M_AXI_GP0_ARSIZE(processing_system7_0_M_AXI_GP0_ARSIZE),
        .M_AXI_GP0_ARVALID(processing_system7_0_M_AXI_GP0_ARVALID),
        .M_AXI_GP0_AWADDR(processing_system7_0_M_AXI_GP0_AWADDR),
        .M_AXI_GP0_AWBURST(processing_system7_0_M_AXI_GP0_AWBURST),
        .M_AXI_GP0_AWCACHE(processing_system7_0_M_AXI_GP0_AWCACHE),
        .M_AXI_GP0_AWID(processing_system7_0_M_AXI_GP0_AWID),
        .M_AXI_GP0_AWLEN(processing_system7_0_M_AXI_GP0_AWLEN),
        .M_AXI_GP0_AWLOCK(processing_system7_0_M_AXI_GP0_AWLOCK),
        .M_AXI_GP0_AWPROT(processing_system7_0_M_AXI_GP0_AWPROT),
        .M_AXI_GP0_AWQOS(processing_system7_0_M_AXI_GP0_AWQOS),
        .M_AXI_GP0_AWREADY(processing_system7_0_M_AXI_GP0_AWREADY),
        .M_AXI_GP0_AWSIZE(processing_system7_0_M_AXI_GP0_AWSIZE),
        .M_AXI_GP0_AWVALID(processing_system7_0_M_AXI_GP0_AWVALID),
        .M_AXI_GP0_BID(processing_system7_0_M_AXI_GP0_BID),
        .M_AXI_GP0_BREADY(processing_system7_0_M_AXI_GP0_BREADY),
        .M_AXI_GP0_BRESP(processing_system7_0_M_AXI_GP0_BRESP),
        .M_AXI_GP0_BVALID(processing_system7_0_M_AXI_GP0_BVALID),
        .M_AXI_GP0_RDATA(processing_system7_0_M_AXI_GP0_RDATA),
        .M_AXI_GP0_RID(processing_system7_0_M_AXI_GP0_RID),
        .M_AXI_GP0_RLAST(processing_system7_0_M_AXI_GP0_RLAST),
        .M_AXI_GP0_RREADY(processing_system7_0_M_AXI_GP0_RREADY),
        .M_AXI_GP0_RRESP(processing_system7_0_M_AXI_GP0_RRESP),
        .M_AXI_GP0_RVALID(processing_system7_0_M_AXI_GP0_RVALID),
        .M_AXI_GP0_WDATA(processing_system7_0_M_AXI_GP0_WDATA),
        .M_AXI_GP0_WID(processing_system7_0_M_AXI_GP0_WID),
        .M_AXI_GP0_WLAST(processing_system7_0_M_AXI_GP0_WLAST),
        .M_AXI_GP0_WREADY(processing_system7_0_M_AXI_GP0_WREADY),
        .M_AXI_GP0_WSTRB(processing_system7_0_M_AXI_GP0_WSTRB),
        .M_AXI_GP0_WVALID(processing_system7_0_M_AXI_GP0_WVALID),
        .PS_CLK(FIXED_IO_0_ps_clk),
        .PS_PORB(FIXED_IO_0_ps_porb),
        .PS_SRSTB(FIXED_IO_0_ps_srstb),
        .S_AXI_HP0_ACLK(pl_clk_out),
        .S_AXI_HP0_ARADDR(tinyyolo_accel_0_m_axi_ARADDR),
        .S_AXI_HP0_ARBURST(tinyyolo_accel_0_m_axi_ARBURST),
        .S_AXI_HP0_ARCACHE(tinyyolo_accel_0_m_axi_ARCACHE),
        .S_AXI_HP0_ARID(tinyyolo_accel_0_m_axi_ARID),
        .S_AXI_HP0_ARLEN(tinyyolo_accel_0_m_axi_ARLEN),
        .S_AXI_HP0_ARLOCK(tinyyolo_accel_0_m_axi_ARLOCK),
        .S_AXI_HP0_ARPROT(tinyyolo_accel_0_m_axi_ARPROT),
        .S_AXI_HP0_ARQOS(tinyyolo_accel_0_m_axi_ARQOS),
        .S_AXI_HP0_ARREADY(tinyyolo_accel_0_m_axi_ARREADY),
        .S_AXI_HP0_ARSIZE(tinyyolo_accel_0_m_axi_ARSIZE),
        .S_AXI_HP0_ARVALID(tinyyolo_accel_0_m_axi_ARVALID),
        .S_AXI_HP0_AWADDR(tinyyolo_accel_0_m_axi_AWADDR),
        .S_AXI_HP0_AWBURST(tinyyolo_accel_0_m_axi_AWBURST),
        .S_AXI_HP0_AWCACHE(tinyyolo_accel_0_m_axi_AWCACHE),
        .S_AXI_HP0_AWID(tinyyolo_accel_0_m_axi_AWID),
        .S_AXI_HP0_AWLEN(tinyyolo_accel_0_m_axi_AWLEN),
        .S_AXI_HP0_AWLOCK(tinyyolo_accel_0_m_axi_AWLOCK),
        .S_AXI_HP0_AWPROT(tinyyolo_accel_0_m_axi_AWPROT),
        .S_AXI_HP0_AWQOS(tinyyolo_accel_0_m_axi_AWQOS),
        .S_AXI_HP0_AWREADY(tinyyolo_accel_0_m_axi_AWREADY),
        .S_AXI_HP0_AWSIZE(tinyyolo_accel_0_m_axi_AWSIZE),
        .S_AXI_HP0_AWVALID(tinyyolo_accel_0_m_axi_AWVALID),
        .S_AXI_HP0_BID(tinyyolo_accel_0_m_axi_BID),
        .S_AXI_HP0_BREADY(tinyyolo_accel_0_m_axi_BREADY),
        .S_AXI_HP0_BRESP(tinyyolo_accel_0_m_axi_BRESP),
        .S_AXI_HP0_BVALID(tinyyolo_accel_0_m_axi_BVALID),
        .S_AXI_HP0_RDATA(tinyyolo_accel_0_m_axi_RDATA),
        .S_AXI_HP0_RDISSUECAP1_EN(reset_zero_dout),
        .S_AXI_HP0_RID(tinyyolo_accel_0_m_axi_RID),
        .S_AXI_HP0_RLAST(tinyyolo_accel_0_m_axi_RLAST),
        .S_AXI_HP0_RREADY(tinyyolo_accel_0_m_axi_RREADY),
        .S_AXI_HP0_RRESP(tinyyolo_accel_0_m_axi_RRESP),
        .S_AXI_HP0_RVALID(tinyyolo_accel_0_m_axi_RVALID),
        .S_AXI_HP0_WDATA(tinyyolo_accel_0_m_axi_WDATA),
        .S_AXI_HP0_WID(tinyyolo_accel_0_m_axi_WID),
        .S_AXI_HP0_WLAST(tinyyolo_accel_0_m_axi_WLAST),
        .S_AXI_HP0_WREADY(tinyyolo_accel_0_m_axi_WREADY),
        .S_AXI_HP0_WRISSUECAP1_EN(reset_zero_dout),
        .S_AXI_HP0_WSTRB(tinyyolo_accel_0_m_axi_WSTRB),
        .S_AXI_HP0_WVALID(tinyyolo_accel_0_m_axi_WVALID),
        .UART0_RX(UART_0_rxd),
        .UART0_TX(UART_0_txd),
        .USB0_VBUS_PWRFAULT(1'b0));
  Tiny_Yolo_ps_ctrl_reset_0 ps_ctrl_reset
       (.aux_reset_in(reset_zero_dout),
        .dcm_locked(pl_clk_locked),
        .ext_reset_in(processing_system7_0_FCLK_RESET0_N),
        .interconnect_aresetn(ps_ctrl_reset_interconnect_aresetn),
        .mb_debug_sys_rst(reset_zero_dout),
        .slowest_sync_clk(processing_system7_0_FCLK_CLK0));
  assign reset_zero_dout = 1'h0;
  Tiny_Yolo_smartconnect_0_0 smartconnect_0
       (.M00_AXI_araddr(smartconnect_0_M00_AXI_ARADDR),
        .M00_AXI_arready(smartconnect_0_M00_AXI_ARREADY),
        .M00_AXI_arvalid(smartconnect_0_M00_AXI_ARVALID),
        .M00_AXI_awaddr(smartconnect_0_M00_AXI_AWADDR),
        .M00_AXI_awready(smartconnect_0_M00_AXI_AWREADY),
        .M00_AXI_awvalid(smartconnect_0_M00_AXI_AWVALID),
        .M00_AXI_bready(smartconnect_0_M00_AXI_BREADY),
        .M00_AXI_bresp(smartconnect_0_M00_AXI_BRESP),
        .M00_AXI_bvalid(smartconnect_0_M00_AXI_BVALID),
        .M00_AXI_rdata(smartconnect_0_M00_AXI_RDATA),
        .M00_AXI_rready(smartconnect_0_M00_AXI_RREADY),
        .M00_AXI_rresp(smartconnect_0_M00_AXI_RRESP),
        .M00_AXI_rvalid(smartconnect_0_M00_AXI_RVALID),
        .M00_AXI_wdata(smartconnect_0_M00_AXI_WDATA),
        .M00_AXI_wready(smartconnect_0_M00_AXI_WREADY),
        .M00_AXI_wstrb(smartconnect_0_M00_AXI_WSTRB),
        .M00_AXI_wvalid(smartconnect_0_M00_AXI_WVALID),
        .S00_AXI_araddr(processing_system7_0_M_AXI_GP0_ARADDR),
        .S00_AXI_arburst(processing_system7_0_M_AXI_GP0_ARBURST),
        .S00_AXI_arcache(processing_system7_0_M_AXI_GP0_ARCACHE),
        .S00_AXI_arid(processing_system7_0_M_AXI_GP0_ARID),
        .S00_AXI_arlen(processing_system7_0_M_AXI_GP0_ARLEN),
        .S00_AXI_arlock(processing_system7_0_M_AXI_GP0_ARLOCK),
        .S00_AXI_arprot(processing_system7_0_M_AXI_GP0_ARPROT),
        .S00_AXI_arqos(processing_system7_0_M_AXI_GP0_ARQOS),
        .S00_AXI_arready(processing_system7_0_M_AXI_GP0_ARREADY),
        .S00_AXI_arsize(processing_system7_0_M_AXI_GP0_ARSIZE),
        .S00_AXI_arvalid(processing_system7_0_M_AXI_GP0_ARVALID),
        .S00_AXI_awaddr(processing_system7_0_M_AXI_GP0_AWADDR),
        .S00_AXI_awburst(processing_system7_0_M_AXI_GP0_AWBURST),
        .S00_AXI_awcache(processing_system7_0_M_AXI_GP0_AWCACHE),
        .S00_AXI_awid(processing_system7_0_M_AXI_GP0_AWID),
        .S00_AXI_awlen(processing_system7_0_M_AXI_GP0_AWLEN),
        .S00_AXI_awlock(processing_system7_0_M_AXI_GP0_AWLOCK),
        .S00_AXI_awprot(processing_system7_0_M_AXI_GP0_AWPROT),
        .S00_AXI_awqos(processing_system7_0_M_AXI_GP0_AWQOS),
        .S00_AXI_awready(processing_system7_0_M_AXI_GP0_AWREADY),
        .S00_AXI_awsize(processing_system7_0_M_AXI_GP0_AWSIZE),
        .S00_AXI_awvalid(processing_system7_0_M_AXI_GP0_AWVALID),
        .S00_AXI_bid(processing_system7_0_M_AXI_GP0_BID),
        .S00_AXI_bready(processing_system7_0_M_AXI_GP0_BREADY),
        .S00_AXI_bresp(processing_system7_0_M_AXI_GP0_BRESP),
        .S00_AXI_bvalid(processing_system7_0_M_AXI_GP0_BVALID),
        .S00_AXI_rdata(processing_system7_0_M_AXI_GP0_RDATA),
        .S00_AXI_rid(processing_system7_0_M_AXI_GP0_RID),
        .S00_AXI_rlast(processing_system7_0_M_AXI_GP0_RLAST),
        .S00_AXI_rready(processing_system7_0_M_AXI_GP0_RREADY),
        .S00_AXI_rresp(processing_system7_0_M_AXI_GP0_RRESP),
        .S00_AXI_rvalid(processing_system7_0_M_AXI_GP0_RVALID),
        .S00_AXI_wdata(processing_system7_0_M_AXI_GP0_WDATA),
        .S00_AXI_wid(processing_system7_0_M_AXI_GP0_WID),
        .S00_AXI_wlast(processing_system7_0_M_AXI_GP0_WLAST),
        .S00_AXI_wready(processing_system7_0_M_AXI_GP0_WREADY),
        .S00_AXI_wstrb(processing_system7_0_M_AXI_GP0_WSTRB),
        .S00_AXI_wvalid(processing_system7_0_M_AXI_GP0_WVALID),
        .aclk(processing_system7_0_FCLK_CLK0),
        .aclk1(pl_clk_out),
        .aresetn(ps_ctrl_reset_interconnect_aresetn));
  Tiny_Yolo_tinyyolo_accel_0_0 tinyyolo_accel_0
       (.m_axi_araddr(tinyyolo_accel_0_m_axi_ARADDR),
        .m_axi_arburst(tinyyolo_accel_0_m_axi_ARBURST),
        .m_axi_arcache(tinyyolo_accel_0_m_axi_ARCACHE),
        .m_axi_arid(tinyyolo_accel_0_m_axi_ARID),
        .m_axi_arlen(tinyyolo_accel_0_m_axi_ARLEN),
        .m_axi_arlock(tinyyolo_accel_0_m_axi_ARLOCK),
        .m_axi_arprot(tinyyolo_accel_0_m_axi_ARPROT),
        .m_axi_arqos(tinyyolo_accel_0_m_axi_ARQOS),
        .m_axi_arready(tinyyolo_accel_0_m_axi_ARREADY),
        .m_axi_arsize(tinyyolo_accel_0_m_axi_ARSIZE),
        .m_axi_arvalid(tinyyolo_accel_0_m_axi_ARVALID),
        .m_axi_awaddr(tinyyolo_accel_0_m_axi_AWADDR),
        .m_axi_awburst(tinyyolo_accel_0_m_axi_AWBURST),
        .m_axi_awcache(tinyyolo_accel_0_m_axi_AWCACHE),
        .m_axi_awid(tinyyolo_accel_0_m_axi_AWID),
        .m_axi_awlen(tinyyolo_accel_0_m_axi_AWLEN),
        .m_axi_awlock(tinyyolo_accel_0_m_axi_AWLOCK),
        .m_axi_awprot(tinyyolo_accel_0_m_axi_AWPROT),
        .m_axi_awqos(tinyyolo_accel_0_m_axi_AWQOS),
        .m_axi_awready(tinyyolo_accel_0_m_axi_AWREADY),
        .m_axi_awsize(tinyyolo_accel_0_m_axi_AWSIZE),
        .m_axi_awvalid(tinyyolo_accel_0_m_axi_AWVALID),
        .m_axi_bid(tinyyolo_accel_0_m_axi_BID),
        .m_axi_bready(tinyyolo_accel_0_m_axi_BREADY),
        .m_axi_bresp(tinyyolo_accel_0_m_axi_BRESP),
        .m_axi_bvalid(tinyyolo_accel_0_m_axi_BVALID),
        .m_axi_rdata(tinyyolo_accel_0_m_axi_RDATA),
        .m_axi_rid(tinyyolo_accel_0_m_axi_RID),
        .m_axi_rlast(tinyyolo_accel_0_m_axi_RLAST),
        .m_axi_rready(tinyyolo_accel_0_m_axi_RREADY),
        .m_axi_rresp(tinyyolo_accel_0_m_axi_RRESP),
        .m_axi_rvalid(tinyyolo_accel_0_m_axi_RVALID),
        .m_axi_wdata(tinyyolo_accel_0_m_axi_WDATA),
        .m_axi_wid(tinyyolo_accel_0_m_axi_WID),
        .m_axi_wlast(tinyyolo_accel_0_m_axi_WLAST),
        .m_axi_wready(tinyyolo_accel_0_m_axi_WREADY),
        .m_axi_wstrb(tinyyolo_accel_0_m_axi_WSTRB),
        .m_axi_wvalid(tinyyolo_accel_0_m_axi_WVALID),
        .s00_axi_aclk(pl_clk_out),
        .s00_axi_araddr(smartconnect_0_M00_AXI_ARADDR),
        .s00_axi_aresetn(proc_sys_reset_0_peripheral_aresetn),
        .s00_axi_arready(smartconnect_0_M00_AXI_ARREADY),
        .s00_axi_arvalid(smartconnect_0_M00_AXI_ARVALID),
        .s00_axi_awaddr(smartconnect_0_M00_AXI_AWADDR),
        .s00_axi_awready(smartconnect_0_M00_AXI_AWREADY),
        .s00_axi_awvalid(smartconnect_0_M00_AXI_AWVALID),
        .s00_axi_bready(smartconnect_0_M00_AXI_BREADY),
        .s00_axi_bresp(smartconnect_0_M00_AXI_BRESP),
        .s00_axi_bvalid(smartconnect_0_M00_AXI_BVALID),
        .s00_axi_rdata(smartconnect_0_M00_AXI_RDATA),
        .s00_axi_rready(smartconnect_0_M00_AXI_RREADY),
        .s00_axi_rresp(smartconnect_0_M00_AXI_RRESP),
        .s00_axi_rvalid(smartconnect_0_M00_AXI_RVALID),
        .s00_axi_wdata(smartconnect_0_M00_AXI_WDATA),
        .s00_axi_wready(smartconnect_0_M00_AXI_WREADY),
        .s00_axi_wstrb(smartconnect_0_M00_AXI_WSTRB),
        .s00_axi_wvalid(smartconnect_0_M00_AXI_WVALID));
endmodule
