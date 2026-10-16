// ============================================================
// tb_soc.v —— SoC 顶层集成验证（阶段4 分工 C）
//
// 【验证对象】RTL/soc_top.v（A 的顶层集成）
//   端口与地址映射严格按 docs/阶段4-契约S-soc顶层端口.md
//
// 【这个测试台验证什么】（= 阶段4 交付要求「UART 回显仿真通过记录」）
//   [1] 固件装进 SRAM 后 CPU 能启动（信箱出现魔数 'SOC!'）
//   [2] 冒烟：CPU 读写 SRAM / FIR / DMA / UART 寄存器都正确
//   [3] UART 回显：给 uart_rxd 发 N 个字节，uart_txd 原样回来
//   [4] 全程 AXI 协议零违规（检查器挂在 CPU 侧 AXI 主口上）
//
// 【⚠️ 对 A 的两条命名要求】（TB 靠层次化引用访问内部信号）
//   · soc_top 里片内 SRAM 的实例名必须是  u_sram
//     （其存储阵列沿用 axi_sram.v 的 mem，TB 用它装固件、读测试信箱）
//   · soc_top 里 AHB→AXI 桥的实例名必须是  u_ahb2axi
//     （TB 在它的 AXI 主口 m_axi_* 上挂 AXI 协议检查器）
//   这两条已写进 docs/阶段4-契约S-soc顶层端口.md §S.12。
//
// 【运行】
//   先编固件：  python sw/build.py
//   再跑仿真：  sim\sim.cmd -Only soc
// ============================================================
`timescale 1ns/1ps

module tb_soc;

    // ---- 与 soc_top 的默认参数保持一致（契约S §S.1 / §S.3）----
    localparam ADDR_W     = 32;
    localparam DATA_W     = 32;
    localparam ID_W       = 4;
    localparam SRAM_BYTES = 65536;
    localparam CLK_FREQ   = 100_000_000;   // 仿真用 100MHz
    localparam UART_DIV   = 10;            // BAUD = 100MHz / 10 = 10M
    localparam CLK_HALF   = 5;             // 10ns 周期
    localparam BAUD_NS    = (CLK_FREQ / UART_DIV) == 0 ? 100 : (1_000_000_000 / (CLK_FREQ / UART_DIV));

    localparam SW_DEPTH   = SRAM_BYTES / 4;      // SRAM 字数（16384）
    localparam MB_WORD    = 32'h0000_0F00 / 4;   // 测试信箱（字节地址 0xF00 → 字索引 0x3C0）
    localparam FW_HEX     = "sw/firmware.hex";

    reg clk = 0;
    reg rst_n = 0;
    always #CLK_HALF clk = ~clk;

    wire uart_txd;
    reg  uart_rxd = 1;          // UART 空闲态为高

    // ============================================================
    // DUT —— 严格按契约S §S.1 例化
    // ============================================================
    soc_top #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W),
        .SRAM_BYTES(SRAM_BYTES), .CLK_FREQ(CLK_FREQ), .UART_DIV(UART_DIV)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .uart_txd(uart_txd), .uart_rxd(uart_rxd)
    );

    // ============================================================
    // AXI 协议检查器 —— 挂在 CPU 侧的 AXI 主口（AHB→AXI 桥的输出）
    // 这是整片 SoC 里最繁忙、最容易出协议问题的一条路径
    // ============================================================
    wire [31:0] err_axi_cpu;

    axi_protocol_checker #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W), .LEN_W(8),
        .NAME("cpu_axi"), .ALLOW_WRAP(1)
    ) u_chk_cpu (
        .clk(clk), .rst_n(rst_n),
        .awid(dut.u_ahb2axi.m_axi_awid), .awaddr(dut.u_ahb2axi.m_axi_awaddr),
        .awlen(dut.u_ahb2axi.m_axi_awlen), .awsize(dut.u_ahb2axi.m_axi_awsize),
        .awburst(dut.u_ahb2axi.m_axi_awburst),
        .awvalid(dut.u_ahb2axi.m_axi_awvalid), .awready(dut.u_ahb2axi.m_axi_awready),
        .wdata(dut.u_ahb2axi.m_axi_wdata), .wstrb(dut.u_ahb2axi.m_axi_wstrb),
        .wlast(dut.u_ahb2axi.m_axi_wlast),
        .wvalid(dut.u_ahb2axi.m_axi_wvalid), .wready(dut.u_ahb2axi.m_axi_wready),
        .bid(dut.u_ahb2axi.m_axi_bid), .bresp(dut.u_ahb2axi.m_axi_bresp),
        .bvalid(dut.u_ahb2axi.m_axi_bvalid), .bready(dut.u_ahb2axi.m_axi_bready),
        .arid(dut.u_ahb2axi.m_axi_arid), .araddr(dut.u_ahb2axi.m_axi_araddr),
        .arlen(dut.u_ahb2axi.m_axi_arlen), .arsize(dut.u_ahb2axi.m_axi_arsize),
        .arburst(dut.u_ahb2axi.m_axi_arburst),
        .arvalid(dut.u_ahb2axi.m_axi_arvalid), .arready(dut.u_ahb2axi.m_axi_arready),
        .rid(dut.u_ahb2axi.m_axi_rid), .rdata(dut.u_ahb2axi.m_axi_rdata),
        .rresp(dut.u_ahb2axi.m_axi_rresp), .rlast(dut.u_ahb2axi.m_axi_rlast),
        .rvalid(dut.u_ahb2axi.m_axi_rvalid), .rready(dut.u_ahb2axi.m_axi_rready),
        .error_count(err_axi_cpu)
    );

    // ============================================================
    // UART 物理层 BFM
    //   发送（TB → DUT）：按 10M 波特给 uart_rxd 打串行帧
    //   接收（DUT → TB）：监控 uart_txd，拼回字节
    // ============================================================
    // ---- 发送：一个字节 = 起始位(0) + 8 数据位(LSB 先) + 停止位(1) ----
    task uart_send_byte;
        input [7:0] b;
        integer i;
        begin
            uart_rxd = 1'b0;                // 起始位
            #BAUD_NS;
            for (i = 0; i < 8; i = i + 1) begin
                uart_rxd = b[i];            // LSB 先
                #BAUD_NS;
            end
            uart_rxd = 1'b1;                // 停止位
            #BAUD_NS;
        end
    endtask

    // ---- 接收：等一个起始位，然后按半位对齐采样 ----
    reg [7:0] rx_byte;
    integer   rx_count = 0;

    task uart_recv_byte;
        output [7:0] b;
        integer i;
        integer w;
        reg got_start;
        begin
            // 等起始位下降沿，但【必须有超时】——
            // 否则 DUT 不回显时这里会永久挂住，仿真跑到全局超时才结束
            // 一个字节在 10M 波特下只要 100 拍；给 5000 拍（50 个字节时间）
            // 已经非常宽裕。别写太大 —— 8 个字节各等一次，累积起来会顶穿全局超时。
            got_start = 0;
            for (w = 0; w < 5000; w = w + 1) begin
                @(posedge clk);
                if (uart_txd === 1'b0) begin got_start = 1; w = 5000; end
            end
            if (!got_start) begin
                b = 8'hXX;
                $display("      ⚠️ 等不到起始位（%0t）—— 对端没发数据", $time);
                disable uart_recv_byte;
            end
            #(BAUD_NS + BAUD_NS/2);         // 跳到第一个数据位的中点
            for (i = 0; i < 8; i = i + 1) begin
                b[i] = uart_txd;
                #BAUD_NS;
            end
            // 此时应在停止位上
            rx_count = rx_count + 1;
        end
    endtask

    // ============================================================
    // 统计
    // ============================================================
    integer errors = 0;
    integer checks = 0;

    task chk;
        input [31:0]  got;
        input [31:0]  exp;
        input [255:0] name;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("  [FAIL] %0s : got=0x%08X  期望=0x%08X", name, got, exp);
            end
        end
    endtask

    task chk_true;
        input cond;
        input [255:0] name;
        begin
            checks = checks + 1;
            if (cond !== 1'b1) begin
                errors = errors + 1;
                $display("  [FAIL] %0s", name);
            end
        end
    endtask

    // 读 SRAM 里的一个字（字索引）
    function [31:0] sram_word;
        input integer widx;
        begin
            sram_word = dut.u_sram.mem[widx];
        end
    endfunction

    // ============================================================
    // 测试流程
    // ============================================================
    integer i, k;
    reg [7:0] tx_bytes [0:15];
    reg [7:0] got_b;
    reg [31:0] mb;
    integer echo_exp;
    integer guard;
    integer fw_fd;

    initial begin
        // ⚠️ 波形默认【不录】。
        //   原因：$dumpvars(0, tb_soc) 会把 16384 个字的 SRAM 阵列
        //   每次变化全录进 VCD —— CPU 一跑起来波形就爆，仿真慢到跑不完
        //   （实测 10 分钟不结束；关掉后秒级完成）。
        //   要看波形：vvp sim.out +vcd      只录顶层信号，够看控制流。
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_soc.vcd");
            $dumpvars(1, tb_soc);
        end

        // ---- 复位期间把固件装进 SRAM ----
        rst_n = 0;
        for (i = 0; i < SW_DEPTH; i = i + 1) dut.u_sram.mem[i] = 32'h0;

        if (!$test$plusargs("nofw")) begin
            // 先填 0 再装固件：SRAM 没有复位，不填的话未初始化区是 X，
            // CPU 一读到 X 就可能跑飞
            $display("  装载固件: %0s", FW_HEX);
            fw_fd = $fopen(FW_HEX, "r");
            if (!fw_fd) $fatal(1, "FAIL: missing firmware; run python sw/build.py");
            $fclose(fw_fd);
            $readmemh(FW_HEX, dut.u_sram.mem);
            // 说明：固件通常只有几百个字，而 SRAM 有 16384 个字，
            // iverilog 会报 "Not enough words in the file for the requested
            // range" —— 这是【正常】的，它只填固件那部分，其余保持预填的 0。
            // 不显示"已装入"，免得文件不存在时也报成功。
            if ((^sram_word(0) === 1'bx) || (sram_word(0) == 0) ||
                (^sram_word(1) === 1'bx) || ((sram_word(1) & 1) == 0))
                $fatal(1, "FAIL: invalid firmware vectors");
        end else begin
            $display("  ⚠️ 跳过固件装载（+nofw），只做结构性检查");
        end

        repeat (20) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (20) @(posedge clk);

        $display("");
        $display("========== SoC 顶层集成验证 ==========");

        // ----------------------------------------------------
        // [1] CPU 启动：等信箱出现魔数 'SOC!'
        // ----------------------------------------------------
        $display("[1] CPU 启动（等测试信箱出现魔数）");
        guard = 0;
        mb = 32'h0;
        while ((mb !== 32'h534F4321) && (guard < 20000)) begin
            @(negedge clk);
            mb = sram_word(MB_WORD + 0);
            guard = guard + 1;
        end
        $display("      等了 %0d 拍", guard);
        chk(mb, 32'h534F4321, "信箱魔数 'SOC!'（CPU 取指+执行正常）");
        if (mb !== 32'h534F4321) begin
            $display("  ⚠️ CPU 没跑起来 —— 后面的测试跳过。");
            $display("     排查顺序：1) 固件编出来了没(python sw/build.py)");
            $display("               2) SRAM 是否接在互连 m3（不是 m2）");
            $display("               3) 向量表是不是在 0x0");
            $display("");
            $display("===== FAIL: CPU 未启动 =====");
            $finish;
        end

        // ----------------------------------------------------
        // [2] 冒烟测试结果（固件自己写进信箱）
        // ----------------------------------------------------
        $display("[2] 冒烟测试（固件写进信箱的结果）");
        // 等固件把状态置成 SMOKE_OK
        guard = 0;
        while ((sram_word(MB_WORD + 6) !== 32'h1000) && (guard < 200000)) begin
            @(negedge clk);
            guard = guard + 1;
        end
        chk(sram_word(MB_WORD + 6), 32'h0000_1000, "固件完成冒烟测试");
        $display("      冒烟 通过 %0d 项 / 失败 %0d 项",
                 sram_word(MB_WORD + 1), sram_word(MB_WORD + 2));
        chk(sram_word(MB_WORD + 2), 32'h0, "冒烟测试零失败");

        // ----------------------------------------------------
        // [3] UART 回显：发 N 个字节，全部原样回来
        // ----------------------------------------------------
        $display("[3] UART 回显（发 %0d 个字节）", 8);
        tx_bytes[0] = 8'h41;  // 'A'
        tx_bytes[1] = 8'h42;  // 'B'
        tx_bytes[2] = 8'h43;  // 'C'
        tx_bytes[3] = 8'h30;  // '0'
        tx_bytes[4] = 8'h39;  // '9'
        tx_bytes[5] = 8'h00;
        tx_bytes[6] = 8'hFF;
        tx_bytes[7] = 8'h7E;  // '~'

        // 逐个发，同时收（firmware 是"收到就发回"，可以边发边收）
        for (i = 0; i < 8; i = i + 1) begin
            fork
                uart_send_byte(tx_bytes[i]);
                begin
                    uart_recv_byte(got_b);
                    chk({24'h0, got_b}, {24'h0, tx_bytes[i]}, "回显字节");
                end
            join
        end
        chk({24'h0, sram_word(MB_WORD + 3)}, 32'd8, "固件统计的回显字节数");

        // ----------------------------------------------------
        // [4] AXI 协议检查器
        // ----------------------------------------------------
        repeat (50) @(negedge clk);
        $display("[4] AXI 协议检查器（挂在 CPU 侧 AXI 主口）");
        $display("      违规数 : %0d", err_axi_cpu);
        chk(err_axi_cpu, 32'h0, "AXI 协议零违规");

        // ----------------------------------------------------
        $display("");
        $display("============================================");
        if (errors == 0)
            $display("===== PASS: %0d 项检查全部通过，UART 回显闭环正常 =====", checks);
        else
            $display("===== FAIL: %0d 项检查中 %0d 项失败 =====", checks, errors);
        $display("============================================");
        $finish;
    end

    initial begin
        #3_000_000;    // 3ms 仿真时间上限（10M 波特下，几十个字节绰绰有余）
        $display("!!!! TIMEOUT：仿真超时");
        $finish;
    end

endmodule
