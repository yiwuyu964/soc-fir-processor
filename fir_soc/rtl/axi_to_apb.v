// ============================================================
// axi_to_apb.v —— AXI4 从设备 → APB 主设备 的协议桥
//
// 赛题原文要求：
//   "AHB到AXI接口桥（Cortex-M0），AXI到APB接口桥（UART）"
//   本模块就是后半句那个 AXI → APB 桥。
//
// 为什么需要它：
//   APB 是 AMBA 家族里最简单的总线（8 根信号、没有突发、不流水），
//   低速外设（UART / 定时器 / GPIO / 看门狗）挂在它上面成本最低。
//   但 CPU 侧出来的是 AXI4，所以中间要有一个"翻译"。
//
//     Cortex-M0 ──AXI4──▶ [本桥] ──APB──▶ UART / 定时器 / GPIO
//
// ------------------------------------------------------------
// 接口形态（为什么长这样）
// ------------------------------------------------------------
// 1) 从设备侧是【AXI4】而不是 AXI-Lite：
//    Cortex-M0 DesignStart 的 AHB→AXI 桥输出的是带 AWLEN/AWSIZE/AWBURST
//    的完整 AXI4。本桥直接对接，省掉一级 axi4_to_axilite，
//    而且突发信息不会在转换中被丢掉（AXI-Lite 没有突发）。
//
// 2) 没有 ID 信号（AWID/BID/ARID/RID）：
//    M0 的 AXI 口本身就没有 ID——单主设备、顺序完成，符合协议。
//
// 3) 没有 WSTRB：
//    M0 的 AHB 侧没有写选通，它的 AXI 写数据通道也不输出 WSTRB。
//    本桥按 AWSIZE + 当前地址自动算出 APB 的 PSTRB，窄传输也能正确工作。
//
// ------------------------------------------------------------
// 支持的 AXI 特性
// ------------------------------------------------------------
//   ✅ 单拍        （AWLEN = 0）
//   ✅ INCR 突发   （地址逐拍递增，APB 侧拆成多次传输）
//   ✅ FIXED 突发  （地址固定，用于 FIFO 端口）
//   ✅ 窄传输      （按 AWSIZE 生成 PSTRB）
//   ❌ WRAP 突发   → 返回 SLVERR（M0 访问外设不会产生 WRAP）
//   ❌ 多个未完成事务（一次只处理一笔；读写之间轮转，不会饿死）
//
// ------------------------------------------------------------
// APB 传输时序（IHI0024 第 3 章 / 第 4 章）
// ------------------------------------------------------------
//   IDLE   : PSEL=0 PENABLE=0
//   SETUP  : PSEL=1 PENABLE=0   PADDR/PWRITE/PWDATA 有效    ← 固定 1 拍
//   ACCESS : PSEL=1 PENABLE=1                                ← 等 PREADY
//            PREADY=1 时： 写 → 传输完成
//                          读 → PRDATA 有效
//
// 信号映射：
//   AWADDR  → PADDR          WDATA   → PWDATA
//   (AWSIZE + 地址) → PSTRB  PRDATA  → RDATA
//   PSLVERR → BRESP / RRESP = SLVERR (2'b10)
//
// ------------------------------------------------------------
// 超时保护（可选）
// ------------------------------------------------------------
//   APB 从设备若一直不拉 PREADY，AXI 主设备会永久等待，形成死锁。
//   TIMEOUT > 0 时，ACCESS 等待超过 TIMEOUT 拍就返回 SLVERR，
//   把"死锁"变成"可恢复的错误响应"。
//   仿真时建议保持 0（关闭），这样从设备自身的 bug 不会被掩盖。
// ============================================================
`timescale 1ns/1ps

module axi_to_apb #(
    parameter ADDR_W  = 32,
    parameter DATA_W  = 32,
    parameter TIMEOUT = 0              // 0 = 关闭超时保护
)(
    input  wire                 clk,
    input  wire                 rst_n,

    // ---- AXI4 从设备侧（连 Cortex-M0 或 AXI 互连）----
    input  wire                 awvalid,
    output wire                 awready,
    input  wire [ADDR_W-1:0]    awaddr,
    input  wire [7:0]           awlen,
    input  wire [2:0]           awsize,
    input  wire [1:0]           awburst,

    input  wire                 wvalid,
    output wire                 wready,
    input  wire [DATA_W-1:0]    wdata,
    input  wire                 wlast,

    output reg  [1:0]           bresp,
    output reg                  bvalid,
    input  wire                 bready,

    input  wire                 arvalid,
    output wire                 arready,
    input  wire [ADDR_W-1:0]    araddr,
    input  wire [7:0]           arlen,
    input  wire [2:0]           arsize,
    input  wire [1:0]           arburst,

    output reg  [DATA_W-1:0]    rdata,
    output reg  [1:0]           rresp,
    output reg                  rlast,
    output reg                  rvalid,
    input  wire                 rready,

    // ---- APB 主设备侧（连 UART / 定时器 / GPIO 等）----
    output wire                 psel,
    output wire                 penable,
    output wire [ADDR_W-1:0]    paddr,
    output wire                 pwrite,
    output wire [DATA_W-1:0]    pwdata,
    output wire [DATA_W/8-1:0]  pstrb,
    output wire [2:0]           pprot,
    input  wire [DATA_W-1:0]    prdata,
    input  wire                 pready,
    input  wire                 pslverr
);

    // ============================================================
    // 常量
    // ============================================================
    localparam RESP_OKAY   = 2'b00;
    localparam RESP_SLVERR = 2'b10;

    localparam BURST_FIXED = 2'b00;
    localparam BURST_INCR  = 2'b01;
    localparam BURST_WRAP  = 2'b10;

    localparam S_IDLE   = 3'd0;
    localparam S_GETW   = 3'd1;
    localparam S_SETUP  = 3'd2;
    localparam S_ACCESS = 3'd3;
    localparam S_BRESP  = 3'd4;
    localparam S_RBEAT  = 3'd5;

    // ============================================================
    // 状态与寄存器
    // ============================================================
    reg [2:0]        state;
    reg              is_write;      // 当前事务是写(1)还是读(0)
    reg              wr_pending;    // 有写事务在处理中
    reg              rr;            // 读写轮转位（防止读被写饿死）
    reg              abort;         // 当前事务是不支持的突发类型：只回错误、不碰 APB

    reg [ADDR_W-1:0] cur_addr;      // 当前这一拍的 APB 地址
    reg [7:0]        beat;          // 当前第几拍（0 起）

    // 写事务参数
    reg [7:0]        w_len;
    reg [2:0]        w_size;
    reg [1:0]        w_burst;
    reg [DATA_W-1:0] beat_data;

    // 读事务参数
    reg [7:0]        r_len;
    reg [2:0]        r_size;
    reg [1:0]        r_burst;

    reg [15:0]       wait_cnt;      // 超时计数

    // PPROT：普通访问、安全态、数据访问（IHI0024 第 2 章）
    assign pprot = 3'b000;

    // ------------------------------------------------------------
    // APB 控制信号由【当前状态】直接组合产生，不放在时序块里赋值。
    // 原因：如果在 S_ACCESS 分支里 psel<=1，那么状态切走的那一拍 psel 仍会
    // 保持高电平，APB 从设备会把同一次传输又执行一遍（读会重读、
    // 写会重复写），时序也对不上。组合产生可以保证状态一走、信号立刻撤。
    //   S_SETUP  : PSEL=1 PENABLE=0      （固定 1 拍）
    //   S_ACCESS : PSEL=1 PENABLE=1      （保持到 PREADY）
    // ------------------------------------------------------------
    assign psel    = (state == S_SETUP) || (state == S_ACCESS);
    assign penable = (state == S_ACCESS);

    // ============================================================
    // 握手条件
    // ============================================================
    wire aw_hs = awvalid && awready;
    wire w_hs  = wvalid  && wready;
    wire ar_hs = arvalid && arready;
    wire b_hs  = bvalid  && bready;
    wire r_hs  = rvalid  && rready;

    // ---- AXI 从设备 ready：只在空闲态、且没有未完成响应时接收 ----
    assign awready = (state == S_IDLE) && !wr_pending && !bvalid;
    assign arready = (state == S_IDLE) && !wr_pending && !rvalid;
    assign wready  = (state == S_GETW);

    // ============================================================
    // 地址步进与写选通
    // ============================================================
    wire [ADDR_W-1:0] size_r  = {{(ADDR_W-3){1'b0}}, is_write ? w_size : r_size};
    wire [ADDR_W-1:0] burst_r = {{(ADDR_W-2){1'b0}}, is_write ? w_burst : r_burst};
    wire [ADDR_W-1:0] addr_step = {{(ADDR_W-1){1'b0}}, 1'b1} << size_r;
    wire [ADDR_W-1:0] next_addr = (burst_r == BURST_FIXED) ? cur_addr
                                                          : (cur_addr + addr_step);

    // PSTRB：按传输大小和地址低位算出有效字节通道
    //   size=0(1字节) → 0001 << addr[1:0]
    //   size=1(2字节) → 0011 << addr[1:0]
    //   size>=2       → 1111
    function [DATA_W/8-1:0] strb_of;
        input [2:0] sz;
        input [1:0] off;
        begin
            case (sz)
                3'd0:    strb_of = 4'b0001 << off;
                3'd1:    strb_of = 4'b0011 << off;
                default: strb_of = 4'b1111;
            endcase
        end
    endfunction

    // ------------------------------------------------------------
    // PADDR / PWRITE / PWDATA / PSTRB 同样由组合逻辑给出。
    // 若放在时序块里赋值，进入 SETUP 的第一拍它们仍是【上一笔的旧值】，
    // 到 ACCESS 才变过来——这违反 APB 协议（SETUP 阶段地址就必须有效）。
    // ------------------------------------------------------------
    assign paddr  = cur_addr;
    assign pwrite = is_write;
    assign pwdata = is_write ? beat_data : {DATA_W{1'b0}};
    assign pstrb  = is_write ? strb_of(w_size, cur_addr[1:0])
                             : {(DATA_W/8){1'b1}};

    // ============================================================
    // 主状态机
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            is_write  <= 1'b0;
            wr_pending<= 1'b0;
            rr        <= 1'b0;
            abort     <= 1'b0;
            cur_addr  <= {ADDR_W{1'b0}};
            beat      <= 8'd0;
            w_len     <= 8'd0;
            w_size    <= 3'd0;
            w_burst   <= 2'd0;
            beat_data <= {DATA_W{1'b0}};
            r_len     <= 8'd0;
            r_size    <= 3'd0;
            r_burst   <= 2'd0;
            wait_cnt  <= 16'd0;
            // paddr/pwrite/pwdata/pstrb 是组合信号，不需要复位
            // pwrite/pwdata/pstrb 同 paddr，都是组合信号，不需要复位
            bresp     <= RESP_OKAY;
            bvalid    <= 1'b0;
            rdata     <= {DATA_W{1'b0}};
            rresp     <= RESP_OKAY;
            rlast     <= 1'b0;
            rvalid    <= 1'b0;
        end
        else begin
            // ---- 默认输出（各状态按需覆盖）----
            // 注意：psel / penable 不在这里赋值，由状态组合产生（见上）
            bvalid  <= 1'b0;
            rvalid  <= 1'b0;

            case (state)

            // ---------------------------------------------------
            // 空闲：决定下一笔做读还是写，并锁存地址
            // ---------------------------------------------------
            S_IDLE: begin
                wr_pending <= 1'b0;
                wait_cnt   <= 16'd0;

                // 读写轮转：上一笔是写，这一笔优先读，反之亦然
                if (aw_hs && (!arvalid || rr) ) begin
                    // ---- 接受一笔写 ----
                    is_write  <= 1'b1;
                    wr_pending<= 1'b1;
                    rr        <= 1'b0;
                    cur_addr  <= awaddr;
                    w_len     <= awlen;
                    w_size    <= awsize;
                    w_burst   <= awburst;
                    beat      <= 8'd0;
                    // WRAP 不支持：标记 abort，但仍然必须把 W 数据全部收完。
                    // 依据 AXI 协议：即使要返回错误响应，从设备也必须接收所有写数据拍，
                    // 否则主设备的 W 通道会一直等 WREADY，整条总线挂死。
                    abort     <= (awburst == BURST_WRAP);
                    state     <= S_GETW;
                end
                else if (ar_hs) begin
                    // ---- 接受一笔读 ----
                    is_write  <= 1'b0;
                    rr        <= 1'b1;
                    cur_addr  <= araddr;
                    r_len     <= arlen;
                    r_size    <= arsize;
                    r_burst   <= arburst;
                    beat      <= 8'd0;
                    abort     <= (arburst == BURST_WRAP);

                    if (arburst == BURST_WRAP) begin
                        // WRAP 不支持：逐拍回 SLVERR，RLAST 落在最后一拍。
                        // 不提前终止突发，避免主设备侧行为不确定。
                        rdata  <= {DATA_W{1'b0}};
                        rresp  <= RESP_SLVERR;
                        rlast  <= (arlen == 8'd0);
                        rvalid <= 1'b1;
                        state  <= S_RBEAT;
                    end else begin
                        state <= S_SETUP;
                    end
                end
            end

            // ---------------------------------------------------
            // 取一拍写数据（AXI 的 W 通道是逐拍给的）
            // ---------------------------------------------------
            S_GETW: begin
                if (w_hs) begin
                    if (abort) begin
                        // 不支持的突发：数据照收（丢弃），收完最后一拍再回 SLVERR
                        if (beat == w_len) begin
                            bresp      <= RESP_SLVERR;
                            bvalid     <= 1'b1;
                            wr_pending <= 1'b0;
                            state      <= S_BRESP;
                        end else begin
                            beat  <= beat + 8'd1;
                            state <= S_GETW;
                        end
                    end else begin
                        beat_data <= wdata;
                        state     <= S_SETUP;
                    end
                end
            end

            // ---------------------------------------------------
            // APB SETUP：固定 1 拍
            // ---------------------------------------------------
            S_SETUP: begin
                // PADDR/PWRITE/PWDATA/PSTRB 由组合逻辑给出（见上），
                // 保证从 SETUP 第一拍起就有效，符合 APB 协议。
                wait_cnt<= 16'd0;
                state   <= S_ACCESS;
            end

            // ---------------------------------------------------
            // APB ACCESS：等 PREADY
            // ---------------------------------------------------
            S_ACCESS: begin
                if (pready) begin
                    // ---------------- 这次 APB 传输完成 ----------------
                    if (is_write) begin
                        if (pslverr || (beat == w_len)) begin
                            bresp      <= pslverr ? RESP_SLVERR : RESP_OKAY;
                            bvalid     <= 1'b1;
                            wr_pending <= 1'b0;
                            state      <= S_BRESP;
                        end else begin
                            cur_addr <= next_addr;
                            beat     <= beat + 8'd1;
                            state    <= S_GETW;
                        end
                    end
                    else begin
                        rdata  <= prdata;
                        rresp  <= pslverr ? RESP_SLVERR : RESP_OKAY;
                        rlast  <= (beat == r_len);
                        rvalid <= 1'b1;
                        state  <= S_RBEAT;
                    end
                end
                else if (TIMEOUT != 0 && wait_cnt == TIMEOUT-1) begin
                    // ---------------- 从设备超时 → 报错，避免死锁 ----------------
                    if (is_write) begin
                        bresp      <= RESP_SLVERR;
                        bvalid     <= 1'b1;
                        wr_pending <= 1'b0;
                        state      <= S_BRESP;
                    end else begin
                        rdata  <= {DATA_W{1'b0}};
                        rresp  <= RESP_SLVERR;
                        rlast  <= 1'b1;
                        rvalid <= 1'b1;
                        state  <= S_RBEAT;
                    end
                end
                else begin
                    wait_cnt <= wait_cnt + 16'd1;
                end
            end

            // ---------------------------------------------------
            // 等待写响应被主设备取走
            // ---------------------------------------------------
            S_BRESP: begin
                bvalid <= 1'b1;
                if (b_hs) begin
                    bvalid <= 1'b0;
                    state  <= S_IDLE;
                end
            end

            // ---------------------------------------------------
            // 等待读数据拍被主设备取走
            // ---------------------------------------------------
            S_RBEAT: begin
                rvalid <= 1'b1;
                if (r_hs) begin
                    if (rlast) begin
                        rvalid <= 1'b0;
                        state  <= S_IDLE;
                    end
                    else if (abort) begin
                        // 不支持的突发：继续把剩下的错误拍发完
                        beat  <= beat + 8'd1;
                        rdata <= {DATA_W{1'b0}};
                        rresp <= RESP_SLVERR;
                        rlast <= (beat + 8'd1 == r_len);
                    end
                    else begin
                        // 关键：这一拍的数据已经被主设备取走，必须立刻撤销 RVALID。
                        // case 是按"当前状态"执行的，如果不在这里清掉，
                        // 顶部的 rvalid<=1 会让 RVALID 多保持一拍，
                        // 主设备会把同一拍数据采两次，剩下的突发就没人接了。
                        rvalid   <= 1'b0;
                        cur_addr <= next_addr;
                        beat     <= beat + 8'd1;
                        state    <= S_SETUP;
                    end
                end
            end

            endcase
        end
    end

endmodule
