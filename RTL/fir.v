// ============================================================
// fir.v —— 81 阶可配置系数 FIR 的 AXI4 从接口 + 中断（阶段1 分工 B）
//
// ============================================================
// 【接口契约】docs/契约1-接口契约（冻结版）.md §契约 B / C
// ============================================================
//   权威来源（不许改，改了要全队重新确认）：
//     · 端口      ：docs/任务4-模块接口信号清单.md 1.5 节 + 0.3 节模板
//     · 寄存器映射：docs/任务3-地址映射与中断分配.md 4.1 节
//
//   端口：AXI4 从口（5 通道，带 ID，ID_W=4，s_ 前缀）+ irq_done / irq_err
//   基址：0x4000_0000（本模块只译码 4KB 内的偏移；基址高位由 AXI 互连译码）
//
// ============================================================
// 【寄存器映射】（契约 C，严格照抄）
// ============================================================
//   CTRL    @0x000        W  bit0=1 清空延迟线与输出 FIFO（同时清中断锁存）
//   DIN     @0x004        W  写一个样本（低 16bit，Q1.15），一拍 en 进 fir_core
//   DOUT    @0x008        R  读一个滤波结果（低 16bit），弹出输出 FIFO
//   STATUS  @0x00C        R  [31:16]fifo_count / [3]err / [2]done
//                            [1]fifo_full / [0]fifo_empty（位定义见任务三 4.1）
//   COEF[k] @0x100 + 4k   W  第 k 个系数（k=0..81），占 0x100 ~ 0x247
//
// ============================================================
// 【中断】（契约 B / 任务三 4.1，已确认 [2]=done、[3]=err）
// ============================================================
//   irq_done → IRQ0：有新结果可取。电平（高有效）：
//     · 每 push 一个结果置 1
//     · 读 STATUS 清除；FIFO 被读空也自动清（避免悬空的电平）
//     · CTRL flush 清除
//   irq_err  → IRQ1：错误。电平（高有效）：
//     · 溢出：FIFO 满时又出结果（该结果丢弃）
//     · 读空：DOUT 空时来读（该拍回 SLVERR）
//     · 读 STATUS 清除；CTRL flush 清除
//
// ============================================================
// 【支持的 AXI4 特性】（契约 B：单拍 + INCR 突发）
// ============================================================
//   ✅ 单拍（LEN=0）
//   ✅ INCR 突发（地址按 AWSIZE 递增；突发不跨 4KB，由区域预检保证）
//   ✅ FIXED 突发（地址不变；DIN 是单地址，多拍样本用 FIXED 流式写入）
//   ✅ AWID/ARID → BID/RID 透传（ID_W=4，支持互连按 ID 路由）
//   ✅ AWLEN/ARLEN 数拍、WLAST 对齐检查（beat==AWLEN 或 WLAST 提前到都收尾）
//   ✅ WSTRB 写选通：CTRL 看 byte0；DIN/COEF 看低 16bit（0000 = 空写不生效）
//   ✅ AWSIZE ≤ 2（字节 / 半字 / 字，M0 桥与 DMA 都只会用这些）
//   ❌ WRAP 突发、AWSIZE > 2 → SLVERR
//   ❌ 非法地址（非寄存器偏移）、访问类型不符（写只读 / 读只写）→ SLVERR
//   错误策略：AW/AR 接受时对整笔突发做区域预检，任一拍非法 → 整笔 SLVERR
//            且【无副作用】（写数据全部丢弃、DOUT 不弹、STATUS 不清）。
//             依据 AXI 协议：即使回错误，写数据也必须全部收完，否则 W 通道挂死。
//
// ============================================================
// 【VALID/READY 铁律】
// ============================================================
//   · VALID（BVALID/RVALID）是寄存器输出，从不看 READY；握手完成才撤销。
//   · READY 是组合输出，只在空闲态给出；AW/AR 同时有效时按 rr 轮转仲裁，
//     同一拍最多完成一个握手（不会出现"握了手但参数没锁存"的丢事务）。
//   · 通道之间无组合环：AW/W → fir_core（打拍）→ FIFO（打拍）→ R，
//     写侧不依赖读侧状态，读侧不依赖写侧握手。
//
// ============================================================
// 【数据流】
// ============================================================
//   AXI 写 DIN  → en 一拍 + din → fir_core（延迟 5 拍，吞吐 1 sample/cycle）
//   fir_core dout/dout_v → 输出 FIFO（512 深）→ AXI 读 DOUT 弹出
//   ⚠️ 前导 0：flush 后第 1 个 dout_v 是"延迟线全零"的结果（恒 0），也进 FIFO。
//       C 驱动用一次多余读丢掉它；TB 按 got[i+1]==exp[i] 比对（契约 E.6）。
//
// ============================================================
// 【验证】TB/tb_fir.v
// ============================================================
//   单拍读写 / INCR 写突发（82 拍系数）/ INCR 读突发（DOUT+STATUS+RLAST）/
//   FIXED 突发（256 拍 DIN、多拍 DOUT 排空）/ WSTRB（字节 flush、半字 DIN、
//   空写）/ 错误响应（WRAP、SIZE>2、非法地址、访问类型、跨 4KB）/ 中断
//   （done 置位清除、err 读空、FIFO 溢出）/ 336 个结果与黄金模型逐位一致。
// ============================================================
`timescale 1ns/1ps

module fir #(
    parameter ADDR_W     = 32,       // AXI 地址宽度（任务四 0.1）
    parameter DATA_W     = 32,       // AXI 数据宽度
    parameter ID_W       = 4,        // AXI 事务 ID 宽度（区分 2 个主设备）
    parameter DW         = 16,       // fir_core 数据位宽 Q1.15
    parameter CW         = 16,       // fir_core 系数位宽 Q1.15
    parameter AW         = 40,       // fir_core 累加器位宽
    parameter NTAP       = 82,       // 81st order = 82 independently writable taps
    parameter FIFO_DEPTH = 512       // 输出 FIFO 深度（容纳 337 个结果绰绰有余）
)(
    input  wire                 clk,
    input  wire                 rst_n,

    // ---- AXI4 从口 · 写地址通道 AW ----
    input  wire [ID_W-1:0]      s_axi_awid,
    input  wire [ADDR_W-1:0]    s_axi_awaddr,
    input  wire [7:0]           s_axi_awlen,
    input  wire [2:0]           s_axi_awsize,
    input  wire [1:0]           s_axi_awburst,
    input  wire                 s_axi_awvalid,
    output wire                 s_axi_awready,
    // ---- AXI4 从口 · 写数据通道 W ----
    input  wire [DATA_W-1:0]    s_axi_wdata,
    input  wire [DATA_W/8-1:0]  s_axi_wstrb,
    input  wire                 s_axi_wlast,
    input  wire                 s_axi_wvalid,
    output wire                 s_axi_wready,
    // ---- AXI4 从口 · 写响应通道 B ----
    output wire [ID_W-1:0]      s_axi_bid,
    output wire [1:0]           s_axi_bresp,
    output wire                 s_axi_bvalid,
    input  wire                 s_axi_bready,
    // ---- AXI4 从口 · 读地址通道 AR ----
    input  wire [ID_W-1:0]      s_axi_arid,
    input  wire [ADDR_W-1:0]    s_axi_araddr,
    input  wire [7:0]           s_axi_arlen,
    input  wire [2:0]           s_axi_arsize,
    input  wire [1:0]           s_axi_arburst,
    input  wire                 s_axi_arvalid,
    output wire                 s_axi_arready,
    // ---- AXI4 从口 · 读数据通道 R ----
    output wire [ID_W-1:0]      s_axi_rid,
    output wire [DATA_W-1:0]    s_axi_rdata,
    output wire [1:0]           s_axi_rresp,
    output wire                 s_axi_rlast,
    output wire                 s_axi_rvalid,
    input  wire                 s_axi_rready,

    // ---- 中断（任务四 1.5 / 契约 B）----
    output wire                 irq_done,   // 滤波完成：结果可取，电平，读 STATUS 清 → IRQ0
    output wire                 irq_err     // 错误：溢出 / 读空，电平，读 STATUS 清 → IRQ1
);

    // ============================================================
    // 0. 常量
    // ============================================================
    localparam RESP_OKAY   = 2'b00;
    localparam RESP_SLVERR = 2'b10;

    localparam BURST_FIXED = 2'b00;
    localparam BURST_INCR  = 2'b01;
    localparam BURST_WRAP  = 2'b10;

    localparam [11:0] OFF_CTRL   = 12'h000;   // CTRL
    localparam [11:0] OFF_DIN    = 12'h004;   // DIN
    localparam [11:0] OFF_DOUT   = 12'h008;   // DOUT
    localparam [11:0] OFF_STATUS = 12'h00C;   // STATUS
    localparam [11:0] OFF_COEF   = 12'h100;   // COEF[0]
    localparam [11:0] OFF_COEF_END = OFF_COEF + 4*(NTAP-1) + 3;   // COEF[81] 末字节 = 0x247

    localparam CNT_W = $clog2(FIFO_DEPTH+1);  // FIFO 计数位宽（DEPTH=512 → 10）

    localparam S_IDLE  = 2'd0;                // 空闲：只在这里收 AW/AR
    localparam S_GETW  = 2'd1;                // 逐拍收 W 数据
    localparam S_BRESP = 2'd2;                // 等主设备取走写响应
    localparam S_RBEAT = 2'd3;                // 逐拍给读数据

    // ============================================================
    // 1. 状态与事务参数寄存器
    // ============================================================
    reg [1:0]        state;
    reg              rr;              // 读写轮转位：防止写（或读）饿死对方
    reg              abort;           // 当前事务不支持/非法：只回错误、无副作用

    reg [ID_W-1:0]   awid_r;          // AWID 锁存 → BID
    reg [ID_W-1:0]   arid_r;          // ARID 锁存 → RID
    reg [7:0]        w_len, r_len;
    reg [2:0]        w_size, r_size;
    reg [1:0]        w_burst, r_burst;
    reg [ADDR_W-1:0] cur_addr;        // 当前这一拍的地址（INCR 逐拍递增）
    reg [7:0]        beat;            // 当前第几拍（0 起）

    reg [1:0]        bresp;
    reg              bvalid;
    reg              rlast;
    reg              rvalid;

    // fir_core 侧的一拍脉冲 / 数据（W 拍握手当拍给出）
    reg              flush;           // CTRL bit0=1：清延迟线 + 清 FIFO + 清中断锁存
    reg              en;              // DIN 拍：一拍 en
    reg  [DW-1:0]    din;             // DIN 拍：样本
    reg              coef_we;         // COEF 拍：一拍写使能
    reg  [$clog2(NTAP)-1:0] coef_idx;
    reg  [CW-1:0]    coef_din;

    // 中断锁存（电平输出）
    reg              irq_done_latch;
    reg              err_latch;

    // ============================================================
    // 2. 握手与 READY（VALID 从不看 READY；READY 只在空闲态）
    // ============================================================
    wire in_idle = (state == S_IDLE);

    // AW/AR 同时有效时按 rr 轮转：保证同一拍最多完成一个握手
    assign s_axi_awready = in_idle && !bvalid && (rr || !s_axi_arvalid);
    assign s_axi_arready = in_idle && !rvalid && (!rr || !s_axi_awvalid);
    assign s_axi_wready  = (state == S_GETW);

    wire aw_hs = s_axi_awvalid && s_axi_awready;
    wire w_hs  = s_axi_wvalid  && s_axi_wready;
    wire ar_hs = s_axi_arvalid && s_axi_arready;
    wire b_hs  = bvalid && s_axi_bready;
    wire r_hs  = rvalid && s_axi_rready;

    // ============================================================
    // 3. 突发预检（AW/AR 接受时组合计算，从输入信号直接算）
    //    规则：整笔突发的字节范围必须完全落在【同一类合法区域】内，
    //    否则整笔 SLVERR 且无副作用。区域检查天然保证"突发不跨 4KB"。
    // ============================================================
    // ---- 写侧：合法区域 = CTRL[0,3] / DIN[4,7] / COEF[0x100, 0x247] ----
    wire [13:0] w_nbeats = {6'd0, s_axi_awlen} + 14'd1;
    wire [13:0] w_bytes  = (s_axi_awburst == BURST_FIXED) ? (14'd1 << s_axi_awsize)
                                                          : (w_nbeats << s_axi_awsize);
    wire [13:0] w_start  = {2'd0, s_axi_awaddr[11:0]};
    wire [13:0] w_end    = w_start + w_bytes - 14'd1;

    wire aw_in_ctrl = (w_start >= 14'h000) && (w_end <= 14'h003);
    wire aw_in_din  = (w_start >= 14'h004) && (w_end <= 14'h007);
    wire aw_in_coef = (w_start >= 14'h100) && (w_end <= {2'd0, OFF_COEF_END});
    wire aw_ok      = (s_axi_awsize <= 3'd2) && !s_axi_awburst[1]
                    && (aw_in_ctrl || aw_in_din || aw_in_coef);

    // ---- 读侧：合法区域 = DOUT+STATUS[0x008, 0x00F]（相邻、同为只读）----
    wire [13:0] r_nbeats = {6'd0, s_axi_arlen} + 14'd1;
    wire [13:0] r_bytes  = (s_axi_arburst == BURST_FIXED) ? (14'd1 << s_axi_arsize)
                                                          : (r_nbeats << s_axi_arsize);
    wire [13:0] r_start  = {2'd0, s_axi_araddr[11:0]};
    wire [13:0] r_end    = r_start + r_bytes - 14'd1;

    wire ar_ok = (s_axi_arsize <= 3'd2) && !s_axi_arburst[1]
               && (r_start >= 14'h008) && (r_end <= 14'h00F);

    // ============================================================
    // 4. 当前拍寄存器译码
    // ============================================================
    wire [11:0] cur_off = cur_addr[11:0];

    wire w_is_ctrl = (cur_off == OFF_CTRL);
    wire w_is_din  = (cur_off == OFF_DIN);
    wire w_is_coef = (cur_off >= OFF_COEF) && (cur_off <= OFF_COEF_END);

    wire in_rbeat    = (state == S_RBEAT);
    wire rbeat_valid = in_rbeat && !abort;
    wire r_is_dout   = (cur_off == OFF_DOUT);
    wire r_is_status = (cur_off == OFF_STATUS);

    // ============================================================
    // 5. fir_core（契约 A，A 的分工产物） + 输出 FIFO
    // ============================================================
    wire [DW-1:0] dout;
    wire          dout_v;
    wire [DW-1:0] fifo_rdata;
    wire          fifo_full, fifo_empty;
    wire [CNT_W-1:0] fifo_count;

    fir_core #(
        .DW(DW), .CW(CW), .AW(AW), .NTAP(NTAP)
    ) u_fir_core (
        .clk(clk), .rst_n(rst_n),
        .flush(flush), .en(en), .din(din),
        .dout(dout), .dout_v(dout_v),
        .coef_idx(coef_idx), .coef_din(coef_din), .coef_we(coef_we)
    );

    // 读侧动作（只在 DOUT 拍握手完成的那一拍生效）：
    //   dout_pop       ：弹出队头（rdata 组合取自队头，握手当拍弹出，不丢拍不重读）
    //   status_read    ：读 STATUS 握手 → 清中断锁存
    //   read_empty_err ：DOUT 拍握手时 FIFO 空 → 该拍 SLVERR + 锁 err
    wire dout_pop       = r_hs && rbeat_valid && r_is_dout && (s_axi_rresp == RESP_OKAY);
    wire status_read    = r_hs && rbeat_valid && r_is_status;
    wire read_empty_err = r_hs && rbeat_valid && r_is_dout && (s_axi_rresp == RESP_SLVERR);
    wire overflow_err   = dout_v && fifo_full;      // 满时又出结果（丢弃）
    wire fifo_drained   = dout_pop && (fifo_count == {{(CNT_W-1){1'b0}}, 1'b1});

    sync_fifo #(
        .WIDTH(DW), .DEPTH(FIFO_DEPTH)
    ) u_out_fifo (
        .clk(clk), .rst_n(rst_n), .clr(flush),
        .wen(dout_v), .wdata(dout),
        .full(fifo_full),
        .ren(dout_pop), .rdata(fifo_rdata), .empty(fifo_empty),
        .count(fifo_count)
    );

    // ============================================================
    // 6. 读数据通道（组合输出，握手当拍的值就是对的）
    //    ⚠️ 不能用"准备拍时锁存 rdata"的写法：连续两拍 DOUT 时，
    //       上一拍握手同时弹出队头，锁存值会晚一拍 → 重读同一个数。
    // ============================================================
    wire [31:0] status_word =
        {{(16-CNT_W){1'b0}}, fifo_count, 12'h000,
         err_latch, !fifo_empty, fifo_full, fifo_empty};

    assign s_axi_rid = arid_r;
    wire [DATA_W-1:0] live_rdata = rbeat_valid
                       ? (r_is_dout   ? (fifo_empty ? {DATA_W{1'b0}} : {{(DATA_W-DW){1'b0}}, fifo_rdata})
                                      : (r_is_status ? status_word : {DATA_W{1'b0}}))
                       : {DATA_W{1'b0}};
    wire [1:0] live_rresp = (in_rbeat && (abort || (r_is_dout && fifo_empty)))
                       ? RESP_SLVERR : RESP_OKAY;
    // Snapshot stalled beats: status and an empty FIFO may change while waiting.
    reg r_hold;
    reg [DATA_W-1:0] held_rdata;
    reg [1:0] held_rresp;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_hold <= 1'b0;
            held_rdata <= 0;
            held_rresp <= 0;
        end else if (r_hs) r_hold <= 1'b0;
        else if (rvalid && !r_hold) begin
            r_hold <= 1'b1;
            held_rdata <= live_rdata;
            held_rresp <= live_rresp;
        end
    end
    assign s_axi_rdata = r_hold ? held_rdata : live_rdata;
    assign s_axi_rresp = r_hold ? held_rresp : live_rresp;

    assign s_axi_bid = awid_r;

    // ---- 响应通道：B/R 的 VALID/LAST/RESP 由 FSM 寄存器驱动 ----
    assign s_axi_bresp  = bresp;
    assign s_axi_bvalid = bvalid;
    assign s_axi_rlast  = rlast;
    assign s_axi_rvalid = rvalid;

    // ============================================================
    // 7. 主状态机（结构对齐 axi_to_apb.v：单事务、beat 计数、错误全收）
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            rr       <= 1'b0;
            abort    <= 1'b0;
            awid_r   <= {ID_W{1'b0}};
            arid_r   <= {ID_W{1'b0}};
            w_len    <= 8'd0;  w_size <= 3'd0;  w_burst <= BURST_FIXED;
            r_len    <= 8'd0;  r_size <= 3'd0;  r_burst <= BURST_FIXED;
            cur_addr <= {ADDR_W{1'b0}};
            beat     <= 8'd0;
            bresp    <= RESP_OKAY;
            bvalid   <= 1'b0;
            rlast    <= 1'b0;
            rvalid   <= 1'b0;
            din      <= {DW{1'b0}};
            en       <= 1'b0;
            flush    <= 1'b0;
            coef_idx <= {$clog2(NTAP){1'b0}};
            coef_din <= {CW{1'b0}};
            coef_we  <= 1'b0;
        end
        else begin
            // ---- 默认：响应通道与一拍脉冲每拍先清，状态里按需置位 ----
            bvalid  <= 1'b0;
            rvalid  <= 1'b0;
            en      <= 1'b0;
            flush   <= 1'b0;
            coef_we <= 1'b0;

            case (state)

            // ---------------------------------------------------
            // 空闲：收 AW / AR，做突发预检
            // ---------------------------------------------------
            S_IDLE: begin
                if (aw_hs) begin
                    rr       <= 1'b0;
                    awid_r   <= s_axi_awid;
                    w_len    <= s_axi_awlen;
                    w_size   <= s_axi_awsize;
                    w_burst  <= s_axi_awburst;
                    cur_addr <= s_axi_awaddr;
                    beat     <= 8'd0;
                    abort    <= !aw_ok;
                    state    <= S_GETW;
                end
                else if (ar_hs) begin
                    rr       <= 1'b1;
                    arid_r   <= s_axi_arid;
                    r_len    <= s_axi_arlen;
                    r_size   <= s_axi_arsize;
                    r_burst  <= s_axi_arburst;
                    cur_addr <= s_axi_araddr;
                    beat     <= 8'd0;
                    abort    <= !ar_ok;
                    rlast    <= (s_axi_arlen == 8'd0);
                    rvalid   <= 1'b1;
                    state    <= S_RBEAT;
                end
            end

            // ---------------------------------------------------
            // 逐拍收 W：握手当拍执行寄存器写（abort 时只收不写）
            // ---------------------------------------------------
            S_GETW: begin
                if (w_hs) begin
                    if (!abort) begin
                        if (w_is_ctrl) begin
                            // CTRL：bit0=1 且 byte0 选通 → flush 一拍
                            flush <= s_axi_wstrb[0] && s_axi_wdata[0];
                        end
                        else if (w_is_din) begin
                            // DIN：低 16bit 选通有效 → en 一拍 + 样本
                            en  <= (s_axi_wstrb[1:0] != 2'b00);
                            din <= s_axi_wdata[DW-1:0];
                        end
                        else if (w_is_coef) begin
                            // COEF[k]：低 16bit 选通有效 → coef 写口一拍
                            coef_we  <= (s_axi_wstrb[1:0] != 2'b00);
                            coef_idx <= (cur_off - OFF_COEF) >> 2;
                            coef_din <= s_axi_wdata[CW-1:0];
                        end
                    end
                    // 收尾条件：数到最后一拍（或主设备 WLAST 提前到，二者取其先）
                    if ((beat == w_len) || s_axi_wlast) begin
                        bresp  <= abort ? RESP_SLVERR : RESP_OKAY;
                        bvalid <= 1'b1;
                        state  <= S_BRESP;
                    end
                    else begin
                        beat <= beat + 8'd1;
                        if (!abort && (w_burst == BURST_INCR))
                            cur_addr <= cur_addr + (ADDR_W'(1'b1) << w_size);
                    end
                end
            end

            // ---------------------------------------------------
            // 写响应：等主设备取走
            // ---------------------------------------------------
            S_BRESP: begin
                bvalid <= 1'b1;
                if (b_hs) begin
                    bvalid <= 1'b0;
                    state  <= S_IDLE;
                end
            end

            // ---------------------------------------------------
            // 逐拍给读数据：RVALID 连续保持，主设备一拍一拍取（背靠背）
            // ---------------------------------------------------
            S_RBEAT: begin
                rvalid <= 1'b1;
                if (r_hs) begin
                    if (rlast) begin
                        rvalid <= 1'b0;
                        state  <= S_IDLE;
                    end
                    else begin
                        beat  <= beat + 8'd1;
                        rlast <= (beat + 8'd1 == r_len);
                        if (!abort && (r_burst == BURST_INCR))
                            cur_addr <= cur_addr + (ADDR_W'(1'b1) << r_size);
                    end
                end
            end

            endcase
        end
    end

    // ============================================================
    // 8. 中断锁存（电平，读 STATUS 清除）
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irq_done_latch <= 1'b0;
            err_latch      <= 1'b0;
        end
        else if (flush) begin
            // flush 把"结果/错误"连锅端：状态都不存在了，中断也不该悬着
            irq_done_latch <= 1'b0;
            err_latch      <= 1'b0;
        end
        else begin
            // irq_done：新结果置 1；读 STATUS 或 FIFO 被读空后清
            if (dout_v)                           irq_done_latch <= 1'b1;
            else if (status_read || fifo_drained) irq_done_latch <= 1'b0;

            // irq_err：溢出 / 读空置 1；读 STATUS 清
            if (overflow_err || read_empty_err)   err_latch <= 1'b1;
            else if (status_read)                 err_latch <= 1'b0;
        end
    end

    assign irq_done = irq_done_latch;
    assign irq_err  = err_latch;

endmodule
