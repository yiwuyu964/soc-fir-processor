// ============================================================
// dma.v —— 6 通道 DMA 控制器顶层（阶段3 分工 A）
//
// 【契约依据】
//   docs/契约A-配置总线.md（cfg 总线）
//   docs/契约AB-DMA内部接口.md §2（engine 端口，B 实现，不许改）
//   docs/契约C-AXI ID编码.md（ID = {CH[2:0], 1'b1}）
//   docs/任务4-模块接口信号清单.md §1.6（对外端口/中断）
//
// 【组成】
//   1 个 dma_regs（AXI4 从口 + 24 寄存器）
//   6 个 dma_engine（每通道一个 AXI4 主口）
//   6→1 AXI 主口仲裁（AW/AR round-robin，突发期间锁定）
//   中断生成（irq_done[5:0] / irq_err）
//
// 【6→1 仲裁要点】
//   · AW/AR 用 axi_arbiter round-robin；AW 锁到 WLAST，AR 锁到 RLAST。
//   · B/R 回选用 ID[3:1]（=CH），不是 ID[0]（ID[0] 恒 1 是 DMA 标记）。
//   · 引擎 ID 已是 {CH,1'b1}，顶层仲裁原样透传，不改写。
//   · START 是 dma_regs 已生成的一拍脉冲，直连引擎 start，不做边沿检测。
//
// 【链式传输】parameter CHAIN_EN（默认 0）预留，本阶段不实现。
// ============================================================
`timescale 1ns/1ps

module dma #(
    parameter ADDR_W   = 32,
    parameter DATA_W   = 32,
    parameter ID_W     = 4,
    parameter LEN_W    = 8,
    parameter NCH      = 6,
    parameter CHAIN_EN = 0            // 链式传输预留，本阶段不实现
)(
    input  wire                clk,
    input  wire                rst_n,

    // ---- AXI4 从口（配置口，基址 0x4000_1000）----
    input  wire [ID_W-1:0]     s_axi_awid,
    input  wire [ADDR_W-1:0]   s_axi_awaddr,
    input  wire [LEN_W-1:0]    s_axi_awlen,
    input  wire [2:0]          s_axi_awsize,
    input  wire [1:0]          s_axi_awburst,
    input  wire                s_axi_awvalid,
    output wire                s_axi_awready,
    input  wire [DATA_W-1:0]   s_axi_wdata,
    input  wire [DATA_W/8-1:0] s_axi_wstrb,
    input  wire                s_axi_wlast,
    input  wire                s_axi_wvalid,
    output wire                s_axi_wready,
    output wire [ID_W-1:0]     s_axi_bid,
    output wire [1:0]          s_axi_bresp,
    output wire                s_axi_bvalid,
    input  wire                s_axi_bready,
    input  wire [ID_W-1:0]     s_axi_arid,
    input  wire [ADDR_W-1:0]   s_axi_araddr,
    input  wire [LEN_W-1:0]    s_axi_arlen,
    input  wire [2:0]          s_axi_arsize,
    input  wire [1:0]          s_axi_arburst,
    input  wire                s_axi_arvalid,
    output wire                s_axi_arready,
    output wire [ID_W-1:0]     s_axi_rid,
    output wire [DATA_W-1:0]   s_axi_rdata,
    output wire [1:0]          s_axi_rresp,
    output wire                s_axi_rlast,
    output wire                s_axi_rvalid,
    input  wire                s_axi_rready,

    // ---- AXI4 主口（数据口，接互连 s1）----
    output wire [ID_W-1:0]     m_axi_awid,
    output wire [ADDR_W-1:0]   m_axi_awaddr,
    output wire [LEN_W-1:0]    m_axi_awlen,
    output wire [2:0]          m_axi_awsize,
    output wire [1:0]          m_axi_awburst,
    output wire                m_axi_awvalid,
    input  wire                m_axi_awready,
    output wire [DATA_W-1:0]   m_axi_wdata,
    output wire [DATA_W/8-1:0] m_axi_wstrb,
    output wire                m_axi_wlast,
    output wire                m_axi_wvalid,
    input  wire                m_axi_wready,
    input  wire [ID_W-1:0]     m_axi_bid,
    input  wire [1:0]          m_axi_bresp,
    input  wire                m_axi_bvalid,
    output wire                m_axi_bready,
    output wire [ID_W-1:0]     m_axi_arid,
    output wire [ADDR_W-1:0]   m_axi_araddr,
    output wire [LEN_W-1:0]    m_axi_arlen,
    output wire [2:0]          m_axi_arsize,
    output wire [1:0]          m_axi_arburst,
    output wire                m_axi_arvalid,
    input  wire                m_axi_arready,
    input  wire [ID_W-1:0]     m_axi_rid,
    input  wire [DATA_W-1:0]   m_axi_rdata,
    input  wire [1:0]          m_axi_rresp,
    input  wire                m_axi_rlast,
    input  wire                m_axi_rvalid,
    output wire                m_axi_rready,

    // ---- 中断（电平，任务四 §1.6）----
    output wire [NCH-1:0]      irq_done,   // = st_status[ch][1]（DONE）→ IRQ2~7
    output wire                irq_err     // = 6 通道 ERR 的或 → IRQ8
);

    // ============================================================
    // 0. 配置总线
    // ============================================================
    wire [NCH*32-1:0] cfg_src, cfg_dst, cfg_len, cfg_ctrl;
    wire [NCH*32-1:0] st_status;

    dma_regs #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W), .LEN_W(LEN_W), .NCH(NCH)
    ) u_regs (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awid(s_axi_awid), .s_axi_awaddr(s_axi_awaddr), .s_axi_awlen(s_axi_awlen),
        .s_axi_awsize(s_axi_awsize), .s_axi_awburst(s_axi_awburst),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wlast(s_axi_wlast),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bid(s_axi_bid), .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_arid(s_axi_arid), .s_axi_araddr(s_axi_araddr), .s_axi_arlen(s_axi_arlen),
        .s_axi_arsize(s_axi_arsize), .s_axi_arburst(s_axi_arburst),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rid(s_axi_rid), .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .s_axi_rlast(s_axi_rlast), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .cfg_src(cfg_src), .cfg_dst(cfg_dst), .cfg_len(cfg_len), .cfg_ctrl(cfg_ctrl),
        .st_status(st_status)
    );

    // ============================================================
    // 1. 6 个引擎 + 状态聚合 + 中断
    // ============================================================
    wire [NCH-1:0][ID_W-1:0]     eng_awid, eng_arid, eng_bid, eng_rid;
    wire [NCH-1:0][ADDR_W-1:0]   eng_awaddr, eng_araddr;
    wire [NCH-1:0][LEN_W-1:0]    eng_awlen, eng_arlen;
    wire [NCH-1:0][2:0]          eng_awsize, eng_arsize;
    wire [NCH-1:0][1:0]          eng_awburst, eng_arburst, eng_bresp, eng_rresp;
    wire [NCH-1:0]               eng_awvalid, eng_awready, eng_arvalid, eng_arready;
    wire [NCH-1:0][DATA_W-1:0]   eng_wdata, eng_rdata;
    wire [NCH-1:0][DATA_W/8-1:0] eng_wstrb;
    wire [NCH-1:0]               eng_wlast, eng_wvalid, eng_wready;
    wire [NCH-1:0]               eng_bvalid, eng_bready;
    wire [NCH-1:0]               eng_rlast, eng_rvalid, eng_rready;
    wire [NCH-1:0][31:0]         eng_status;

    wire [NCH-1:0]               ch_err;

    genvar g;
    generate
        for (g = 0; g < NCH; g = g + 1) begin : g_eng
            dma_engine #(
                .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W), .LEN_W(LEN_W), .CH(g)
            ) u_eng (
                .clk(clk), .rst_n(rst_n),
                .cfg_src(cfg_src[g*32 +: 32]),
                .cfg_dst(cfg_dst[g*32 +: 32]),
                .cfg_len(cfg_len[g*32 +: 32]),
                .cfg_src_inc(cfg_ctrl[g*32 + 1]),   // SRC_INC
                .cfg_dst_inc(cfg_ctrl[g*32 + 2]),   // DST_INC
                .start(cfg_ctrl[g*32 + 0]),         // START 一拍脉冲，直连，不做边沿检测
                .busy(), .done(), .err(), .status(eng_status[g]),
                .m_awid(eng_awid[g]), .m_awaddr(eng_awaddr[g]), .m_awlen(eng_awlen[g]),
                .m_awsize(eng_awsize[g]), .m_awburst(eng_awburst[g]),
                .m_awvalid(eng_awvalid[g]), .m_awready(eng_awready[g]),
                .m_wdata(eng_wdata[g]), .m_wstrb(eng_wstrb[g]), .m_wlast(eng_wlast[g]),
                .m_wvalid(eng_wvalid[g]), .m_wready(eng_wready[g]),
                .m_bid(eng_bid[g]), .m_bresp(eng_bresp[g]),
                .m_bvalid(eng_bvalid[g]), .m_bready(eng_bready[g]),
                .m_arid(eng_arid[g]), .m_araddr(eng_araddr[g]), .m_arlen(eng_arlen[g]),
                .m_arsize(eng_arsize[g]), .m_arburst(eng_arburst[g]),
                .m_arvalid(eng_arvalid[g]), .m_arready(eng_arready[g]),
                .m_rid(eng_rid[g]), .m_rdata(eng_rdata[g]), .m_rresp(eng_rresp[g]),
                .m_rlast(eng_rlast[g]), .m_rvalid(eng_rvalid[g]), .m_rready(eng_rready[g])
            );

            assign st_status[g*32 +: 32] = eng_status[g];
            assign irq_done[g]           = st_status[g*32 + 1];  // DONE（粘滞）
            assign ch_err[g]             = st_status[g*32 + 2];  // ERR
        end
    endgenerate

    assign irq_err = |ch_err;

    // ============================================================
    // 2. 6→1 写通道仲裁：AW round-robin + W 跟随，锁到 WLAST
    // ============================================================
    wire [NCH-1:0] aw_req, aw_grant;
    wire           aw_hs, w_done;
    reg            w_active;
    reg  [NCH-1:0] w_owner;

    generate
        for (g = 0; g < NCH; g = g + 1) begin : g_awreq
            assign aw_req[g] = eng_awvalid[g] && !w_active;
        end
    endgenerate

    axi_arbiter #(.N(NCH)) u_aw_arb (
        .clk(clk), .rst_n(rst_n), .req(aw_req), .advance(aw_hs), .grant(aw_grant)
    );

    // AW 一热 mux（ID 原样透传）
    assign m_axi_awid    = ({ID_W{aw_grant[0]}} & eng_awid[0])   | ({ID_W{aw_grant[1]}} & eng_awid[1])   |
                           ({ID_W{aw_grant[2]}} & eng_awid[2])   | ({ID_W{aw_grant[3]}} & eng_awid[3])   |
                           ({ID_W{aw_grant[4]}} & eng_awid[4])   | ({ID_W{aw_grant[5]}} & eng_awid[5]);
    assign m_axi_awaddr  = ({ADDR_W{aw_grant[0]}} & eng_awaddr[0]) | ({ADDR_W{aw_grant[1]}} & eng_awaddr[1]) |
                           ({ADDR_W{aw_grant[2]}} & eng_awaddr[2]) | ({ADDR_W{aw_grant[3]}} & eng_awaddr[3]) |
                           ({ADDR_W{aw_grant[4]}} & eng_awaddr[4]) | ({ADDR_W{aw_grant[5]}} & eng_awaddr[5]);
    assign m_axi_awlen   = ({LEN_W{aw_grant[0]}} & eng_awlen[0])  | ({LEN_W{aw_grant[1]}} & eng_awlen[1])  |
                           ({LEN_W{aw_grant[2]}} & eng_awlen[2])  | ({LEN_W{aw_grant[3]}} & eng_awlen[3])  |
                           ({LEN_W{aw_grant[4]}} & eng_awlen[4])  | ({LEN_W{aw_grant[5]}} & eng_awlen[5]);
    assign m_axi_awsize  = ({3{aw_grant[0]}} & eng_awsize[0]) | ({3{aw_grant[1]}} & eng_awsize[1]) |
                           ({3{aw_grant[2]}} & eng_awsize[2]) | ({3{aw_grant[3]}} & eng_awsize[3]) |
                           ({3{aw_grant[4]}} & eng_awsize[4]) | ({3{aw_grant[5]}} & eng_awsize[5]);
    assign m_axi_awburst = ({2{aw_grant[0]}} & eng_awburst[0]) | ({2{aw_grant[1]}} & eng_awburst[1]) |
                           ({2{aw_grant[2]}} & eng_awburst[2]) | ({2{aw_grant[3]}} & eng_awburst[3]) |
                           ({2{aw_grant[4]}} & eng_awburst[4]) | ({2{aw_grant[5]}} & eng_awburst[5]);
    assign m_axi_awvalid = |(aw_grant & eng_awvalid);
    assign aw_hs = m_axi_awvalid && m_axi_awready;

    // AWREADY 回选
    generate
        for (g = 0; g < NCH; g = g + 1) begin : g_awready
            assign eng_awready[g] = aw_grant[g] & m_axi_awready;
        end
    endgenerate

    // W 跟随 w_owner（突发期间锁定）
    assign m_axi_wdata  = ({DATA_W{w_owner[0]}} & eng_wdata[0]) | ({DATA_W{w_owner[1]}} & eng_wdata[1]) |
                          ({DATA_W{w_owner[2]}} & eng_wdata[2]) | ({DATA_W{w_owner[3]}} & eng_wdata[3]) |
                          ({DATA_W{w_owner[4]}} & eng_wdata[4]) | ({DATA_W{w_owner[5]}} & eng_wdata[5]);
    assign m_axi_wstrb  = ({4{w_owner[0]}} & eng_wstrb[0]) | ({4{w_owner[1]}} & eng_wstrb[1]) |
                          ({4{w_owner[2]}} & eng_wstrb[2]) | ({4{w_owner[3]}} & eng_wstrb[3]) |
                          ({4{w_owner[4]}} & eng_wstrb[4]) | ({4{w_owner[5]}} & eng_wstrb[5]);
    assign m_axi_wlast  = (w_owner[0] & eng_wlast[0]) | (w_owner[1] & eng_wlast[1]) |
                          (w_owner[2] & eng_wlast[2]) | (w_owner[3] & eng_wlast[3]) |
                          (w_owner[4] & eng_wlast[4]) | (w_owner[5] & eng_wlast[5]);
    assign m_axi_wvalid = w_active && ((w_owner[0] & eng_wvalid[0]) | (w_owner[1] & eng_wvalid[1]) |
                                       (w_owner[2] & eng_wvalid[2]) | (w_owner[3] & eng_wvalid[3]) |
                                       (w_owner[4] & eng_wvalid[4]) | (w_owner[5] & eng_wvalid[5]));
    assign w_done = m_axi_wvalid && m_axi_wready && m_axi_wlast;

    generate
        for (g = 0; g < NCH; g = g + 1) begin : g_wready
            assign eng_wready[g] = w_owner[g] & m_axi_wready;
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_active <= 1'b0;
            w_owner  <= {NCH{1'b0}};
        end
        else begin
            if (aw_hs) begin
                w_active <= 1'b1;
                w_owner  <= aw_grant;
            end
            else if (w_done) begin
                w_active <= 1'b0;
                w_owner  <= {NCH{1'b0}};
            end
        end
    end

    // ============================================================
    // 3. B 回选：按 ID[3:1]（=CH），ID[0] 恒 1 不能用来选
    // ============================================================
    generate
        for (g = 0; g < NCH; g = g + 1) begin : g_b
            assign eng_bid[g]   = m_axi_bid;
            assign eng_bresp[g] = m_axi_bresp;
            assign eng_bvalid[g] = m_axi_bvalid && (m_axi_bid[3:1] == g);
        end
    endgenerate
    // m_axi_bready 只赋一次（坑：勿再加一个或约减的重复赋值）
    assign m_axi_bready = eng_bready[m_axi_bid[3:1]];

    // ============================================================
    // 4. 6→1 读通道仲裁：AR round-robin，锁到 RLAST；R 按 ID 回选
    // ============================================================
    wire [NCH-1:0] ar_req, ar_grant;
    wire           ar_hs, r_done;
    reg            r_active;

    generate
        for (g = 0; g < NCH; g = g + 1) begin : g_arreq
            assign ar_req[g] = eng_arvalid[g] && !r_active;
        end
    endgenerate

    axi_arbiter #(.N(NCH)) u_ar_arb (
        .clk(clk), .rst_n(rst_n), .req(ar_req), .advance(ar_hs), .grant(ar_grant)
    );

    assign m_axi_arid    = ({ID_W{ar_grant[0]}} & eng_arid[0])   | ({ID_W{ar_grant[1]}} & eng_arid[1])   |
                           ({ID_W{ar_grant[2]}} & eng_arid[2])   | ({ID_W{ar_grant[3]}} & eng_arid[3])   |
                           ({ID_W{ar_grant[4]}} & eng_arid[4])   | ({ID_W{ar_grant[5]}} & eng_arid[5]);
    assign m_axi_araddr  = ({ADDR_W{ar_grant[0]}} & eng_araddr[0]) | ({ADDR_W{ar_grant[1]}} & eng_araddr[1]) |
                           ({ADDR_W{ar_grant[2]}} & eng_araddr[2]) | ({ADDR_W{ar_grant[3]}} & eng_araddr[3]) |
                           ({ADDR_W{ar_grant[4]}} & eng_araddr[4]) | ({ADDR_W{ar_grant[5]}} & eng_araddr[5]);
    assign m_axi_arlen   = ({LEN_W{ar_grant[0]}} & eng_arlen[0])  | ({LEN_W{ar_grant[1]}} & eng_arlen[1])  |
                           ({LEN_W{ar_grant[2]}} & eng_arlen[2])  | ({LEN_W{ar_grant[3]}} & eng_arlen[3])  |
                           ({LEN_W{ar_grant[4]}} & eng_arlen[4])  | ({LEN_W{ar_grant[5]}} & eng_arlen[5]);
    assign m_axi_arsize  = ({3{ar_grant[0]}} & eng_arsize[0]) | ({3{ar_grant[1]}} & eng_arsize[1]) |
                           ({3{ar_grant[2]}} & eng_arsize[2]) | ({3{ar_grant[3]}} & eng_arsize[3]) |
                           ({3{ar_grant[4]}} & eng_arsize[4]) | ({3{ar_grant[5]}} & eng_arsize[5]);
    assign m_axi_arburst = ({2{ar_grant[0]}} & eng_arburst[0]) | ({2{ar_grant[1]}} & eng_arburst[1]) |
                           ({2{ar_grant[2]}} & eng_arburst[2]) | ({2{ar_grant[3]}} & eng_arburst[3]) |
                           ({2{ar_grant[4]}} & eng_arburst[4]) | ({2{ar_grant[5]}} & eng_arburst[5]);
    assign m_axi_arvalid = |(ar_grant & eng_arvalid);
    assign ar_hs = m_axi_arvalid && m_axi_arready;

    generate
        for (g = 0; g < NCH; g = g + 1) begin : g_arready
            assign eng_arready[g] = ar_grant[g] & m_axi_arready;
        end
    endgenerate

    // R 回选
    generate
        for (g = 0; g < NCH; g = g + 1) begin : g_r
            assign eng_rid[g]    = m_axi_rid;
            assign eng_rdata[g]  = m_axi_rdata;
            assign eng_rresp[g]  = m_axi_rresp;
            assign eng_rlast[g]  = m_axi_rlast;
            assign eng_rvalid[g] = m_axi_rvalid && (m_axi_rid[3:1] == g);
        end
    endgenerate
    assign m_axi_rready = eng_rready[m_axi_rid[3:1]];
    assign r_done = m_axi_rvalid && m_axi_rready && m_axi_rlast;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_active <= 1'b0;
        end
        else begin
            if (ar_hs)       r_active <= 1'b1;
            else if (r_done) r_active <= 1'b0;
        end
    end

    // ============================================================
    // 契约 C 断言：DMA 主口 ID 最低位恒为 1（不改写，原样透传自引擎）
    // ============================================================
`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && m_axi_awvalid && (m_axi_awid[0] !== 1'b1))
            $display("  [契约C违规] t=%0t AWID=%b 最低位不是 1", $time, m_axi_awid);
        if (rst_n && m_axi_arvalid && (m_axi_arid[0] !== 1'b1))
            $display("  [契约C违规] t=%0t ARID=%b 最低位不是 1", $time, m_axi_arid);
    end
`endif

    // 链式传输预留（本阶段不实现）：若实现，需在 cfg_ctrl 高位加 CHAIN_EN/CHAIN_NEXT，
    // 并为引擎补 chain_en/chain_next/chain_trig 端口，由下一通道的 chain_trig 当 start。

endmodule
