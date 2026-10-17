// ============================================================
// axi_mem_model.v —— AXI4 存储器从设备模型（验证公共件）
//
// 【干什么】
//   模拟一块字节可寻址的存储器，作为 AXI4 从设备。给 DMA / 互连 /
//   其他主设备的测试台当"对手"用。
//
// 【支持】
//   · 五通道标准 AXI4 从口（带 ID）
//   · 单拍（LEN=0）与 INCR / FIXED 突发
//   · WSTRB 字节选通（窄传输写）
//   · RLAST 由拍数对齐自动产生
//   · 错误注入：起始地址 == err_addr 的事务返回 SLVERR（BRESP/RRESP = 2'b10）
//     （err_addr 是【完整地址】，不是相对 BASE 的偏移）
//   · 基址 BASE：内部用 (addr - BASE) 当索引，所以大基址（如 0x2000_0000）
//     不必分配超大数组；同一测试台里多个从设备各自传自己的 BASE 即可。
//
// 【怎么用】
//   axi_mem_model #(.BASE(32'h2000_0000), .MEM_BYTES(16384)) u_mem (
//       .clk(clk), .rst_n(rst_n),
//       .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize),
//       .awburst(awburst), .awvalid(awvalid), .awready(awready),
//       ... (W / B / AR / R 通道同标准接法)
//       .err_addr(32'hFFFF_FFFF)      // 不注入错误时给一个不会命中的地址
//   );
//
// 【测试台怎么读写里面的数据】
//   存储器是内部的 mem 数组，测试台可以用层次化引用直接访问：
//       u_mem.mem[addr] = 8'hA5;              // 预置数据
//       if (u_mem.mem[addr] !== 8'hA5) ...    // 检查结果
//   注意：复位会把整块存储器清零。
//
// 【来源】
//   本文件是从 TB/tb_dma_engine.v（阶段3 分工 B）里内联的 axi_mem_model
//   原样提取出来的，提取后 tb_dma_engine.v 改为例化本文件，行为不变。
//   提取的目的：让 tb_dma.v、互连测试台等都能复用同一个模型，避免各写一份。
//
// 【注意】模型的写通道是 WS_IDLE→WS_W→WS_B 串行的：
//   一次只有一个写事务在处理，awready 在非 IDLE 时拉低。
//   读通道同理。这足够本项目的 DMA 测试用，但不是高并发的 AXI 从设备。
// ============================================================
`timescale 1ns/1ps

module axi_mem_model #(
    parameter ADDR_W = 32,
    parameter DATA_W = 32,
    parameter ID_W   = 4,
    parameter BASE      = 32'h0,      // 本从设备基址：索引前先减掉（默认 0，即从 0 编址）
    parameter MEM_BYTES = 16384,
    parameter STALL_CYCLES = 0
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire [ID_W-1:0]      awid,
    input  wire [ADDR_W-1:0]    awaddr,
    input  wire [7:0]           awlen,
    input  wire [2:0]           awsize,
    input  wire [1:0]           awburst,
    input  wire                 awvalid,
    output wire                 awready,
    input  wire [DATA_W-1:0]    wdata,
    input  wire [DATA_W/8-1:0]  wstrb,
    input  wire                 wlast,
    input  wire                 wvalid,
    output wire                 wready,
    output wire [ID_W-1:0]      bid,
    output wire [1:0]           bresp,
    output wire                 bvalid,
    input  wire                 bready,
    input  wire [ID_W-1:0]      arid,
    input  wire [ADDR_W-1:0]    araddr,
    input  wire [7:0]           arlen,
    input  wire [2:0]           arsize,
    input  wire [1:0]           arburst,
    input  wire                 arvalid,
    output wire                 arready,
    output wire [ID_W-1:0]      rid,
    output wire [DATA_W-1:0]    rdata,
    output wire [1:0]           rresp,
    output wire                 rlast,
    output wire                 rvalid,
    input  wire                 rready,
    input  wire [ADDR_W-1:0]    err_addr   // 起始地址==err_addr 的事务返回 SLVERR
);

    reg [7:0] mem [0:MEM_BYTES-1];

    localparam BURST_FIXED = 2'b00;
    localparam BURST_INCR  = 2'b01;

    // ---- 写侧 ----
    localparam WS_IDLE = 2'd0, WS_W = 2'd1, WS_B = 2'd2;
    reg [1:0]        ws_cur, ws_next;
    reg [ID_W-1:0]   w_id;
    reg [ADDR_W-1:0] w_start;
    reg [7:0]        w_beat;
    reg [2:0]        w_size;
    reg [1:0]        w_burst;
    reg              w_err;

    wire [ADDR_W-1:0] w_beat_addr = (w_burst == BURST_FIXED) ? w_start
                                   : (w_start + ({{(ADDR_W-8){1'b0}}, w_beat} << w_size));
    wire [ADDR_W-1:0] w_word_base = (w_beat_addr & ~(ADDR_W'(4'd3))) - BASE;

    wire aw_hs = awvalid && awready;
    wire w_hs  = wvalid  && wready;
    wire b_hs  = bvalid  && bready;

    integer stall_phase=0;
    always @(posedge clk or negedge rst_n)
        if(!rst_n) stall_phase<=0;
        else if(stall_phase==STALL_CYCLES) stall_phase<=0;
        else stall_phase<=stall_phase+1;
    wire ready_slot = (stall_phase==0);
    assign awready = (ws_cur == WS_IDLE) && ready_slot;
    assign wready  = (ws_cur == WS_W) && ready_slot;
    assign bvalid  = (ws_cur == WS_B);
    assign bid     = w_id;
    assign bresp   = w_err ? 2'b10 : 2'b00;

    always @(*) begin
        ws_next = ws_cur;
        case (ws_cur)
            WS_IDLE: if (aw_hs)          ws_next = WS_W;
            WS_W   : if (w_hs && wlast)  ws_next = WS_B;
            WS_B   : if (b_hs)           ws_next = WS_IDLE;
            default:                     ws_next = WS_IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        integer i;
        if (!rst_n) begin
            ws_cur <= WS_IDLE;
            w_id <= 0; w_start <= 0; w_beat <= 0; w_size <= 0; w_burst <= 0; w_err <= 0;
            for (i = 0; i < MEM_BYTES; i = i + 1) mem[i] <= 8'h00;
        end
        else begin
            ws_cur <= ws_next;
            case (ws_cur)
                WS_IDLE: begin
                    if (aw_hs) begin
                        w_id    <= awid;
                        w_start <= awaddr;
                        w_size  <= awsize;
                        w_burst <= awburst;
                        w_err   <= (awaddr == err_addr);
                        w_beat  <= 8'd0;
                    end
                end
                WS_W: begin
                    if (w_hs) begin
                        for (i = 0; i < DATA_W/8; i = i + 1) begin
                            if (wstrb[i]) mem[w_word_base + i] <= wdata[8*i +: 8];
                        end
                        w_beat <= w_beat + 8'd1;
                    end
                end
                default: ;
            endcase
        end
    end

    // ---- 读侧 ----
    localparam RS_IDLE = 2'd0, RS_R = 2'd1;
    reg [1:0]        rs_cur, rs_next;
    reg [ID_W-1:0]   r_id;
    reg [ADDR_W-1:0] r_start;
    reg [7:0]        r_beat, r_len;
    reg [2:0]        r_size;
    reg [1:0]        r_burst;
    reg              r_err;

    wire [ADDR_W-1:0] r_beat_addr = (r_burst == BURST_FIXED) ? r_start
                                   : (r_start + ({{(ADDR_W-8){1'b0}}, r_beat} << r_size));
    wire [ADDR_W-1:0] r_word_base = (r_beat_addr & ~(ADDR_W'(4'd3))) - BASE;

    wire ar_hs = arvalid && arready;
    wire r_hs  = rvalid  && rready;

    assign arready = (rs_cur == RS_IDLE) && ready_slot;
    assign rvalid  = (rs_cur == RS_R);
    assign rid     = r_id;
    assign rresp   = r_err ? 2'b10 : 2'b00;
    assign rlast   = (r_beat == r_len);
    assign rdata   = {mem[r_word_base+3], mem[r_word_base+2],
                      mem[r_word_base+1], mem[r_word_base+0]};

    always @(*) begin
        rs_next = rs_cur;
        case (rs_cur)
            RS_IDLE: if (ar_hs)          rs_next = RS_R;
            RS_R   : if (r_hs && rlast)  rs_next = RS_IDLE;
            default:                     rs_next = RS_IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rs_cur <= RS_IDLE;
            r_id <= 0; r_start <= 0; r_beat <= 0; r_len <= 0; r_size <= 0; r_burst <= 0; r_err <= 0;
        end
        else begin
            rs_cur <= rs_next;
            case (rs_cur)
                RS_IDLE: begin
                    if (ar_hs) begin
                        r_id    <= arid;
                        r_start <= araddr;
                        r_size  <= arsize;
                        r_burst <= arburst;
                        r_len   <= arlen;
                        r_err   <= (araddr == err_addr);
                        r_beat  <= 8'd0;
                    end
                end
                RS_R: begin
                    if (r_hs) r_beat <= r_beat + 8'd1;
                end
                default: ;
            endcase
        end
    end

endmodule
