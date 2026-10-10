// ============================================================
// tb_uart_echo.v —— UART 回显的集成验证
//
// 这是赛题"CPU 正常跑通（UART 回显）"那条计分项的验证。
//
// 被测链路（和真实 SoC 里一模一样）：
//
//   AXI 主设备 ──AXI4──▶ axi_to_apb ──APB──▶ uart_apb ──串口──▶ 环回
//    （测试台                                （发送+接收）      │
//      扮演 CPU）                                              │
//                        ◀────────── rxd ◀────────────────────┘
//
// 也就是说：这一条测试同时验证了三样东西
//   1) AXI→APB 桥（批次①的模块，在真实系统里跑）
//   2) APB UART 的寄存器读写
//   3) 串口收发 + 回显闭环
//
// 波特率特意调快（5 MHz，对应每比特 20 个时钟），让仿真几微秒就跑完。
// ============================================================
`timescale 1ns/1ps

module tb_uart_echo;

    localparam CLK_FREQ = 100_000_000;
    localparam BAUD     =   5_000_000;          // 仿真加速用，实际 115200
    localparam BIT_CNT  = CLK_FREQ / BAUD;      // = 20

    // UART 寄存器地址
    localparam ADDR_DATA   = 32'h000;
    localparam ADDR_STATUS = 32'h004;
    localparam ADDR_RXDATA = 32'h008;

    reg clk   = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;                        // 100 MHz

    // ============================================================
    // AXI 主设备侧信号
    // ============================================================
    reg  [31:0] m_awaddr;  reg [7:0] m_awlen;  reg [2:0] m_awsize;  reg [1:0] m_awburst;  reg m_awvalid;
    wire        awready;
    reg  [31:0] m_wdata;   reg       m_wlast;  reg       m_wvalid;
    wire        wready;
    wire [1:0]  bresp;     wire      bvalid;   reg       m_bready;
    reg  [31:0] m_araddr;  reg [7:0] m_arlen;  reg [2:0] m_arsize;  reg [1:0] m_arburst;  reg m_arvalid;
    wire        arready;
    wire [31:0] rdata;     wire [1:0] rresp;   wire      rlast;     wire      rvalid;     reg m_rready;

    // APB 中间信号
    wire        psel, penable, pwrite;
    wire [31:0] paddr, pwdata, prdata;
    wire [3:0]  pstrb;
    wire [2:0]  pprot;
    wire        pready, pslverr;

    // 串口
    wire        uart_txd;
    reg         ext_txd = 1'b1;      // 测试台模拟 PC 发的串行数据
    reg         ext_en  = 1'b1;      // 1=外部驱动 rxd，0=环回（txd 接回 rxd）
    wire        uart_rxd = ext_en ? ext_txd : uart_txd;

    // ============================================================
    // 两个被测模块
    // ============================================================
    axi_to_apb #(.ADDR_W(32), .DATA_W(32), .TIMEOUT(0)) u_bridge (
        .clk(clk), .rst_n(rst_n),
        .awvalid(m_awvalid), .awready(awready), .awaddr(m_awaddr),
        .awlen(m_awlen), .awsize(m_awsize), .awburst(m_awburst),
        .wvalid(m_wvalid), .wready(wready), .wdata(m_wdata), .wlast(m_wlast),
        .bresp(bresp), .bvalid(bvalid), .bready(m_bready),
        .arvalid(m_arvalid), .arready(arready), .araddr(m_araddr),
        .arlen(m_arlen), .arsize(m_arsize), .arburst(m_arburst),
        .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(m_rready),
        .psel(psel), .penable(penable), .paddr(paddr), .pwrite(pwrite),
        .pwdata(pwdata), .pstrb(pstrb), .pprot(pprot),
        .prdata(prdata), .pready(pready), .pslverr(pslverr)
    );

    uart_apb #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD), .FIFO_DEPTH(16)) u_uart (
        .clk(clk), .rst_n(rst_n),
        .psel(psel), .penable(penable), .pwrite(pwrite),
        .paddr(paddr), .pwdata(pwdata), .pstrb(pstrb), .pprot(pprot),
        .prdata(prdata), .pready(pready), .pslverr(pslverr),
        .rxd(uart_rxd), .txd(uart_txd)
    );

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
                $display("  [FAIL] %0s : got=0x%08X 期望=0x%08X", name, got, exp);
            end
        end
    endtask

    // ============================================================
    // AXI 主设备 BFM（单拍读写，够访问 UART 寄存器了）
    // ============================================================
    task axi_write32;
        input  [31:0] a;
        input  [31:0] d;
        output [1:0]  resp;
        begin
            @(negedge clk);
            m_awaddr = a; m_awlen = 0; m_awsize = 3'd2; m_awburst = 2'b01; m_awvalid = 1'b1;
            m_wdata  = d; m_wlast = 1'b1; m_wvalid = 1'b1;
            m_bready = 1'b1;

            // 注意：axi_to_apb 的设计是"地址在空闲态收、数据在取数态收"，
            // 所以 awready 和 wready 不会同时为高，必须分两步等。
            @(posedge clk);
            while (!awready) @(posedge clk);
            @(negedge clk) m_awvalid = 1'b0;

            @(posedge clk);
            while (!wready) @(posedge clk);
            @(negedge clk) m_wvalid = 1'b0;

            @(posedge clk);
            while (!bvalid) @(posedge clk);
            resp = bresp;
            @(negedge clk) m_bready = 1'b0;
        end
    endtask

    task axi_read32;
        input  [31:0] a;
        output [31:0] d;
        output [1:0]  resp;
        begin
            @(negedge clk);
            m_araddr = a; m_arlen = 0; m_arsize = 3'd2; m_arburst = 2'b01; m_arvalid = 1'b1;
            m_rready = 1'b1;

            @(posedge clk);
            while (!arready) @(posedge clk);
            @(negedge clk) m_arvalid = 1'b0;

            @(posedge clk);
            while (!rvalid) @(posedge clk);
            d = rdata; resp = rresp;
            @(negedge clk) m_rready = 1'b0;
        end
    endtask

    // ============================================================
    // 串口模型
    // ============================================================
    // 发送一个字节到 rxd 线上（模拟 PC 发数据给 FPGA）
    task ser_send;
        input [7:0] b;
        input       good_stop;       // 0 = 故意把停止位拉低，测帧错误
        integer i;
        begin
            ext_txd = 1'b0;                       // 起始位
            repeat (BIT_CNT) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                ext_txd = b[i];                   // 先发最低位
                repeat (BIT_CNT) @(posedge clk);
            end
            ext_txd = good_stop;                  // 停止位
            repeat (BIT_CNT) @(posedge clk);
            ext_txd = 1'b1;
        end
    endtask

    // 从 txd 线上收一个字节（模拟 PC 收 FPGA 发出来的数据）
    task ser_recv;
        output [7:0] b;
        integer i;
        begin
            @(negedge uart_txd);                                  // 等起始位
            repeat (BIT_CNT + BIT_CNT/2) @(posedge clk);          // 走到 bit0 中点
            for (i = 0; i < 8; i = i + 1) begin
                b[i] = uart_txd;
                repeat (BIT_CNT) @(posedge clk);
            end
        end
    endtask

    // ============================================================
    // 测试序列
    // ============================================================
    reg [31:0] rd;
    reg [1:0]  rs;
    reg [7:0]  rb;

    integer k;
    reg [7:0] echo_set [0:3];

    initial begin
        $dumpfile("tb_uart_echo.vcd");
        $dumpvars(0, tb_uart_echo);

        m_awvalid = 0; m_wvalid = 0; m_arvalid = 0; m_bready = 0; m_rready = 0;
        m_awaddr = 0; m_awlen = 0; m_awsize = 2; m_awburst = 1; m_wdata = 0; m_wlast = 0;
        m_araddr = 0; m_arlen = 0; m_arsize = 2; m_arburst = 1;

        rst_n = 0;
        repeat (5) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (5) @(posedge clk);

        $display("");
        $display("========== UART 回显 集成测试（AXI→APB→UART）==========");

        // ----------------------------------------------------
        $display("[1] 发送：AXI 写 DATA -> 在 txd 线上收下来核对");
        ext_en  = 1'b1;                 // 断开环回，只观察 txd
        ext_txd = 1'b1;
        fork
            axi_write32(ADDR_DATA, 32'h0000_0055, rs);      // 写 'U'
            begin
                ser_recv(rb);                                // 同时在线上收
                chk({24'd0, rb}, 32'h55, "TX 线上收到的字节");
            end
        join
        chk({30'd0, rs}, 32'h0, "写 DATA 应返回 OKAY");
        repeat (BIT_CNT) @(posedge clk);

        // ----------------------------------------------------
        $display("[2] 接收：外部驱动 rxd -> AXI 读 RXDATA");
        fork
            ser_send(8'hA3, 1'b1);
            begin
                // 轮询 STATUS.rx_valid
                rd = 32'd0;
                for (k = 0; k < 200 && rd[1] == 1'b0; k = k + 1)
                    axi_read32(ADDR_STATUS, rd, rs);
                chk(rd[1], 1'b1, "STATUS.rx_valid 应变为 1");
            end
        join
        axi_read32(ADDR_RXDATA, rd, rs);
        chk(rd[7:0], 32'hA3, "读到的接收字节");
        axi_read32(ADDR_STATUS, rd, rs);
        chk(rd[1], 1'b0, "读走之后 rx_valid 应回到 0");

        // ----------------------------------------------------
        $display("[3] 回显：环回，写什么就应该收回来什么");
        ext_en = 1'b0;                  // txd 接回 rxd
        fork
            axi_write32(ADDR_DATA, 32'h0000_003C, rs);      // 写 '<'
            begin
                ser_recv(rb);
                chk({24'd0, rb}, 32'h3C, "环回收到的字节");
            end
        join
        // 等接收 FIFO 里有数据，再读出来核对
        rd = 32'd0;
        for (k = 0; k < 200 && rd[1] == 1'b0; k = k + 1)
            axi_read32(ADDR_STATUS, rd, rs);
        axi_read32(ADDR_RXDATA, rd, rs);
        chk(rd[7:0], 32'h3C, "环回后从 RXDATA 读到的字节");

        // ----------------------------------------------------
        $display("[4] 连续回显 4 个字节");
        echo_set[0] = 8'h48;   // 'H'
        echo_set[1] = 8'h65;   // 'e'
        echo_set[2] = 8'h6C;   // 'l'
        echo_set[3] = 8'h6C;   // 'l'
        for (k = 0; k < 4; k = k + 1) begin
            // 等发送器空闲
            rd = 32'hFFFF_FFFF;
            while (rd[0] != 1'b0) axi_read32(ADDR_STATUS, rd, rs);
            axi_write32(ADDR_DATA, {24'd0, echo_set[k]}, rs);
            chk({30'd0, rs}, 32'h0, "发送应返回 OKAY");
        end
        // 依次读回 4 个字节
        for (k = 0; k < 4; k = k + 1) begin
            rd = 32'd0;
            for (integer t = 0; t < 300 && rd[1] == 1'b0; t = t + 1)
                axi_read32(ADDR_STATUS, rd, rs);
            chk(rd[1], 1'b1, "应有可读的接收数据");
            axi_read32(ADDR_RXDATA, rd, rs);
            chk(rd[7:0], {24'd0, echo_set[k]}, "连续回显第 k 个字节");
        end

        // ----------------------------------------------------
        $display("[5] 发送器忙的时候写 DATA -> 应返回 SLVERR");
        ext_en = 1'b1; ext_txd = 1'b1;    // 断开环回
        axi_write32(ADDR_DATA, 32'h0000_0011, rs);       // 第 1 个：开始发送
        chk({30'd0, rs}, 32'h0, "空闲时写 DATA 应成功");
        // 立刻再写一次（此时一定还在发）
        axi_write32(ADDR_DATA, 32'h0000_0022, rs);
        chk({30'd0, rs}, 32'h2, "忙时写 DATA 应返回 SLVERR");
        repeat (BIT_CNT * 12) @(posedge clk);

        // ----------------------------------------------------
        $display("[6] 帧错误：停止位被拉低 -> STATUS[3] 应为 1");
        fork
            ser_send(8'h5A, 1'b0);        // 故意坏的停止位
            begin
                rd = 32'd0;
                for (k = 0; k < 300 && rd[3] == 1'b0; k = k + 1)
                    axi_read32(ADDR_STATUS, rd, rs);
                chk(rd[3], 1'b1, "STATUS.rx_frame_err 应为 1");
            end
        join
        // 清掉错误标志，再确认会归零
        axi_read32(ADDR_STATUS, rd, rs);
        chk(rd[3], 1'b0, "读过 STATUS 后帧错误标志应清掉");

        // ----------------------------------------------------
        repeat (20) @(posedge clk);
        $display("");
        $display("============================================");
        if (errors == 0)
            $display("===== PASS: %0d 项检查全部通过，UART 回显闭环正常 =====", checks);
        else
            $display("===== FAIL: %0d 项检查中 %0d 项失败 =====", checks, errors);
        $display("============================================");
        $finish;
    end

    // 兜底超时
    initial begin
        #600000;
        $display("!!!! TIMEOUT：仿真超时");
        $finish;
    end

endmodule
