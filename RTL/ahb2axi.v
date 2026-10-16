// ============================================================
// ahb2axi.v —— AHB-Lite 从口 → AXI4 主口 协议桥（阶段2 分工 B）
//
// ============================================================
// 【接口契约】docs/任务四_模块接口信号清单.md 1.2 节（对外端口）
// ============================================================
//   AHB-Lite 从口（接 Cortex-M0，HSEL 恒 1 或来自译码）：
//     HADDR/HTRANS/HWRITE/HSIZE/HBURST/HPROT/HWDATA/HSEL   （入）
//     HRDATA/HREADY/HRESP                                 （出）
//   AXI4 主口（接 AXI 互连 s0 口，主设备 ID=0）：
//     AW/W/B/AR/R 五通道，awid/arid 恒 0
//
//   ⚠️ HRESP 位宽：任务四 1.2 表里写 "HRESP out 2"，但 AHB-Lite 与
//      Cortex-M0 DesignStart 的 HRESP 都是 1 位（0=OKAY，1=ERROR），
//      这里按 1 位实现（与 M0 的 hresp_i 对齐）。
//   ⚠️ HREADY：任务四只列 HREADY（出）。本桥是 M0 唯一 AHB 从设备，
//      系统 HREADY 就是自身 HREADY 的回环，故内部用 hready_sys = HREADY。
//
// ============================================================
// 【AHB-Lite → AXI 翻译】
// ============================================================
//   HSIZE → AWSIZE/ARSIZE 直接透传（000=字节/001=半字/010=字）
//   HBURST → 统一映射成 AXI INCR，长度封顶 16 拍：
//     SINGLE(000)→LEN=0 / INCR(001)或INCR16或WRAP16→LEN=15
//     WRAP4/INCR4→LEN=3 / WRAP8/INCR8→LEN=7
//     （M0 实际只发 SINGLE 和短 INCR；WRAP 映射成等长 INCR，避免下游 SLVERR）
//
//   WSTRB：由 HSIZE + 该拍地址低两位生成（0001/0011 << addr[1:0]，字则 1111）。
//   写数据 HWDATA、读数据 R_DATA 均直接透传，不做 lane 搬移。
//
// ============================================================
// 【AHB 流水线时序】（本模块历史 bug 所在，2025 review 重写）
// ============================================================
//   AHB 是【流水线】的：地址相位与上一拍的数据相位重叠，背靠背传输之间
//   【没有 IDLE 空档】。早期版本要求"两笔之间必须有 IDLE"，真实 M0 一上电
//   连读 0x0/0x4 两个向量就丢第二笔 → 复位向量读成 0 → HardFault。
//
//   本版本按 ARM 官方 ahb2axi4_ahb.v 的语义重写：
//     · 新突发 = HSEL && HREADY && (HTRANS == NONSEQ)
//       （HREADY=1 本身就代表"上一拍已完成"，不额外要求状态机回 IDLE）
//
//     · 读：一拍 R 拍 ↔ 一拍 AHB 数据相位（HREADY = R 握手完成），
//           读数据相位与下一拍的地址相位天然重合。
//
//     · 写：AHB 的写数据相位紧跟在地址相位后【一拍】，而 AXI 的 W 通道要等
//           AW 握手后才能发（AW 有一拍锁存 + 握手延迟）。若直接把 HWDATA
//           接到 W 通道，采样会晚一拍 → 突发写整体错位（历史上实测到
//           "该写 a0..a3，结果写成 a1,a3,0,0"）。
//           因此这里加【一拍写数据缓冲】：在 AHB 数据相位把 HWDATA 与
//           WSTRB 一起抓进 wbuf，AHB 该拍即可完成；W 拍再按 AXI 侧节奏排出。
//           HREADY 在写时 = "缓冲空"，AXI 慢时自动把 AHB 顶住。
//           等 B 期间 HREADY=0，保证 B/HRESP 不会被下一笔突发覆盖。
//
//     · HRESP：按 AHB 规范做【两拍错误响应】——第一拍 HREADY=0 + HRESP=1，
//              第二拍 HREADY=1 + HRESP=1。
//
// ============================================================
// 【VALID/READY 铁律】
// ============================================================
//   AXI 主口的 VALID 只依赖"已锁存/已捕获"的状态，握手完成前不撤销；
//   READY 独立于 VALID。内部无组合环。
//
// ============================================================
// 【验证】TB/tb_ahb2axi.v + 顶层 TB/tb_soc.v
// ============================================================
`timescale 1ns/1ps

module ahb2axi #(
    parameter ADDR_W = 32,
    parameter DATA_W = 32,
    parameter ID_W   = 4
)(
    input  wire                 clk,
    input  wire                 rst_n,

    // ---- AHB-Lite 从口（任务四 1.2 / 0.4，接 Cortex-M0）----
    input  wire                 HSEL,
    input  wire [ADDR_W-1:0]    HADDR,
    input  wire [1:0]           HTRANS,
    input  wire                 HWRITE,
    input  wire [2:0]           HSIZE,
    input  wire [2:0]           HBURST,
    input  wire [3:0]           HPROT,
    input  wire [DATA_W-1:0]    HWDATA,
    output wire [DATA_W-1:0]    HRDATA,
    output wire                 HREADY,
    output wire                 HRESP,

    // ---- AXI4 主口（任务四 0.3，主设备 ID=0）----
    output wire [ID_W-1:0]      m_axi_awid,
    output wire [ADDR_W-1:0]    m_axi_awaddr,
    output wire [7:0]           m_axi_awlen,
    output wire [2:0]           m_axi_awsize,
    output wire [1:0]           m_axi_awburst,
    output wire                 m_axi_awvalid,
    input  wire                 m_axi_awready,
    output wire [DATA_W-1:0]    m_axi_wdata,
    output wire [DATA_W/8-1:0]  m_axi_wstrb,
    output wire                 m_axi_wlast,
    output wire                 m_axi_wvalid,
    input  wire                 m_axi_wready,
    input  wire [ID_W-1:0]      m_axi_bid,
    input  wire [1:0]           m_axi_bresp,
    input  wire                 m_axi_bvalid,
    output wire                 m_axi_bready,
    output wire [ID_W-1:0]      m_axi_arid,
    output wire [ADDR_W-1:0]    m_axi_araddr,
    output wire [7:0]           m_axi_arlen,
    output wire [2:0]           m_axi_arsize,
    output wire [1:0]           m_axi_arburst,
    output wire                 m_axi_arvalid,
    input  wire                 m_axi_arready,
    input  wire [ID_W-1:0]      m_axi_rid,
    input  wire [DATA_W-1:0]    m_axi_rdata,
    input  wire [1:0]           m_axi_rresp,
    input  wire                 m_axi_rlast,
    input  wire                 m_axi_rvalid,
    output wire                 m_axi_rready
);

    // ============================================================
    // 0. 常量
    // ============================================================
    localparam HTRANS_IDLE   = 2'b00;
    localparam HTRANS_NONSEQ = 2'b10;
    localparam HTRANS_SEQ    = 2'b11;

    localparam HBURST_SINGLE = 3'b000;
    localparam HBURST_INCR   = 3'b001;
    localparam HBURST_WRAP4  = 3'b010;
    localparam HBURST_INCR4  = 3'b011;
    localparam HBURST_WRAP8  = 3'b100;
    localparam HBURST_INCR8  = 3'b101;
    localparam HBURST_WRAP16 = 3'b110;
    localparam HBURST_INCR16 = 3'b111;

    localparam AXBURST_INCR  = 2'b01;

    // ============================================================
    // 1. 状态（全部先声明）
    // ============================================================
    // 当前突发参数
    reg  [ADDR_W-1:0] b_addr;
    reg  [2:0]        b_size;
    reg  [7:0]        b_len;
    reg               b_write;
    reg               b_incr;      // 1 = 未定义长度 INCR（每拍拆成一笔 AXI SINGLE）
    reg               act;
    reg               aw_done;
    reg               ar_done;
    reg               b_wait;
    reg  [1:0]        b_resp;

    // 读：已收到的 R 拍数
    reg  [7:0]        rcnt;

    // 写数据缓冲（一拍）：AHB 数据相位 → AXI W 通道
    reg               wbuf_v;
    reg  [DATA_W-1:0] wbuf_data;
    reg  [DATA_W/8-1:0] wbuf_strb;
    reg               wbuf_last;
    reg  [7:0]        wcap;        // 已捕获的 W 拍数

    // 写数据相位标志：突发地址相位被接受后的下一拍起，总线上就有"某一拍的写数据"
    reg               wdata_pend;

    // HRESP 两拍错误响应计数
    reg  [1:0]        err_cnt;

    // ============================================================
    // 2. 基础线网
    // ============================================================
    wire hready_sys = HREADY;                  // 单从设备：系统 HREADY 即自身

    wire aw_hs = m_axi_awvalid && m_axi_awready;
    wire w_hs  = m_axi_wvalid  && m_axi_wready;
    wire b_hs  = m_axi_bvalid  && m_axi_bready;
    wire ar_hs = m_axi_arvalid && m_axi_arready;
    wire r_hs  = m_axi_rvalid  && m_axi_rready;

    // 本拍 AHB 给的是一个"写拍"（地址相位）
    // 写数据相位：突发地址相位被接受后的下一拍起，直到最后一拍数据被抓走
    // 捕获一个 W 拍（抓到 = 本拍 AHB 数据相位完成）
    wire w_cap = wdata_pend && act && b_write && !wbuf_v;

    // 当前待捕获那一拍的字节地址（用于算 WSTRB）
    wire [ADDR_W-1:0] beat_off  = {{(ADDR_W-8){1'b0}}, wcap} << b_size;
    wire [ADDR_W-1:0] beat_addr = b_addr + beat_off;

    // 新事务：
    //   · NONSEQ            —— 一笔新突发 / 单拍的起点
    //   · 未定义长度 INCR 的后续 SEQ 拍 —— 每拍各自成为一笔 AXI SINGLE
    //   ⚠️ AHB 的 INCR 是"长度未定义"突发，长度由主机何时停止决定，桥无法预知。
    //      早期版本把 INCR 一律映射成 AWLEN=15（16 拍），提前把长度发了出去，
    //      而从设备会一直等第 16 拍 W → 写突发永远完不成。
    //      Cortex-M0 压 8 字异常帧（STMDB，正是 INCR 突发）就因此被写坏成
    //      0xFFFFFFFF，帧里 PC/xPSR 非法 → HardFault → 跳到 Default_Handler 卡死。
    //      所以 INCR 只能拆成 SINGLE，绝不能猜长度。
    wire new_burst = HSEL && hready_sys &&
                     ((HTRANS == HTRANS_NONSEQ) ||
                      (b_incr && (HTRANS == HTRANS_SEQ) && !act));

    // ============================================================
    // 3. 时序：事务参数、W 缓冲、拍计数、B 响应
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_addr    <= {ADDR_W{1'b0}};
            b_size    <= 3'd2;
            b_len     <= 8'd0;
            b_write   <= 1'b0;
            b_incr    <= 1'b0;
            act       <= 1'b0;
            aw_done   <= 1'b0;
            ar_done   <= 1'b0;
            b_wait    <= 1'b0;
            b_resp    <= 2'b00;
            rcnt      <= 8'd0;
            wbuf_v    <= 1'b0;
            wbuf_data <= {DATA_W{1'b0}};
            wbuf_strb <= {DATA_W/8{1'b0}};
            wbuf_last <= 1'b0;
            wcap      <= 8'd0;
            wdata_pend<= 1'b0;
            err_cnt   <= 2'd0;
        end
        else begin
            // ---- 写数据相位标志 ----
            //   突发地址相位被接受的下一拍起，总线上就挂着写数据；直到最后一拍抓完
            if (w_cap && (wcap >= b_len)) wdata_pend <= 1'b0;
            if (new_burst && HWRITE)      wdata_pend <= 1'b1;

            // ---- W 缓冲排出 ----
            if (w_hs) wbuf_v <= 1'b0;

            // ---- 错误响应：至少两拍，并保持到下一笔突发开始 ----
            //   （HRESP 属于"刚完成的那笔传输"，下一笔到来前主机随时可能采样）
            if (new_burst) err_cnt <= 2'd0;

            if (new_burst) begin
                // 新突发（可能紧跟上一笔最后一拍，中间没有 IDLE）
                b_addr  <= HADDR;
                b_size  <= HSIZE;
                b_incr  <= (HBURST == HBURST_INCR);
                b_len   <= (HBURST == HBURST_INCR) ? 8'd0 : len_of(HBURST);
                b_write <= HWRITE;
                act     <= 1'b1;
                aw_done <= 1'b0;
                ar_done <= 1'b0;
                b_wait  <= 1'b0;
                rcnt    <= 8'd0;
                wcap    <= 8'd0;
            end
            else if (act) begin
                if (b_write) begin
                    if (aw_hs) aw_done <= 1'b1;

                    // 在 AHB 数据相位抓走 HWDATA + WSTRB
                    if (w_cap) begin
                        wbuf_v    <= 1'b1;
                        wbuf_data <= HWDATA;
                        wbuf_strb <= wstrb_of(b_size, beat_addr[1:0]);
                        wbuf_last <= (wcap >= b_len);
                        if (wcap < b_len) wcap <= wcap + 8'd1;
                        else              b_wait <= 1'b1;   // 最后一拍已抓完 → 等 B
                    end

                    if (b_hs) begin
                        b_resp <= m_axi_bresp;
                        if (m_axi_bresp[1]) err_cnt <= 2'd2;   // 两拍错误响应
                        act    <= 1'b0;
                        b_wait <= 1'b0;
                    end
                end
                else begin
                    if (ar_hs) ar_done <= 1'b1;
                    if (r_hs) begin
                        if (m_axi_rresp[1]) err_cnt <= 2'd2;
                        if (rcnt < b_len) rcnt <= rcnt + 8'd1;
                        else              act  <= 1'b0;         // 最后一拍 → 突发结束
                    end
                end
            end
        end
    end

    // ============================================================
    // 4. HREADY / HRESP / HRDATA
    // ============================================================
    assign HRESP = (err_cnt != 2'd0);

    assign HREADY = (err_cnt != 2'd0) ? 1'b1                   // 错误已挂起：本拍可完成
                  : !act              ? 1'b1                   // 空闲：随时可收地址
                  // 等 B：末拍要等 B 才能把 BRESP 报成 HRESP。
                  //   无错 → 本拍即完成；有错 → 本拍不给 HREADY，改走上面两拍错误响应
                  :  b_wait           ? (b_hs && !m_axi_bresp[1])
                  // 写：非末拍靠"缓冲空"推进；末拍必须等 B 才知道有没有错，
                  //     因此末拍不给 HREADY，由上面的 b_wait 分支收尾
                  :  b_write          ? ((wcap < b_len) && !wbuf_v)
                  :                     r_hs;                  // 读：R 拍即数据相位

    assign HRDATA = m_axi_rdata;

    // ============================================================
    // 5. HBURST → AWLEN/ARLEN（统一 INCR）
    // ============================================================
    function [7:0] len_of;
        input [2:0] burst;
        begin
            case (burst)
                HBURST_INCR, HBURST_INCR16, HBURST_WRAP16 : len_of = 8'd15;
                HBURST_INCR4,  HBURST_WRAP4              : len_of = 8'd3;
                HBURST_INCR8,  HBURST_WRAP8              : len_of = 8'd7;
                default                                   : len_of = 8'd0;   // SINGLE
            endcase
        end
    endfunction

    // ============================================================
    // 6. WSTRB：HSIZE + 该拍地址低两位
    // ============================================================
    function [DATA_W/8-1:0] wstrb_of;
        input [2:0] sz;
        input [1:0] off;
        begin
            case (sz)
                3'd0   : wstrb_of = 4'b0001 << off;
                3'd1   : wstrb_of = 4'b0011 << off;
                default: wstrb_of = 4'b1111;
            endcase
        end
    endfunction

    // ============================================================
    // 7. AXI 主口输出
    // ============================================================
    // ---- 写地址 ----
    assign m_axi_awid    = {ID_W{1'b0}};
    assign m_axi_awaddr  = b_addr;
    assign m_axi_awlen   = b_len;
    assign m_axi_awsize  = b_size;
    assign m_axi_awburst = AXBURST_INCR;
    assign m_axi_awvalid = act && b_write && !aw_done;

    // ---- 写数据（来自缓冲，与 AW 握手延迟无关）----
    assign m_axi_wdata   = wbuf_data;
    assign m_axi_wstrb   = wbuf_strb;
    assign m_axi_wlast   = wbuf_last;
    assign m_axi_wvalid  = wbuf_v;

    // ---- 写响应 ----
    assign m_axi_bready  = act && b_write && b_wait;

    // ---- 读地址 ----
    assign m_axi_arid    = {ID_W{1'b0}};
    assign m_axi_araddr  = b_addr;
    assign m_axi_arlen   = b_len;
    assign m_axi_arsize  = b_size;
    assign m_axi_arburst = AXBURST_INCR;
    assign m_axi_arvalid = act && !b_write && !ar_done;

    // ---- 读数据 ----
    assign m_axi_rready  = act && !b_write;

endmodule
