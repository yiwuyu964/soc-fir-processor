// ============================================================
// axi_sram.v —— 片内 SRAM（AXI4 从设备，阶段4 分工 B）
//
// ============================================================
// 【接口契约】
// ============================================================
//   · docs/阶段4-三人分工.md §2「👤 B —— 片内 SRAM」
//   · docs/任务四_模块接口信号清单.md 0.3 节（AXI4 从口标准模板，前缀 s_axi_）
//   · 地址映射（阶段4 §1 方案 B）：SRAM @ 0x0000_0000，64KB
//     （M0 复位后从 0x0 取向量表和入口，故 SRAM 放 0x0，不做 ROM）
//
//   对外是一个标准 AXI4 从口（5 通道、带 ID），由 soc_top 挂在 axi_ic 的主口上。
//
// ============================================================
// 【⚠️ 顶层集成注意：接到互连的哪个口】
// ============================================================
//   阶段4-三人分工.md §1/§2 写的是「m2 → axi_sram @0x0000_0000」，
//   但 axi_ic.v 的译码函数（f_decode，见 RTL/axi_ic.v）实际是：
//       a[31:16]==16'h0000 → 从设备 3   （注释标为 "ROM  @0x0000_0000"）
//       a[31:16]==16'h2000 → 从设备 2   （注释标为 "SRAM @0x2000_0000"）
//   即 **0x0 这一段落在互连的 m3 口上，不在 m2**。
//
//   方案 B（SRAM @0x0，不做 ROM）因此应当：
//     · 把本模块接到 axi_ic 的 **m3_axi_***（不是 m2），并用默认 BASE_ADDR=0；
//     · m2 口不用（悬空即可，互连对未用从设备会回 DECERR）。
//   若反过来接到 m2（地址就成了 0x2000_0000），必须设 BASE_ADDR=0x2000_0000，
//   但那样 CPU 复位后从 0x0 取向量表会走到没接的 m3 上，起不来。
//
//   （axi_ic.v 是阶段2 A 的产物、本阶段 A 只碰 soc_top.v，所以不改互连，
//     只在 soc_top 接线时按上面的结论接。）
//
// ============================================================
// 【支持的特性】
// ============================================================
//   ✅ 单拍（LEN=0）
//   ✅ INCR 突发（地址按 SIZE 递增）
//   ✅ FIXED 突发（地址不变，按 SIZE 对齐的重复访问）
//   ✅ AWID/ARID → BID/RID 透传
//   ✅ WSTRB 字节选通（只写选中的字节）
//   ✅ RLAST 按 ARLEN 拍数对齐
//   ✅ 可综合：字宽存储阵列 + 字节写使能 + 同步读（BRAM 风格）
//   ❌ WRAP 突发 / SIZE>2（超过 32bit 总线）→ SLVERR
//   ❌ 地址越界（不在 [BASE_ADDR, BASE_ADDR+SRAM_BYTES)）→ DECERR
//
// ============================================================
// 【为什么和 TB/axi_mem_model.v 不一样（可综合性）】
// ============================================================
//   TB/axi_mem_model.v 是**纯仿真模型**，不能直接综合：
//     1. 复位时 `for (i) mem[i] <= 0` 清空整块存储 —— 综合工具无法把
//        同步复位接到 BRAM 的每个存储单元上，本模块**只复位控制寄存器，
//        不复位存储阵列**（上电内容未定义，由 CPU 固件自行初始化）；
//     2. `err_addr` 错误注入端口是给测试台用的 —— 本模块换成**真实的
//        地址越界/类型检查**（握手当拍组合判断，结果锁存后随 B/R 返回）。
//
//   另外存储阵列按**字宽**（`reg [DATA_W-1:0]`）组织而不是按字节组织，
//   配合 `wstrb` 生成字节写使能，这正是 FPGA 推断 BRAM（带字节使能）的写法。
//
// ============================================================
// 【读通路时序】
// ============================================================
//   用同步读（地址 → 下一拍数据）以贴合 BRAM：
//     RS_IDLE --AR 握手--> RS_REQ（发读地址）--> RS_RESP（RVALID+数据）
//     RS_RESP --R 握手且非末拍--> RS_REQ（下一拍）...
//   每个读拍 2 个时钟（REQ + RESP），吞吐不是最优但简单、可综合、易验证。
//
// ============================================================
// 【验证】TB/tb_axi_sram.v
// ============================================================
//   单拍读写 / INCR 突发 / WSTRB 字节写 / 越界 DECERR / WRAP·SIZE>2 拒绝 /
//   挂 axi_protocol_checker 零违规。
//
// ⚠️ SRAM_BYTES 建议取 2 的幂（默认 64KB）：字索引按 $clog2(DEPTH) 位截取，
//    取 2 的幂时索引范围恰好等于存储深度。存储阵列上电内容未定义（不复位），
//    由 CPU 固件在启动代码里初始化。
// ============================================================
`timescale 1ns/1ps

module axi_sram #(
    parameter ADDR_W     = 32,
    parameter DATA_W     = 32,
    parameter ID_W       = 4,
    parameter SRAM_BYTES = 65536,          // 片内 SRAM 大小（默认 64KB）
    parameter BASE_ADDR  = 32'h0000_0000   // 基址（阶段4 方案 B：0x0）
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // ---- AXI4 从口 · 写地址 AW ----
    input  wire [ID_W-1:0]       s_axi_awid,
    input  wire [ADDR_W-1:0]     s_axi_awaddr,
    input  wire [7:0]            s_axi_awlen,
    input  wire [2:0]            s_axi_awsize,
    input  wire [1:0]            s_axi_awburst,
    input  wire                  s_axi_awvalid,
    output wire                  s_axi_awready,
    // ---- 写数据 W ----
    input  wire [DATA_W-1:0]     s_axi_wdata,
    input  wire [DATA_W/8-1:0]   s_axi_wstrb,
    input  wire                  s_axi_wlast,
    input  wire                  s_axi_wvalid,
    output wire                  s_axi_wready,
    // ---- 写响应 B ----
    output wire [ID_W-1:0]       s_axi_bid,
    output wire [1:0]            s_axi_bresp,
    output wire                  s_axi_bvalid,
    input  wire                  s_axi_bready,
    // ---- 读地址 AR ----
    input  wire [ID_W-1:0]       s_axi_arid,
    input  wire [ADDR_W-1:0]     s_axi_araddr,
    input  wire [7:0]            s_axi_arlen,
    input  wire [2:0]            s_axi_arsize,
    input  wire [1:0]            s_axi_arburst,
    input  wire                  s_axi_arvalid,
    output wire                  s_axi_arready,
    // ---- 读数据 R ----
    output wire [ID_W-1:0]       s_axi_rid,
    output wire [DATA_W-1:0]     s_axi_rdata,
    output wire [1:0]            s_axi_rresp,
    output wire                  s_axi_rlast,
    output wire                  s_axi_rvalid,
    input  wire                  s_axi_rready
);

    // ============================================================
    // 0. 常量
    // ============================================================
    localparam BYTES_PER_WORD = DATA_W / 8;                    // 4
    localparam DEPTH          = SRAM_BYTES / BYTES_PER_WORD;   // 字数（64KB → 16384）
    localparam AW             = $clog2(DEPTH);                 // 字地址位宽（14）

    localparam BURST_FIXED = 2'b00;
    localparam BURST_INCR  = 2'b01;
    localparam BURST_WRAP  = 2'b10;

    localparam RESP_OKAY   = 2'b00;
    localparam RESP_SLVERR = 2'b10;
    localparam RESP_DECERR = 2'b11;

    // SRAM 地址窗口 [BASE_ADDR, BASE_ADDR + SRAM_BYTES)
    localparam [ADDR_W:0] SRAM_LO = {1'b0, BASE_ADDR};
    localparam [ADDR_W:0] SRAM_HI = {1'b0, BASE_ADDR} + SRAM_BYTES;

    // 状态编码
    localparam WS_IDLE = 2'd0, WS_W = 2'd1, WS_B = 2'd2;
    localparam RS_IDLE = 2'd0, RS_REQ = 2'd1, RS_RESP = 2'd2;

    // ============================================================
    // 1. 存储阵列（可综合；只由写通路更新，无复位）
    // ============================================================
    reg [DATA_W-1:0] mem [0:DEPTH-1];

    // ============================================================
    // 2. 写侧：地址范围 / 类型检查（握手当拍组合判断）
    // ============================================================
    wire [8:0]      w_nbeats = (s_axi_awburst == BURST_FIXED) ? 9'd1
                             : ({1'b0, s_axi_awlen} + 9'd1);
    wire [16:0]     w_nbytes = w_nbeats << s_axi_awsize;
    wire [ADDR_W-1:0] w_align_mask = (32'd1 << s_axi_awsize) - 1;
    wire [ADDR_W-1:0] w_aligned = s_axi_awaddr & ~w_align_mask;
    wire [ADDR_W:0] w_end    = {1'b0, w_aligned} + w_nbytes;
    wire w_cross_4k = (s_axi_awburst == BURST_INCR) &&
                      ({1'b0,w_aligned[11:0]} + w_nbytes > 4096);
    wire            w_range_bad = ({1'b0, s_axi_awaddr} < SRAM_LO) || (w_end > SRAM_HI);
    wire            w_type_bad  = (s_axi_awsize > 3'd2) || s_axi_awburst[1] || w_cross_4k ||
                                  (s_axi_awburst == BURST_FIXED && s_axi_awlen > 15);
    wire [1:0]      w_resp_now  = w_range_bad ? RESP_DECERR
                                : (w_type_bad  ? RESP_SLVERR : RESP_OKAY);

    // ---- 写侧寄存器 ----
    reg [1:0]        ws_cur, ws_next;
    reg [ID_W-1:0]   w_id;
    reg [ADDR_W-1:0] w_start;
    reg [7:0]        w_len;
    reg [2:0]        w_size;
    reg [1:0]        w_burst;
    reg [7:0]        w_beat;
    reg [1:0]        w_resp_r;

    wire aw_hs = s_axi_awvalid && s_axi_awready;
    wire w_hs  = s_axi_wvalid  && s_axi_wready;
    wire b_hs  = s_axi_bvalid  && s_axi_bready;

    assign s_axi_awready = (ws_cur == WS_IDLE);
    assign s_axi_wready  = (ws_cur == WS_W);
    assign s_axi_bvalid  = (ws_cur == WS_B);
    assign s_axi_bid     = w_id;
    assign s_axi_bresp   = w_resp_r;

    // 当前写拍地址（INCR 递增 / FIXED 不变）与字索引
    wire [ADDR_W-1:0] w_beat_addr = (w_burst == BURST_FIXED) ? w_start
                                  : ((w_start & ~((32'd1 << w_size)-1)) + ({{(ADDR_W-8){1'b0}}, w_beat} << w_size));
    wire [AW-1:0]     w_word_idx  = (w_beat_addr - BASE_ADDR) >> 2;

    always @(*) begin
        ws_next = ws_cur;
        case (ws_cur)
            WS_IDLE: if (aw_hs)                ws_next = WS_W;
            WS_W   : if (w_hs && (s_axi_wlast || (w_beat == w_len)))
                                               ws_next = WS_B;
            WS_B   : if (b_hs)                 ws_next = WS_IDLE;
            default:                           ws_next = WS_IDLE;
        endcase
    end

    // ============================================================
    // 3. 读侧：地址范围 / 类型检查
    // ============================================================
    wire [8:0]      r_nbeats = (s_axi_arburst == BURST_FIXED) ? 9'd1
                             : ({1'b0, s_axi_arlen} + 9'd1);
    wire [16:0]     r_nbytes = r_nbeats << s_axi_arsize;
    wire [ADDR_W-1:0] r_align_mask = (32'd1 << s_axi_arsize) - 1;
    wire [ADDR_W-1:0] r_aligned = s_axi_araddr & ~r_align_mask;
    wire [ADDR_W:0] r_end    = {1'b0, r_aligned} + r_nbytes;
    wire r_cross_4k = (s_axi_arburst == BURST_INCR) &&
                      ({1'b0,r_aligned[11:0]} + r_nbytes > 4096);
    wire            r_range_bad = ({1'b0, s_axi_araddr} < SRAM_LO) || (r_end > SRAM_HI);
    wire            r_type_bad  = (s_axi_arsize > 3'd2) || s_axi_arburst[1] || r_cross_4k ||
                                  (s_axi_arburst == BURST_FIXED && s_axi_arlen > 15);
    wire [1:0]      r_resp_now  = r_range_bad ? RESP_DECERR
                                : (r_type_bad  ? RESP_SLVERR : RESP_OKAY);

    // ---- 读侧寄存器 ----
    reg [1:0]        rs_cur, rs_next;
    reg [ID_W-1:0]   r_id;
    reg [ADDR_W-1:0] r_start;
    reg [7:0]        r_len;
    reg [7:0]        r_beat;
    reg [2:0]        r_size;
    reg [1:0]        r_burst;
    reg [1:0]        r_resp_r;
    reg [DATA_W-1:0] rdata_r;

    wire ar_hs = s_axi_arvalid && s_axi_arready;
    wire r_hs  = s_axi_rvalid  && s_axi_rready;

    assign s_axi_arready = (rs_cur == RS_IDLE);
    assign s_axi_rvalid  = (rs_cur == RS_RESP);
    assign s_axi_rid     = r_id;
    assign s_axi_rresp   = r_resp_r;
    assign s_axi_rdata   = rdata_r;
    assign s_axi_rlast   = (r_beat == r_len);

    // 当前读拍地址与字索引
    wire [ADDR_W-1:0] r_beat_addr = (r_burst == BURST_FIXED) ? r_start
                                  : ((r_start & ~((32'd1 << r_size)-1)) + ({{(ADDR_W-8){1'b0}}, r_beat} << r_size));
    wire [AW-1:0]     r_word_idx  = (r_beat_addr - BASE_ADDR) >> 2;

    // SRAM 同步读：只在 RS_REQ 拍取数，下一拍进 rdata_r（BRAM 风格）
    wire rd_en = (rs_cur == RS_REQ);

    always @(*) begin
        rs_next = rs_cur;
        case (rs_cur)
            RS_IDLE: if (ar_hs)                          rs_next = RS_REQ;
            RS_REQ :                                     rs_next = RS_RESP;
            RS_RESP: if (r_hs) begin
                         if (r_beat == r_len)            rs_next = RS_IDLE;
                         else                            rs_next = RS_REQ;
                     end
            default:                                     rs_next = RS_IDLE;
        endcase
    end

    // ============================================================
    // 4. 时序逻辑
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ws_cur   <= WS_IDLE;
            w_id     <= {ID_W{1'b0}};
            w_start  <= {ADDR_W{1'b0}};
            w_len    <= 8'd0;
            w_size   <= 3'd2;
            w_burst  <= BURST_INCR;
            w_beat   <= 8'd0;
            w_resp_r <= RESP_OKAY;

            rs_cur   <= RS_IDLE;
            r_id     <= {ID_W{1'b0}};
            r_start  <= {ADDR_W{1'b0}};
            r_len    <= 8'd0;
            r_beat   <= 8'd0;
            r_size   <= 3'd2;
            r_burst  <= BURST_INCR;
            r_resp_r <= RESP_OKAY;
        end
        else begin
            ws_cur <= ws_next;
            rs_cur <= rs_next;

            // ---------- 写通路 ----------
            case (ws_cur)
                WS_IDLE: begin
                    if (aw_hs) begin
                        w_id     <= s_axi_awid;
                        w_start  <= s_axi_awaddr;
                        w_len    <= s_axi_awlen;
                        w_size   <= s_axi_awsize;
                        w_burst  <= s_axi_awburst;
                        w_resp_r <= w_resp_now;      // 锁存错误判定
                        w_beat   <= 8'd0;
                    end
                end
                WS_W: begin
                    if (w_hs) begin
                        // 存储写入不在这里：见文件末尾『存储体（可推断 BRAM）』那块。
                        // 本 always 带异步复位，Vivado 会认定 RAM 也受异步复位影响，
                        // 直接报 Synth 8-3391 拒绝推断 BRAM（524288 bit 拆不成触发器）。
                        w_beat <= w_beat + 8'd1;
                    end
                end
                default: ;
            endcase

            // ---------- 读通路 ----------
            // 同步读端口：RS_REQ 拍发地址，下一拍数据可用（读数在文件末尾那块做）

            case (rs_cur)
                RS_IDLE: begin
                    if (ar_hs) begin
                        r_id     <= s_axi_arid;
                        r_start  <= s_axi_araddr;
                        r_len    <= s_axi_arlen;
                        r_size   <= s_axi_arsize;
                        r_burst  <= s_axi_arburst;
                        r_resp_r <= r_resp_now;      // 锁存错误判定
                        r_beat   <= 8'd0;
                    end
                end
                RS_RESP: begin
                    if (r_hs && (r_beat != r_len)) r_beat <= r_beat + 8'd1;
                end
                default: ;
            endcase
        end
    end

    // ============================================================
    // 5. 存储体（可推断 BRAM）
    //
    // 【为什么单独开一个 always】
    //   上面状态机块是 always @(posedge clk or negedge rst_n)。Vivado 看到同一块里
    //   既有异步复位又有存储器写入，会认定『这块 RAM 对异步复位敏感』，直接报
    //   Synth 8-3391 拒绝推断 BRAM（本设计 524288 bit，也拆不成触发器）。
    //   把存储的读/写放进【纯同步、无异步复位】的时钟块，才是 BRAM 的标准写法。
    //   『复位期间不落盘』的原语义用 rst_n 做同步使能来保持，功能不变。
    //   - 写：按 WSTRB 逐字节写使能（常量位选，对应 BRAM 的 4 个 byte-enable）
    //   - 读：同步读，地址拍后一拍出数
    // ============================================================
    always @(posedge clk) begin
        if (rst_n && w_hs && (w_resp_r == RESP_OKAY)) begin
            if (s_axi_wstrb[0]) mem[w_word_idx][7:0]   <= s_axi_wdata[7:0];
            if (s_axi_wstrb[1]) mem[w_word_idx][15:8]  <= s_axi_wdata[15:8];
            if (s_axi_wstrb[2]) mem[w_word_idx][23:16] <= s_axi_wdata[23:16];
            if (s_axi_wstrb[3]) mem[w_word_idx][31:24] <= s_axi_wdata[31:24];
        end
        if (rst_n && rd_en) rdata_r <= mem[r_word_idx];
    end

endmodule
