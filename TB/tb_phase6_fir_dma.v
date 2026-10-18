// ============================================================
// tb_phase6_fir_dma.v —— 阶段6：FIR × DMA 软硬件协同验证（含 CPU）
//
// 【验证对象】sw/main.c 里的 phase6_fir_dma()：
//   1. CPU 把 81 个系数写进 FIR（COEF[k] @ 0x4000_0100 + 4k）
//   2. CPU 发 flush（FIR_CTRL=1）
//   3. DMA ch0：内存样本(336) → FIR_DIN（目的地址固定）
//   4. DMA ch1：FIR_DOUT → 结果区(337)（源地址固定，每读一次弹出）
//   5. 固件把 results[1..336] 与黄金模型 exp[0..335] 逐位比对
//
// 【判定依据】固件写进 SRAM 信箱的结果（TB 直接读内存，不依赖串口）：
//   MB[0]  魔数 'SOC!' 0x534F4321
//   MB[6]  冒烟完成标志 0x1000
//   MB[7]  bit0=DMA0 完成 bit1=DMA1 完成 bit2=逐位比对全对 [31:16]=错拍数
//   MB[8]  第一个有效结果 results[1]（应与 exp[0] 相同）
//   MB[9]  最后一个结果    results[336]（应与 exp[335] 相同）
//
// 【运行】sim\sim.cmd -Only phase6
// ============================================================
`timescale 1ns/1ps

module tb_phase6_fir_dma;
    localparam ADDR_W=32, DATA_W=32, ID_W=4, SRAM_BYTES=65536;
    localparam SW_DEPTH = SRAM_BYTES/4;
    localparam MB       = 32'h0000_0F00/4;   // 信箱字索引

    reg clk=0, rst_n=0, uart_rxd=1;
    wire uart_txd;
    always #5 clk = ~clk;

    soc_top #(.ADDR_W(ADDR_W),.DATA_W(DATA_W),.ID_W(ID_W),
              .SRAM_BYTES(SRAM_BYTES),.CLK_FREQ(100_000_000),.UART_DIV(10)) dut (
        .clk(clk), .rst_n(rst_n), .uart_txd(uart_txd), .uart_rxd(uart_rxd));

    integer errors = 0, i, waited;

    // 波形：sim.cmd 默认会删掉 .vcd，想看就加 -KeepVcd
    // 本台要跑约 8 万拍，全层次 dump 会到 200MB+；这里只 dump soc_top 顶层
    // （AHB/AXI 总线信号），体积小得多，看总线时序足够了。
    // 想看内部模块就把 1 改成 0。
    initial begin
        $dumpfile("tb_phase6_fir_dma.vcd");
        $dumpvars(1, dut);
    end

    task chk(input [31:0] got, input [31:0] want, input [255:0] name);
        begin
            if (got !== want) begin
                errors = errors + 1;
                $display("  [FAIL] %0s : got=0x%08X 期望=0x%08X", name, got, want);
            end else
                $display("  [ OK ] %0s : 0x%08X", name, got);
        end
    endtask

    initial begin
        // 判据完全来自固件写进信箱的结果（MB[7]/MB[8]/MB[9]），
        // 不在这里读 fir/exp.hex 做交叉核对：那份文件是本地生成产物
        // （不在版本控制里），可能过期，拿它比对会把"数据陈旧"误报成"RTL 错"。
        // 固件内部已经用 sw/fir_testvec.h 做了 336 拍逐位比对，那才是权威判据。
        for (i=0;i<SW_DEPTH;i=i+1) dut.u_sram.mem[i] = 32'h0;
        $readmemh("sw/firmware.hex", dut.u_sram.mem);

        rst_n = 0;
        repeat (20) @(posedge clk);
        @(negedge clk); rst_n = 1;

        // 先等阶段6 跑完（固件在阶段6 之后才写 MB[6]）
        waited = 0;
        while (dut.u_sram.mem[MB+6] !== 32'h0000_1000 && waited < 800000) begin
            @(posedge clk); waited = waited + 1;
        end
        $display("");
        $display("========== 阶段6 FIR×DMA 软硬件协同 ==========");
        $display("  等到冒烟+阶段6 完成，用了 %0d 拍", waited);
        $display("");

        chk(dut.u_sram.mem[MB+0], 32'h534F_4321, "信箱魔数 'SOC!'");
        chk(dut.u_sram.mem[MB+6], 32'h0000_1000, "阶段6+冒烟完成标志");
        chk(dut.u_sram.mem[MB+2], 32'h0000_0000, "冒烟失败计数");

        // MB[7]：两个 DMA 都完成 + 逐位比对全对 + 错拍数为 0
        $display("");
        $display("  MB[7] = 0x%08X  (bit0=DMA0 bit1=DMA1 bit2=比对全对 [31:16]=错拍数)",
                 dut.u_sram.mem[MB+7]);
        chk(dut.u_sram.mem[MB+7] & 32'h1, 32'h1, "DMA0：样本 -> FIR_DIN 完成");
        chk(dut.u_sram.mem[MB+7] & 32'h2, 32'h2, "DMA1：FIR_DOUT -> 结果区 完成");
        chk(dut.u_sram.mem[MB+7] & 32'h4, 32'h4, "results[1..336] 与黄金模型逐位一致");
        chk(dut.u_sram.mem[MB+7] >> 16, 32'h0, "错拍数 = 0");

        // 首/末结果作为诊断信息打印（权威判据是 MB[7] 的比对结论）
        $display("");
        $display("  诊断：results[1]=0x%08X  results[336]=0x%08X",
                 dut.u_sram.mem[MB+8], dut.u_sram.mem[MB+9]);

        $display("");
        $display("============================================");
        if (errors == 0) $display("===== PASS: 阶段6 FIR×DMA 端到端通过（误差 0%% < 0.1%%）=====");
        else             $display("===== FAIL: %0d 项失败 =====", errors);
        $display("============================================");
        $finish;
    end
endmodule
