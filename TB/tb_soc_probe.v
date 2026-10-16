// 诊断台：查 UART 写通路到底断在哪一环
`timescale 1ns/1ps

module tb_soc_probe;
    localparam ADDR_W=32, DATA_W=32, ID_W=4, SRAM_BYTES=65536;
    localparam SW_DEPTH = SRAM_BYTES/4;
    localparam MB_WORD  = 32'h0000_0F00/4;

    reg clk=0, rst_n=0, uart_rxd=1;
    wire uart_txd;
    always #5 clk = ~clk;

    soc_top #(.ADDR_W(ADDR_W),.DATA_W(DATA_W),.ID_W(ID_W),
              .SRAM_BYTES(SRAM_BYTES),.CLK_FREQ(100_000_000),.UART_DIV(10)) dut (
        .clk(clk), .rst_n(rst_n), .uart_txd(uart_txd), .uart_rxd(uart_rxd));

    integer i;
    integer saw_start = 0;
    integer tx_edges = 0;
    reg tx_prev = 1;

    // 监控：CPU 侧 AXI 主口上有没有对 0x4000_2000 的写
    integer hit_uart_aw = 0;
    always @(posedge clk) if (rst_n) begin
        if (dut.u_ahb2axi.m_axi_awvalid && dut.u_ahb2axi.m_axi_awready) begin
            $display("    [AXI-W] addr=0x%08X", dut.u_ahb2axi.m_axi_awaddr);
            if (dut.u_ahb2axi.m_axi_awaddr == 32'h4000_2000) hit_uart_aw = hit_uart_aw + 1;
        end
        if (dut.u_ahb2axi.m_axi_arvalid && dut.u_ahb2axi.m_axi_arready)
            $display("    [AXI-R] addr=0x%08X", dut.u_ahb2axi.m_axi_araddr);
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if (uart_txd !== tx_prev) begin
                tx_edges = tx_edges + 1;
                $display("    [TXD] t=%0t  %b -> %b", $time, tx_prev, uart_txd);
                tx_prev = uart_txd;
            end
        end
    end

    initial begin
        rst_n = 0;
        for (i=0;i<SW_DEPTH;i=i+1) dut.u_sram.mem[i] = 32'h0;
        $readmemh("sw/probe.hex", dut.u_sram.mem);
        repeat (20) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (20) @(posedge clk);

        $display("---- 等 2000 拍，看 CPU 干了什么 ----");
        repeat (2000) @(posedge clk);

        $display("");
        $display("信箱魔数  (MB+0, 0xF00) = 0x%08X   (期望 534F4321)", dut.u_sram.mem[MB_WORD+0]);
        $display("状态      (MB+6, 0xF18) = 0x%08X   (期望 00001000)", dut.u_sram.mem[MB_WORD+6]);
        $display("回显计数  (MB+3, 0xF0C) = 0x%08X   (期望 00000001)", dut.u_sram.mem[MB_WORD+3]);
        $display("");
        $display("命中 UART 地址(0x4000_2000)的 AXI 写次数 = %0d", hit_uart_aw);
        $display("uart_txd 跳变次数 = %0d", tx_edges);
        $display("uart_txd 当前电平 = %b", uart_txd);
        if (dut.u_sram.mem[MB_WORD] !== 32'h534F4321 ||
            dut.u_sram.mem[MB_WORD+6] !== 32'h1000 ||
            dut.u_sram.mem[MB_WORD+3] !== 32'd1 ||
            hit_uart_aw != 1 || tx_edges != 10 || uart_txd !== 1'b1)
            $fatal(1, "FAIL: CPU-to-UART probe");
        $display("===== PASS: CPU-to-UART probe, 10 TX edges =====");
        $finish;
    end
endmodule
