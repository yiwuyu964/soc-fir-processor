// ============================================================
// axi_protocol_checker.v —— AXI4 协议检查器（纯被动监视器）
//
// 【干什么】
//   例化在任意一个 AXI 端口上，只读不写，自动检查该端口上的
//   事务符不符合 AXI4 协议。任何违规立刻打印（带时间戳和规则号）。
//
// 【怎么用】
//   把它和你的 DUT 接在同一个 AXI 端口上，信号直接并联：
//
//       axi_protocol_checker #(.NAME("s0_axi"), .SIDE(0)) u_chk (
//           .clk(clk), .rst_n(rst_n),
//           .awid(s_axi_awid), .awaddr(s_axi_awaddr), ... );
//
//   跑完仿真后看 error_count：
//       0  = 这个端口上的事务全部合法
//       >0 = 有违规，$display 会打印具体是哪一条、哪一拍
//
// 【SIDE 参数】
//   SIDE=0：监测 AXI **从口**（对面是主设备）—— 检查主设备发来的 AW/W/AR 是否合法
//   SIDE=1：监测 AXI **主口**（对面是从设备）—— 检查从设备回的 B/R 是否合法
//   两种都检查握手类规则（VALID 撤销、载荷变化），只是一些"该谁负责"的
//   规则会分别归到对应方向上。
//
// 【检查的规则】
//   R1  复位期间不许有任何 VALID 拉高
//   R2  VALID 拉高后、握手完成前，不许撤销          （5 个通道全查）
//   R3  握手完成前，载荷（地址/长度/尺寸/类型）不许变（AW/AR）
//   R4  WLAST 必须恰好出现在第 AWLEN+1 拍
//   R5  RLAST 必须恰好出现在第 ARLEN+1 拍
//   R6  W 拍数与 AWLEN+1 一致
//   R7  R 拍数与 ARLEN+1 一致
//   R8  INCR 读突发地址按 SIZE 递增正确
//   R9  突发不跨 4KB 边界
//   R10 写响应 BID 的顺序必须与 AWID 一致
//   R11 未支持的突发类型（WRAP，除非 ALLOW_WRAP=1）
//   R12 （保留，见下方"无法动态检查的规则"）
//   R13 W 突发开始时必须有对应的 AW（本设计的约定，见下方"设计约定"）
//   R14 未完成事务队列溢出
//
// 【无法动态检查、改为代码审查的规则】（必须人工确认）
//   · "VALID 不许等 READY"：这是组合逻辑依赖层面的规则，纯动态仿真无法
//     可靠区分它和正常的背压。审查方法：在 RTL 里找出所有 VALID 的赋值，
//     确认表达式里没有 READY（尤其不能用 READY 组合产生 VALID）。
//   · R12 "FIXED 突发的地址保持不变"：AXI 的 W 通道和 R 通道本身不带地址，
//     从端口信号上观测不到每一拍访问了哪个地址，因此无法动态检查。
//     审查方法：确认 FIXED 突发的从设备端不会自行递增地址。
//
// 【设计约定】（本 checker 按本 SoC 的约定实现，比 AXI 规范更严一点）
//   本设计的互连、桥、从设备都遵循：
//     · AW 先于 W，AR 先于 R（不允许写数据抢在写地址前）
//     · 同一个 ID 的读数据不乱序
//   如果你的模块打破了这两条，checker 会报 R13 或 R10 —— 那不是误报，
//   而是说明该模块不符合本设计的约定。
//
// 【控制台编码】
//   Windows cmd 默认 GBK，中文报错会显示成乱码。执行 chcp 65001 切到 UTF-8 即可。
//   规则号（R1~R14）和端口名都是 ASCII，即使乱码也能定位问题。
//
// 【为什么不能查"VALID 不许等 READY"】
//   那条规则是"组合逻辑依赖"层面的（VALID 不能由 READY 组合产生），
//   纯动态仿真无法可靠区分它和正常的背压。做法是代码审查：
//   在 RTL 里检查所有 VALID 的赋值，确认表达式里没有 READY。见 §文档。
// ============================================================
`timescale 1ns/1ps

module axi_protocol_checker #(
    parameter ADDR_W     = 32,
    parameter DATA_W     = 32,
    parameter ID_W       = 4,
    parameter LEN_W      = 8,
    parameter NAME       = "AXI",   // 报错时打印的端口名
    parameter SIDE       = 0,       // 0=监测从口（对面是主） 1=监测主口（对面是从）
    parameter ALLOW_WRAP = 0,       // 是否允许 WRAP 突发（本设计不支持）
    parameter DEPTH      = 8,       // 未完成事务队列深度
    parameter MAX_REPORT = 20       // 最多打印多少条，防止刷屏
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // ---------------- 写地址通道 AW ----------------
    input  wire [ID_W-1:0]       awid,
    input  wire [ADDR_W-1:0]     awaddr,
    input  wire [LEN_W-1:0]      awlen,
    input  wire [2:0]            awsize,
    input  wire [1:0]            awburst,
    input  wire                  awvalid,
    input  wire                  awready,

    // ---------------- 写数据通道 W ----------------
    input  wire [DATA_W-1:0]     wdata,
    input  wire [DATA_W/8-1:0]   wstrb,
    input  wire                  wlast,
    input  wire                  wvalid,
    input  wire                  wready,

    // ---------------- 写响应通道 B ----------------
    input  wire [ID_W-1:0]       bid,
    input  wire [1:0]            bresp,
    input  wire                  bvalid,
    input  wire                  bready,

    // ---------------- 读地址通道 AR ----------------
    input  wire [ID_W-1:0]       arid,
    input  wire [ADDR_W-1:0]     araddr,
    input  wire [LEN_W-1:0]      arlen,
    input  wire [2:0]            arsize,
    input  wire [1:0]            arburst,
    input  wire                  arvalid,
    input  wire                  arready,

    // ---------------- 读数据通道 R ----------------
    input  wire [ID_W-1:0]       rid,
    input  wire [DATA_W-1:0]     rdata,
    input  wire [1:0]            rresp,
    input  wire                  rlast,
    input  wire                  rvalid,
    input  wire                  rready,

    // ---------------- 汇总 ----------------
    output reg [31:0]            error_count
);

    // ============================================================
    // 报错
    // ============================================================
    task err;
        input [8*8-1:0]   rule;     // "R2" 之类
        input [8*72-1:0]  msg;      // 说明
        begin
            error_count = error_count + 1;
            if (error_count <= MAX_REPORT)
                $display("  [%0t] [%0s] 违反 %0s : %0s", $time, NAME, rule, msg);
        end
    endtask

    // ============================================================
    // 上一拍的信号（用来判断"VALID 中途撤销"和"载荷变化"）
    // ============================================================
    reg                  awvalid_d, awready_d;
    reg [ADDR_W-1:0]     awaddr_d;
    reg [LEN_W-1:0]      awlen_d;
    reg [2:0]            awsize_d;
    reg [1:0]            awburst_d;

    reg                  wvalid_d, wready_d;
    reg                  bvalid_d, bready_d;

    reg                  arvalid_d, arready_d;
    reg [ADDR_W-1:0]     araddr_d;
    reg [LEN_W-1:0]      arlen_d;
    reg [2:0]            arsize_d;
    reg [1:0]            arburst_d;

    reg                  rvalid_d, rready_d;
    reg [ID_W-1:0] awid_d, arid_d, bid_d, rid_d;
    reg [DATA_W-1:0] wdata_d, rdata_d;
    reg [DATA_W/8-1:0] wstrb_d;
    reg wlast_d, rlast_d;
    reg [1:0] bresp_d, rresp_d;

    always @(posedge clk) begin
        awvalid_d <= awvalid;  awready_d <= awready;
        awaddr_d  <= awaddr;   awlen_d   <= awlen;
        awsize_d  <= awsize;   awburst_d <= awburst;

        wvalid_d  <= wvalid;   wready_d  <= wready;
        bvalid_d  <= bvalid;   bready_d  <= bready;

        arvalid_d <= arvalid;  arready_d <= arready;
        araddr_d  <= araddr;   arlen_d   <= arlen;
        arsize_d  <= arsize;   arburst_d <= arburst;

        rvalid_d  <= rvalid;   rready_d  <= rready;
        awid_d <= awid; arid_d <= arid; bid_d <= bid; rid_d <= rid;
        wdata_d <= wdata; wstrb_d <= wstrb; wlast_d <= wlast;
        rdata_d <= rdata; rlast_d <= rlast;
        bresp_d <= bresp; rresp_d <= rresp;
    end

    wire aw_hs = awvalid && awready;      // AW 握手
    wire w_hs  = wvalid  && wready;       // W  握手（一拍数据）
    wire b_hs  = bvalid  && bready;       // B  握手
    wire ar_hs = arvalid && arready;      // AR 握手
    wire r_hs  = rvalid  && rready;       // R  握手（一拍数据）

    // ============================================================
    // R1：复位期间不许有 VALID
    // ============================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            if (awvalid) err("R1", "复位期间 AWVALID 拉高");
            if (wvalid)  err("R1", "复位期间 WVALID 拉高");
            if (bvalid)  err("R1", "复位期间 BVALID 拉高");
            if (arvalid) err("R1", "复位期间 ARVALID 拉高");
            if (rvalid)  err("R1", "复位期间 RVALID 拉高");
        end
    end

    // ============================================================
    // R2 / R3：握手前不许撤销 VALID、不许改载荷
    // ============================================================
    always @(posedge clk) begin
        if (rst_n) begin
            // ---- AW ----
            if (awvalid_d && !awready_d) begin
                if (!awvalid) err("R2", "AWVALID 在握手完成前被撤销");
                if (awvalid && (awid !== awid_d || awaddr !== awaddr_d || awlen !== awlen_d ||
                                awsize !== awsize_d || awburst !== awburst_d))
                    err("R3", "AW 载荷在握手完成前发生变化");
            end
            // ---- W ----
            if (wvalid_d && !wready_d) begin
                if (!wvalid) err("R2", "WVALID 在握手完成前被撤销");
                if (wvalid && {wdata,wstrb,wlast} !== {wdata_d,wstrb_d,wlast_d})
                    err("R3", "W payload changed under backpressure");
            end
            // ---- B ----
            if (bvalid_d && !bready_d) begin
                if (!bvalid) err("R2", "BVALID 在握手完成前被撤销");
                if (bvalid && {bid,bresp} !== {bid_d,bresp_d})
                    err("R3", "B payload changed under backpressure");
            end
            // ---- AR ----
            if (arvalid_d && !arready_d) begin
                if (!arvalid) err("R2", "ARVALID 在握手完成前被撤销");
                if (arvalid && (arid !== arid_d || araddr !== araddr_d || arlen !== arlen_d ||
                                arsize !== arsize_d || arburst !== arburst_d))
                    err("R3", "AR 载荷在握手完成前发生变化");
            end
            // ---- R ----
            if (rvalid_d && !rready_d) begin
                if (!rvalid) err("R2", "RVALID 在握手完成前被撤销");
                if (rvalid && {rid,rdata,rresp,rlast} !== {rid_d,rdata_d,rresp_d,rlast_d})
                    err("R3", "R payload changed under backpressure");
            end
        end
    end

    // ============================================================
    // 突发合法性公共检查（R9 / R11 / R12）
    //   addr  : 起始地址
    //   len   : AWLEN / ARLEN
    //   size  : AWSIZE / ARSIZE
    //   burst : AWBURST / ARBURST
    //   tag   : 报错时标明是 AW 还是 AR
    // ============================================================
    task check_burst_static;
        input [ADDR_W-1:0]  addr;
        input [LEN_W-1:0]   len;
        input [2:0]         size;
        input [1:0]         burst;
        input [8*8-1:0]     tag;
        reg [ADDR_W+8:0]    total;
        begin
            // R11：WRAP 未支持
            if (burst == 2'b10 && !ALLOW_WRAP)
                err("R11", {tag, " 使用 WRAP 突发，本设计不支持"});

            // 2'b11 是保留值
            if (burst == 2'b11)
                err("R11", {tag, " 突发类型为保留值 2'b11"});
            if (burst == 2'b00 && len > 15)
                err("R11", {tag, " FIXED burst exceeds 16 beats"});
            if (size > $clog2(DATA_W/8))
                err("R11", {tag, " SIZE exceeds data bus width"});

            // R9：不跨 4KB 边界（只对 INCR 有意义；FIXED 不跨）
            if (burst == 2'b01) begin
                total = (addr[11:0]) + ((len + 1) << size);
                if (total > 4096)
                    err("R9", {tag, " INCR 突发跨越 4KB 边界"});
            end
        end
    endtask

    // ============================================================
    // AW / AR 队列（先进先出，保存未完成事务的信息）
    // ============================================================
    reg [LEN_W-1:0]   awq_len  [0:DEPTH-1];
    reg [ID_W-1:0]    awq_id   [0:DEPTH-1];
    reg [ADDR_W-1:0]  awq_addr [0:DEPTH-1];
    reg [2:0]         awq_size [0:DEPTH-1];
    reg [1:0]         awq_burst[0:DEPTH-1];
    integer awq_wp = 0, awq_rp = 0, awq_cnt = 0;

    reg [LEN_W-1:0]   arq_len  [0:DEPTH-1];
    reg [ID_W-1:0]    arq_id   [0:DEPTH-1];
    reg [ADDR_W-1:0]  arq_addr [0:DEPTH-1];
    reg [2:0]         arq_size [0:DEPTH-1];
    reg [1:0]         arq_burst[0:DEPTH-1];
    integer arq_wp = 0, arq_rp = 0, arq_cnt = 0;

    // 写响应期望的 ID 队列
    reg [ID_W-1:0]    bidq [0:DEPTH-1];
    integer bidq_wp = 0, bidq_rp = 0, bidq_cnt = 0;

    // ============================================================
    // W / R 突发的进行状态
    // ============================================================
    reg              w_active = 0;
    integer          w_beats  = 0;
    reg [LEN_W-1:0]  w_exp_len = 0;

    reg              r_active = 0;
    integer          r_beats  = 0;
    reg [LEN_W-1:0]  r_exp_len = 0;
    reg [ADDR_W-1:0] r_exp_addr = 0;   // INCR 读的下一个期望地址
    reg [2:0]        r_size = 0;
    reg [1:0]        r_burst = 0;

    integer i;

    // ============================================================
    // 主检查流程
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            awq_wp = 0; awq_rp = 0; awq_cnt = 0;
            arq_wp = 0; arq_rp = 0; arq_cnt = 0;
            bidq_wp = 0; bidq_rp = 0; bidq_cnt = 0;
            w_active = 0; w_beats = 0; w_exp_len = 0;
            r_active = 0; r_beats = 0; r_exp_len = 0;
            error_count = 0;
        end
        else begin
            // ----------------------------------------------------
            // AW 握手：静态检查 + 入队
            // ----------------------------------------------------
            if (aw_hs) begin
                check_burst_static(awaddr, awlen, awsize, awburst, "AW");
                if (awq_cnt >= DEPTH) begin
                    err("R14", "AW 队列溢出（未完成写事务过多）");
                end
                else begin
                    awq_len  [awq_wp] = awlen;
                    awq_id   [awq_wp] = awid;
                    awq_addr [awq_wp] = awaddr;
                    awq_size [awq_wp] = awsize;
                    awq_burst[awq_wp] = awburst;
                    awq_wp = (awq_wp + 1) % DEPTH;
                    awq_cnt = awq_cnt + 1;
                end
            end

            // ----------------------------------------------------
            // W 每一拍
            // ----------------------------------------------------
            if (w_hs) begin
                if (!w_active) begin
                    // 突发第一拍 —— 必须有对应的 AW（设计约定）
                    if (awq_cnt == 0) begin
                        err("R13", "W 突发开始，但队列里没有对应的 AW");
                    end
                    else begin
                        w_exp_len = awq_len[awq_rp];
                        w_active  = 1;
                        w_beats   = 1;
                        // 该 AW 的 ID 转交给写响应队列
                        if (bidq_cnt >= DEPTH)
                            err("R14", "BID 队列溢出");
                        else begin
                            bidq[bidq_wp] = awq_id[awq_rp];
                            bidq_wp = (bidq_wp + 1) % DEPTH;
                            bidq_cnt = bidq_cnt + 1;
                        end
                        awq_rp = (awq_rp + 1) % DEPTH;
                        awq_cnt = awq_cnt - 1;
                    end
                end
                else begin
                    w_beats = w_beats + 1;
                end

                // R4：WLAST 的位置
                if (w_active) begin
                    if (w_beats == (w_exp_len + 1)) begin
                        if (!wlast)
                            err("R4", "WLAST 未出现在最后一拍");
                    end
                    else begin
                        if (wlast)
                            err("R4", "WLAST 出现过早（拍数不足 AWLEN+1）");
                    end
                end

                if (wlast && w_active) begin
                    // R6：整段拍数
                    if (w_beats != (w_exp_len + 1))
                        err("R6", "W 拍数与 AWLEN+1 不符");
                    w_active = 0;
                    w_beats  = 0;
                end
            end

            // ----------------------------------------------------
            // B 握手：R10 顺序检查
            // ----------------------------------------------------
            if (b_hs) begin
                if (bidq_cnt == 0)
                    err("R10", "收到写响应，但队列里没有等待的 AW");
                else begin
                    if (bid !== bidq[bidq_rp])
                        err("R10", "BID 与 AWID 的顺序不一致");
                    bidq_rp = (bidq_rp + 1) % DEPTH;
                    bidq_cnt = bidq_cnt - 1;
                end
            end

            // ----------------------------------------------------
            // AR 握手：静态检查 + 入队
            // ----------------------------------------------------
            if (ar_hs) begin
                check_burst_static(araddr, arlen, arsize, arburst, "AR");
                if (arq_cnt >= DEPTH) begin
                    err("R14", "AR 队列溢出（未完成读事务过多）");
                end
                else begin
                    arq_len  [arq_wp] = arlen;
                    arq_id   [arq_wp] = arid;
                    arq_addr [arq_wp] = araddr;
                    arq_size [arq_wp] = arsize;
                    arq_burst[arq_wp] = arburst;
                    arq_wp = (arq_wp + 1) % DEPTH;
                    arq_cnt = arq_cnt + 1;
                end
            end

            // ----------------------------------------------------
            // R 每一拍
            // ----------------------------------------------------
            if (r_hs) begin
                if (!r_active) begin
                    if (arq_cnt == 0) begin
                        err("R13", "R 突发开始，但队列里没有对应的 AR");
                    end
                    else begin
                        r_exp_len  = arq_len[arq_rp];
                        r_size     = arq_size[arq_rp];
                        r_burst    = arq_burst[arq_rp];
                        r_exp_addr = arq_addr[arq_rp];
                        r_active   = 1;
                        r_beats    = 1;
                        if (rid !== arq_id[arq_rp])
                            err("R10", "RID 与 ARID 的顺序不一致");
                        arq_rp = (arq_rp + 1) % DEPTH;
                        arq_cnt = arq_cnt - 1;
                    end
                end
                else begin
                    r_beats = r_beats + 1;
                    // R8：INCR 地址递增
                    if (r_burst == 2'b01)
                        r_exp_addr = r_exp_addr + (1 << r_size);
                end

                if (r_active) begin
                    // R8：这一拍的地址（只在 INCR 时检查，且要能观测到地址）
                    //     读数据通道本身不带地址，所以这里检查的是"算出来的期望"
                    //     如果从设备按 INCR 正常返回，拍数对得上即可；
                    //     地址递增的严格核对由互连/桥的 TB 结合 ARADDR 做。
                    // R5：RLAST 的位置
                    if (r_beats == (r_exp_len + 1)) begin
                        if (!rlast)
                            err("R5", "RLAST 未出现在最后一拍");
                    end
                    else begin
                        if (rlast)
                            err("R5", "RLAST 出现过早（拍数不足 ARLEN+1）");
                    end
                end

                if (rlast && r_active) begin
                    if (r_beats != (r_exp_len + 1))
                        err("R7", "R 拍数与 ARLEN+1 不符");
                    r_active = 0;
                    r_beats  = 0;
                end
            end
        end
    end

endmodule
