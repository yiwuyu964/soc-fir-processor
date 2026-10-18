// ============================================================
// tb_fir.v —— FIR 的 AXI4 从接口 + 中断 单元验证（阶段1 分工 B）
//
// 覆盖（对应阶段1-三人分工.md B 的验收清单）：
//   [1]  复位后 STATUS 初始值 + RID 透传
//   [2]  单拍写 CTRL（flush）+ BID 透传
//   [3]  单拍写 COEF[k]
//   [4]  冲激响应：flush 后第 1 个结果是前导 0（契约 E.6），
//        之后 ±500 / 3277 手算核对；irq_done 置位与"读 STATUS 清除"
//   [5]  饱和：COEF[0..1]=32767、输入 32767×2 → 32766 → 正饱和 32767
//   [6]  读空错误：DOUT 空读 → SLVERR + irq_err；读 STATUS 清除
//   [7]  WSTRB：字节写 CTRL 也能 flush、半字写 DIN、WSTRB=0000 空写无副作用
//   [8]  错误响应：未映射地址 / 访问类型不符 / WRAP / SIZE>2 / 跨 4KB /
//        跨区域 INCR —— 全部 SLVERR 且被拒写事务无副作用
//   [9]  INCR 写突发：82 拍下发全部系数（契约 D.6 的 B 消费方式）
//   [10] FIXED 写突发：256 拍样本 + 82 拍 0 流式写 DIN（338 拍 → 338 个结果）
//   [11] 结果就绪 + irq_done + STATUS 计数（count=338）
//   [12] INCR 读突发：DOUT+STATUS 两拍，RLAST 落在第 2 拍
//   [13] FIXED 读突发：回读 337 个结果，与 fir/exp.hex 逐位一致（got[i+1]==exp[i]）
//   [14] 回读完毕后 STATUS 复核
//   [15] FIFO 溢出：写 603 个样本 → count=512 + irq_err；读 STATUS 清，排空 512 拍
//   [16] 复位健壮性
//
// 协议检查器（仿真全程在线）：
//   · BVALID/RVALID 在 READY=0 时不得撤销（VALID 不许等 READY 的运行时检查）
//   · AXI 输出不允许出现 X
//   · BFM 逐拍核对 BID/RID 透传、RRESP 全程一致、RLAST 只在最后一拍
//
// 运行（从仓库根目录，先由 C 的脚本生成向量）：
//   python fir/fir_coeff.py --taps 81 --cutoff 0.12 --nsamp 256
//   iverilog -g2012 -Wall -o sim.out RTL/fir.v RTL/fir_core.v RTL/sync_fifo.v TB/tb_fir.v
//   vvp sim.out
// ============================================================
`timescale 1ns/1ps

module tb_fir;

    localparam ADDR_W = 32;
    localparam DATA_W = 32;
    localparam ID_W   = 4;
    localparam DW     = 16;
    localparam NTAP   = 82;
    localparam NSAMP  = 256;
    localparam NEXP   = NSAMP + NTAP - 1;        // 全卷积长度 = 337
    localparam BASE   = 32'h4000_0000;           // 契约 C：FIR 基址

    reg clk   = 0;
    reg rst_n = 0;

    // ---- AXI4 主设备侧（BFM 驱动）----
    reg  [ID_W-1:0]   m_awid;
    reg  [ADDR_W-1:0] m_awaddr;
    reg  [7:0]        m_awlen;
    reg  [2:0]        m_awsize;
    reg  [1:0]        m_awburst;
    reg               m_awvalid;
    wire              s_awready;
    reg  [DATA_W-1:0] m_wdata;
    reg  [3:0]        m_wstrb;
    reg               m_wlast;
    reg               m_wvalid;
    wire              s_wready;
    wire [ID_W-1:0]   s_bid;
    wire [1:0]        s_bresp;
    wire              s_bvalid;
    reg               m_bready;
    reg  [ID_W-1:0]   m_arid;
    reg  [ADDR_W-1:0] m_araddr;
    reg  [7:0]        m_arlen;
    reg  [2:0]        m_arsize;
    reg  [1:0]        m_arburst;
    reg               m_arvalid;
    wire              s_arready;
    wire [ID_W-1:0]   s_rid;
    wire [DATA_W-1:0] s_rdata;
    wire [1:0]        s_rresp;
    wire              s_rlast;
    wire              s_rvalid;
    reg               m_rready;

    wire irq_done, irq_err;

    fir #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awid(m_awid), .s_axi_awaddr(m_awaddr), .s_axi_awlen(m_awlen),
        .s_axi_awsize(m_awsize), .s_axi_awburst(m_awburst),
        .s_axi_awvalid(m_awvalid), .s_axi_awready(s_awready),
        .s_axi_wdata(m_wdata), .s_axi_wstrb(m_wstrb), .s_axi_wlast(m_wlast),
        .s_axi_wvalid(m_wvalid), .s_axi_wready(s_wready),
        .s_axi_bid(s_bid), .s_axi_bresp(s_bresp), .s_axi_bvalid(s_bvalid),
        .s_axi_bready(m_bready),
        .s_axi_arid(m_arid), .s_axi_araddr(m_araddr), .s_axi_arlen(m_arlen),
        .s_axi_arsize(m_arsize), .s_axi_arburst(m_arburst),
        .s_axi_arvalid(m_arvalid), .s_axi_arready(s_arready),
        .s_axi_rid(s_rid), .s_axi_rdata(s_rdata), .s_axi_rresp(s_rresp),
        .s_axi_rlast(s_rlast), .s_axi_rvalid(s_rvalid), .s_axi_rready(m_rready),
        .irq_done(irq_done), .irq_err(irq_err)
    );

    always #5 clk = ~clk;                       // 100 MHz

    // ============================================================
    // 数据区
    // ============================================================
    reg [DATA_W-1:0] wmem  [0:511];             // 写数据 / 写选通
    reg [3:0]        wsmem [0:511];
    reg [DATA_W-1:0] rmem  [0:511];             // 读回数据 / 响应 / rlast
    reg [1:0]        rrespm[0:511];
    reg              rlastm[0:511];

    reg [15:0] coeffs [0:NTAP-1];               // fir/coeffs.hex（契约 D.4）
    reg [15:0] stim   [0:NSAMP-1];              // fir/stim.hex（契约 E.2）
    reg [15:0] exp    [0:NEXP-1];               // fir/exp.hex（全卷积 337 个）

    integer errors = 0;
    integer checks = 0;

    task chk;
        input [31:0]  got;
        input [31:0]  expv;
        input [255:0] name;
        begin
            checks = checks + 1;
            if (got !== expv) begin
                errors = errors + 1;
                $display("  [FAIL] %0s : got=0x%08X  期望=0x%08X", name, got, expv);
            end
        end
    endtask

    // ============================================================
    // AXI4 主设备 BFM
    // ============================================================
    // 写事务：数据取自 wmem[base..base+len]，选通取自 wsmem[..]
    task axi_write;
        input [31:0]     addr;
        input [ID_W-1:0] id;
        input [7:0]      len;
        input [2:0]      size;
        input [1:0]      burst;
        input [8:0]      base;
        output [1:0]     resp;
        integer i;
        begin
            @(negedge clk);
            m_awid = id; m_awaddr = addr; m_awlen = len;
            m_awsize = size; m_awburst = burst;
            m_awvalid = 1'b1; m_bready = 1'b1;

            @(posedge clk);
            while (!s_awready) @(posedge clk);
            @(negedge clk) m_awvalid = 1'b0;

            for (i = 0; i <= len; i = i + 1) begin
                @(negedge clk);
                m_wdata = wmem[base + i];
                m_wstrb = wsmem[base + i];
                m_wlast = (i == len);
                m_wvalid = 1'b1;
                @(posedge clk);
                while (!s_wready) @(posedge clk);
                @(negedge clk) m_wvalid = 1'b0;
            end

            @(posedge clk);
            while (!s_bvalid) @(posedge clk);
            resp = s_bresp;
            checks = checks + 1;
            if (s_bid !== id) begin
                errors = errors + 1;
                $display("  [FAIL] BID 透传 : got=%0d 期望=%0d", s_bid, id);
            end
            @(negedge clk) m_bready = 1'b0;
        end
    endtask

    // 读事务：结果存 rmem[base..base+len]，响应/rlast 逐拍记录
    task axi_read;
        input [31:0]     addr;
        input [ID_W-1:0] id;
        input [7:0]      len;
        input [2:0]      size;
        input [1:0]      burst;
        input [8:0]      base;
        output [1:0]     resp;
        integer i;
        begin
            @(negedge clk);
            m_arid = id; m_araddr = addr; m_arlen = len;
            m_arsize = size; m_arburst = burst;
            m_arvalid = 1'b1; m_rready = 1'b1;

            @(posedge clk);
            while (!s_arready) @(posedge clk);
            @(negedge clk) m_arvalid = 1'b0;

            for (i = 0; i <= len; i = i + 1) begin
                @(posedge clk);
                while (!s_rvalid) @(posedge clk);
                rmem[base + i]   = s_rdata;
                rrespm[base + i] = s_rresp;
                rlastm[base + i] = s_rlast;
                if (i == 0) resp = s_rresp;
                checks = checks + 1;
                if (s_rid !== id) begin
                    errors = errors + 1;
                    $display("  [FAIL] RID 透传 : got=%0d 期望=%0d", s_rid, id);
                end
                @(negedge clk);
            end
            @(negedge clk) m_rready = 1'b0;
        end
    endtask

    // 读突发一致性：每拍响应一致、RLAST 只在最后一拍
    task chk_rd_burst;
        input [7:0]      len;
        input [8:0]      base;
        input [1:0]      exp_resp;
        input [255:0]    name;
        integer i;
        begin
            checks = checks + 1;
            for (i = 0; i <= len; i = i + 1) begin
                if (rrespm[base + i] !== exp_resp) begin
                    errors = errors + 1;
                    $display("  [FAIL] %0s : 第%0d拍 resp=0b%b 期望=0b%b",
                             name, i, rrespm[base+i], exp_resp);
                end
                if (rlastm[base + i] !== (i == len)) begin
                    errors = errors + 1;
                    $display("  [FAIL] %0s : 第%0d拍 rlast=%b 期望=%b",
                             name, i, rlastm[base+i], (i == len));
                end
            end
        end
    endtask

    task wait_cycles;
        input [15:0] n;
        begin
            repeat (n) @(posedge clk);
        end
    endtask

    // ============================================================
    // AXI 协议检查器（全程在线）
    // ============================================================
    reg bvalid_d, rvalid_d, b_hs_d, r_hs_d;

    always @(posedge clk) begin
        if (rst_n) begin
            // VALID 不许等 READY 的运行时检查：
            // VALID 拉高后，在 READY=0 的情况下绝不允许自己掉下去
            if (bvalid_d && !s_bvalid && !b_hs_d) begin
                errors = errors + 1;
                $display("  [AXI-ERR] t=%0t BVALID 在 BREADY=0 时被撤销", $time);
            end
            if (rvalid_d && !s_rvalid && !r_hs_d) begin
                errors = errors + 1;
                $display("  [AXI-ERR] t=%0t RVALID 在 RREADY=0 时被撤销", $time);
            end
            bvalid_d <= s_bvalid;
            rvalid_d <= s_rvalid;
            b_hs_d <= s_bvalid && m_bready;
            r_hs_d <= s_rvalid && m_rready;
        end
        else begin
            bvalid_d <= 1'b0; rvalid_d <= 1'b0;
            b_hs_d <= 1'b0; r_hs_d <= 1'b0;
        end
    end

    // AXI 输出 / 中断不允许出现 X
    always @(posedge clk) begin
        if (rst_n) begin
            if (^{s_awready, s_wready, s_bid, s_bresp, s_bvalid,
                  s_arready, s_rid, s_rdata, s_rresp, s_rlast, s_rvalid,
                  irq_done, irq_err} === 1'bx) begin
                errors = errors + 1;
                $display("  [AXI-ERR] t=%0t AXI 输出出现未知态 X", $time);
            end
        end
    end

    // ============================================================
    // 测试序列
    // ============================================================
    reg [1:0] resp;
    integer   i;

    initial begin
        $dumpfile("tb_fir.vcd");
        $dumpvars(2, tb_fir);

        // ---- 初始化 ----
        m_awvalid = 0; m_wvalid = 0; m_arvalid = 0; m_bready = 0; m_rready = 0;
        m_awid = 0; m_awaddr = 0; m_awlen = 0; m_awsize = 3'd2; m_awburst = 2'b01;
        m_wdata = 0; m_wstrb = 4'hF; m_wlast = 0;
        m_arid = 0; m_araddr = 0; m_arlen = 0; m_arsize = 3'd2; m_arburst = 2'b01;
        for (i = 0; i < 512; i = i + 1) wsmem[i] = 4'hF;

        $readmemh("fir/coeffs.hex", coeffs);
        $readmemh("fir/stim.hex",   stim);
        $readmemh("fir/exp.hex",    exp);

        rst_n = 0;
        repeat (5) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (3) @(posedge clk);

        $display("");
        $display("========== FIR AXI4 从接口 + 中断 单元测试 ==========");

        // ----------------------------------------------------
        // [1] 复位后 STATUS 初始值 + RID 透传
        // ----------------------------------------------------
        $display("[1] 复位后 STATUS 初始值");
        axi_read(BASE + 32'h00C, 4'hA, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk_rd_burst(8'd0, 9'd0, 2'b00, "STATUS 读");
        chk(rmem[0], 32'h0000_0001, "复位后 STATUS（empty=1）");
        chk({31'd0, irq_done}, 32'h0, "复位后 irq_done=0");
        chk({31'd0, irq_err}, 32'h0, "复位后 irq_err=0");

        // ----------------------------------------------------
        // [2] 单拍写 CTRL=1（flush），BID 透传
        // ----------------------------------------------------
        $display("[2] 单拍写 CTRL=1（flush）");
        wmem[0] = 32'h0000_0001;
        axi_write(BASE + 32'h000, 4'hB, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk({30'd0, resp}, 32'h0, "CTRL 写响应 OKAY");

        // ----------------------------------------------------
        // [3] 单拍写 COEF[0]=16384（0.5）
        // ----------------------------------------------------
        $display("[3] 单拍写 COEF[0]=16384");
        wmem[0] = 32'h0000_4000;
        axi_write(BASE + 32'h100, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk({30'd0, resp}, 32'h0, "COEF[0] 写响应 OKAY");

        // ----------------------------------------------------
        // [4] 冲激响应（h0=0.5）：前导 0 / 500 / -500 / 3277
        //     + irq_done 置位与"读 STATUS 清除"
        // ----------------------------------------------------
        $display("[4] 冲激响应与 irq_done");
        wmem[0] = 32'h0000_0001;
        axi_write(BASE + 32'h000, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);   // flush

        wmem[0] = 32'h0000_03E8;                                           // DIN=1000
        axi_write(BASE + 32'h004, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk({30'd0, resp}, 32'h0, "DIN 写响应 OKAY");

        wait_cycles(16'd30);
        chk({31'd0, irq_done}, 32'h1, "有结果后 irq_done=1");
        axi_read(BASE + 32'h00C, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk(rmem[0], 32'h0001_0004, "STATUS：count=1, done=1");
        chk({31'd0, irq_done}, 32'h0, "读 STATUS 后 irq_done 清除");

        axi_read(BASE + 32'h008, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk(rmem[0], 32'h0000_0000, "flush 后第 1 个结果是前导 0");

        // 再连续写 3 个样本（最后多写一拍 0 把 6554 的结果"挤"出来）：
        // 契约 A 的时序是"第 m 次 en 打的是前 m-1 个样本形成的延迟线"，
        // 所以结果流 = [0, y0, y1, ...]，最后一个样本的结果需要再多写一拍。
        wmem[0] = 32'hFFFF_FC18;                                           // DIN=-1000
        axi_write(BASE + 32'h004, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        wmem[0] = 32'h0000_199A;                                           // DIN=6554
        axi_write(BASE + 32'h004, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        wmem[0] = 32'h0000_0000;                                           // DIN=0（排空拍）
        axi_write(BASE + 32'h004, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        wait_cycles(16'd30);
        axi_read(BASE + 32'h008, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk(rmem[0], 32'h0000_01F4, "1000 × 0.5 = 500");
        axi_read(BASE + 32'h008, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk(rmem[0], 32'h0000_FE0C, "-1000 × 0.5 = -500（16bit 零扩展）");
        axi_read(BASE + 32'h008, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk(rmem[0], 32'h0000_0CCD, "6554 × 0.5 = 3277");

        axi_read(BASE + 32'h00C, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk(rmem[0], 32'h0000_0001, "读完后 FIFO 空");

        // ----------------------------------------------------
        // [5] 饱和：COEF[0..1]=32767，输入 32767×2 → 32766 → 正饱和 32767
        // ----------------------------------------------------
        $display("[5] 饱和（契约 A6 经 AXI 路径）");
        wmem[0] = 32'h0000_0001;
        axi_write(BASE + 32'h000, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);    // flush
        wmem[0] = 32'h0000_7FFF;
        axi_write(BASE + 32'h100, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);    // COEF[0]
        axi_write(BASE + 32'h104, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);    // COEF[1]
        wmem[0] = 32'h0000_7FFF;                                           // DIN=32767
        axi_write(BASE + 32'h004, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        axi_write(BASE + 32'h004, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        wmem[0] = 32'h0000_0000;                                           // DIN=0（排空拍）
        axi_write(BASE + 32'h004, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        wait_cycles(16'd30);
        axi_read(BASE + 32'h008, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk(rmem[0], 32'h0000_0000, "饱和用例：前导 0");
        axi_read(BASE + 32'h008, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk(rmem[0], 32'h0000_7FFE, "32767×32767>>15 = 32766");
        axi_read(BASE + 32'h008, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk(rmem[0], 32'h0000_7FFF, "两项相加正饱和到 32767");

        // ----------------------------------------------------
        // [6] 读空错误：DOUT 空读 → SLVERR + irq_err，读 STATUS 清除
        // ----------------------------------------------------
        $display("[6] 读空错误（irq_err）");
        wmem[0] = 32'h0000_0001;
        axi_write(BASE + 32'h000, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);    // flush 清空
        axi_read(BASE + 32'h008, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk({30'd0, resp}, 32'h2, "DOUT 读空应返回 SLVERR");
        chk({31'd0, irq_err}, 32'h1, "读空后 irq_err=1");
        axi_read(BASE + 32'h00C, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk(rmem[0], 32'h0000_0009, "STATUS：empty=1, err=1");
        chk({31'd0, irq_err}, 32'h0, "读 STATUS 后 irq_err 清除");
        axi_read(BASE + 32'h00C, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk(rmem[0], 32'h0000_0001, "再次读 STATUS：err 位已清");

        // ----------------------------------------------------
        // [7] WSTRB：字节 flush / 半字 DIN / 空写
        // ----------------------------------------------------
        $display("[7] WSTRB 写选通");
        // 恢复系数 h0=0.5（[5] 改成了 32767）
        wmem[0] = 32'h0000_4000;
        axi_write(BASE + 32'h100, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        wmem[0] = 32'h0000_0000;
        axi_write(BASE + 32'h104, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);

        // 3 个整字 DIN → 3 个结果（前导 0 + 500 + 500；第 m 次 en 打前 m-1 个样本）
        wmem[0] = 32'h0000_03E8;
        axi_write(BASE + 32'h004, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        axi_write(BASE + 32'h004, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        axi_write(BASE + 32'h004, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        wait_cycles(16'd30);
        axi_read(BASE + 32'h00C, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk(rmem[0], 32'h0003_0004, "STATUS：count=3, done=1");

        // 字节写 CTRL（size=0, WSTRB=0001）→ flush 生效，FIFO 清空
        wmem[0]  = 32'h0000_0001;
        wsmem[0] = 4'b0001;
        axi_write(BASE + 32'h000, 4'h1, 8'd0, 3'd0, 2'b01, 9'd0, resp);
        chk({30'd0, resp}, 32'h0, "字节写 CTRL 响应 OKAY");
        wsmem[0] = 4'hF;
        axi_read(BASE + 32'h00C, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk(rmem[0], 32'h0000_0001, "字节 flush 后 FIFO 空");

        // 半字写 DIN（size=1, WSTRB=0011）→ 前导 0 + 500
        wmem[0]  = 32'h0000_03E8;
        wsmem[0] = 4'b0011;
        axi_write(BASE + 32'h004, 4'h1, 8'd0, 3'd1, 2'b01, 9'd0, resp);
        chk({30'd0, resp}, 32'h0, "半字写 DIN 响应 OKAY");
        axi_write(BASE + 32'h004, 4'h1, 8'd0, 3'd1, 2'b01, 9'd0, resp);
        wsmem[0] = 4'hF;
        wait_cycles(16'd20);
        axi_read(BASE + 32'h008, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk(rmem[0], 32'h0000_0000, "半字 DIN：前导 0");
        axi_read(BASE + 32'h008, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk(rmem[0], 32'h0000_01F4, "半字 DIN：500");

        // WSTRB=0000 空写 DIN → 不产生样本
        wmem[0]  = 32'h0000_03E8;
        wsmem[0] = 4'b0000;
        axi_write(BASE + 32'h004, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk({30'd0, resp}, 32'h0, "空写 DIN 响应 OKAY");
        wsmem[0] = 4'hF;
        wait_cycles(16'd20);
        axi_read(BASE + 32'h00C, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk(rmem[0], 32'h0000_0001, "空写不产生样本（FIFO 仍空）");

        // ----------------------------------------------------
        // [8] 错误响应（协议违规 / 非法地址 / 访问类型不符）
        // ----------------------------------------------------
        $display("[8] 错误响应");
        wmem[0] = 32'hDEAD_BEEF;
        axi_write(BASE + 32'h010, 4'h2, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk({30'd0, resp}, 32'h2, "写未映射地址应 SLVERR");
        axi_write(BASE + 32'h00C, 4'h2, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk({30'd0, resp}, 32'h2, "写 STATUS（只读）应 SLVERR");
        axi_read(BASE + 32'h004, 4'h2, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk({30'd0, resp}, 32'h2, "读 DIN（只写）应 SLVERR");
        chk_rd_burst(8'd0, 9'd0, 2'b10, "读 DIN 错误拍");
        axi_read(BASE + 32'h100, 4'h2, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk({30'd0, resp}, 32'h2, "读 COEF（只写）应 SLVERR");
        axi_read(BASE + 32'h010, 4'h2, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk({30'd0, resp}, 32'h2, "读未映射地址应 SLVERR");

        wmem[0] = 32'h0000_03E8; wmem[1] = 32'h0000_03E8;
        axi_write(BASE + 32'h004, 4'h3, 8'd1, 3'd2, 2'b10, 9'd0, resp);
        chk({30'd0, resp}, 32'h2, "WRAP 突发写应 SLVERR");
        axi_read(BASE + 32'h008, 4'h3, 8'd1, 3'd2, 2'b10, 9'd0, resp);
        chk({30'd0, resp}, 32'h2, "WRAP 突发读应 SLVERR");
        chk_rd_burst(8'd1, 9'd0, 2'b10, "WRAP 读错误拍");

        wmem[0] = 32'h0000_03E8;
        axi_write(BASE + 32'h004, 4'h3, 8'd0, 3'd3, 2'b01, 9'd0, resp);
        chk({30'd0, resp}, 32'h2, "SIZE=3 应 SLVERR");

        wmem[0] = 32'h0000_03E8; wmem[1] = 32'h1234_5678;
        axi_write(BASE + 32'h004, 4'h3, 8'd1, 3'd2, 2'b01, 9'd0, resp);
        chk({30'd0, resp}, 32'h2, "跨 DIN+DOUT 的 INCR 写应 SLVERR");
        axi_read(BASE + 32'h008, 4'h3, 8'd2, 3'd2, 2'b01, 9'd0, resp);
        chk({30'd0, resp}, 32'h2, "跨区域的 INCR 读应 SLVERR");
        chk_rd_burst(8'd2, 9'd0, 2'b10, "INCR 读错误拍");

        wmem[0] = 32'h0000_0001; wmem[1] = 32'h0000_0002;
        axi_write(BASE + 32'hFFC, 4'h3, 8'd1, 3'd2, 2'b01, 9'd0, resp);
        chk({30'd0, resp}, 32'h2, "跨 4KB 边界的 INCR 写应 SLVERR");

        // 副作用检查：上面被拒的 DIN 写都不该注入样本
        wait_cycles(16'd30);
        axi_read(BASE + 32'h00C, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk(rmem[0], 32'h0000_0001, "被拒写事务无副作用（FIFO 仍空）");

        // ----------------------------------------------------
        // [9] INCR 写突发：82 拍下发全部系数（契约 D.6 的 B 消费方式）
        // ----------------------------------------------------
        $display("[9] INCR 写突发下发 82 个系数");
        for (i = 0; i < NTAP; i = i + 1) wmem[i] = {16'h0000, coeffs[i]};
        axi_write(BASE + 32'h100, 4'h2, NTAP-1, 3'd2, 2'b01, 9'd0, resp);
        chk({30'd0, resp}, 32'h0, "INCR 系数突发（82 拍）响应 OKAY");

        // ----------------------------------------------------
        // [10] FIXED 写突发：256 拍样本 + 82 拍 0（排空）流式写 DIN
        //      338 个 en 脉冲 → 338 个结果 = 前导 0 + 337 个全卷积输出
        // ----------------------------------------------------
        $display("[10] FIXED 写突发下发 256 个样本 + 82 个排空 0");
        wmem[0] = 32'h0000_0001;
        axi_write(BASE + 32'h000, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);    // flush
        for (i = 0; i < NSAMP; i = i + 1) wmem[i] = {16'h0000, stim[i]};
        axi_write(BASE + 32'h004, 4'h3, 8'd255, 3'd2, 2'b00, 9'd0, resp);
        chk({30'd0, resp}, 32'h0, "FIXED 突发写 DIN（256 拍样本）响应 OKAY");
        for (i = 0; i < NTAP; i = i + 1) wmem[i] = 32'h0000_0000;
        axi_write(BASE + 32'h004, 4'h3, NTAP-1, 3'd2, 2'b00, 9'd0, resp);
        chk({30'd0, resp}, 32'h0, "FIXED 突发写 DIN（82 拍 0，排空）响应 OKAY");

        // ----------------------------------------------------
        // [11] 结果就绪 + irq_done + STATUS 计数
        // ----------------------------------------------------
        $display("[11] 结果就绪与 irq_done");
        wait_cycles(16'd700);
        chk({31'd0, irq_done}, 32'h1, "结果就绪后 irq_done=1");
        axi_read(BASE + 32'h00C, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk(rmem[0], ((NEXP+1) << 16) | 4, "STATUS: full result count, done=1");
        chk({31'd0, irq_done}, 32'h0, "读 STATUS 后 irq_done 清除");

        // ----------------------------------------------------
        // [12] INCR 读突发：DOUT+STATUS 两拍，RLAST 落在第 2 拍
        // ----------------------------------------------------
        $display("[12] INCR 读突发（DOUT + STATUS）");
        axi_read(BASE + 32'h008, 4'h5, 8'd1, 3'd2, 2'b01, 9'd0, resp);
        chk({30'd0, resp}, 32'h0, "INCR 读第 0 拍（DOUT）响应 OKAY");
        chk(rmem[0], 32'h0000_0000, "第 0 拍 DOUT = 前导 0");
        chk(rmem[1], (NEXP << 16) | 4, "STATUS: leading result consumed, done=1");
        chk_rd_burst(8'd1, 9'd0, 2'b00, "INCR 读突发");

        // ----------------------------------------------------
        // [13] FIXED 读突发回读 337 个结果，与黄金模型逐位比对
        // ----------------------------------------------------
        $display("[13] 全量回读 337 个结果，与黄金模型逐位比对");
        axi_read(BASE + 32'h008, 4'h6, 8'd255, 3'd2, 2'b00, 9'd0, resp);
        chk({30'd0, resp}, 32'h0, "FIXED 读突发 0（256 拍）OKAY");
        chk_rd_burst(8'd255, 9'd0, 2'b00, "FIXED 读突发 0");
        axi_read(BASE + 32'h008, 4'h6, NTAP-2, 3'd2, 2'b00, 9'd256, resp);
        chk({30'd0, resp}, 32'h0, "FIXED 读突发 1（80 拍）OKAY");
        chk_rd_burst(NTAP-2, 9'd256, 2'b00, "FIXED 读突发 1");

        // 比对约定（契约 E.6）：got[0]=前导 0（[12] 已查），got[i+1]==exp[i]
        begin
            integer bad;
            bad = 0;
            for (i = 0; i < NEXP; i = i + 1) begin
                if (rmem[i][15:0] !== exp[i]) begin
                    bad = bad + 1;
                    if (bad <= 8)
                        $display("  [MISMATCH] 样本 %0d: AXI 读回=0x%04X 黄金模型=0x%04X",
                                 i, rmem[i][15:0], exp[i]);
                end
            end
            checks = checks + 1;
            if (bad != 0) begin
                errors = errors + 1;
                $display("  [FAIL] 337 个样本逐位比对：%0d 处不一致", bad);
            end
        end

        // 导出 AXI 读回结果（含前导 0），供 fir_coeff.py --check 独立复核
        //（组合验收第 4 步：B 的 AXI 读回 == C 的 exp.hex）
        begin
            reg [15:0] got_hex [0:NEXP];
            integer g;
            got_hex[0] = 16'd0;                        // 前导 0（[12] 已读走并核对）
            for (g = 0; g < NEXP; g = g + 1) got_hex[g+1] = rmem[g][15:0];
            $writememh("got.hex", got_hex);
        end

        // ----------------------------------------------------
        // [14] 回读完毕后的 STATUS 复核
        // ----------------------------------------------------
        $display("[14] 回读完毕后的 STATUS");
        axi_read(BASE + 32'h00C, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk(rmem[0], 32'h0000_0001, "FIFO 空、err=0");
        chk({31'd0, irq_done}, 32'h0, "irq_done 保持 0");
        chk({31'd0, irq_err}, 32'h0, "irq_err 保持 0");

        // ----------------------------------------------------
        // [15] FIFO 溢出错误：写 603 个样本 → count=512 + irq_err
        // ----------------------------------------------------
        $display("[15] FIFO 溢出错误（irq_err）");
        wmem[0] = 32'h0000_0001;
        axi_write(BASE + 32'h000, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);    // flush
        for (i = 0; i < 256; i = i + 1) wmem[i] = {16'h0000, stim[i]};
        axi_write(BASE + 32'h004, 4'h1, 8'd255, 3'd2, 2'b00, 9'd0, resp);
        axi_write(BASE + 32'h004, 4'h1, 8'd255, 3'd2, 2'b00, 9'd0, resp);
        axi_write(BASE + 32'h004, 4'h1, 8'd90, 3'd2, 2'b00, 9'd0, resp);
        wait_cycles(16'd700);
        chk({31'd0, irq_err}, 32'h1, "溢出后 irq_err=1");
        axi_read(BASE + 32'h00C, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk(rmem[0], 32'h0200_000E, "STATUS：count=512, full=1, done=1, err=1");
        chk({31'd0, irq_err}, 32'h0, "读 STATUS 后 irq_err 清除");

        // 排空 512 个结果
        axi_read(BASE + 32'h008, 4'h7, 8'd255, 3'd2, 2'b00, 9'd0, resp);
        chk({30'd0, resp}, 32'h0, "排空突发 0（256 拍）OKAY");
        chk_rd_burst(8'd255, 9'd0, 2'b00, "排空突发 0");
        axi_read(BASE + 32'h008, 4'h7, 8'd255, 3'd2, 2'b00, 9'd0, resp);
        chk({30'd0, resp}, 32'h0, "排空突发 1（256 拍）OKAY");
        chk_rd_burst(8'd255, 9'd0, 2'b00, "排空突发 1");
        axi_read(BASE + 32'h00C, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk(rmem[0], 32'h0000_0001, "排空后 FIFO 空");

        // ----------------------------------------------------
        // [16] 复位健壮性
        // ----------------------------------------------------
        $display("[16] 复位健壮性");
        @(negedge clk); rst_n = 0;
        repeat (5) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (2) @(posedge clk);
        chk({31'd0, s_bvalid}, 32'h0, "复位后 BVALID=0");
        chk({31'd0, s_rvalid}, 32'h0, "复位后 RVALID=0");
        chk({31'd0, irq_done}, 32'h0, "复位后 irq_done=0");
        chk({31'd0, irq_err}, 32'h0, "复位后 irq_err=0");
        axi_read(BASE + 32'h00C, 4'h1, 8'd0, 3'd2, 2'b01, 9'd0, resp);
        chk(rmem[0], 32'h0000_0001, "复位后 STATUS=1（FIFO 空）");

        // ----------------------------------------------------
        wmem[0]=1;
        // STATUS must remain frozen while FIFO results arrive under R backpressure.
        axi_write(32'h40000000,0,0,2,1,0,resp); // CTRL flush (wmem[0] set below)
        @(negedge clk);
        m_araddr=32'h4000000c; m_arlen=0; m_arid=0; m_arsize=2;
        m_arburst=1; m_arvalid=1; m_rready=0;
        @(posedge clk); while(!s_arready) @(posedge clk);
        @(negedge clk); m_arvalid=0;
        wait(s_rvalid); @(negedge clk);
        begin
            reg [31:0] held;
            held=s_rdata;
            force dut.dout_v=1'b1;
            repeat(4) begin @(negedge clk); chk(s_rdata,held,"stalled STATUS stability"); end
            release dut.dout_v;
        end
        m_rready=1; @(negedge clk); m_rready=0;
        repeat (10) @(posedge clk);
        $display("");
        $display("============================================");
        if (errors == 0)
            $display("===== PASS: %0d 项检查全部通过，AXI 协议无违规 =====", checks);
        else
            $display("===== FAIL: %0d 项检查中 %0d 项失败 =====", checks, errors);
        $display("============================================");
        $finish;
    end

    // 超时保护：防止测试挂死
    initial begin
        #2000000;
        $display("!!!! TIMEOUT：仿真超时，测试未正常结束");
        $finish;
    end

endmodule
