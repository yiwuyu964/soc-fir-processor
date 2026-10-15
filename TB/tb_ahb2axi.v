// ============================================================
// tb_ahb2axi.v —— AHB→AXI 桥 单元验证（阶段2 分工 B）
//
// 测试台两样东西：
//   1) AHB-Lite 主设备 BFM —— 扮演 Cortex-M0（窄写复制数据到所有 lane）
//   2) AXI4 从设备模型 —— 字节可寻址存储器 + 可注入 SLVERR
//
// 覆盖（对应阶段2-三人分工.md B 的验收清单）：
//   [1] 单拍字写 + 读回（AW/AR 地址、SIZE、BURST=INCR、AWID/ARID=0）
//   [2] 三种 HSIZE 写：字节/半字/字落到正确 byte lane（WSTRB + WDATA）
//   [3] 三种 HSIZE 读：从正确 lane 取数据（HRDATA）
//   [4] INCR 写突发（4 拍）：AWLEN=3、地址递增、WLAST 在最后一拍
//   [5] INCR 读突发（4 拍）：ARLEN=3、RLAST、逐拍读回一致
//   [6] 错误贯通：AXI SLVERR（写 BRESP / 读 RRESP）→ AHB HRESP=1
//   [7] 非对齐字节地址的 lane 行为
//   [8] 长时间随机读写，无死锁 + 协议零违规
//
// 运行（从仓库根目录）：
//   iverilog -g2012 -Wall -o sim.out RTL/ahb2axi.v TB/tb_ahb2axi.v
//   vvp sim.out
// ============================================================
`timescale 1ns/1ps

// ------------------------------------------------------------
// AXI4 从设备模型：字节可寻址存储器 + 可注入 SLVERR
// ------------------------------------------------------------
module axi_slave_model #(
    parameter ADDR_W = 32,
    parameter DATA_W = 32,
    parameter ID_W   = 4,
    parameter MEM_BYTES = 2048
)(
    input  wire                 clk,
    input  wire                 rst_n,
    // 写地址
    input  wire [ID_W-1:0]      awid,
    input  wire [ADDR_W-1:0]    awaddr,
    input  wire [7:0]           awlen,
    input  wire [2:0]           awsize,
    input  wire [1:0]           awburst,
    input  wire                 awvalid,
    output wire                 awready,
    // 写数据
    input  wire [DATA_W-1:0]    wdata,
    input  wire [DATA_W/8-1:0]  wstrb,
    input  wire                 wlast,
    input  wire                 wvalid,
    output wire                 wready,
    // 写响应
    output wire [ID_W-1:0]      bid,
    output wire [1:0]           bresp,
    output wire                 bvalid,
    input  wire                 bready,
    // 读地址
    input  wire [ID_W-1:0]      arid,
    input  wire [ADDR_W-1:0]    araddr,
    input  wire [7:0]           arlen,
    input  wire [2:0]           arsize,
    input  wire [1:0]           arburst,
    input  wire                 arvalid,
    output wire                 arready,
    // 读数据
    output wire [ID_W-1:0]      rid,
    output wire [DATA_W-1:0]    rdata,
    output wire [1:0]           rresp,
    output wire                 rlast,
    output wire                 rvalid,
    input  wire                 rready,
    // 错误注入：起始地址（字对齐）等于 err_addr 的事务返回 SLVERR
    input  wire [ADDR_W-1:0]    err_addr
);

    reg [7:0] mem [0:MEM_BYTES-1];

    // ---- 写侧 ----
    localparam WS_IDLE = 2'd0, WS_W = 2'd1, WS_B = 2'd2;
    reg [1:0]        ws_cur, ws_next;
    reg [ID_W-1:0]   w_id;
    reg [ADDR_W-1:0] w_addr;
    reg [7:0]        w_beat;
    reg [2:0]        w_size;
    reg              w_err;

    wire [ADDR_W-1:0] w_beat_addr = w_addr + ({{(ADDR_W-8){1'b0}}, w_beat} << w_size);
    wire [ADDR_W-1:0] w_word_base = w_beat_addr & ~(ADDR_W'(4'd3));

    wire aw_hs = awvalid && awready;
    wire w_hs  = wvalid  && wready;
    wire b_hs  = bvalid  && bready;

    assign awready = (ws_cur == WS_IDLE);
    assign wready  = (ws_cur == WS_W);
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
            w_id <= 0; w_addr <= 0; w_beat <= 0; w_size <= 0; w_err <= 0;
            for (i = 0; i < MEM_BYTES; i = i + 1) mem[i] <= 8'h00;
        end
        else begin
            ws_cur <= ws_next;
            case (ws_cur)
                WS_IDLE: begin
                    if (aw_hs) begin
                        w_id   <= awid;
                        w_addr <= awaddr;
                        w_size <= awsize;
                        w_err  <= (awaddr == err_addr);
                        w_beat <= 8'd0;
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
    reg [ADDR_W-1:0] r_addr;
    reg [7:0]        r_beat, r_len;
    reg [2:0]        r_size;
    reg              r_err;

    wire [ADDR_W-1:0] r_beat_addr = r_addr + ({{(ADDR_W-8){1'b0}}, r_beat} << r_size);
    wire [ADDR_W-1:0] r_word_base = r_beat_addr & ~(ADDR_W'(4'd3));

    wire ar_hs = arvalid && arready;
    wire r_hs  = rvalid  && rready;

    assign arready = (rs_cur == RS_IDLE);
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
            r_id <= 0; r_addr <= 0; r_beat <= 0; r_len <= 0; r_size <= 0; r_err <= 0;
        end
        else begin
            rs_cur <= rs_next;
            case (rs_cur)
                RS_IDLE: begin
                    if (ar_hs) begin
                        r_id   <= arid;
                        r_addr <= araddr;
                        r_size <= arsize;
                        r_len  <= arlen;
                        r_err  <= (araddr == err_addr);
                        r_beat <= 8'd0;
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


// ------------------------------------------------------------
// 顶层测试台
// ------------------------------------------------------------
module tb_ahb2axi;

    localparam ADDR_W = 32;
    localparam DATA_W = 32;
    localparam ID_W   = 4;

    reg clk   = 0;
    reg rst_n = 0;

    // ---- AHB 主设备侧 ----
    reg                HSEL;
    reg [ADDR_W-1:0]   HADDR;
    reg [1:0]          HTRANS;
    reg                HWRITE;
    reg [2:0]          HSIZE;
    reg [2:0]          HBURST;
    reg [3:0]          HPROT;
    reg [DATA_W-1:0]   HWDATA;
    wire [DATA_W-1:0]  HRDATA;
    wire               HREADY;
    wire               HRESP;

    // ---- AXI 从设备侧 ----
    wire [ID_W-1:0]    m_awid;
    wire [ADDR_W-1:0]  m_awaddr;
    wire [7:0]         m_awlen;
    wire [2:0]         m_awsize;
    wire [1:0]         m_awburst;
    wire               m_awvalid;
    wire               m_awready;
    wire [DATA_W-1:0]  m_wdata;
    wire [3:0]         m_wstrb;
    wire               m_wlast;
    wire               m_wvalid;
    wire               m_wready;
    wire [ID_W-1:0]    m_bid;
    wire [1:0]         m_bresp;
    wire               m_bvalid;
    wire               m_bready;
    wire [ID_W-1:0]    m_arid;
    wire [ADDR_W-1:0]  m_araddr;
    wire [7:0]         m_arlen;
    wire [2:0]         m_arsize;
    wire [1:0]         m_arburst;
    wire               m_arvalid;
    wire               m_arready;
    wire [ID_W-1:0]    m_rid;
    wire [DATA_W-1:0]  m_rdata;
    wire [1:0]         m_rresp;
    wire               m_rlast;
    wire               m_rvalid;
    wire               m_rready;

    reg [ADDR_W-1:0]   err_addr;

    ahb2axi #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)) dut (
        .clk(clk), .rst_n(rst_n),
        .HSEL(HSEL), .HADDR(HADDR), .HTRANS(HTRANS), .HWRITE(HWRITE),
        .HSIZE(HSIZE), .HBURST(HBURST), .HPROT(HPROT), .HWDATA(HWDATA),
        .HRDATA(HRDATA), .HREADY(HREADY), .HRESP(HRESP),
        .m_axi_awid(m_awid), .m_axi_awaddr(m_awaddr), .m_axi_awlen(m_awlen),
        .m_axi_awsize(m_awsize), .m_axi_awburst(m_awburst),
        .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
        .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wlast(m_wlast),
        .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
        .m_axi_bid(m_bid), .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid),
        .m_axi_bready(m_bready),
        .m_axi_arid(m_arid), .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen),
        .m_axi_arsize(m_arsize), .m_axi_arburst(m_arburst),
        .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
        .m_axi_rid(m_rid), .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp),
        .m_axi_rlast(m_rlast), .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready)
    );

    axi_slave_model #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)) u_slave (
        .clk(clk), .rst_n(rst_n),
        .awid(m_awid), .awaddr(m_awaddr), .awlen(m_awlen), .awsize(m_awsize),
        .awburst(m_awburst), .awvalid(m_awvalid), .awready(m_awready),
        .wdata(m_wdata), .wstrb(m_wstrb), .wlast(m_wlast), .wvalid(m_wvalid), .wready(m_wready),
        .bid(m_bid), .bresp(m_bresp), .bvalid(m_bvalid), .bready(m_bready),
        .arid(m_arid), .araddr(m_araddr), .arlen(m_arlen), .arsize(m_arsize),
        .arburst(m_arburst), .arvalid(m_arvalid), .arready(m_arready),
        .rid(m_rid), .rdata(m_rdata), .rresp(m_rresp), .rlast(m_rlast),
        .rvalid(m_rvalid), .rready(m_rready),
        .err_addr(err_addr)
    );

    always #5 clk = ~clk;   // 100 MHz

    // ============================================================
    // 统计与检查
    // ============================================================
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
    // AHB 主设备 BFM（地址+数据同拍给出，HREADY=0 期间保持）
    // ============================================================
    reg [DATA_W-1:0] wmem [0:511];
    reg [DATA_W-1:0] rmem [0:511];
    reg              rresp_mem [0:511];

    task ahb_write;
        input [31:0] addr;
        input [2:0]  size;
        input [2:0]  burst;
        input [7:0]  nbeats;
        input [8:0]  base;
        integer i;
        begin
            for (i = 0; i < nbeats; i = i + 1) begin
                @(negedge clk);
                HADDR  = addr + i * (1 << size);
                HTRANS = (i == 0) ? 2'b10 : 2'b11;
                HWRITE = 1'b1;
                HSIZE  = size;
                HBURST = burst;
                HWDATA = wmem[base + i];
                @(posedge clk);                 // 地址期（桥在此拍采样地址，HREADY 尚为 1）
                @(posedge clk);                 // 桥已拉低 HREADY
                while (!HREADY) @(posedge clk); // 数据期完成
            end
            @(negedge clk);
            HTRANS = 2'b00; HWDATA = 32'h0;
        end
    endtask

    task ahb_read;
        input [31:0] addr;
        input [2:0]  size;
        input [2:0]  burst;
        input [7:0]  nbeats;
        input [8:0]  base;
        integer i;
        begin
            for (i = 0; i < nbeats; i = i + 1) begin
                @(negedge clk);
                HADDR  = addr + i * (1 << size);
                HTRANS = (i == 0) ? 2'b10 : 2'b11;
                HWRITE = 1'b0;
                HSIZE  = size;
                HBURST = burst;
                @(posedge clk);                 // 地址期
                @(posedge clk);                 // 桥已拉低 HREADY
                while (!HREADY) @(posedge clk); // 数据期完成
                rmem[base + i]      = HRDATA;
                rresp_mem[base + i] = HRESP;
            end
            @(negedge clk);
            HTRANS = 2'b00;
        end
    endtask

    // ============================================================
    // 协议监视（AXI 主口侧）
    // ============================================================
    reg awvalid_d, wvalid_d, arvalid_d;
    reg aw_hs_d, w_hs_d, ar_hs_d;

    always @(posedge clk) begin
        if (rst_n) begin
            if (awvalid_d && !m_awvalid && !aw_hs_d) begin
                errors = errors + 1;
                $display("  [AXI-ERR] t=%0t AWVALID 在无握手时撤销", $time);
            end
            if (wvalid_d && !m_wvalid && !w_hs_d) begin
                errors = errors + 1;
                $display("  [AXI-ERR] t=%0t WVALID 在无握手时撤销", $time);
            end
            if (arvalid_d && !m_arvalid && !ar_hs_d) begin
                errors = errors + 1;
                $display("  [AXI-ERR] t=%0t ARVALID 在无握手时撤销", $time);
            end
            if (m_awvalid && (m_awid !== {ID_W{1'b0}})) begin
                errors = errors + 1;
                $display("  [AXI-ERR] t=%0t AWID 非 0", $time);
            end
            if (m_arvalid && (m_arid !== {ID_W{1'b0}})) begin
                errors = errors + 1;
                $display("  [AXI-ERR] t=%0t ARID 非 0", $time);
            end
            if (^{m_awaddr, m_awlen, m_awsize, m_awburst, m_awvalid,
                  m_wdata, m_wstrb, m_wlast, m_wvalid,
                  m_bready, m_araddr, m_arlen, m_arsize, m_arburst, m_arvalid,
                  m_rready, HRDATA, HREADY, HRESP} === 1'bx) begin
                errors = errors + 1;
                $display("  [AXI-ERR] t=%0t 输出出现未知态 X", $time);
            end
            awvalid_d <= m_awvalid;
            wvalid_d  <= m_wvalid;
            arvalid_d <= m_arvalid;
            aw_hs_d <= m_awvalid && m_awready;
            w_hs_d  <= m_wvalid  && m_wready;
            ar_hs_d <= m_arvalid && m_arready;
        end
        else begin
            awvalid_d <= 1'b0; wvalid_d <= 1'b0; arvalid_d <= 1'b0;
            aw_hs_d <= 1'b0; w_hs_d <= 1'b0; ar_hs_d <= 1'b0;
        end
    end

    // ============================================================
    // 测试序列
    // ============================================================
    integer i;

    initial begin
        $dumpfile("tb_ahb2axi.vcd");
        $dumpvars(2, tb_ahb2axi);

        HSEL = 1'b1; HADDR = 0; HTRANS = 2'b00; HWRITE = 0; HSIZE = 3'd2;
        HBURST = 3'b000; HPROT = 4'b0000; HWDATA = 0;
        err_addr = 32'hFFFF_FFFF;   // 默认不注入错误
        for (i = 0; i < 512; i = i + 1) begin wmem[i] = 0; rmem[i] = 0; rresp_mem[i] = 0; end

        rst_n = 0;
        repeat (5) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (3) @(posedge clk);

        $display("");
        $display("========== AHB -> AXI 桥 单元测试 ==========");

        // [1] 单拍字写 + 读回
        $display("[1] 单拍字写 + 读回");
        wmem[0] = 32'hDEAD_BEEF;
        ahb_write(32'h0000_0010, 3'd2, 3'b000, 8'd1, 9'd0);
        chk({31'd0, HRESP}, 32'h0, "字写 HRESP=OKAY");
        ahb_read(32'h0000_0010, 3'd2, 3'b000, 8'd1, 9'd0);
        chk(rmem[0], 32'hDEAD_BEEF, "字读回");

        // [2] 三种 HSIZE 写 lane
        $display("[2] 字节/半字写 lane");
        wmem[0] = 32'hABAB_ABAB;   // 字节 0xAB 复制到所有 lane
        ahb_write(32'h0000_0021, 3'd0, 3'b000, 8'd1, 9'd0);
        chk({31'd0, HRESP}, 32'h0, "字节写 HRESP=OKAY");
        wmem[0] = 32'hCDEF_CDEF;
        ahb_write(32'h0000_0022, 3'd1, 3'b000, 8'd1, 9'd0);
        chk({31'd0, HRESP}, 32'h0, "半字写 HRESP=OKAY");
        wmem[0] = 32'h1122_3344;
        ahb_write(32'h0000_0024, 3'd2, 3'b000, 8'd1, 9'd0);

        // [3] 三种 HSIZE 读 lane
        $display("[3] 字节/半字读 lane");
        ahb_read(32'h0000_0021, 3'd0, 3'b000, 8'd1, 9'd0);
        chk(rmem[0][15:8], 8'hAB, "字节读 0x21 → lane1=AB");
        ahb_read(32'h0000_0022, 3'd1, 3'b000, 8'd1, 9'd0);
        chk(rmem[0][31:16], 16'hCDEF, "半字读 0x22 → lane[3:2]=CDEF");
        ahb_read(32'h0000_0024, 3'd2, 3'b000, 8'd1, 9'd0);
        chk(rmem[0], 32'h1122_3344, "字读 0x24");

        // [4] INCR 写突发（4 拍）
        $display("[4] INCR 写突发（4 拍）");
        for (i = 0; i < 4; i = i + 1) wmem[i] = 32'hA0 + i;
        ahb_write(32'h0000_0030, 3'd2, 3'b011, 8'd4, 9'd0);   // INCR4
        chk({31'd0, HRESP}, 32'h0, "INCR 写 HRESP=OKAY");
        ahb_read(32'h0000_0030, 3'd2, 3'b011, 8'd4, 9'd0);    // INCR4
        for (i = 0; i < 4; i = i + 1) chk(rmem[i], 32'hA0 + i, "INCR 写后逐拍读回");

        // [5] 连续单拍读 + HRESP 检查
        $display("[5] 连续单拍读 + HRESP 检查");
        ahb_read(32'h0000_0010, 3'd2, 3'b000, 8'd1, 9'd0);
        chk({31'd0, rresp_mem[0]}, 32'h0, "读 HRESP=OKAY");
        chk(rmem[0], 32'hDEAD_BEEF, "连续读 0x10");

        // [6] 错误贯通
        $display("[6] 错误贯通");
        err_addr = 32'h0000_0050;
        wmem[0] = 32'h1234_5678;
        ahb_write(32'h0000_0050, 3'd2, 3'b000, 8'd1, 9'd0);
        chk({31'd0, HRESP}, 32'h1, "写 SLVERR → HRESP=ERROR");
        ahb_read(32'h0000_0050, 3'd2, 3'b000, 8'd1, 9'd0);
        chk({31'd0, HRESP}, 32'h1, "读 SLVERR → HRESP=ERROR");
        err_addr = 32'hFFFF_FFFF;   // 恢复

        // [7] 非对齐字节地址
        $display("[7] 非对齐字节地址");
        wmem[0] = 32'h5A5A_5A5A;
        ahb_write(32'h0000_0063, 3'd0, 3'b000, 8'd1, 9'd0);   // lane 3
        ahb_read(32'h0000_0063, 3'd0, 3'b000, 8'd1, 9'd0);
        chk(rmem[0][31:24], 8'h5A, "字节读 0x63 → lane3=5A");

        // [8] 长时间随机读写
        $display("[8] 随机读写 200 笔");
        begin
            integer n, dir, sz, off;
            for (n = 0; n < 200; n = n + 1) begin
                dir = (n % 3 == 0) ? 1'b1 : 1'b0;
                sz  = (n % 3);
                off = (n * 7) & 32'h7FC;
                if (dir) begin
                    wmem[0] = {8{n[7:0]}};
                    ahb_write(32'h0000 + off, sz[2:0], 3'b000, 8'd1, 9'd0);
                end
                else begin
                    ahb_read(32'h0000 + off, sz[2:0], 3'b000, 8'd1, 9'd0);
                end
            end
        end

        // ----------------------------------------------------
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

    // 超时保护
    initial begin
        #2000000;
        $display("!!!! TIMEOUT：仿真超时，测试未正常结束");
        $finish;
    end

endmodule
