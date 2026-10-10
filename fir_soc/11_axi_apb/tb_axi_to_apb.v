// ============================================================
// tb_axi_to_apb.v —— AXI→APB 桥的单元验证
//
// 这个测试台自己搭了两样东西：
//   1) AXI4 主设备 BFM   —— 扮演 Cortex-M0，发起读/写事务（含突发）
//   2) APB 从设备模型    —— 扮演 UART 那类外设，16 个寄存器，
//                           可以配置等待拍数和错误地址
//
// 除了功能比对，它还实时检查 APB 协议（IHI0024 第 3/4 章）：
//   · PENABLE 不能脱离 PSEL
//   · PENABLE 拉高前 PSEL 必须已经有效至少一拍（SETUP 阶段）
//   · PADDR/PWRITE/PWDATA 在 SETUP→ACCESS 之间必须保持稳定
// ============================================================
`timescale 1ns/1ps

// ------------------------------------------------------------
// APB 从设备模型：NREG 个 32bit 寄存器，支持等待状态和错误注入
// ------------------------------------------------------------
module apb_slave_model #(
    parameter ADDR_W = 32,
    parameter DATA_W = 32,
    parameter NREG   = 16
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire [3:0]           wait_sel,     // 运行时选择等待拍数
    input  wire [ADDR_W-1:0]    err_addr,     // 访问这个地址返回 PSLVERR
    input  wire                 dbg_on,       // 打开 APB 事务打印
    input  wire                 psel,
    input  wire                 penable,
    input  wire [ADDR_W-1:0]    paddr,
    input  wire                 pwrite,
    input  wire [DATA_W-1:0]    pwdata,
    input  wire [DATA_W/8-1:0]  pstrb,
    input  wire [2:0]           pprot,
    output reg  [DATA_W-1:0]    prdata,
    output reg                  pready,
    output reg                  pslverr
);
    reg [DATA_W-1:0] mem [0:NREG-1];
    reg [3:0]        wait_cnt;
    integer          i;

    wire [3:0] idx = paddr[5:2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pready   <= 1'b0;
            pslverr  <= 1'b0;
            prdata   <= {DATA_W{1'b0}};
            wait_cnt <= 4'd0;
            for (i = 0; i < NREG; i = i + 1) mem[i] <= {DATA_W{1'b0}};
        end else begin
            pready  <= 1'b0;
            pslverr <= 1'b0;

            if (psel && penable) begin
                if (wait_cnt < wait_sel) begin
                    wait_cnt <= wait_cnt + 4'd1;      // 故意拖几拍，测 PREADY 等待
                end else begin
                    wait_cnt <= 4'd0;
                    pready   <= 1'b1;
                    if (dbg_on)
                        $display("      [APB] t=%0t %s addr=0x%08X wdata=0x%08X strb=%b rdata=0x%08X",
                                 $time, pwrite ? "WR" : "RD", paddr, pwdata, pstrb, prdata);
                    if (paddr == err_addr) begin
                        pslverr <= 1'b1;              // 错误注入
                    end else if (pwrite) begin
                        if (pstrb[0]) mem[idx][ 7: 0] <= pwdata[ 7: 0];
                        if (pstrb[1]) mem[idx][15: 8] <= pwdata[15: 8];
                        if (pstrb[2]) mem[idx][23:16] <= pwdata[23:16];
                        if (pstrb[3]) mem[idx][31:24] <= pwdata[31:24];
                    end else begin
                        prdata <= mem[idx];
                    end
                end
            end else begin
                wait_cnt <= 4'd0;
            end
        end
    end
endmodule


// ------------------------------------------------------------
// 顶层测试台
// ------------------------------------------------------------
module tb_axi_to_apb;

    localparam ADDR_W = 32;
    localparam DATA_W = 32;

    reg clk   = 0;
    reg rst_n = 0;

    always #5 clk = ~clk;          // 100 MHz

    // ---- DUT 端口 ----
    reg  [ADDR_W-1:0] m_awaddr;  reg [7:0] m_awlen;  reg [2:0] m_awsize;  reg [1:0] m_awburst;  reg m_awvalid;
    wire              awready;
    reg  [DATA_W-1:0] m_wdata;   reg       m_wlast;  reg       m_wvalid;
    wire              wready;
    wire [1:0]        bresp;     wire      bvalid;   reg       m_bready;
    reg  [ADDR_W-1:0] m_araddr;  reg [7:0] m_arlen;  reg [2:0] m_arsize;  reg [1:0] m_arburst;  reg m_arvalid;
    wire              arready;
    wire [DATA_W-1:0] rdata;     wire [1:0] rresp_w;  wire      rlast;     wire      rvalid;     reg m_rready;

    wire              psel, penable, pwrite;
    wire [ADDR_W-1:0] paddr;
    wire [DATA_W-1:0] pwdata, prdata;
    wire [DATA_W/8-1:0] pstrb;
    wire [2:0]        pprot;
    wire              pready, pslverr;

    // 测试参数：必须在例化之前声明，否则会被当成隐式 1bit 线网（-Wall 会告警）
    reg [3:0]  wait_sel = 4'd0;              // APB 从设备插入的等待拍数
    reg [31:0] err_addr = 32'h0000_FF00;     // 访问这个地址返回 PSLVERR
    reg        dbg_on   = 1'b0;              // 逐拍时序打印开关

    axi_to_apb #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .TIMEOUT(0)) dut (
        .clk(clk), .rst_n(rst_n),
        .awvalid(m_awvalid), .awready(awready), .awaddr(m_awaddr),
        .awlen(m_awlen), .awsize(m_awsize), .awburst(m_awburst),
        .wvalid(m_wvalid), .wready(wready), .wdata(m_wdata), .wlast(m_wlast),
        .bresp(bresp), .bvalid(bvalid), .bready(m_bready),
        .arvalid(m_arvalid), .arready(arready), .araddr(m_araddr),
        .arlen(m_arlen), .arsize(m_arsize), .arburst(m_arburst),
        .rdata(rdata), .rresp(rresp_w), .rlast(rlast), .rvalid(rvalid), .rready(m_rready),
        .psel(psel), .penable(penable), .paddr(paddr), .pwrite(pwrite),
        .pwdata(pwdata), .pstrb(pstrb), .pprot(pprot),
        .prdata(prdata), .pready(pready), .pslverr(pslverr)
    );

    apb_slave_model #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .NREG(16)) u_apb (
        .clk(clk), .rst_n(rst_n),
        .wait_sel(wait_sel), .err_addr(err_addr), .dbg_on(dbg_on),
        .psel(psel), .penable(penable), .paddr(paddr), .pwrite(pwrite),
        .pwdata(pwdata), .pstrb(pstrb), .pprot(pprot),
        .prdata(prdata), .pready(pready), .pslverr(pslverr)
    );

    // R 通道监视：看清每一拍读数据是什么时候被取走的
    always @(posedge clk) begin
        if (rst_n && dbg_on && rvalid)
            $display("      [RCH] t=%0t rvalid=1 rready=%b rdata=0x%08X rlast=%b",
                     $time, m_rready, rdata, rlast);
    end

    // FSM 内部追踪
    always @(posedge clk) begin
        if (rst_n && dbg_on)
            $display("      [FSM] t=%0t st=%0d wr=%b beat=%0d len=%0d addr=0x%08X pready=%b psel=%b pen=%b wready=%b wvalid=%b wdata=0x%08X",
                     $time, dut.state, dut.is_write, dut.beat, dut.w_len, dut.cur_addr,
                     pready, psel, penable, wready, m_wvalid, m_wdata);
    end

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

    // ============================================================
    // APB 协议检查（IHI0024 第 3/4 章）
    // ============================================================
    reg        psel_d, penable_d, pwrite_d;
    reg [31:0] paddr_d, pwdata_d;
    reg [31:0] setup_addr, setup_wdata;
    reg        setup_pwrite;

    always @(posedge clk) begin
        if (rst_n) begin
            if (penable && !psel) begin
                $display("  [APB-ERR] PENABLE=1 时 PSEL=0"); errors = errors + 1;
            end
            if (penable && !penable_d && !psel_d) begin
                $display("  [APB-ERR] PENABLE 与 PSEL 同拍拉高（缺少 SETUP 阶段）"); errors = errors + 1;
            end
            if (psel && !penable) begin
                setup_addr   <= paddr;
                setup_pwrite <= pwrite;
                setup_wdata  <= pwdata;
            end
            if (psel && penable) begin
                if (paddr !== setup_addr) begin
                    $display("  [APB-ERR] PADDR 在 SETUP→ACCESS 之间变化"); errors = errors + 1;
                end
                if (pwrite !== setup_pwrite) begin
                    $display("  [APB-ERR] PWRITE 在 SETUP→ACCESS 之间变化"); errors = errors + 1;
                end
                if (pwrite && pwdata !== setup_wdata) begin
                    $display("  [APB-ERR] PWDATA 在 SETUP→ACCESS 之间变化"); errors = errors + 1;
                end
            end
            psel_d <= psel; penable_d <= penable; pwrite_d <= pwrite;
            paddr_d <= paddr; pwdata_d <= pwdata;
        end
    end

    // ============================================================
    // AXI4 主设备 BFM
    // ============================================================
    // 写事务（支持 1~4 拍突发）
    task axi_write;
        input [31:0] base;
        input [7:0]  len;
        input [2:0]  size;
        input [1:0]  burst;
        input [31:0] d0, d1, d2, d3;
        output [1:0] resp;
        integer i;
        reg [31:0] d;
        begin
            @(negedge clk);
            m_awaddr = base; m_awlen = len; m_awsize = size; m_awburst = burst;
            m_awvalid = 1'b1;
            m_bready  = 1'b1;

            @(posedge clk);
            while (!awready) @(posedge clk);
            @(negedge clk) m_awvalid = 1'b0;

            for (i = 0; i <= len; i = i + 1) begin
                case (i)
                    0: d = d0; 1: d = d1; 2: d = d2; default: d = d3;
                endcase
                @(negedge clk);
                m_wdata = d; m_wlast = (i == len); m_wvalid = 1'b1;
                @(posedge clk);
                while (!wready) @(posedge clk);
                @(negedge clk) m_wvalid = 1'b0;
            end

            @(posedge clk);
            while (!bvalid) @(posedge clk);
            resp = bresp;
            @(negedge clk) m_bready = 1'b0;
        end
    endtask

    // 读事务（支持 1~4 拍突发）
    task axi_read;
        input [31:0] base;
        input [7:0]  len;
        input [2:0]  size;
        input [1:0]  burst;
        output [31:0] q0, q1, q2, q3;
        output [1:0]  resp;
        integer i;
        reg [31:0] q;
        begin
            @(negedge clk);
            m_araddr = base; m_arlen = len; m_arsize = size; m_arburst = burst;
            m_arvalid = 1'b1;
            m_rready  = 1'b1;

            @(posedge clk);
            while (!arready) @(posedge clk);
            @(negedge clk) m_arvalid = 1'b0;

            for (i = 0; i <= len; i = i + 1) begin
                @(posedge clk);
                while (!rvalid) @(posedge clk);
                q = rdata;
                case (i)
                    0: q0 = q; 1: q1 = q; 2: q2 = q; default: q3 = q;
                endcase
                if (i == 0) resp = rresp_w;
                @(negedge clk);
            end
            @(negedge clk) m_rready = 1'b0;
        end
    endtask

    // ============================================================
    // 测试序列
    // ============================================================
    reg [31:0] q0, q1, q2, q3;
    reg [1:0]  resp;

    initial begin
        $dumpfile("tb_axi_to_apb.vcd");
        $dumpvars(0, tb_axi_to_apb);

        m_awvalid = 0; m_wvalid = 0; m_arvalid = 0; m_bready = 0; m_rready = 0;
        m_awaddr = 0; m_awlen = 0; m_awsize = 3'd2; m_awburst = 2'b01;
        m_wdata = 0; m_wlast = 0;
        m_araddr = 0; m_arlen = 0; m_arsize = 3'd2; m_arburst = 2'b01;

        rst_n = 0;
        repeat (5) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (3) @(posedge clk);

        $display("");
        $display("========== AXI -> APB 桥 单元测试 ==========");

        // ----------------------------------------------------
        $display("[1] 单拍写 + 读回");
        axi_write(32'h0000_0000, 8'd0, 3'd2, 2'b01, 32'hDEAD_BEEF, 0,0,0, resp);
        chk({30'd0, resp}, 32'h0, "写响应应为 OKAY");
        axi_read (32'h0000_0000, 8'd0, 3'd2, 2'b01, q0,q1,q2,q3, resp);
        chk(q0, 32'hDEAD_BEEF, "读回 寄存器0");

        // ----------------------------------------------------
        $display("[2] 连续单拍写 4 个寄存器 + 逐个读回");
        axi_write(32'h0000_0004, 8'd0, 3'd2, 2'b01, 32'h1111_1111, 0,0,0, resp);
        axi_write(32'h0000_0008, 8'd0, 3'd2, 2'b01, 32'h2222_2222, 0,0,0, resp);
        axi_write(32'h0000_000C, 8'd0, 3'd2, 2'b01, 32'h3333_3333, 0,0,0, resp);
        axi_read (32'h0000_0004, 8'd0, 3'd2, 2'b01, q0,q1,q2,q3, resp);
        chk(q0, 32'h1111_1111, "读回 寄存器1");
        axi_read (32'h0000_0008, 8'd0, 3'd2, 2'b01, q0,q1,q2,q3, resp);
        chk(q0, 32'h2222_2222, "读回 寄存器2");
        axi_read (32'h0000_000C, 8'd0, 3'd2, 2'b01, q0,q1,q2,q3, resp);
        chk(q0, 32'h3333_3333, "读回 寄存器3");

        // ----------------------------------------------------
        $display("[3] 字节写（窄传输，检查 PSTRB 生成）");
        // 注意：AXI 窄传输要把数据放在【地址对应的字节通道】上。
        // 0x14 是字节 0 → 数据在 WDATA[7:0]；0x15 是字节 1 → 数据在 WDATA[15:8]。
        axi_write(32'h0000_0014, 8'd0, 3'd0, 2'b01, 32'h0000_00AA, 0,0,0, resp);
        axi_write(32'h0000_0015, 8'd0, 3'd0, 2'b01, 32'h0000_BB00, 0,0,0, resp);
        axi_read (32'h0000_0014, 8'd0, 3'd2, 2'b01, q0,q1,q2,q3, resp);
        chk(q0, 32'h0000_BBAA, "字节写后应为 0x0000BBAA");

        // ----------------------------------------------------
        $display("[4] 从设备插入 3 拍等待状态");
        wait_sel = 4'd3;
        axi_write(32'h0000_0020, 8'd0, 3'd2, 2'b01, 32'hCAFE_BABE, 0,0,0, resp);
        axi_read (32'h0000_0020, 8'd0, 3'd2, 2'b01, q0,q1,q2,q3, resp);
        chk(q0, 32'hCAFE_BABE, "带等待状态的读回");
        chk({30'd0, resp}, 32'h0, "带等待状态时响应仍应为 OKAY");
        wait_sel = 4'd0;

        // ----------------------------------------------------
        $display("[5] 访问错误地址 -> 应返回 SLVERR");
        axi_write(32'h0000_FF00, 8'd0, 3'd2, 2'b01, 32'h1234_5678, 0,0,0, resp);
        chk({30'd0, resp}, 32'h2, "写错误地址应返回 SLVERR");
        axi_read (32'h0000_FF00, 8'd0, 3'd2, 2'b01, q0,q1,q2,q3, resp);
        chk({30'd0, resp}, 32'h2, "读错误地址应返回 SLVERR");

        // ----------------------------------------------------
        $display("[6] INCR 突发写 4 拍 + 突发读 4 拍");
        // 调试开关：改成 1'b1 就会打印 APB 每次传输、R 通道每一拍、FSM 每个状态，
        // 定位时序问题时非常有用。默认关闭，保持输出干净。
        dbg_on = 1'b0;
        axi_write(32'h0000_0040, 8'd3, 3'd2, 2'b01,
                  32'hA0A0_A0A0, 32'hB1B1_B1B1, 32'hC2C2_C2C2, 32'hD3D3_D3D3, resp);
        chk({30'd0, resp}, 32'h0, "突发写响应应为 OKAY");
        axi_read (32'h0000_0040, 8'd3, 3'd2, 2'b01, q0,q1,q2,q3, resp);
        chk(q0, 32'hA0A0_A0A0, "突发读 第0拍");
        chk(q1, 32'hB1B1_B1B1, "突发读 第1拍");
        chk(q2, 32'hC2C2_C2C2, "突发读 第2拍");
        chk(q3, 32'hD3D3_D3D3, "突发读 第3拍");

        // ----------------------------------------------------
        dbg_on = 1'b0;
        $display("[7] FIXED 突发（地址不变，模拟 FIFO 端口）");
        axi_write(32'h0000_0060, 8'd2, 3'd2, 2'b00,
                  32'h0000_0001, 32'h0000_0002, 32'h0000_0003, 0, resp);
        chk({30'd0, resp}, 32'h0, "FIXED 突发写应成功");
        axi_read (32'h0000_0060, 8'd0, 3'd2, 2'b01, q0,q1,q2,q3, resp);
        chk(q0, 32'h0000_0003, "FIXED 突发后寄存器应保留最后一次写入值");

        // ----------------------------------------------------
        $display("[8] WRAP 突发 -> 本桥不支持，应返回 SLVERR");
        axi_write(32'h0000_0080, 8'd3, 3'd2, 2'b10,
                  32'h1, 32'h2, 32'h3, 32'h4, resp);
        chk({30'd0, resp}, 32'h2, "WRAP 突发写应返回 SLVERR");
        axi_read (32'h0000_0080, 8'd3, 3'd2, 2'b10, q0,q1,q2,q3, resp);
        chk({30'd0, resp}, 32'h2, "WRAP 突发读应返回 SLVERR");

        // ----------------------------------------------------
        repeat (10) @(posedge clk);
        $display("");
        $display("============================================");
        if (errors == 0)
            $display("===== PASS: %0d 项检查全部通过，APB 协议无违规 =====", checks);
        else
            $display("===== FAIL: %0d 项检查中 %0d 项失败 =====", checks, errors);
        $display("============================================");
        $finish;
    end

    // 超时保护：防止测试挂死
    initial begin
        #200000;
        $display("!!!! TIMEOUT：仿真超时，测试未正常结束");
        $finish;
    end

endmodule
