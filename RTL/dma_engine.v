// ============================================================
// dma_engine.v —— 6 通道 DMA 的单通道数据搬运引擎（阶段3 分工 B）
//
// ============================================================
// 【接口契约】docs/阶段3-三人分工.md §2.2 契约 B（端口不许改）
// ============================================================
//   本模块是 6 通道 DMA 的【数据搬运引擎】，由顶层 dma.v 实例化 6 次。
//   每个引擎对外是一个标准 AXI4 主口，靠 ID 区分：
//       m_awid = m_arid = { CH[2:0], 1'b1 }   （契约 C，DMA 主设备 ID 低位=1）
//
//   AXI 互连（阶段 2）不用改，仍能靠 ID 区分"这是 DMA 还是 CPU"。
//
// ============================================================
// 【干什么】
// ============================================================
//   收到 start 一拍脉冲后，把 cfg_len 个字（32bit）从 cfg_src 搬到 cfg_dst：
//     · 读突发：AR/R，INCR 或 FIXED（cfg_src_inc 决定），RLAST 由拍数对齐
//     · 写突发：AW/W/B，INCR 或 FIXED（cfg_dst_inc 决定），WSTRB 全 1（整字）
//     · 单拍（LEN=0）是 INCR/FIXED 的 LEN=0 特例，不单独写一套
//   三种"传输场景"（存储器↔FIR、存储器↔存储器、UART↔存储器）在硬件上是
//   同一件事——把数据从 SRC 搬到 DST，差别只在地址是否递增（见 docs §3）：
//       SRC_INC=1 目的地地址每次 +4；SRC_INC=0 源地址固定（读 FIR DOUT / UART RXDATA）
//       DST_INC=1 目的地地址每次 +4；DST_INC=0 目的地址固定（写 FIR DIN / UART DATA）
//
// ============================================================
// 【4KB 边界自动拆分】
// ============================================================
//   AWLEN/ARLEN 最大 256 拍（LEN 是 8bit），且一个突发不许跨 4KB。
//   每段长度 = min( 剩余字数, 256, 源侧离 4KB 边界的字数, 目的侧离 4KB 边界的字数 )。
//   例：搬 1000 字、源地址 0x0F00 → 拆成 64 / 256 / 256 / 256 / 168 五段。
//
// ============================================================
// 【流控】
// ============================================================
//   读回来的数据先存进同步 FIFO（RTL/sync_fifo.v，深度 256 = 单段最大拍数），
//   写通道再从 FIFO 取数发 W 拍。读→写串行（先整段读进 FIFO，再整段写出），
//   简单且正确；"读超前、边读边写"是决赛吞吐优化，本阶段不做。
//
// ============================================================
// 【错误处理】
// ============================================================
//   RRESP=SLVERR：记录错误，但按 AXI 规范仍要收完本读突发的所有 R 拍
//                 （主设备不能取消已发出的读突发），收完后拉 err、停止（不写）。
//   BRESP=SLVERR：写突发已发完，直接拉 err、停止。
//
// ============================================================
// 【状态输出】
// ============================================================
//   busy   : 电平，搬运期间为 1
//   done   : 一拍脉冲，搬运完成
//   err    : 一拍脉冲，出错
//   status : bit0=BUSY / bit1=DONE / bit2=ERR（DONE/ERR 是粘滞位，下次 start 清除）
//
// ============================================================
// 【验证】TB/tb_dma_engine.v
// ============================================================
//   单拍 / INCR 突发 / 跨 4KB 长传输自动拆分 / SRC_INC=0、DST_INC=0（FIXED）/
//   错误响应停止 + err / done 脉冲与 status 位 / 挂 axi_protocol_checker 主口零违规。
// ============================================================
`timescale 1ns/1ps

module dma_engine #(
    parameter ADDR_W = 32,
    parameter DATA_W = 32,
    parameter ID_W   = 4,
    parameter LEN_W  = 8,
    parameter CH     = 0            // 通道号，用于生成 AXI ID
)(
    input  wire                clk,
    input  wire                rst_n,

    // ---- 配置（来自 dma_regs）----
    input  wire [ADDR_W-1:0]   cfg_src,
    input  wire [ADDR_W-1:0]   cfg_dst,
    input  wire [31:0]         cfg_len,       // 传输字数（32bit 字个数）
    input  wire                cfg_src_inc,   // 源地址是否递增（UART 读时为 0）
    input  wire                cfg_dst_inc,   // 目的地址是否递增（UART 写时为 0）
    input  wire                start,         // 一拍脉冲：启动本通道

    // ---- 状态 ----
    output wire                busy,
    output reg                 done,          // 完成脉冲（一拍）
    output reg                 err,           // 错误脉冲（一拍）
    output wire [31:0]         status,        // bit0 BUSY / bit1 DONE / bit2 ERR

    // ---- AXI4 主口（标准信号，交给顶层仲裁）----
    output wire [ID_W-1:0]     m_awid,
    output wire [ADDR_W-1:0]   m_awaddr,
    output wire [LEN_W-1:0]    m_awlen,
    output wire [2:0]          m_awsize,
    output wire [1:0]          m_awburst,
    output wire                m_awvalid,
    input  wire                m_awready,
    output wire [DATA_W-1:0]   m_wdata,
    output wire [DATA_W/8-1:0] m_wstrb,
    output wire                m_wlast,
    output wire                m_wvalid,
    input  wire                m_wready,
    input  wire [ID_W-1:0]     m_bid,
    input  wire [1:0]          m_bresp,
    input  wire                m_bvalid,
    output wire                m_bready,
    output wire [ID_W-1:0]     m_arid,
    output wire [ADDR_W-1:0]   m_araddr,
    output wire [LEN_W-1:0]    m_arlen,
    output wire [2:0]          m_arsize,
    output wire [1:0]          m_arburst,
    output wire                m_arvalid,
    input  wire                m_arready,
    input  wire [ID_W-1:0]     m_rid,
    input  wire [DATA_W-1:0]   m_rdata,
    input  wire [1:0]          m_rresp,
    input  wire                m_rlast,
    input  wire                m_rvalid,
    output wire                m_rready
);

    // ============================================================
    // 0. 常量
    // ============================================================
    localparam AXBURST_FIXED = 2'b00;
    localparam AXBURST_INCR  = 2'b01;

    localparam FIFO_DEPTH = 256;   // 单段最大拍数，FIFO 恰好能装一整段

    localparam S_IDLE    = 3'd0;
    localparam S_R_AR    = 3'd1;   // 发读地址
    localparam S_R_DATA  = 3'd2;   // 收读数据 → FIFO
    localparam S_W_AW    = 3'd3;   // 发写地址
    localparam S_W_DATA  = 3'd4;   // 从 FIFO 取数发写数据
    localparam S_W_B     = 3'd5;   // 等写响应
    localparam S_DONE    = 3'd6;   // 完成（一拍）
    localparam S_ERR     = 3'd7;   // 出错（一拍）

    // ============================================================
    // 1. 状态与配置锁存
    // ============================================================
    reg [2:0]        state, state_next;

    reg [ADDR_W-1:0] src_addr;     // 当前段源起始地址
    reg [ADDR_W-1:0] dst_addr;     // 当前段目的起始地址
    reg [31:0]       remaining;    // 剩余字数
    reg              src_inc;      // 锁存的 cfg_src_inc
    reg              dst_inc;      // 锁存的 cfg_dst_inc
    reg              err_flag;     // 本段读过程中出现过 SLVERR

    reg [8:0]        r_beat;       // 已收 R 拍数
    reg [8:0]        w_beat;       // 已发 W 拍数

    reg              done_latch;   // status 粘滞位
    reg              err_latch;

    // ============================================================
    // 2. 本段长度（组合计算，段内不变）
    // ============================================================
    reg [8:0]  seg_len;
    reg [31:0] seg_src_lim, seg_dst_lim;

    // 离 4KB 边界还能放多少字（FIXED 时地址不动，不设限）
    always @(*) begin
        if (!src_inc)                       seg_src_lim = 32'd256;
        else if (src_addr[11:0] > 12'hC00)  seg_src_lim = (32'd4096 - {20'b0, src_addr[11:0]}) >> 2;
        else                                seg_src_lim = 32'd256;

        if (!dst_inc)                       seg_dst_lim = 32'd256;
        else if (dst_addr[11:0] > 12'hC00)  seg_dst_lim = (32'd4096 - {20'b0, dst_addr[11:0]}) >> 2;
        else                                seg_dst_lim = 32'd256;

        // 三者取最小：剩余、源限制、目的限制
        if (remaining >= 32'd256)           seg_len = 9'd256;
        else                                seg_len = remaining[8:0];
        if (seg_src_lim < {23'b0, seg_len}) seg_len = seg_src_lim[8:0];
        if (seg_dst_lim < {23'b0, seg_len}) seg_len = seg_dst_lim[8:0];
        // AXI4 permits at most 16 beats for FIXED bursts.
        if ((!src_inc || !dst_inc) && seg_len > 9'd16) seg_len = 9'd16;
    end

    // ============================================================
    // 3. 握手与 AXI ID
    // ============================================================
    localparam [2:0] CH_ID = CH[2:0];
    wire [ID_W-1:0]  axi_id = {CH_ID, 1'b1};   // 契约 C：DMA 主设备 ID 低位=1

    wire ar_hs = m_arvalid && m_arready;
    wire r_hs  = m_rvalid  && m_rready;
    wire aw_hs = m_awvalid && m_awready;
    wire w_hs  = m_wvalid  && m_wready;
    wire b_hs  = m_bvalid  && m_bready;

    wire start_go = (state == S_IDLE) && start;

    // ============================================================
    // 4. 读数据暂存 FIFO
    // ============================================================
    wire [DATA_W-1:0] fifo_rdata;
    wire              fifo_empty, fifo_full;

    sync_fifo #(
        .WIDTH(DATA_W), .DEPTH(FIFO_DEPTH)
    ) u_fifo (
        .clk(clk), .rst_n(rst_n), .clr(start_go),
        .wen(r_hs), .wdata(m_rdata),
        .full(fifo_full),
        .ren(w_hs), .rdata(fifo_rdata), .empty(fifo_empty),
        .count()
    );

    // ============================================================
    // 5. 次态
    // ============================================================
    always @(*) begin
        state_next = state;
        case (state)
            S_IDLE: begin
                if (start_go) begin
                    if (cfg_len == 32'd0) state_next = S_DONE;
                    else if (cfg_src[1:0] != 0 || cfg_dst[1:0] != 0) state_next = S_ERR;
                    else                  state_next = S_R_AR;
                end
            end
            S_R_AR: begin
                if (ar_hs)                state_next = S_R_DATA;
            end
            S_R_DATA: begin
                if (r_hs) begin
                    if (r_beat == (seg_len - 9'd1)) begin
                        // 本段读完：有错则报错（不写），否则去写
                        if (err_flag || m_rresp[1]) state_next = S_ERR;
                        else                        state_next = S_W_AW;
                    end
                end
            end
            S_W_AW: begin
                if (aw_hs)                state_next = S_W_DATA;
            end
            S_W_DATA: begin
                if (w_hs && (w_beat == (seg_len - 9'd1)))
                                          state_next = S_W_B;
            end
            S_W_B: begin
                if (b_hs) begin
                    if (m_bresp[1])       state_next = S_ERR;
                    else if ((remaining - {23'b0, seg_len}) == 32'd0)
                                          state_next = S_DONE;
                    else if (cfg_src[1:0] != 0 || cfg_dst[1:0] != 0) state_next = S_ERR;
                    else                  state_next = S_R_AR;
                end
            end
            S_DONE:                       state_next = S_IDLE;
            S_ERR :                       state_next = S_IDLE;
            default:                      state_next = S_IDLE;
        endcase
    end

    // ============================================================
    // 6. 时序逻辑
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            src_addr    <= {ADDR_W{1'b0}};
            dst_addr    <= {ADDR_W{1'b0}};
            remaining   <= 32'd0;
            src_inc     <= 1'b0;
            dst_inc     <= 1'b0;
            err_flag    <= 1'b0;
            r_beat      <= 9'd0;
            w_beat      <= 9'd0;
            done_latch  <= 1'b0;
            err_latch   <= 1'b0;
            done        <= 1'b0;
            err         <= 1'b0;
        end
        else begin
            state <= state_next;
            done  <= 1'b0;
            err   <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start_go) begin
                        src_addr   <= cfg_src;
                        dst_addr   <= cfg_dst;
                        remaining  <= cfg_len;
                        src_inc    <= cfg_src_inc;
                        dst_inc    <= cfg_dst_inc;
                        err_flag   <= 1'b0;
                        done_latch <= 1'b0;
                        err_latch  <= 1'b0;
                    end
                end
                S_R_AR: begin
                    if (ar_hs) r_beat <= 9'd0;
                end
                S_R_DATA: begin
                    if (r_hs) begin
                        if (m_rresp[1]) err_flag <= 1'b1;
                        r_beat <= r_beat + 9'd1;
                    end
                end
                S_W_AW: begin
                    if (aw_hs) w_beat <= 9'd0;
                end
                S_W_DATA: begin
                    if (w_hs) w_beat <= w_beat + 9'd1;
                end
                S_W_B: begin
                    if (b_hs) begin
                        if (src_inc) src_addr <= src_addr + ({23'b0, seg_len} << 2);
                        if (dst_inc) dst_addr <= dst_addr + ({23'b0, seg_len} << 2);
                        remaining <= remaining - {23'b0, seg_len};
                    end
                end
                S_DONE: begin
                    done       <= 1'b1;
                    done_latch <= 1'b1;
                end
                S_ERR: begin
                    err        <= 1'b1;
                    err_latch  <= 1'b1;
                end
                default: ;
            endcase
        end
    end

    // ============================================================
    // 7. 输出
    // ============================================================
    assign busy = (state != S_IDLE) && (state != S_DONE) && (state != S_ERR);
    assign status = {29'b0, err_latch, done_latch, busy};

    // ---- AXI 读 ----
    assign m_arid    = axi_id;
    assign m_araddr  = src_addr;
    assign m_arlen   = seg_len - 9'd1;
    assign m_arsize  = 3'd2;                         // 整字（32bit）
    assign m_arburst = src_inc ? AXBURST_INCR : AXBURST_FIXED;
    assign m_arvalid = (state == S_R_AR);
    assign m_rready  = (state == S_R_DATA);

    // ---- AXI 写 ----
    assign m_awid    = axi_id;
    assign m_awaddr  = dst_addr;
    assign m_awlen   = seg_len - 9'd1;
    assign m_awsize  = 3'd2;
    assign m_awburst = dst_inc ? AXBURST_INCR : AXBURST_FIXED;
    assign m_awvalid = (state == S_W_AW);

    assign m_wdata   = fifo_rdata;
    assign m_wstrb   = {DATA_W/8{1'b1}};            // 整字传输，选通全 1
    assign m_wlast   = (state == S_W_DATA) && (w_beat == (seg_len - 9'd1));
    assign m_wvalid  = (state == S_W_DATA);

    assign m_bready  = (state == S_W_B);

endmodule
