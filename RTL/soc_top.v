// ============================================================
// soc_top.v —— SoC 顶层集成（阶段4 分工 A）
//
// ============================================================
// 【顶层契约】docs/契约S-soc顶层端口.md（端口/参数逐字一致）
//             docs/阶段4-三人分工.md §1（地址映射）
// ============================================================
//   把阶段 1~3 的模块 + 阶段 4 B 的 SRAM 拼成完整 SoC：
//
//     cortexm0ds_logic（AHB-Lite 核）
//            │ AHB-Lite
//     ahb2axi（RTL/ahb2axi.v）                    ← 主设备 ID = 0（契约C）
//            │ AXI4
//     axi_ic（RTL/axi_ic.v）+ axi_arbiter          ← 2 主 × 5 从
//       ├─ m0 → fir（RTL/fir.v）          @0x4000_0000
//       ├─ m1 → dma 配置口（RTL/dma.v）    @0x4000_1000
//       ├─ m2 → 未用（方案 B 留空，接静态无效值）
//       ├─ m3 → axi_sram（RTL/axi_sram.v）@0x0000_0000   ← 方案 B：程序+数据+栈
//       └─ m4 → axi_to_apb ──APB──► uart_apb @0x4000_2000
//     dma 数据口 → axi_ic.s1（主 ID = {CH[2:0], 1'b1}）
//
// ============================================================
// 【地址映射】（契约S §S.4，互连译码为准）
// ============================================================
//   0x0000_0000  64KB  片内 SRAM     → ic.m3
//   0x2000_0000  64KB  未用（tie-off）→ ic.m2
//   0x4000_0000   4KB  FIR           → ic.m0
//   0x4000_1000   4KB  DMA 配置口    → ic.m1
//   0x4000_2000  64KB  AXI→APB（UART）→ ic.m4
//
// ============================================================
// 【中断】（契约S §S.5 / 任务三 §5.2）
// ============================================================
//   IRQ0  FIR done    IRQ1  FIR err
//   IRQ2~7 DMA ch0~5 done   IRQ8 DMA err   （其余预留，恒 0）
//
// ============================================================
// 【时钟 / 复位】
// ============================================================
//   单一时钟域 clk。rst_n 低有效：**异步置位、同步释放**（内部两级同步后分发）。
//
// ============================================================
// 【SWD】
// ============================================================
//   本 IP（cortexm0ds_logic / cortexm0ds）不暴露 SWD 端口，顶层无调试脚。
// ============================================================
`timescale 1ns/1ps

module soc_top #(
    parameter ADDR_W     = 32,
    parameter DATA_W     = 32,
    parameter ID_W       = 4,
    parameter SRAM_BYTES = 65536,       // 片内 SRAM 大小（64KB）
    parameter CLK_FREQ   = 100_000_000, // 时钟频率（Hz），给 UART 算波特率
    parameter UART_DIV   = 10           // UART 分频：BAUD = CLK_FREQ / UART_DIV
)(
    input  wire clk,        // 单一时钟域
    input  wire rst_n,      // 低有效异步复位
    output wire uart_txd,   // UART 发送（对外引脚）
    input  wire uart_rxd    // UART 接收（对外引脚）
);

    localparam LEN_W = 8;   // AXI 突发长度位宽（与各子模块一致）

    // ============================================================
    // 0. 复位：异步置位、同步释放
    // ============================================================
    (* ASYNC_REG = "TRUE" *) reg [1:0] rst_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rst_sync <= 2'b00;
        else        rst_sync <= {rst_sync[0], 1'b1};
    end
    wire rst_n_sync = rst_sync[1];

    // ============================================================
    // 1. 线网声明（全部前置，避免"先用后声明"）
    // ============================================================
    // ---- CPU AHB-Lite ----
    wire [ADDR_W-1:0] h_haddr, h_hwdata, h_hrdata;
    wire [2:0]        h_hburst, h_hsize;
    wire [3:0]        h_hprot;
    wire [1:0]        h_htrans;
    wire              h_hwrite, h_hready, h_hresp, h_hmastlock;

    // ---- 中断 ----
    wire              fir_irq_done, fir_irq_err;
    wire [5:0]        dma_irq_done;
    wire              dma_irq_err;
    wire [31:0]       irq_lines;

    // ---- AXI：AHB→AXI 桥主口 → ic.s0（主设备 ID = 0，契约C）----
    wire [ID_W-1:0]      b_awid, b_arid;
    wire [ADDR_W-1:0]    b_awaddr, b_araddr;
    wire [LEN_W-1:0]     b_awlen, b_arlen;
    wire [2:0]           b_awsize, b_arsize;
    wire [1:0]           b_awburst, b_arburst;
    wire                 b_awvalid, b_awready, b_arvalid, b_arready;
    wire [DATA_W-1:0]    b_wdata;
    wire [DATA_W/8-1:0]  b_wstrb;
    wire                 b_wlast, b_wvalid, b_wready;
    wire [ID_W-1:0]      b_bid, b_rid;
    wire [1:0]           b_bresp, b_rresp;
    wire                 b_bvalid, b_bready, b_rlast, b_rvalid, b_rready;
    wire [DATA_W-1:0]    b_rdata;

    // ---- AXI：DMA 数据口 → ic.s1 ----
    wire [ID_W-1:0]      dm_awid, dm_arid;
    wire [ADDR_W-1:0]    dm_awaddr, dm_araddr;
    wire [LEN_W-1:0]     dm_awlen, dm_arlen;
    wire [2:0]           dm_awsize, dm_arsize;
    wire [1:0]           dm_awburst, dm_arburst;
    wire                 dm_awvalid, dm_awready, dm_arvalid, dm_arready;
    wire [DATA_W-1:0]    dm_wdata;
    wire [DATA_W/8-1:0]  dm_wstrb;
    wire                 dm_wlast, dm_wvalid, dm_wready;
    wire [ID_W-1:0]      dm_bid, dm_rid;
    wire [1:0]           dm_bresp, dm_rresp;
    wire                 dm_bvalid, dm_bready, dm_rlast, dm_rvalid, dm_rready;
    wire [DATA_W-1:0]    dm_rdata;

    // ---- AXI：ic.m0 → FIR ----
    wire [ID_W-1:0]      f_awid, f_arid;
    wire [ADDR_W-1:0]    f_awaddr, f_araddr;
    wire [LEN_W-1:0]     f_awlen, f_arlen;
    wire [2:0]           f_awsize, f_arsize;
    wire [1:0]           f_awburst, f_arburst;
    wire                 f_awvalid, f_awready, f_arvalid, f_arready;
    wire [DATA_W-1:0]    f_wdata;
    wire [DATA_W/8-1:0]  f_wstrb;
    wire                 f_wlast, f_wvalid, f_wready;
    wire [ID_W-1:0]      f_bid, f_rid;
    wire [1:0]           f_bresp, f_rresp;
    wire                 f_bvalid, f_bready, f_rlast, f_rvalid, f_rready;
    wire [DATA_W-1:0]    f_rdata;

    // ---- AXI：ic.m1 → DMA 配置口 ----
    wire [ID_W-1:0]      dc_awid, dc_arid;
    wire [ADDR_W-1:0]    dc_awaddr, dc_araddr;
    wire [LEN_W-1:0]     dc_awlen, dc_arlen;
    wire [2:0]           dc_awsize, dc_arsize;
    wire [1:0]           dc_awburst, dc_arburst;
    wire                 dc_awvalid, dc_awready, dc_arvalid, dc_arready;
    wire [DATA_W-1:0]    dc_wdata;
    wire [DATA_W/8-1:0]  dc_wstrb;
    wire                 dc_wlast, dc_wvalid, dc_wready;
    wire [ID_W-1:0]      dc_bid, dc_rid;
    wire [1:0]           dc_bresp, dc_rresp;
    wire                 dc_bvalid, dc_bready, dc_rlast, dc_rvalid, dc_rready;
    wire [DATA_W-1:0]    dc_rdata;

    // ---- AXI：ic.m2 → 未用（静态无效值 tie-off）----
    wire [ID_W-1:0]      m2_bid, m2_rid;
    wire [1:0]           m2_bresp, m2_rresp;
    wire                 m2_awready, m2_wready, m2_bvalid, m2_arready, m2_rlast, m2_rvalid;
    wire [DATA_W-1:0]    m2_rdata;

    // ---- AXI：ic.m3 → 片内 SRAM ----
    wire [ID_W-1:0]      sr_awid, sr_arid;
    wire [ADDR_W-1:0]    sr_awaddr, sr_araddr;
    wire [LEN_W-1:0]     sr_awlen, sr_arlen;
    wire [2:0]           sr_awsize, sr_arsize;
    wire [1:0]           sr_awburst, sr_arburst;
    wire                 sr_awvalid, sr_awready, sr_arvalid, sr_arready;
    wire [DATA_W-1:0]    sr_wdata;
    wire [DATA_W/8-1:0]  sr_wstrb;
    wire                 sr_wlast, sr_wvalid, sr_wready;
    wire [ID_W-1:0]      sr_bid, sr_rid;
    wire [1:0]           sr_bresp, sr_rresp;
    wire                 sr_bvalid, sr_bready, sr_rlast, sr_rvalid, sr_rready;
    wire [DATA_W-1:0]    sr_rdata;

    // ---- AXI：ic.m4 → AXI→APB 桥（该桥无 ID / 无 WSTRB）----
    wire [ADDR_W-1:0]    ap_awaddr, ap_araddr;
    wire [LEN_W-1:0]     ap_awlen, ap_arlen;
    wire [2:0]           ap_awsize, ap_arsize;
    wire [1:0]           ap_awburst, ap_arburst;
    wire                 ap_awvalid, ap_awready, ap_arvalid, ap_arready;
    wire [DATA_W-1:0]    ap_wdata;
    wire                 ap_wlast, ap_wvalid, ap_wready;
    wire [1:0]           ap_bresp, ap_rresp;
    wire                 ap_bvalid, ap_bready, ap_rlast, ap_rvalid, ap_rready;
    wire [DATA_W-1:0]    ap_rdata;
    wire [ID_W-1:0]      ap_awid, ap_arid;
    reg [ID_W-1:0]       ap_bid, ap_rid;
    // The bridge serializes transactions, so one tag per direction suffices.
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin ap_bid <= 0; ap_rid <= 0; end
        else begin
            if (ap_awvalid && ap_awready) ap_bid <= ap_awid;
            if (ap_arvalid && ap_arready) ap_rid <= ap_arid;
        end
    end

    // ---- APB（桥 → UART）----
    wire                 p_psel, p_penable, p_pwrite, p_pready, p_pslverr;
    wire [ADDR_W-1:0]    p_paddr;
    wire [DATA_W-1:0]    p_pwdata, p_prdata;
    wire [DATA_W/8-1:0]  p_pstrb;
    wire [2:0]           p_pprot;

    // ============================================================
    // 2. CPU —— cortexm0ds_logic（AHB-Lite 核）
    // ============================================================
    // vis_* 调试输出本设计不用，命名关联里省略（不接）
    cortexm0ds_logic u_cpu (
        .hclk       (clk),
        .hreset_n   (rst_n_sync),
        .haddr_o    (h_haddr),
        .hburst_o   (h_hburst),
        .hmastlock_o(h_hmastlock),
        .hprot_o    (h_hprot),
        .hsize_o    (h_hsize),
        .htrans_o   (h_htrans),
        .hwdata_o   (h_hwdata),
        .hwrite_o   (h_hwrite),
        .hrdata_i   (h_hrdata),
        .hready_i   (h_hready),
        .hresp_i    (h_hresp),
        .nmi_i      (1'b0),
        .irq_i      (irq_lines),
        .txev_o     (),
        .rxev_i     (1'b0),
        .lockup_o   (),
        .sys_reset_req_o(),
        .st_clk_en_i(1'b1),
        .st_calib_i (26'd0),
        .sleeping_o ()
    );

    // ============================================================
    // 3. AHB → AXI4 桥（主设备 ID = 0，契约C）
    // ============================================================
    ahb2axi #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)) u_ahb2axi (
        .clk(clk), .rst_n(rst_n_sync),
        // AHB 从口：本设计只有这一个 AHB 从设备，HSEL 恒有效
        .HSEL  (1'b1),
        .HADDR (h_haddr),
        .HTRANS(h_htrans),
        .HWRITE(h_hwrite),
        .HSIZE (h_hsize),
        .HBURST(h_hburst),
        .HPROT (h_hprot),
        .HWDATA(h_hwdata),
        .HRDATA(h_hrdata),
        .HREADY(h_hready),
        .HRESP (h_hresp),
        // AXI 主口 → ic.s0
        .m_axi_awid(b_awid), .m_axi_awaddr(b_awaddr), .m_axi_awlen(b_awlen),
        .m_axi_awsize(b_awsize), .m_axi_awburst(b_awburst),
        .m_axi_awvalid(b_awvalid), .m_axi_awready(b_awready),
        .m_axi_wdata(b_wdata), .m_axi_wstrb(b_wstrb), .m_axi_wlast(b_wlast),
        .m_axi_wvalid(b_wvalid), .m_axi_wready(b_wready),
        .m_axi_bid(b_bid), .m_axi_bresp(b_bresp), .m_axi_bvalid(b_bvalid), .m_axi_bready(b_bready),
        .m_axi_arid(b_arid), .m_axi_araddr(b_araddr), .m_axi_arlen(b_arlen),
        .m_axi_arsize(b_arsize), .m_axi_arburst(b_arburst),
        .m_axi_arvalid(b_arvalid), .m_axi_arready(b_arready),
        .m_axi_rid(b_rid), .m_axi_rdata(b_rdata), .m_axi_rresp(b_rresp),
        .m_axi_rlast(b_rlast), .m_axi_rvalid(b_rvalid), .m_axi_rready(b_rready)
    );

    // ============================================================
    // 4. AXI 互连（2 主 × 5 从）
    // ============================================================
    axi_ic #(.DATA_W(DATA_W), .ADDR_W(ADDR_W), .ID_W(ID_W), .N_MASTER(2),
             .N_SLAVE(5), .M2_RESERVED(1)) u_ic (
        .clk(clk), .rst_n(rst_n_sync),
        // ---- 从口 0：CPU 桥（ID=0）----
        .s0_axi_awid(b_awid), .s0_axi_awaddr(b_awaddr), .s0_axi_awlen(b_awlen),
        .s0_axi_awsize(b_awsize), .s0_axi_awburst(b_awburst),
        .s0_axi_awvalid(b_awvalid), .s0_axi_awready(b_awready),
        .s0_axi_wdata(b_wdata), .s0_axi_wstrb(b_wstrb), .s0_axi_wlast(b_wlast),
        .s0_axi_wvalid(b_wvalid), .s0_axi_wready(b_wready),
        .s0_axi_bid(b_bid), .s0_axi_bresp(b_bresp), .s0_axi_bvalid(b_bvalid), .s0_axi_bready(b_bready),
        .s0_axi_arid(b_arid), .s0_axi_araddr(b_araddr), .s0_axi_arlen(b_arlen),
        .s0_axi_arsize(b_arsize), .s0_axi_arburst(b_arburst),
        .s0_axi_arvalid(b_arvalid), .s0_axi_arready(b_arready),
        .s0_axi_rid(b_rid), .s0_axi_rdata(b_rdata), .s0_axi_rresp(b_rresp),
        .s0_axi_rlast(b_rlast), .s0_axi_rvalid(b_rvalid), .s0_axi_rready(b_rready),
        // ---- 从口 1：DMA 数据口（ID={CH,1'b1}）----
        .s1_axi_awid(dm_awid), .s1_axi_awaddr(dm_awaddr), .s1_axi_awlen(dm_awlen),
        .s1_axi_awsize(dm_awsize), .s1_axi_awburst(dm_awburst),
        .s1_axi_awvalid(dm_awvalid), .s1_axi_awready(dm_awready),
        .s1_axi_wdata(dm_wdata), .s1_axi_wstrb(dm_wstrb), .s1_axi_wlast(dm_wlast),
        .s1_axi_wvalid(dm_wvalid), .s1_axi_wready(dm_wready),
        .s1_axi_bid(dm_bid), .s1_axi_bresp(dm_bresp), .s1_axi_bvalid(dm_bvalid), .s1_axi_bready(dm_bready),
        .s1_axi_arid(dm_arid), .s1_axi_araddr(dm_araddr), .s1_axi_arlen(dm_arlen),
        .s1_axi_arsize(dm_arsize), .s1_axi_arburst(dm_arburst),
        .s1_axi_arvalid(dm_arvalid), .s1_axi_arready(dm_arready),
        .s1_axi_rid(dm_rid), .s1_axi_rdata(dm_rdata), .s1_axi_rresp(dm_rresp),
        .s1_axi_rlast(dm_rlast), .s1_axi_rvalid(dm_rvalid), .s1_axi_rready(dm_rready),
        // ---- 主口 0：FIR @0x4000_0000 ----
        .m0_axi_awid(f_awid), .m0_axi_awaddr(f_awaddr), .m0_axi_awlen(f_awlen),
        .m0_axi_awsize(f_awsize), .m0_axi_awburst(f_awburst),
        .m0_axi_awvalid(f_awvalid), .m0_axi_awready(f_awready),
        .m0_axi_wdata(f_wdata), .m0_axi_wstrb(f_wstrb), .m0_axi_wlast(f_wlast),
        .m0_axi_wvalid(f_wvalid), .m0_axi_wready(f_wready),
        .m0_axi_bid(f_bid), .m0_axi_bresp(f_bresp), .m0_axi_bvalid(f_bvalid), .m0_axi_bready(f_bready),
        .m0_axi_arid(f_arid), .m0_axi_araddr(f_araddr), .m0_axi_arlen(f_arlen),
        .m0_axi_arsize(f_arsize), .m0_axi_arburst(f_arburst),
        .m0_axi_arvalid(f_arvalid), .m0_axi_arready(f_arready),
        .m0_axi_rid(f_rid), .m0_axi_rdata(f_rdata), .m0_axi_rresp(f_rresp),
        .m0_axi_rlast(f_rlast), .m0_axi_rvalid(f_rvalid), .m0_axi_rready(f_rready),
        // ---- 主口 1：DMA 配置口 @0x4000_1000 ----
        .m1_axi_awid(dc_awid), .m1_axi_awaddr(dc_awaddr), .m1_axi_awlen(dc_awlen),
        .m1_axi_awsize(dc_awsize), .m1_axi_awburst(dc_awburst),
        .m1_axi_awvalid(dc_awvalid), .m1_axi_awready(dc_awready),
        .m1_axi_wdata(dc_wdata), .m1_axi_wstrb(dc_wstrb), .m1_axi_wlast(dc_wlast),
        .m1_axi_wvalid(dc_wvalid), .m1_axi_wready(dc_wready),
        .m1_axi_bid(dc_bid), .m1_axi_bresp(dc_bresp), .m1_axi_bvalid(dc_bvalid), .m1_axi_bready(dc_bready),
        .m1_axi_arid(dc_arid), .m1_axi_araddr(dc_araddr), .m1_axi_arlen(dc_arlen),
        .m1_axi_arsize(dc_arsize), .m1_axi_arburst(dc_arburst),
        .m1_axi_arvalid(dc_arvalid), .m1_axi_arready(dc_arready),
        .m1_axi_rid(dc_rid), .m1_axi_rdata(dc_rdata), .m1_axi_rresp(dc_rresp),
        .m1_axi_rlast(dc_rlast), .m1_axi_rvalid(dc_rvalid), .m1_axi_rready(dc_rready),
        // ---- 主口 2：未用（方案 B 不用 0x2000_0000），接静态无效值 ----
        .m2_axi_awid(), .m2_axi_awaddr(), .m2_axi_awlen(), .m2_axi_awsize(), .m2_axi_awburst(),
        .m2_axi_awvalid(), .m2_axi_awready(1'b0),
        .m2_axi_wdata(), .m2_axi_wstrb(), .m2_axi_wlast(), .m2_axi_wvalid(), .m2_axi_wready(1'b0),
        .m2_axi_bid(4'd0), .m2_axi_bresp(2'd0), .m2_axi_bvalid(1'b0), .m2_axi_bready(),
        .m2_axi_arid(), .m2_axi_araddr(), .m2_axi_arlen(), .m2_axi_arsize(), .m2_axi_arburst(),
        .m2_axi_arvalid(), .m2_axi_arready(1'b0),
        .m2_axi_rid(4'd0), .m2_axi_rdata(32'd0), .m2_axi_rresp(2'd0),
        .m2_axi_rlast(1'b0), .m2_axi_rvalid(1'b0), .m2_axi_rready(),
        // ---- 主口 3：片内 SRAM @0x0000_0000（方案 B 的关键：是 m3！）----
        .m3_axi_awid(sr_awid), .m3_axi_awaddr(sr_awaddr), .m3_axi_awlen(sr_awlen),
        .m3_axi_awsize(sr_awsize), .m3_axi_awburst(sr_awburst),
        .m3_axi_awvalid(sr_awvalid), .m3_axi_awready(sr_awready),
        .m3_axi_wdata(sr_wdata), .m3_axi_wstrb(sr_wstrb), .m3_axi_wlast(sr_wlast),
        .m3_axi_wvalid(sr_wvalid), .m3_axi_wready(sr_wready),
        .m3_axi_bid(sr_bid), .m3_axi_bresp(sr_bresp), .m3_axi_bvalid(sr_bvalid), .m3_axi_bready(sr_bready),
        .m3_axi_arid(sr_arid), .m3_axi_araddr(sr_araddr), .m3_axi_arlen(sr_arlen),
        .m3_axi_arsize(sr_arsize), .m3_axi_arburst(sr_arburst),
        .m3_axi_arvalid(sr_arvalid), .m3_axi_arready(sr_arready),
        .m3_axi_rid(sr_rid), .m3_axi_rdata(sr_rdata), .m3_axi_rresp(sr_rresp),
        .m3_axi_rlast(sr_rlast), .m3_axi_rvalid(sr_rvalid), .m3_axi_rready(sr_rready),
        // ---- 主口 4：AXI→APB 桥 @0x4000_2000 ----
        // ID 在桥外按地址握手锁存，确保 CPU/DMA 的响应都回到原主设备。
        // WSTRB 桥内部按 AWSIZE+地址自算。
        .m4_axi_awid(ap_awid), .m4_axi_awaddr(ap_awaddr), .m4_axi_awlen(ap_awlen),
        .m4_axi_awsize(ap_awsize), .m4_axi_awburst(ap_awburst),
        .m4_axi_awvalid(ap_awvalid), .m4_axi_awready(ap_awready),
        .m4_axi_wdata(ap_wdata), .m4_axi_wstrb(), .m4_axi_wlast(ap_wlast),
        .m4_axi_wvalid(ap_wvalid), .m4_axi_wready(ap_wready),
        .m4_axi_bid(ap_bid), .m4_axi_bresp(ap_bresp), .m4_axi_bvalid(ap_bvalid), .m4_axi_bready(ap_bready),
        .m4_axi_arid(ap_arid), .m4_axi_araddr(ap_araddr), .m4_axi_arlen(ap_arlen),
        .m4_axi_arsize(ap_arsize), .m4_axi_arburst(ap_arburst),
        .m4_axi_arvalid(ap_arvalid), .m4_axi_arready(ap_arready),
        .m4_axi_rid(ap_rid), .m4_axi_rdata(ap_rdata), .m4_axi_rresp(ap_rresp),
        .m4_axi_rlast(ap_rlast), .m4_axi_rvalid(ap_rvalid), .m4_axi_rready(ap_rready)
    );

    // ============================================================
    // 5. FIR 滤波器（@0x4000_0000）
    // ============================================================
    fir #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)) u_fir (
        .clk(clk), .rst_n(rst_n_sync),
        .s_axi_awid(f_awid), .s_axi_awaddr(f_awaddr), .s_axi_awlen(f_awlen),
        .s_axi_awsize(f_awsize), .s_axi_awburst(f_awburst),
        .s_axi_awvalid(f_awvalid), .s_axi_awready(f_awready),
        .s_axi_wdata(f_wdata), .s_axi_wstrb(f_wstrb), .s_axi_wlast(f_wlast),
        .s_axi_wvalid(f_wvalid), .s_axi_wready(f_wready),
        .s_axi_bid(f_bid), .s_axi_bresp(f_bresp), .s_axi_bvalid(f_bvalid), .s_axi_bready(f_bready),
        .s_axi_arid(f_arid), .s_axi_araddr(f_araddr), .s_axi_arlen(f_arlen),
        .s_axi_arsize(f_arsize), .s_axi_arburst(f_arburst),
        .s_axi_arvalid(f_arvalid), .s_axi_arready(f_arready),
        .s_axi_rid(f_rid), .s_axi_rdata(f_rdata), .s_axi_rresp(f_rresp),
        .s_axi_rlast(f_rlast), .s_axi_rvalid(f_rvalid), .s_axi_rready(f_rready),
        .irq_done(fir_irq_done), .irq_err(fir_irq_err)
    );

    // ============================================================
    // 6. 6 通道 DMA（配置口 @0x4000_1000，数据口 → ic.s1）
    // ============================================================
    dma #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W), .LEN_W(LEN_W), .NCH(6)) u_dma (
        .clk(clk), .rst_n(rst_n_sync),
        // 配置口（从）
        .s_axi_awid(dc_awid), .s_axi_awaddr(dc_awaddr), .s_axi_awlen(dc_awlen),
        .s_axi_awsize(dc_awsize), .s_axi_awburst(dc_awburst),
        .s_axi_awvalid(dc_awvalid), .s_axi_awready(dc_awready),
        .s_axi_wdata(dc_wdata), .s_axi_wstrb(dc_wstrb), .s_axi_wlast(dc_wlast),
        .s_axi_wvalid(dc_wvalid), .s_axi_wready(dc_wready),
        .s_axi_bid(dc_bid), .s_axi_bresp(dc_bresp), .s_axi_bvalid(dc_bvalid), .s_axi_bready(dc_bready),
        .s_axi_arid(dc_arid), .s_axi_araddr(dc_araddr), .s_axi_arlen(dc_arlen),
        .s_axi_arsize(dc_arsize), .s_axi_arburst(dc_arburst),
        .s_axi_arvalid(dc_arvalid), .s_axi_arready(dc_arready),
        .s_axi_rid(dc_rid), .s_axi_rdata(dc_rdata), .s_axi_rresp(dc_rresp),
        .s_axi_rlast(dc_rlast), .s_axi_rvalid(dc_rvalid), .s_axi_rready(dc_rready),
        // 数据口（主）→ ic.s1
        .m_axi_awid(dm_awid), .m_axi_awaddr(dm_awaddr), .m_axi_awlen(dm_awlen),
        .m_axi_awsize(dm_awsize), .m_axi_awburst(dm_awburst),
        .m_axi_awvalid(dm_awvalid), .m_axi_awready(dm_awready),
        .m_axi_wdata(dm_wdata), .m_axi_wstrb(dm_wstrb), .m_axi_wlast(dm_wlast),
        .m_axi_wvalid(dm_wvalid), .m_axi_wready(dm_wready),
        .m_axi_bid(dm_bid), .m_axi_bresp(dm_bresp), .m_axi_bvalid(dm_bvalid), .m_axi_bready(dm_bready),
        .m_axi_arid(dm_arid), .m_axi_araddr(dm_araddr), .m_axi_arlen(dm_arlen),
        .m_axi_arsize(dm_arsize), .m_axi_arburst(dm_arburst),
        .m_axi_arvalid(dm_arvalid), .m_axi_arready(dm_arready),
        .m_axi_rid(dm_rid), .m_axi_rdata(dm_rdata), .m_axi_rresp(dm_rresp),
        .m_axi_rlast(dm_rlast), .m_axi_rvalid(dm_rvalid), .m_axi_rready(dm_rready),
        // 中断
        .irq_done(dma_irq_done), .irq_err(dma_irq_err)
    );

    // ============================================================
    // 7. 片内 SRAM（@0x0000_0000，方案 B：程序 + 数据 + 栈）
    // ============================================================
    axi_sram #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W),
        .SRAM_BYTES(SRAM_BYTES), .BASE_ADDR(32'h0000_0000)
    ) u_sram (
        .clk(clk), .rst_n(rst_n_sync),
        .s_axi_awid(sr_awid), .s_axi_awaddr(sr_awaddr), .s_axi_awlen(sr_awlen),
        .s_axi_awsize(sr_awsize), .s_axi_awburst(sr_awburst),
        .s_axi_awvalid(sr_awvalid), .s_axi_awready(sr_awready),
        .s_axi_wdata(sr_wdata), .s_axi_wstrb(sr_wstrb), .s_axi_wlast(sr_wlast),
        .s_axi_wvalid(sr_wvalid), .s_axi_wready(sr_wready),
        .s_axi_bid(sr_bid), .s_axi_bresp(sr_bresp), .s_axi_bvalid(sr_bvalid), .s_axi_bready(sr_bready),
        .s_axi_arid(sr_arid), .s_axi_araddr(sr_araddr), .s_axi_arlen(sr_arlen),
        .s_axi_arsize(sr_arsize), .s_axi_arburst(sr_arburst),
        .s_axi_arvalid(sr_arvalid), .s_axi_arready(sr_arready),
        .s_axi_rid(sr_rid), .s_axi_rdata(sr_rdata), .s_axi_rresp(sr_rresp),
        .s_axi_rlast(sr_rlast), .s_axi_rvalid(sr_rvalid), .s_axi_rready(sr_rready)
    );

    // ============================================================
    // 8. AXI→APB 桥 + UART（@0x4000_2000）
    // ============================================================
    axi_to_apb #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .TIMEOUT(0),
                 .BASE_ADDR(32'h4000_2000)) u_axi2apb (
        .clk(clk), .rst_n(rst_n_sync),
        // AXI 从口（← ic.m4；无 ID / 无 WSTRB）
        .awvalid(ap_awvalid), .awready(ap_awready), .awaddr(ap_awaddr),
        .awlen(ap_awlen), .awsize(ap_awsize), .awburst(ap_awburst),
        .wvalid(ap_wvalid), .wready(ap_wready), .wdata(ap_wdata), .wlast(ap_wlast),
        .bresp(ap_bresp), .bvalid(ap_bvalid), .bready(ap_bready),
        .arvalid(ap_arvalid), .arready(ap_arready), .araddr(ap_araddr),
        .arlen(ap_arlen), .arsize(ap_arsize), .arburst(ap_arburst),
        .rdata(ap_rdata), .rresp(ap_rresp), .rlast(ap_rlast), .rvalid(ap_rvalid), .rready(ap_rready),
        // APB 主口
        .psel(p_psel), .penable(p_penable), .paddr(p_paddr), .pwrite(p_pwrite),
        .pwdata(p_pwdata), .pstrb(p_pstrb), .pprot(p_pprot),
        .prdata(p_prdata), .pready(p_pready), .pslverr(p_pslverr)
    );

    // UART：soc_top 的 UART_DIV 在这里换算成 uart_apb 需要的 CLK_FREQ / BAUD
    uart_apb #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD    (CLK_FREQ / UART_DIV)
    ) u_uart (
        .clk(clk), .rst_n(rst_n_sync),
        .psel(p_psel), .penable(p_penable), .pwrite(p_pwrite), .paddr(p_paddr),
        .pwdata(p_pwdata), .pstrb(p_pstrb), .pprot(p_pprot),
        .prdata(p_prdata), .pready(p_pready), .pslverr(p_pslverr),
        .rxd(uart_rxd), .txd(uart_txd)
    );

    // ============================================================
    // 9. 中断合并（契约S §S.5）
    // ============================================================
    assign irq_lines = { 23'b0,           // [31:9] 预留
                         dma_irq_err,     // [8]    DMA 全局错误
                         dma_irq_done,    // [7:2]  DMA 通道 0~5 完成
                         fir_irq_err,     // [1]    FIR 错误
                         fir_irq_done };  // [0]    FIR 滤波完成

endmodule
