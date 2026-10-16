// ============================================================
// tb_axi_checker.v —— AXI 协议检查器的【自测台】
//
// 目的：证明 checker 不是摆设。
//   方法：先喂一段【完全合法】的流量，必须 0 错误；
//         然后每一条规则各制造一次【故意违规】，必须被抓到。
//
// 为什么必须这么测：
//   一个"永远不报错"的 checker 会让所有人都以为代码是对的。
//   只有证明它对每个违规都会报错，它的"0 错误"才有意义。
//
// 运行：
//   iverilog -g2012 -o sim.out TB/axi_protocol_checker.v TB/tb_axi_checker.v
//   vvp sim.out
//
// ⚠️ 如果控制台里中文显示成乱码（Windows cmd 默认 GBK 编码）：
//     先执行  chcp 65001   切到 UTF-8，再跑仿真。
//     规则号（R1~R14）和端口名都是 ASCII，即使乱码也能看清是哪一条违规。
// ============================================================
`timescale 1ns/1ps

module tb_axi_checker;

    localparam ADDR_W = 32;
    localparam DATA_W = 32;
    localparam ID_W   = 4;
    localparam LEN_W  = 8;

    reg clk = 0;
    reg rst_n = 0;

    reg [ID_W-1:0]     awid = 0;
    reg [ADDR_W-1:0]   awaddr = 0;
    reg [LEN_W-1:0]    awlen = 0;
    reg [2:0]          awsize = 3'd2;
    reg [1:0]          awburst = 2'b01;
    reg                awvalid = 0;
    reg                awready = 0;

    reg [DATA_W-1:0]   wdata = 0;
    reg [DATA_W/8-1:0] wstrb = 4'hF;
    reg                wlast = 0;
    reg                wvalid = 0;
    reg                wready = 0;

    reg [ID_W-1:0]     bid = 0;
    reg [1:0]          bresp = 2'b00;
    reg                bvalid = 0;
    reg                bready = 0;

    reg [ID_W-1:0]     arid = 0;
    reg [ADDR_W-1:0]   araddr = 0;
    reg [LEN_W-1:0]    arlen = 0;
    reg [2:0]          arsize = 3'd2;
    reg [1:0]          arburst = 2'b01;
    reg                arvalid = 0;
    reg                arready = 0;

    reg [ID_W-1:0]     rid = 0;
    reg [DATA_W-1:0]   rdata = 0;
    reg [1:0]          rresp = 2'b00;
    reg                rlast = 0;
    reg                rvalid = 0;
    reg                rready = 0;

    wire [31:0] error_count;

    axi_protocol_checker #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W), .LEN_W(LEN_W),
        .NAME("tb_dut"), .ALLOW_WRAP(0), .MAX_REPORT(5)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
        .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
        .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
        .arvalid(arvalid), .arready(arready),
        .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
        .error_count(error_count)
    );

    always #5 clk = ~clk;              // 100 MHz

    integer checks = 0;
    integer errors = 0;

    // ============================================================
    // 复位：同时把 checker 的 error_count 清零
    // ============================================================
    task do_reset;
        begin
            @(negedge clk);
            awvalid=0; wvalid=0; bvalid=0; arvalid=0; rvalid=0;
            awready=0; wready=0; bready=0; arready=0; rready=0;
            rst_n = 0;
            repeat (3) @(posedge clk);
            @(negedge clk); rst_n = 1;
            repeat (2) @(posedge clk);
        end
    endtask

    task expect_zero;
        input [255:0] name;
        begin
            checks = checks + 1;
            if (error_count !== 0) begin
                errors = errors + 1;
                $display("  [FAIL] %0s : 期望 0 个错误，实际 %0d 个", name, error_count);
            end else
                $display("  [ OK ] %0s : 0 个错误", name);
        end
    endtask

    task expect_at_least;
        input integer want;
        input [255:0] name;
        begin
            checks = checks + 1;
            if (error_count < want) begin
                errors = errors + 1;
                $display("  [FAIL] %0s : 期望至少 %0d 个错误，实际 %0d 个（漏报了！）", name, want, error_count);
            end else
                $display("  [ OK ] %0s : 抓到 %0d 个错误", name, error_count);
        end
    endtask

    // ============================================================
    // 一次完全合法的 INCR 写事务（AW 1 拍 + W len+1 拍 + B 1 拍）
    // ============================================================
    task legal_write;
        input [ADDR_W-1:0] a;
        input [LEN_W-1:0]  len;
        integer k;
        begin
            @(negedge clk);
            awid=4'd0; awaddr=a; awlen=len; awsize=3'd2; awburst=2'b01;
            awvalid=1; awready=1;
            @(negedge clk); awvalid=0; awready=0;

            for (k = 0; k <= len; k = k + 1) begin
                @(negedge clk);
                wdata=k; wstrb=4'hF; wlast=(k==len); wvalid=1; wready=1;
            end
            @(negedge clk); wvalid=0; wready=0; wlast=0;

            @(negedge clk);
            bid=4'd0; bresp=2'b00; bvalid=1; bready=1;
            @(negedge clk); bvalid=0; bready=0;
            @(negedge clk);
        end
    endtask

    // ============================================================
    // 一次完全合法的 INCR 读事务（AR 1 拍 + R len+1 拍）
    // ============================================================
    task legal_read;
        input [ADDR_W-1:0] a;
        input [LEN_W-1:0]  len;
        integer k;
        begin
            @(negedge clk);
            arid=4'd0; araddr=a; arlen=len; arsize=3'd2; arburst=2'b01;
            arvalid=1; arready=1;
            @(negedge clk); arvalid=0; arready=0;

            for (k = 0; k <= len; k = k + 1) begin
                @(negedge clk);
                rid=4'd0; rdata=k; rresp=2'b00; rlast=(k==len); rvalid=1; rready=1;
            end
            @(negedge clk); rvalid=0; rready=0; rlast=0;
            @(negedge clk);
        end
    endtask

    // ============================================================
    initial begin
        $dumpfile("tb_axi_checker.vcd");
        $dumpvars(0, tb_axi_checker);

        repeat (4) @(posedge clk);

        $display("");
        $display("========== AXI 协议检查器 自测 ==========");
        $display("（先喂合法流量验不误报，再逐条制造违规验不漏报）");
        $display("");

        // ----------------------------------------------------
        // 0) 合法流量 —— 必须 0 错误（防误报）
        // ----------------------------------------------------
        $display("[T0] 合法流量：2 次写 + 2 次读");
        do_reset;
        legal_write(32'h4000_0000, 8'd3);      // 4 拍写
        legal_write(32'h4000_1000, 8'd0);      // 单拍写
        legal_read (32'h4000_0000, 8'd3);      // 4 拍读
        legal_read (32'h2000_0000, 8'd0);      // 单拍读
        repeat (4) @(posedge clk);
        expect_zero("T0 合法流量不误报");

        // ----------------------------------------------------
        // 1) R2：AWVALID 在握手完成前被撤销
        // ----------------------------------------------------
        $display("[T1] R2 违规：AWVALID 中途撤销");
        do_reset;
        @(negedge clk); awid=0; awaddr=32'h4000_0000; awlen=0; awsize=3'd2; awburst=2'b01;
                        awvalid=1; awready=0;      // 对方不 ready
        repeat (2) @(negedge clk);
        awvalid = 0;                                // ← 违规：没握手就撤
        repeat (3) @(posedge clk);
        expect_at_least(1, "T1 抓到 AWVALID 撤销");

        // ----------------------------------------------------
        // 2) R3：AW 载荷在握手前变化
        // ----------------------------------------------------
        $display("[T2] R3 违规：AW 载荷中途变化（顺带会触发 R2）");
        do_reset;
        @(negedge clk); awid=0; awaddr=32'h4000_0000; awlen=8'd3; awsize=3'd2; awburst=2'b01;
                        awvalid=1; awready=0;
        repeat (2) @(negedge clk);
        awaddr = 32'h4000_0100;                     // ← 违规：地址变了
        repeat (3) @(posedge clk);
        @(negedge clk); awvalid=0;
        repeat (2) @(posedge clk);
        expect_at_least(1, "T2 抓到 AW 载荷变化");

        // ----------------------------------------------------
        // 3) R4：WLAST 出现过早
        // ----------------------------------------------------
        $display("[T3] R4 违规：WLAST 出现过早（顺带触发 R6）");
        do_reset;
        @(negedge clk); awid=0; awaddr=32'h4000_0000; awlen=8'd3; awsize=3'd2; awburst=2'b01;
                        awvalid=1; awready=1;
        @(negedge clk); awvalid=0; awready=0;
        @(negedge clk); wdata=0; wstrb=4'hF; wlast=1; wvalid=1; wready=1;   // ← 第 1 拍就 last
        @(negedge clk); wlast=0; wvalid=0; wready=0;
        repeat (3) @(posedge clk);
        expect_at_least(1, "T3 抓到 WLAST 过早");

        // ----------------------------------------------------
        // 4) R5：RLAST 出现过早
        // ----------------------------------------------------
        $display("[T4] R5 违规：RLAST 出现过早");
        do_reset;
        @(negedge clk); arid=0; araddr=32'h4000_0000; arlen=8'd3; arsize=3'd2; arburst=2'b01;
                        arvalid=1; arready=1;
        @(negedge clk); arvalid=0; arready=0;
        @(negedge clk); rid=0; rdata=0; rlast=1; rvalid=1; rready=1;        // ← 第 1 拍就 last
        @(negedge clk); rlast=0; rvalid=0; rready=0;
        repeat (3) @(posedge clk);
        expect_at_least(1, "T4 抓到 RLAST 过早");

        // ----------------------------------------------------
        // 5) R9：突发跨 4KB 边界
        // ----------------------------------------------------
        $display("[T5] R9 违规：INCR 突发跨 4KB");
        do_reset;
        // 地址 0x4000_0FF0，len=4，size=2 → 5 拍 × 4 字节 = 20 字节
        // 0xFF0 + 20 = 0x1004，最后一个字落在 0x1000 → 确实跨过 4KB 边界
        @(negedge clk); awid=0; awaddr=32'h4000_0FF0; awlen=8'd4; awsize=3'd2; awburst=2'b01;
                        awvalid=1; awready=1;
        @(negedge clk); awvalid=0; awready=0;
        repeat (3) @(posedge clk);
        expect_at_least(1, "T5 抓到跨 4KB");

        // ----------------------------------------------------
        // 6) R11：使用未支持的 WRAP 突发
        // ----------------------------------------------------
        $display("[T6] R11 违规：WRAP 突发（本设计不支持）");
        do_reset;
        @(negedge clk); awid=0; awaddr=32'h4000_0000; awlen=8'd3; awsize=3'd2; awburst=2'b10;
                        awvalid=1; awready=1;
        @(negedge clk); awvalid=0; awready=0;
        repeat (3) @(posedge clk);
        expect_at_least(1, "T6 抓到 WRAP");

        // ----------------------------------------------------
        // 7) R10：BID 顺序与 AWID 不一致
        // ----------------------------------------------------
        $display("[T7] R10 违规：BID 顺序错");
        do_reset;
        // 先发两个 AW（ID 分别 0 和 1），然后回一个 ID=1 的 B（顺序错）
        @(negedge clk); awid=4'd0; awaddr=32'h4000_0000; awlen=8'd0; awsize=3'd2; awburst=2'b01;
                        awvalid=1; awready=1;
        @(negedge clk); awid=4'd1; awaddr=32'h4000_1000; awlen=8'd0; awsize=3'd2; awburst=2'b01;
                        awvalid=1; awready=1;
        @(negedge clk); awvalid=0; awready=0;
        // 两次 W（对应两个 AW）
        @(negedge clk); wdata=0; wlast=1; wvalid=1; wready=1;
        @(negedge clk); wdata=0; wlast=1; wvalid=1; wready=1;
        @(negedge clk); wvalid=0; wready=0; wlast=0;
        // 第一次响应应该是 ID=0，故意回 ID=1
        @(negedge clk); bid=4'd1; bresp=0; bvalid=1; bready=1;    // ← 违规
        @(negedge clk); bvalid=0; bready=0;
        repeat (3) @(posedge clk);
        expect_at_least(1, "T7 抓到 BID 顺序错");

        // ----------------------------------------------------
        // 8) R13：W 突发开始时没有对应的 AW
        // ----------------------------------------------------
        $display("[T8] R13 违规：W 无对应 AW");
        do_reset;
        @(negedge clk); wdata=0; wlast=1; wvalid=1; wready=1;    // ← 没有 AW 就发 W
        @(negedge clk); wvalid=0; wready=0; wlast=0;
        repeat (3) @(posedge clk);
        expect_at_least(1, "T8 抓到 W 无 AW");

        // ----------------------------------------------------
        // 9) R1：复位期间 VALID 拉高
        // ----------------------------------------------------
        $display("[T9] R1 违规：复位期间 VALID 拉高");
        do_reset;
        @(negedge clk); rst_n = 0; awvalid = 1;    // ← 违规
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1; awvalid = 0;
        repeat (3) @(posedge clk);
        expect_at_least(1, "T9 抓到复位期间 VALID");

        // ----------------------------------------------------
        $display("");
        // Negative tests for fields omitted by the original payload monitor.
        do_reset;
        @(negedge clk); awvalid=1;awready=0;awid=0;
        repeat(2) @(negedge clk); awid=1;
        repeat(2) @(negedge clk); expect_at_least(1,"stalled AWID change");
        do_reset;
        @(negedge clk); wvalid=1;wready=0;wdata=0;
        repeat(2) @(negedge clk); wdata=1;
        repeat(2) @(negedge clk); expect_at_least(1,"stalled WDATA change");
        do_reset;
        @(negedge clk); bvalid=1;bready=0;bresp=0;
        repeat(2) @(negedge clk); bresp=2;
        repeat(2) @(negedge clk); expect_at_least(1,"stalled BRESP change");
        do_reset;
        @(negedge clk); arvalid=1;arready=0;arid=0;
        repeat(2) @(negedge clk); arid=1;
        repeat(2) @(negedge clk); expect_at_least(1,"stalled ARID change");
        do_reset;
        @(negedge clk); rvalid=1;rready=0;rdata=0;
        repeat(2) @(negedge clk); rdata=1;
        repeat(2) @(negedge clk); expect_at_least(1,"stalled RDATA change");
        do_reset;
        @(negedge clk);awvalid=1;awready=1;awburst=0;awlen=16;
        @(negedge clk);awvalid=0;
        repeat(2) @(negedge clk); expect_at_least(1,"FIXED length limit");
        $display("=========================================================");
        if (errors == 0)
            $display("===== PASS: 自测 %0d 项全部通过（不误报、不漏报）=====", checks);
        else
            $display("===== FAIL: %0d 项检查中 %0d 项不通过 =====", checks, errors);
        $display("=========================================================");
        $finish;
    end

    initial begin
        #500000;
        $display("!!!! TIMEOUT：仿真超时");
        $finish;
    end

endmodule
