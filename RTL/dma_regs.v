// ============================================================
// dma_regs.v —— DMA 配置通路（AXI4 从口 + 24 寄存器）阶段3 分工 A
//
// 【契约依据】
//   docs/阶段3-契约A-配置总线.md
//   docs/契约AB-DMA内部接口.md §1（语义以它为准）
//   docs/任务三_地址映射与中断分配.md §4.2（寄存器映射）
//
// 【干什么】
//   CPU 经 AXI4 从口写 6 通道 × 4 寄存器（SRC/DST/LEN/CTRL），
//   把配置展平成 5 条 192bit 向量交给顶层 dma.v：
//     cfg_src / cfg_dst / cfg_len / cfg_ctrl（输出）
//     st_status（输入，状态回读）
//
// 【寄存器映射】基址 0x4000_1000，每通道 16 字节：
//   channel = addr[6:4]，reg_type = addr[3:2]
//   0x00+0x10·N SRC(W)  / 0x04 DST(W) / 0x08 LEN(W) / 0x0C CTRL(W/R)
//
// 【关键语义】
//   · START 是一拍脉冲：CPU 写 CTRL[0]=1 的下一拍，cfg_ctrl[ch][0]
//     产一拍高电平，其余恒 0；START 位自清（读回恒 0）。
//   · LEN=0 = 传 0 个字（不是 AXI 的 AWLEN=0），寄存器层原样透传，不换算。
//   · CTRL 读回要映射：DONE/BUSY/ERR 来自 st_status（bit31/30/29），
//     不是 CTRL 寄存器本身；bit2/1 = DST_INC/SRC_INC；bit0 恒 0。
//   · 读只有 CTRL 合法；读 SRC/DST/LEN → SLVERR。
//   · 写区域预检：整笔突发任一拍落到非法区 → 整笔 SLVERR 且无副作用
//     （写使能由 w_err 门控）。
//
// 【FSM】S_IDLE → S_GETW → S_BRESP / S_RBEAT → S_IDLE，单拍 + INCR 都支持。
// ============================================================
`timescale 1ns/1ps

module dma_regs #(
    parameter ADDR_W = 32,
    parameter DATA_W = 32,
    parameter ID_W   = 4,
    parameter LEN_W  = 8,
    parameter NCH    = 6,
    parameter BASE   = 32'h4000_1000       // 配置口基址
)(
    input  wire                clk,
    input  wire                rst_n,

    // ---- AXI4 从口（配置口，接互连 m1）----
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

    // ---- 配置总线（6 通道 × 32bit 展平）----
    output wire [NCH*32-1:0]   cfg_src,     // 每通道源地址，ch 占 [ch*32 +: 32]
    output wire [NCH*32-1:0]   cfg_dst,     // 每通道目的地址
    output wire [NCH*32-1:0]   cfg_len,     // 每通道传输字数
    output wire [NCH*32-1:0]   cfg_ctrl,    // bit0 START / bit1 SRC_INC / bit2 DST_INC
    input  wire [NCH*32-1:0]   st_status    // bit0 BUSY / bit1 DONE / bit2 ERR
);

    // ============================================================
    // 常量与状态
    // ============================================================
    localparam RESP_OKAY   = 2'b00;
    localparam RESP_SLVERR = 2'b10;
    localparam BURST_FIXED = 2'b00;
    localparam BURST_INCR  = 2'b01;
    localparam BURST_WRAP  = 2'b10;

    localparam S_IDLE  = 2'd0;
    localparam S_GETW  = 2'd1;
    localparam S_BRESP = 2'd2;
    localparam S_RBEAT = 2'd3;

    // ============================================================
    // 状态与寄存器
    // ============================================================
    reg [1:0]        state;
    reg              rr;            // 读写轮转位（防读/写饿死）
    reg [ADDR_W-1:0] cur_addr;      // 当前这一拍的地址
    reg [7:0]        beat;          // 当前第几拍（0 起）

    reg [LEN_W-1:0]  w_len;
    reg [2:0]        w_size;
    reg [1:0]        w_burst;
    reg              w_err;         // 整笔写预检：任一拍非法 / WRAP → SLVERR

    reg [LEN_W-1:0]  r_len;
    reg [2:0]        r_size;
    reg [1:0]        r_burst;
    reg              r_err;         // WRAP/保留值 → 逐拍 SLVERR

    reg [ID_W-1:0]   bid_l, rid_l;  // 锁存的 AWID / ARID

    // ---- 24 个寄存器 ----
    reg [31:0] src_r [0:NCH-1];
    reg [31:0] dst_r [0:NCH-1];
    reg [31:0] len_r [0:NCH-1];
    reg [1:0]  inc_r [0:NCH-1];     // [0]=SRC_INC [1]=DST_INC

    // START 一拍脉冲：每拍默认清 0，写 CTRL[0]=1 时置 1（仅此一个 always 块驱动）
    reg [NCH-1:0] start_pulse;

    // ============================================================
    // 地址合法性：映射到 0x4000_1000 + 0x00~0x5F
    // ============================================================
    function f_legal;
        input [ADDR_W-1:0] a;
        begin
            f_legal = (a[ADDR_W-1:12] == BASE[ADDR_W-1:12]) &&
                      (a[11:7] == 5'b0) &&
                      (a[6:4] < NCH);
        end
    endfunction

    // 整笔写突发预检：任一拍落到非法区 → 0
    function f_wburst_ok;
        input [ADDR_W-1:0] a;
        input [1:0]        b;
        input [LEN_W-1:0]  l;
        input [2:0]        sz;
        integer k;
        integer step;
        reg [ADDR_W-1:0] ak;
        begin
            f_wburst_ok = 1'b1;
            step = 1 << sz;
            for (k = 0; k <= l; k = k + 1) begin
                if (b == BURST_FIXED) ak = a;
                else                  ak = a + (k * step);
                if (!f_legal(ak))     f_wburst_ok = 1'b0;
            end
        end
    endfunction

    // ============================================================
    // 握手
    // ============================================================
    wire aw_hs = s_axi_awvalid && s_axi_awready;
    wire w_hs  = s_axi_wvalid  && s_axi_wready;
    wire ar_hs = s_axi_arvalid && s_axi_arready;
    wire b_hs  = s_axi_bvalid  && s_axi_bready;
    wire r_hs  = s_axi_rvalid  && s_axi_rready;

    // ---- ready：空闲态；读写同时来由 rr 决定谁优先（避免同时握手却只处理一笔）----
    assign s_axi_awready = (state == S_IDLE) && (!s_axi_arvalid || rr);
    assign s_axi_arready = (state == S_IDLE) && (!s_axi_awvalid || !rr);
    assign s_axi_wready  = (state == S_GETW);

    // ============================================================
    // 地址步进
    // ============================================================
    wire [ADDR_W-1:0] w_step = {{(ADDR_W-1){1'b0}}, 1'b1} << w_size;
    wire [ADDR_W-1:0] r_step = {{(ADDR_W-1){1'b0}}, 1'b1} << r_size;
    wire [ADDR_W-1:0] w_next = (w_burst == BURST_FIXED) ? cur_addr : (cur_addr + w_step);
    wire [ADDR_W-1:0] r_next = (r_burst == BURST_FIXED) ? cur_addr : (cur_addr + r_step);

    wire aw_wrap_or_resv = (s_axi_awburst == BURST_WRAP) || (s_axi_awburst == 2'b11);
    wire ar_wrap_or_resv = s_axi_arburst[1] || (s_axi_arsize > 3'd2);

    // 写字节选通展开：wstrb[i] 门控字节 i
    wire [DATA_W-1:0] wstrb_full = {{8{s_axi_wstrb[3]}}, {8{s_axi_wstrb[2]}},
                                     {8{s_axi_wstrb[1]}}, {8{s_axi_wstrb[0]}}};

    // ============================================================
    // 读数据：只有 CTRL 合法，映射来自 st_status。
    // 用函数按【给定地址】计算，结果在握手时【寄存器化】锁存，
    // 避免 st_status 在 RVALID 期间变化导致 R 数据抖动（AXI 要求 R 数据稳定）。
    // ============================================================
    function [DATA_W-1:0] f_rddata;
        input [ADDR_W-1:0] a;
        input              err;
        begin
            if (!err && f_legal(a) && (a[3:2] == 2'd3))
                f_rddata = { st_status[a[6:4]*32+1], st_status[a[6:4]*32+0],
                             st_status[a[6:4]*32+2], {(DATA_W-6){1'b0}},
                             inc_r[a[6:4]][1], inc_r[a[6:4]][0], 1'b0 };
            else
                f_rddata = {DATA_W{1'b0}};
        end
    endfunction

    function [1:0] f_rdresp;
        input [ADDR_W-1:0] a;
        input              err;
        begin
            f_rdresp = (!err && f_legal(a) && (a[3:2] == 2'd3)) ? RESP_OKAY : RESP_SLVERR;
        end
    endfunction

    reg              rvalid_r;
    reg [DATA_W-1:0] rdata_r;
    reg [1:0]        rresp_r;
    reg              rlast_r;

    assign s_axi_rvalid = rvalid_r;
    assign s_axi_rdata  = rdata_r;
    assign s_axi_rresp  = rresp_r;
    assign s_axi_rlast  = rlast_r;

    assign s_axi_bid    = bid_l;
    assign s_axi_bresp  = w_err ? RESP_SLVERR : RESP_OKAY;
    assign s_axi_bvalid = (state == S_BRESP);
    assign s_axi_rid    = rid_l;

    // ============================================================
    // 主状态机
    // ============================================================
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            rr        <= 1'b0;
            cur_addr  <= {ADDR_W{1'b0}};
            beat      <= 8'd0;
            w_len     <= {LEN_W{1'b0}};
            w_size    <= 3'd0;
            w_burst   <= 2'd0;
            w_err     <= 1'b0;
            r_len     <= {LEN_W{1'b0}};
            r_size    <= 3'd0;
            r_burst   <= 2'd0;
            r_err     <= 1'b0;
            bid_l     <= {ID_W{1'b0}};
            rid_l     <= {ID_W{1'b0}};
            rvalid_r  <= 1'b0;
            rdata_r   <= {DATA_W{1'b0}};
            rresp_r   <= RESP_OKAY;
            rlast_r   <= 1'b0;
            start_pulse <= {NCH{1'b0}};
            for (i = 0; i < NCH; i = i + 1) begin
                src_r[i] <= 32'd0;
                dst_r[i] <= 32'd0;
                len_r[i] <= 32'd0;
                inc_r[i] <= 2'd0;
            end
        end
        else begin
            // START 脉冲默认清 0；写 CTRL[0]=1 时在下面置 1（单 always 块，无多重驱动）
            start_pulse <= {NCH{1'b0}};

            case (state)
                // ------------------------------------------------
                // 空闲：接受一笔写或读
                // ------------------------------------------------
                S_IDLE: begin
                    if (aw_hs) begin
                        rr       <= 1'b0;
                        cur_addr <= s_axi_awaddr;
                        w_len    <= s_axi_awlen;
                        w_size   <= s_axi_awsize;
                        w_burst  <= s_axi_awburst;
                        w_err    <= aw_wrap_or_resv || (s_axi_awsize > 3'd2) ||
                                    !f_wburst_ok(s_axi_awaddr, s_axi_awburst,
                                                 s_axi_awlen, s_axi_awsize);
                        bid_l    <= s_axi_awid;
                        beat     <= 8'd0;
                        state    <= S_GETW;
                    end
                    else if (ar_hs) begin
                        rr       <= 1'b1;
                        cur_addr <= s_axi_araddr;
                        r_len    <= s_axi_arlen;
                        r_size   <= s_axi_arsize;
                        r_burst  <= s_axi_arburst;
                        r_err    <= ar_wrap_or_resv;
                        rid_l    <= s_axi_arid;
                        beat     <= 8'd0;
                        // 第一拍读数据：按 araddr 计算并锁存，保证 RVALID 期间稳定
                        rvalid_r <= 1'b1;
                        rlast_r  <= (s_axi_arlen == {LEN_W{1'b0}});
                        rresp_r  <= f_rdresp(s_axi_araddr, ar_wrap_or_resv);
                        rdata_r  <= f_rddata(s_axi_araddr, ar_wrap_or_resv);
                        state    <= S_RBEAT;
                    end
                end

                // ------------------------------------------------
                // 取一拍写数据，逐拍写寄存器
                // ------------------------------------------------
                S_GETW: begin
                    if (w_hs) begin
                        // 写使能由 w_err 门控：整笔预检失败 → 无副作用
                        if (!w_err && f_legal(cur_addr)) begin
                            case (cur_addr[3:2])
                                2'd0: src_r[cur_addr[6:4]] <=
                                      (src_r[cur_addr[6:4]] & ~wstrb_full) |
                                      (s_axi_wdata & wstrb_full);
                                2'd1: dst_r[cur_addr[6:4]] <=
                                      (dst_r[cur_addr[6:4]] & ~wstrb_full) |
                                      (s_axi_wdata & wstrb_full);
                                2'd2: len_r[cur_addr[6:4]] <=
                                      (len_r[cur_addr[6:4]] & ~wstrb_full) |
                                      (s_axi_wdata & wstrb_full);
                                2'd3: begin
                                    if (s_axi_wstrb[0]) begin
                                        inc_r[cur_addr[6:4]][0] <= s_axi_wdata[1]; // SRC_INC
                                        inc_r[cur_addr[6:4]][1] <= s_axi_wdata[2]; // DST_INC
                                        if (s_axi_wdata[0])
                                            start_pulse[cur_addr[6:4]] <= 1'b1;
                                    end
                                end
                            endcase
                        end
                        if (beat == w_len) begin
                            state <= S_BRESP;
                        end
                        else begin
                            beat     <= beat + 8'd1;
                            cur_addr <= w_next;
                        end
                    end
                end

                // ------------------------------------------------
                // 写响应（bvalid/bresp 组合产生）
                // ------------------------------------------------
                S_BRESP: begin
                    if (b_hs) state <= S_IDLE;
                end

                // ------------------------------------------------
                // 读数据拍（rvalid/rdata/rresp/rlast 为寄存器输出，握手时逐拍锁存）
                // ------------------------------------------------
                S_RBEAT: begin
                    if (r_hs) begin
                        if (rlast_r) begin
                            rvalid_r <= 1'b0;
                            state    <= S_IDLE;
                        end
                        else begin
                            beat     <= beat + 8'd1;
                            cur_addr <= r_next;
                            rlast_r  <= (beat + 8'd1 == r_len);
                            rresp_r  <= f_rdresp(r_next, r_err);
                            rdata_r  <= f_rddata(r_next, r_err);
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ============================================================
    // 配置总线输出（展平）
    // ============================================================
    genvar g;
    generate
        for (g = 0; g < NCH; g = g + 1) begin : g_cfg
            assign cfg_src [g*32 +: 32] = src_r[g];
            assign cfg_dst [g*32 +: 32] = dst_r[g];
            assign cfg_len [g*32 +: 32] = len_r[g];
            assign cfg_ctrl[g*32 +: 32] = {29'd0, inc_r[g][1], inc_r[g][0], start_pulse[g]};
        end
    endgenerate

endmodule
