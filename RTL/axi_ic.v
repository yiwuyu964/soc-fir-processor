// ============================================================
// axi_ic.v —— AXI4 互连（2 主 5 从交叉开关 + 5 通道仲裁）
//
// 阶段2 分工 A 的核心交付物。
//
// 【契约依据】docs/任务4-模块接口信号清单.md 1.3 节（端口/主从角色）
//             docs/任务3-地址映射与中断分配.md 3.1/3.2 节（地址表）
//             阶段2-三人分工.md §2.2 / §2.3（地址、主设备 ID）
//
// 【拓扑】
//   从口（主设备侧）：s0 = CPU 经 AHB→AXI 桥（AXI ID=0）
//                     s1 = DMA 数据口（AXI ID=1）
//   主口（从设备侧）：m0 = FIR       @0x4000_0000  4KB
//                     m1 = DMA 配置  @0x4000_1000  4KB
//                     m2 = （阶段4 方案 B 不用，留空）
//                     m3 = 片内 SRAM @0x0000_0000 64KB
//                     m4 = AXI→APB   @0x4000_2000 64KB
//
//   ⚠️ 主口编号 ≠ 地址顺序：f_decode 里 a[31:16]==16'h0000 → 3'd3（**m3**）、
//      a[31:16]==16'h2000 → 3'd2（m2）。阶段4 采用方案 B（片内 SRAM @0x0、不做 ROM），
//      所以 **SRAM 必须接 m3_axi_\***，m2 留空（若悬空请接静态无效值）。
//      详见 docs/阶段4-三人分工.md §1「地址映射」、RTL/axi_sram.v 头注释。
//
// 【仲裁策略】
//   · AW / AR：每从设备一个 round-robin 仲裁器（2 主）
//   · W      ：跟随 AW 授权（写数据必须跟地址授权走，否则数据错乱）
//   · B / R  ：每主设备一个 round-robin 仲裁器（5 从），按 BID/RID 回选主设备
//   · 每主设备同时最多 1 笔未完成写（m_w_busy 门控），避免单主多从时 W 数据错乱
//   · 无死锁：依赖全是"主 → 从"单向，B/R 回选只看 ID，不引入"从等主"回路
//
// 【未映射地址】dec=5 → 内部默认错误从设备（第 6 节），回 DECERR，不挂死。
// ============================================================
`timescale 1ns/1ps

module axi_ic #(
    parameter DATA_W   = 32,
    parameter ADDR_W   = 32,
    parameter ID_W     = 4,
    parameter N_MASTER = 2,            // 从口数量（主设备数）
    parameter N_SLAVE  = 5,            // 主口数量（从设备数）
    parameter M2_RESERVED = 0          // SoC leaves m2 unconnected: use DECERR
)(
    input  wire clk,
    input  wire rst_n,

    // ============ 从口 0（CPU / 桥，AXI ID=0）============
    input  wire [ID_W-1:0]     s0_axi_awid,
    input  wire [ADDR_W-1:0]   s0_axi_awaddr,
    input  wire [7:0]          s0_axi_awlen,
    input  wire [2:0]          s0_axi_awsize,
    input  wire [1:0]          s0_axi_awburst,
    input  wire                s0_axi_awvalid,
    output wire                s0_axi_awready,
    input  wire [DATA_W-1:0]   s0_axi_wdata,
    input  wire [DATA_W/8-1:0] s0_axi_wstrb,
    input  wire                s0_axi_wlast,
    input  wire                s0_axi_wvalid,
    output wire                s0_axi_wready,
    output wire [ID_W-1:0]     s0_axi_bid,
    output wire [1:0]          s0_axi_bresp,
    output wire                s0_axi_bvalid,
    input  wire                s0_axi_bready,
    input  wire [ID_W-1:0]     s0_axi_arid,
    input  wire [ADDR_W-1:0]   s0_axi_araddr,
    input  wire [7:0]          s0_axi_arlen,
    input  wire [2:0]          s0_axi_arsize,
    input  wire [1:0]          s0_axi_arburst,
    input  wire                s0_axi_arvalid,
    output wire                s0_axi_arready,
    output wire [ID_W-1:0]     s0_axi_rid,
    output wire [DATA_W-1:0]   s0_axi_rdata,
    output wire [1:0]          s0_axi_rresp,
    output wire                s0_axi_rlast,
    output wire                s0_axi_rvalid,
    input  wire                s0_axi_rready,

    // ============ 从口 1（DMA 数据口，AXI ID=1）============
    input  wire [ID_W-1:0]     s1_axi_awid,
    input  wire [ADDR_W-1:0]   s1_axi_awaddr,
    input  wire [7:0]          s1_axi_awlen,
    input  wire [2:0]          s1_axi_awsize,
    input  wire [1:0]          s1_axi_awburst,
    input  wire                s1_axi_awvalid,
    output wire                s1_axi_awready,
    input  wire [DATA_W-1:0]   s1_axi_wdata,
    input  wire [DATA_W/8-1:0] s1_axi_wstrb,
    input  wire                s1_axi_wlast,
    input  wire                s1_axi_wvalid,
    output wire                s1_axi_wready,
    output wire [ID_W-1:0]     s1_axi_bid,
    output wire [1:0]          s1_axi_bresp,
    output wire                s1_axi_bvalid,
    input  wire                s1_axi_bready,
    input  wire [ID_W-1:0]     s1_axi_arid,
    input  wire [ADDR_W-1:0]   s1_axi_araddr,
    input  wire [7:0]          s1_axi_arlen,
    input  wire [2:0]          s1_axi_arsize,
    input  wire [1:0]          s1_axi_arburst,
    input  wire                s1_axi_arvalid,
    output wire                s1_axi_arready,
    output wire [ID_W-1:0]     s1_axi_rid,
    output wire [DATA_W-1:0]   s1_axi_rdata,
    output wire [1:0]          s1_axi_rresp,
    output wire                s1_axi_rlast,
    output wire                s1_axi_rvalid,
    input  wire                s1_axi_rready,

    // ============ 主口 0（FIR）============
    output wire [ID_W-1:0]     m0_axi_awid,
    output wire [ADDR_W-1:0]   m0_axi_awaddr,
    output wire [7:0]          m0_axi_awlen,
    output wire [2:0]          m0_axi_awsize,
    output wire [1:0]          m0_axi_awburst,
    output wire                m0_axi_awvalid,
    input  wire                m0_axi_awready,
    output wire [DATA_W-1:0]   m0_axi_wdata,
    output wire [DATA_W/8-1:0] m0_axi_wstrb,
    output wire                m0_axi_wlast,
    output wire                m0_axi_wvalid,
    input  wire                m0_axi_wready,
    input  wire [ID_W-1:0]     m0_axi_bid,
    input  wire [1:0]          m0_axi_bresp,
    input  wire                m0_axi_bvalid,
    output wire                m0_axi_bready,
    output wire [ID_W-1:0]     m0_axi_arid,
    output wire [ADDR_W-1:0]   m0_axi_araddr,
    output wire [7:0]          m0_axi_arlen,
    output wire [2:0]          m0_axi_arsize,
    output wire [1:0]          m0_axi_arburst,
    output wire                m0_axi_arvalid,
    input  wire                m0_axi_arready,
    input  wire [ID_W-1:0]     m0_axi_rid,
    input  wire [DATA_W-1:0]   m0_axi_rdata,
    input  wire [1:0]          m0_axi_rresp,
    input  wire                m0_axi_rlast,
    input  wire                m0_axi_rvalid,
    output wire                m0_axi_rready,

    // ============ 主口 1（DMA 配置）============
    output wire [ID_W-1:0]     m1_axi_awid,
    output wire [ADDR_W-1:0]   m1_axi_awaddr,
    output wire [7:0]          m1_axi_awlen,
    output wire [2:0]          m1_axi_awsize,
    output wire [1:0]          m1_axi_awburst,
    output wire                m1_axi_awvalid,
    input  wire                m1_axi_awready,
    output wire [DATA_W-1:0]   m1_axi_wdata,
    output wire [DATA_W/8-1:0] m1_axi_wstrb,
    output wire                m1_axi_wlast,
    output wire                m1_axi_wvalid,
    input  wire                m1_axi_wready,
    input  wire [ID_W-1:0]     m1_axi_bid,
    input  wire [1:0]          m1_axi_bresp,
    input  wire                m1_axi_bvalid,
    output wire                m1_axi_bready,
    output wire [ID_W-1:0]     m1_axi_arid,
    output wire [ADDR_W-1:0]   m1_axi_araddr,
    output wire [7:0]          m1_axi_arlen,
    output wire [2:0]          m1_axi_arsize,
    output wire [1:0]          m1_axi_arburst,
    output wire                m1_axi_arvalid,
    input  wire                m1_axi_arready,
    input  wire [ID_W-1:0]     m1_axi_rid,
    input  wire [DATA_W-1:0]   m1_axi_rdata,
    input  wire [1:0]          m1_axi_rresp,
    input  wire                m1_axi_rlast,
    input  wire                m1_axi_rvalid,
    output wire                m1_axi_rready,

    // ============ 主口 2（0x2000_0000，阶段4 方案 B 留空）============
    output wire [ID_W-1:0]     m2_axi_awid,
    output wire [ADDR_W-1:0]   m2_axi_awaddr,
    output wire [7:0]          m2_axi_awlen,
    output wire [2:0]          m2_axi_awsize,
    output wire [1:0]          m2_axi_awburst,
    output wire                m2_axi_awvalid,
    input  wire                m2_axi_awready,
    output wire [DATA_W-1:0]   m2_axi_wdata,
    output wire [DATA_W/8-1:0] m2_axi_wstrb,
    output wire                m2_axi_wlast,
    output wire                m2_axi_wvalid,
    input  wire                m2_axi_wready,
    input  wire [ID_W-1:0]     m2_axi_bid,
    input  wire [1:0]          m2_axi_bresp,
    input  wire                m2_axi_bvalid,
    output wire                m2_axi_bready,
    output wire [ID_W-1:0]     m2_axi_arid,
    output wire [ADDR_W-1:0]   m2_axi_araddr,
    output wire [7:0]          m2_axi_arlen,
    output wire [2:0]          m2_axi_arsize,
    output wire [1:0]          m2_axi_arburst,
    output wire                m2_axi_arvalid,
    input  wire                m2_axi_arready,
    input  wire [ID_W-1:0]     m2_axi_rid,
    input  wire [DATA_W-1:0]   m2_axi_rdata,
    input  wire [1:0]          m2_axi_rresp,
    input  wire                m2_axi_rlast,
    input  wire                m2_axi_rvalid,
    output wire                m2_axi_rready,

    // ============ 主口 3（0x0000_0000，阶段4 方案 B 接片内 SRAM）============
    output wire [ID_W-1:0]     m3_axi_awid,
    output wire [ADDR_W-1:0]   m3_axi_awaddr,
    output wire [7:0]          m3_axi_awlen,
    output wire [2:0]          m3_axi_awsize,
    output wire [1:0]          m3_axi_awburst,
    output wire                m3_axi_awvalid,
    input  wire                m3_axi_awready,
    output wire [DATA_W-1:0]   m3_axi_wdata,
    output wire [DATA_W/8-1:0] m3_axi_wstrb,
    output wire                m3_axi_wlast,
    output wire                m3_axi_wvalid,
    input  wire                m3_axi_wready,
    input  wire [ID_W-1:0]     m3_axi_bid,
    input  wire [1:0]          m3_axi_bresp,
    input  wire                m3_axi_bvalid,
    output wire                m3_axi_bready,
    output wire [ID_W-1:0]     m3_axi_arid,
    output wire [ADDR_W-1:0]   m3_axi_araddr,
    output wire [7:0]          m3_axi_arlen,
    output wire [2:0]          m3_axi_arsize,
    output wire [1:0]          m3_axi_arburst,
    output wire                m3_axi_arvalid,
    input  wire                m3_axi_arready,
    input  wire [ID_W-1:0]     m3_axi_rid,
    input  wire [DATA_W-1:0]   m3_axi_rdata,
    input  wire [1:0]          m3_axi_rresp,
    input  wire                m3_axi_rlast,
    input  wire                m3_axi_rvalid,
    output wire                m3_axi_rready,

    // ============ 主口 4（AXI→APB 桥）============
    output wire [ID_W-1:0]     m4_axi_awid,
    output wire [ADDR_W-1:0]   m4_axi_awaddr,
    output wire [7:0]          m4_axi_awlen,
    output wire [2:0]          m4_axi_awsize,
    output wire [1:0]          m4_axi_awburst,
    output wire                m4_axi_awvalid,
    input  wire                m4_axi_awready,
    output wire [DATA_W-1:0]   m4_axi_wdata,
    output wire [DATA_W/8-1:0] m4_axi_wstrb,
    output wire                m4_axi_wlast,
    output wire                m4_axi_wvalid,
    input  wire                m4_axi_wready,
    input  wire [ID_W-1:0]     m4_axi_bid,
    input  wire [1:0]          m4_axi_bresp,
    input  wire                m4_axi_bvalid,
    output wire                m4_axi_bready,
    output wire [ID_W-1:0]     m4_axi_arid,
    output wire [ADDR_W-1:0]   m4_axi_araddr,
    output wire [7:0]          m4_axi_arlen,
    output wire [2:0]          m4_axi_arsize,
    output wire [1:0]          m4_axi_arburst,
    output wire                m4_axi_arvalid,
    input  wire                m4_axi_arready,
    input  wire [ID_W-1:0]     m4_axi_rid,
    input  wire [DATA_W-1:0]   m4_axi_rdata,
    input  wire [1:0]          m4_axi_rresp,
    input  wire                m4_axi_rlast,
    input  wire                m4_axi_rvalid,
    output wire                m4_axi_rready
);

    // 总从设备数 = 5 个外部从设备 + 1 个内部默认错误从设备（未映射地址 → SLVERR）
    localparam N_SL = N_SLAVE + 1;

    // ============================================================
    // 0. 端口 → 内部数组
    // ============================================================
    wire [N_MASTER-1:0][ID_W-1:0]     s_awid, s_arid, s_bid, s_rid;
    wire [N_MASTER-1:0][ADDR_W-1:0]   s_awaddr, s_araddr;
    wire [N_MASTER-1:0][7:0]          s_awlen, s_arlen;
    wire [N_MASTER-1:0][2:0]          s_awsize, s_arsize;
    wire [N_MASTER-1:0][1:0]          s_awburst, s_arburst, s_bresp, s_rresp;
    wire [N_MASTER-1:0]               s_awvalid, s_awready, s_arvalid, s_arready;
    wire [N_MASTER-1:0][DATA_W-1:0]   s_wdata, s_rdata;
    wire [N_MASTER-1:0][DATA_W/8-1:0] s_wstrb;
    wire [N_MASTER-1:0]               s_wlast, s_wvalid, s_wready;
    wire [N_MASTER-1:0]               s_bvalid, s_bready;
    wire [N_MASTER-1:0]               s_rlast, s_rvalid, s_rready;

    wire [N_SL-1:0][ID_W-1:0]      m_awid, m_arid, m_bid, m_rid;
    wire [N_SL-1:0][ADDR_W-1:0]    m_awaddr, m_araddr;
    wire [N_SL-1:0][7:0]           m_awlen, m_arlen;
    wire [N_SL-1:0][2:0]           m_awsize, m_arsize;
    wire [N_SL-1:0][1:0]           m_awburst, m_arburst, m_bresp, m_rresp;
    wire [N_SL-1:0]                m_awvalid, m_awready, m_arvalid, m_arready;
    wire [N_SL-1:0][DATA_W-1:0]    m_wdata, m_rdata;
    wire [N_SL-1:0][DATA_W/8-1:0]  m_wstrb;
    wire [N_SL-1:0]                m_wlast, m_wvalid, m_wready;
    wire [N_SL-1:0]                m_bvalid, m_bready;
    wire [N_SL-1:0]                m_rlast, m_rvalid, m_rready;

    // ---- 从口 → 数组 ----
    assign s_awid    = {s1_axi_awid,    s0_axi_awid};
    assign s_awaddr  = {s1_axi_awaddr,  s0_axi_awaddr};
    assign s_awlen   = {s1_axi_awlen,   s0_axi_awlen};
    assign s_awsize  = {s1_axi_awsize,  s0_axi_awsize};
    assign s_awburst = {s1_axi_awburst, s0_axi_awburst};
    assign s_awvalid = {s1_axi_awvalid, s0_axi_awvalid};
    assign s_wdata   = {s1_axi_wdata,   s0_axi_wdata};
    assign s_wstrb   = {s1_axi_wstrb,   s0_axi_wstrb};
    assign s_wlast   = {s1_axi_wlast,   s0_axi_wlast};
    assign s_wvalid  = {s1_axi_wvalid,  s0_axi_wvalid};
    assign s_bready  = {s1_axi_bready,  s0_axi_bready};
    assign s_arid    = {s1_axi_arid,    s0_axi_arid};
    assign s_araddr  = {s1_axi_araddr,  s0_axi_araddr};
    assign s_arlen   = {s1_axi_arlen,   s0_axi_arlen};
    assign s_arsize  = {s1_axi_arsize,  s0_axi_arsize};
    assign s_arburst = {s1_axi_arburst, s0_axi_arburst};
    assign s_arvalid = {s1_axi_arvalid, s0_axi_arvalid};
    assign s_rready  = {s1_axi_rready,  s0_axi_rready};

    assign s0_axi_awready = s_awready[0];  assign s1_axi_awready = s_awready[1];
    assign s0_axi_wready  = s_wready[0];   assign s1_axi_wready  = s_wready[1];
    assign s0_axi_bid     = s_bid[0];      assign s1_axi_bid     = s_bid[1];
    assign s0_axi_bresp   = s_bresp[0];    assign s1_axi_bresp   = s_bresp[1];
    assign s0_axi_bvalid  = s_bvalid[0];   assign s1_axi_bvalid  = s_bvalid[1];
    assign s0_axi_arready = s_arready[0];  assign s1_axi_arready = s_arready[1];
    assign s0_axi_rid     = s_rid[0];      assign s1_axi_rid     = s_rid[1];
    assign s0_axi_rdata   = s_rdata[0];    assign s1_axi_rdata   = s_rdata[1];
    assign s0_axi_rresp   = s_rresp[0];    assign s1_axi_rresp   = s_rresp[1];
    assign s0_axi_rlast   = s_rlast[0];    assign s1_axi_rlast   = s_rlast[1];
    assign s0_axi_rvalid  = s_rvalid[0];   assign s1_axi_rvalid  = s_rvalid[1];

    // ---- 数组 → 主口 ----
    assign m0_axi_awid = m_awid[0];  assign m1_axi_awid = m_awid[1];  assign m2_axi_awid = m_awid[2];  assign m3_axi_awid = m_awid[3];  assign m4_axi_awid = m_awid[4];
    assign m0_axi_awaddr = m_awaddr[0]; assign m1_axi_awaddr = m_awaddr[1]; assign m2_axi_awaddr = m_awaddr[2]; assign m3_axi_awaddr = m_awaddr[3]; assign m4_axi_awaddr = m_awaddr[4];
    assign m0_axi_awlen = m_awlen[0]; assign m1_axi_awlen = m_awlen[1]; assign m2_axi_awlen = m_awlen[2]; assign m3_axi_awlen = m_awlen[3]; assign m4_axi_awlen = m_awlen[4];
    assign m0_axi_awsize = m_awsize[0]; assign m1_axi_awsize = m_awsize[1]; assign m2_axi_awsize = m_awsize[2]; assign m3_axi_awsize = m_awsize[3]; assign m4_axi_awsize = m_awsize[4];
    assign m0_axi_awburst = m_awburst[0]; assign m1_axi_awburst = m_awburst[1]; assign m2_axi_awburst = m_awburst[2]; assign m3_axi_awburst = m_awburst[3]; assign m4_axi_awburst = m_awburst[4];
    assign m0_axi_awvalid = m_awvalid[0]; assign m1_axi_awvalid = m_awvalid[1]; assign m2_axi_awvalid = m_awvalid[2]; assign m3_axi_awvalid = m_awvalid[3]; assign m4_axi_awvalid = m_awvalid[4];
    assign m0_axi_wdata = m_wdata[0]; assign m1_axi_wdata = m_wdata[1]; assign m2_axi_wdata = m_wdata[2]; assign m3_axi_wdata = m_wdata[3]; assign m4_axi_wdata = m_wdata[4];
    assign m0_axi_wstrb = m_wstrb[0]; assign m1_axi_wstrb = m_wstrb[1]; assign m2_axi_wstrb = m_wstrb[2]; assign m3_axi_wstrb = m_wstrb[3]; assign m4_axi_wstrb = m_wstrb[4];
    assign m0_axi_wlast = m_wlast[0]; assign m1_axi_wlast = m_wlast[1]; assign m2_axi_wlast = m_wlast[2]; assign m3_axi_wlast = m_wlast[3]; assign m4_axi_wlast = m_wlast[4];
    assign m0_axi_wvalid = m_wvalid[0]; assign m1_axi_wvalid = m_wvalid[1]; assign m2_axi_wvalid = m_wvalid[2]; assign m3_axi_wvalid = m_wvalid[3]; assign m4_axi_wvalid = m_wvalid[4];
    assign m0_axi_bready = m_bready[0]; assign m1_axi_bready = m_bready[1]; assign m2_axi_bready = m_bready[2]; assign m3_axi_bready = m_bready[3]; assign m4_axi_bready = m_bready[4];
    assign m0_axi_arid = m_arid[0]; assign m1_axi_arid = m_arid[1]; assign m2_axi_arid = m_arid[2]; assign m3_axi_arid = m_arid[3]; assign m4_axi_arid = m_arid[4];
    assign m0_axi_araddr = m_araddr[0]; assign m1_axi_araddr = m_araddr[1]; assign m2_axi_araddr = m_araddr[2]; assign m3_axi_araddr = m_araddr[3]; assign m4_axi_araddr = m_araddr[4];
    assign m0_axi_arlen = m_arlen[0]; assign m1_axi_arlen = m_arlen[1]; assign m2_axi_arlen = m_arlen[2]; assign m3_axi_arlen = m_arlen[3]; assign m4_axi_arlen = m_arlen[4];
    assign m0_axi_arsize = m_arsize[0]; assign m1_axi_arsize = m_arsize[1]; assign m2_axi_arsize = m_arsize[2]; assign m3_axi_arsize = m_arsize[3]; assign m4_axi_arsize = m_arsize[4];
    assign m0_axi_arburst = m_arburst[0]; assign m1_axi_arburst = m_arburst[1]; assign m2_axi_arburst = m_arburst[2]; assign m3_axi_arburst = m_arburst[3]; assign m4_axi_arburst = m_arburst[4];
    assign m0_axi_arvalid = m_arvalid[0]; assign m1_axi_arvalid = m_arvalid[1]; assign m2_axi_arvalid = m_arvalid[2]; assign m3_axi_arvalid = m_arvalid[3]; assign m4_axi_arvalid = m_arvalid[4];
    assign m0_axi_rready = m_rready[0]; assign m1_axi_rready = m_rready[1]; assign m2_axi_rready = m_rready[2]; assign m3_axi_rready = m_rready[3]; assign m4_axi_rready = m_rready[4];

    assign m_awready[0] = m0_axi_awready; assign m_awready[1] = m1_axi_awready; assign m_awready[2] = m2_axi_awready; assign m_awready[3] = m3_axi_awready; assign m_awready[4] = m4_axi_awready;
    assign m_wready[0] = m0_axi_wready; assign m_wready[1] = m1_axi_wready; assign m_wready[2] = m2_axi_wready; assign m_wready[3] = m3_axi_wready; assign m_wready[4] = m4_axi_wready;
    assign m_bid[0] = m0_axi_bid; assign m_bid[1] = m1_axi_bid; assign m_bid[2] = m2_axi_bid; assign m_bid[3] = m3_axi_bid; assign m_bid[4] = m4_axi_bid;
    assign m_bresp[0] = m0_axi_bresp; assign m_bresp[1] = m1_axi_bresp; assign m_bresp[2] = m2_axi_bresp; assign m_bresp[3] = m3_axi_bresp; assign m_bresp[4] = m4_axi_bresp;
    assign m_bvalid[0] = m0_axi_bvalid; assign m_bvalid[1] = m1_axi_bvalid; assign m_bvalid[2] = m2_axi_bvalid; assign m_bvalid[3] = m3_axi_bvalid; assign m_bvalid[4] = m4_axi_bvalid;
    assign m_arready[0] = m0_axi_arready; assign m_arready[1] = m1_axi_arready; assign m_arready[2] = m2_axi_arready; assign m_arready[3] = m3_axi_arready; assign m_arready[4] = m4_axi_arready;
    assign m_rid[0] = m0_axi_rid; assign m_rid[1] = m1_axi_rid; assign m_rid[2] = m2_axi_rid; assign m_rid[3] = m3_axi_rid; assign m_rid[4] = m4_axi_rid;
    assign m_rdata[0] = m0_axi_rdata; assign m_rdata[1] = m1_axi_rdata; assign m_rdata[2] = m2_axi_rdata; assign m_rdata[3] = m3_axi_rdata; assign m_rdata[4] = m4_axi_rdata;
    assign m_rresp[0] = m0_axi_rresp; assign m_rresp[1] = m1_axi_rresp; assign m_rresp[2] = m2_axi_rresp; assign m_rresp[3] = m3_axi_rresp; assign m_rresp[4] = m4_axi_rresp;
    assign m_rlast[0] = m0_axi_rlast; assign m_rlast[1] = m1_axi_rlast; assign m_rlast[2] = m2_axi_rlast; assign m_rlast[3] = m3_axi_rlast; assign m_rlast[4] = m4_axi_rlast;
    assign m_rvalid[0] = m0_axi_rvalid; assign m_rvalid[1] = m1_axi_rvalid; assign m_rvalid[2] = m2_axi_rvalid; assign m_rvalid[3] = m3_axi_rvalid; assign m_rvalid[4] = m4_axi_rvalid;

    // ============================================================
    // 1. 地址译码 → 从设备号 0~4，5=未映射
    // ============================================================
    function [2:0] f_decode;
        input [ADDR_W-1:0] a;
        begin
            if      (a[ADDR_W-1:16] == 16'h0000)                     f_decode = 3'd3;
            else if (a[ADDR_W-1:16] == 16'h2000)                     f_decode = M2_RESERVED ? 3'd5 : 3'd2;
            else if (a[ADDR_W-1:12] == 20'h40000)                    f_decode = 3'd0;
            else if (a[ADDR_W-1:12] == 20'h40001)                    f_decode = 3'd1;
            else if (a[ADDR_W-1:16] == 16'h4000 && a[15:12] >= 4'd2) f_decode = 3'd4;
            else if (a[ADDR_W-1:16] == 16'h4001 && a[15:12] <= 4'd1) f_decode = 3'd4;
            else                                                     f_decode = 3'd5;
        end
    endfunction

    wire [N_MASTER-1:0][2:0] dec_aw, dec_ar;
    genvar gi;
    generate
        for (gi = 0; gi < N_MASTER; gi = gi + 1) begin : g_dec
            assign dec_aw[gi] = f_decode(s_awaddr[gi]);
            assign dec_ar[gi] = f_decode(s_araddr[gi]);
        end
    endgenerate

    // ============================================================
    // 2. 写通道：AW 仲裁 + W 跟随 + 每主未完成写门控
    // ============================================================
    reg  [N_SL-1:0] w_active;   // 从设备有进行中的写突发
    reg  [N_SL-1:0] w_owner;    // 归属主设备号（1bit）

    reg  [N_MASTER-1:0] m_w_busy;  // 主设备有未完成写（单主单写，防 W 数据错乱）
    integer ii;

    always @* begin
        m_w_busy = {N_MASTER{1'b0}};
        for (ii = 0; ii < N_SL; ii = ii + 1) begin
            if (w_active[ii]) m_w_busy[w_owner[ii]] = 1'b1;
        end
    end

    wire [N_SL-1:0][N_MASTER-1:0] aw_req, aw_grant;
    wire [N_SL-1:0]               aw_hs, w_done;

    genvar s;
    generate
        for (s = 0; s < N_SL; s = s + 1) begin : g_wpath
            assign aw_req[s][0] = s_awvalid[0] && (dec_aw[0] == s) && !w_active[s] && !m_w_busy[0];
            assign aw_req[s][1] = s_awvalid[1] && (dec_aw[1] == s) && !w_active[s] && !m_w_busy[1];

            axi_arbiter #(.N(N_MASTER)) u_aw_arb (
                .clk(clk), .rst_n(rst_n),
                .req(aw_req[s]),
                .advance(aw_hs[s]),
                .grant(aw_grant[s])
            );

            assign m_awid[s]    = aw_grant[s][0] ? s_awid[0]    : s_awid[1];
            assign m_awaddr[s]  = aw_grant[s][0] ? s_awaddr[0]  : s_awaddr[1];
            assign m_awlen[s]   = aw_grant[s][0] ? s_awlen[0]   : s_awlen[1];
            assign m_awsize[s]  = aw_grant[s][0] ? s_awsize[0]  : s_awsize[1];
            assign m_awburst[s] = aw_grant[s][0] ? s_awburst[0] : s_awburst[1];
            // 无授权时 valid 必须为 0（一热 AND-OR，防止主 1 的 awvalid 泄漏到其它从设备）
            assign m_awvalid[s] = (aw_grant[s][0] & s_awvalid[0]) | (aw_grant[s][1] & s_awvalid[1]);

            assign aw_hs[s] = m_awvalid[s] && m_awready[s];

            assign m_wdata[s]  = w_owner[s] ? s_wdata[1]  : s_wdata[0];
            assign m_wstrb[s]  = w_owner[s] ? s_wstrb[1]  : s_wstrb[0];
            assign m_wlast[s]  = w_owner[s] ? s_wlast[1]  : s_wlast[0];
            assign m_wvalid[s] = w_active[s] && (w_owner[s] ? s_wvalid[1] : s_wvalid[0]);

            assign w_done[s] = m_wvalid[s] && m_wready[s] && m_wlast[s];

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    w_active[s] <= 1'b0;
                    w_owner[s]  <= 1'b0;
                end
                else if (aw_hs[s]) begin
                    w_active[s] <= 1'b1;
                    w_owner[s]  <= aw_grant[s][1];
                end
                else if (w_done[s]) begin
                    w_active[s] <= 1'b0;
                end
            end
        end
    endgenerate

    // AWREADY 回选：授权给哪个主，就把从设备的 AWREADY 给哪个主
    assign s_awready[0] = (aw_grant[0][0] & m_awready[0]) | (aw_grant[1][0] & m_awready[1]) |
                          (aw_grant[2][0] & m_awready[2]) | (aw_grant[3][0] & m_awready[3]) |
                          (aw_grant[4][0] & m_awready[4]) | (aw_grant[5][0] & m_awready[5]);
    assign s_awready[1] = (aw_grant[0][1] & m_awready[0]) | (aw_grant[1][1] & m_awready[1]) |
                          (aw_grant[2][1] & m_awready[2]) | (aw_grant[3][1] & m_awready[3]) |
                          (aw_grant[4][1] & m_awready[4]) | (aw_grant[5][1] & m_awready[5]);

    reg [N_MASTER-1:0] s_wready_comb;
    integer si;
    always @* begin
        s_wready_comb = {N_MASTER{1'b0}};
        for (si = 0; si < N_SL; si = si + 1) begin
            if (w_active[si] && !w_owner[si]) s_wready_comb[0] = s_wready_comb[0] | m_wready[si];
            if (w_active[si] &&  w_owner[si]) s_wready_comb[1] = s_wready_comb[1] | m_wready[si];
        end
    end
    assign s_wready = s_wready_comb;

    // ============================================================
    // 3. 写响应 B：每主设备 round-robin（5 从），按 BID 回选主
    // ============================================================
    wire [N_MASTER-1:0][N_SL-1:0] b_req, b_grant;
    wire [N_MASTER-1:0]               b_hs;

    genvar m;
    generate
        for (m = 0; m < N_MASTER; m = m + 1) begin : g_bpath
            for (s = 0; s < N_SL; s = s + 1) begin : g_b_req
                assign b_req[m][s] = m_bvalid[s] && (m_bid[s][0] == m[0]);
            end
            axi_arbiter #(.N(N_SL)) u_b_arb (
                .clk(clk), .rst_n(rst_n),
                .req(b_req[m]),
                .advance(b_hs[m]),
                .grant(b_grant[m])
            );
            assign b_hs[m] = (|(b_grant[m] & m_bvalid)) && s_bready[m];
            assign s_bid[m]   = ({ID_W{b_grant[m][0]}} & m_bid[0])
                              | ({ID_W{b_grant[m][1]}} & m_bid[1])
                              | ({ID_W{b_grant[m][2]}} & m_bid[2])
                              | ({ID_W{b_grant[m][3]}} & m_bid[3])
                              | ({ID_W{b_grant[m][4]}} & m_bid[4])
                              | ({ID_W{b_grant[m][5]}} & m_bid[5]);
            assign s_bresp[m] = ({2{b_grant[m][0]}} & m_bresp[0])
                              | ({2{b_grant[m][1]}} & m_bresp[1])
                              | ({2{b_grant[m][2]}} & m_bresp[2])
                              | ({2{b_grant[m][3]}} & m_bresp[3])
                              | ({2{b_grant[m][4]}} & m_bresp[4])
                              | ({2{b_grant[m][5]}} & m_bresp[5]);
            assign s_bvalid[m] = |(b_grant[m] & m_bvalid);
        end
    endgenerate

    reg [N_SL-1:0] m_bready_comb;
    always @* begin
        m_bready_comb = {N_SL{1'b0}};
        for (si = 0; si < N_SL; si = si + 1) begin
            m_bready_comb[si] = (b_grant[0][si] & s_bready[0]) | (b_grant[1][si] & s_bready[1]);
        end
    end
    assign m_bready = m_bready_comb;

    // ============================================================
    // 4. 读通道：AR 仲裁（每从设备，单拍）
    // ============================================================
    wire [N_SL-1:0][N_MASTER-1:0] ar_req, ar_grant;
    wire [N_SL-1:0]               ar_hs;

    generate
        for (s = 0; s < N_SL; s = s + 1) begin : g_rpath
            assign ar_req[s][0] = s_arvalid[0] && (dec_ar[0] == s);
            assign ar_req[s][1] = s_arvalid[1] && (dec_ar[1] == s);

            axi_arbiter #(.N(N_MASTER)) u_ar_arb (
                .clk(clk), .rst_n(rst_n),
                .req(ar_req[s]),
                .advance(ar_hs[s]),
                .grant(ar_grant[s])
            );

            assign m_arid[s]    = ar_grant[s][0] ? s_arid[0]    : s_arid[1];
            assign m_araddr[s]  = ar_grant[s][0] ? s_araddr[0]  : s_araddr[1];
            assign m_arlen[s]   = ar_grant[s][0] ? s_arlen[0]   : s_arlen[1];
            assign m_arsize[s]  = ar_grant[s][0] ? s_arsize[0]  : s_arsize[1];
            assign m_arburst[s] = ar_grant[s][0] ? s_arburst[0] : s_arburst[1];
            // 无授权时 valid 必须为 0
            assign m_arvalid[s] = (ar_grant[s][0] & s_arvalid[0]) | (ar_grant[s][1] & s_arvalid[1]);

            assign ar_hs[s] = m_arvalid[s] && m_arready[s];
        end
    endgenerate

    // ARREADY 回选
    assign s_arready[0] = (ar_grant[0][0] & m_arready[0]) | (ar_grant[1][0] & m_arready[1]) |
                          (ar_grant[2][0] & m_arready[2]) | (ar_grant[3][0] & m_arready[3]) |
                          (ar_grant[4][0] & m_arready[4]) | (ar_grant[5][0] & m_arready[5]);
    assign s_arready[1] = (ar_grant[0][1] & m_arready[0]) | (ar_grant[1][1] & m_arready[1]) |
                          (ar_grant[2][1] & m_arready[2]) | (ar_grant[3][1] & m_arready[3]) |
                          (ar_grant[4][1] & m_arready[4]) | (ar_grant[5][1] & m_arready[5]);

    // ============================================================
    // 5. 读数据 R：每主设备 round-robin（5 从），按 RID 回选主，
    //    授权保持到 RLAST（突发期间不换从）
    // ============================================================
    wire [N_MASTER-1:0][N_SL-1:0] r_req, r_grant_c, r_grant;
    wire [N_MASTER-1:0]               r_hs;
    reg  [N_MASTER-1:0]               r_busy;
    reg  [N_MASTER-1:0][N_SL-1:0]  r_sel;

    generate
        for (m = 0; m < N_MASTER; m = m + 1) begin : g_rrpath
            for (s = 0; s < N_SL; s = s + 1) begin : g_r_req
                assign r_req[m][s] = m_rvalid[s] && (m_rid[s][0] == m[0]) && !r_busy[m];
            end
            axi_arbiter #(.N(N_SL)) u_r_arb (
                .clk(clk), .rst_n(rst_n),
                .req(r_req[m]),
                .advance(r_hs[m]),
                .grant(r_grant_c[m])
            );
            // 有效授权：空闲时用仲裁结果，突发中锁定到 r_sel
            assign r_grant[m] = r_busy[m] ? r_sel[m] : r_grant_c[m];
            assign r_hs[m]    = (|(r_grant[m] & m_rvalid)) && s_rready[m];

            assign s_rid[m]   = ({ID_W{r_grant[m][0]}} & m_rid[0])
                              | ({ID_W{r_grant[m][1]}} & m_rid[1])
                              | ({ID_W{r_grant[m][2]}} & m_rid[2])
                              | ({ID_W{r_grant[m][3]}} & m_rid[3])
                              | ({ID_W{r_grant[m][4]}} & m_rid[4])
                              | ({ID_W{r_grant[m][5]}} & m_rid[5]);
            assign s_rdata[m] = ({DATA_W{r_grant[m][0]}} & m_rdata[0])
                              | ({DATA_W{r_grant[m][1]}} & m_rdata[1])
                              | ({DATA_W{r_grant[m][2]}} & m_rdata[2])
                              | ({DATA_W{r_grant[m][3]}} & m_rdata[3])
                              | ({DATA_W{r_grant[m][4]}} & m_rdata[4])
                              | ({DATA_W{r_grant[m][5]}} & m_rdata[5]);
            assign s_rresp[m] = ({2{r_grant[m][0]}} & m_rresp[0])
                              | ({2{r_grant[m][1]}} & m_rresp[1])
                              | ({2{r_grant[m][2]}} & m_rresp[2])
                              | ({2{r_grant[m][3]}} & m_rresp[3])
                              | ({2{r_grant[m][4]}} & m_rresp[4])
                              | ({2{r_grant[m][5]}} & m_rresp[5]);
            assign s_rlast[m] = |(r_grant[m] & m_rlast);
            assign s_rvalid[m] = |(r_grant[m] & m_rvalid);

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    r_busy[m] <= 1'b0;
                    r_sel[m]  <= {N_SL{1'b0}};
                end
                else if (r_hs[m] && !r_busy[m] && !s_rlast[m]) begin
                    // 多拍读突发：进入 busy，锁住从设备
                    r_busy[m] <= 1'b1;
                    r_sel[m]  <= r_grant_c[m];
                end
                else if (r_hs[m] && r_busy[m] && s_rlast[m]) begin
                    // 最后一拍（含单拍读）：退出 busy
                    r_busy[m] <= 1'b0;
                end
            end
        end
    endgenerate

    reg [N_SL-1:0] m_rready_comb;
    always @* begin
        m_rready_comb = {N_SL{1'b0}};
        for (si = 0; si < N_SL; si = si + 1) begin
            m_rready_comb[si] = (r_grant[0][si] & s_rready[0]) | (r_grant[1][si] & s_rready[1]);
        end
    end
    assign m_rready = m_rready_comb;

    // ============================================================
    // 6. 默认错误从设备（内部从设备 5）：未映射地址 → DECERR，不挂死
    // ============================================================
    localparam RESP_DECERR = 2'b11;     // AXI DECERR：地址未映射到任何从设备

    // ---- 写路径：收 AW、吸收 W、回 B(DECERR) ----
    reg          def_w_busy;
    reg [ID_W-1:0] def_w_id;
    reg [7:0]      def_w_beat, def_w_len;
    reg          def_bvalid;

    assign m_awready[5] = !def_w_busy && !def_bvalid;
    assign m_wready[5]  = def_w_busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            def_w_busy <= 1'b0;
            def_bvalid <= 1'b0;
            def_w_id   <= {ID_W{1'b0}};
            def_w_len  <= 8'd0;
            def_w_beat <= 8'd0;
        end
        else begin
            if (m_awvalid[5] && m_awready[5]) begin
                def_w_busy <= 1'b1;
                def_w_id   <= m_awid[5];
                def_w_len  <= m_awlen[5];
                def_w_beat <= 8'd0;
            end
            if (def_w_busy && m_wvalid[5] && m_wready[5]) begin
                if (m_wlast[5] || (def_w_beat == def_w_len)) begin
                    def_w_busy <= 1'b0;
                    def_bvalid <= 1'b1;
                end
                else def_w_beat <= def_w_beat + 8'd1;
            end
            if (def_bvalid && m_bready[5]) def_bvalid <= 1'b0;
        end
    end

    assign m_bid[5]    = def_w_id;
    assign m_bresp[5]  = RESP_DECERR;
    assign m_bvalid[5] = def_bvalid;

    // ---- 读路径：收 AR、回 R(DECERR) ----
    reg          def_r_busy;
    reg [ID_W-1:0] def_r_id;
    reg [7:0]      def_r_beat, def_r_len;

    assign m_arready[5] = !def_r_busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            def_r_busy <= 1'b0;
            def_r_id   <= {ID_W{1'b0}};
            def_r_len  <= 8'd0;
            def_r_beat <= 8'd0;
        end
        else begin
            if (m_arvalid[5] && m_arready[5]) begin
                def_r_busy <= 1'b1;
                def_r_id   <= m_arid[5];
                def_r_len  <= m_arlen[5];
                def_r_beat <= 8'd0;
            end
            if (def_r_busy && m_rvalid[5] && m_rready[5]) begin
                if (m_rlast[5]) def_r_busy <= 1'b0;
                else def_r_beat <= def_r_beat + 8'd1;
            end
        end
    end

    assign m_rid[5]    = def_r_id;
    assign m_rdata[5]  = {DATA_W{1'b0}};
    assign m_rresp[5]  = RESP_DECERR;
    assign m_rlast[5]  = (def_r_beat == def_r_len);
    assign m_rvalid[5] = def_r_busy;

endmodule
