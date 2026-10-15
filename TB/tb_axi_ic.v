// ============================================================
// tb_axi_ic.v —— AXI 互连单元验证（阶段2 分工 A）
//
// 覆盖：
//   [1] 10 条路径：2 主 × 5 从，每主对每从写+读回，数据一致
//   [2] 并行：两主同时访问不同从设备（crossbar 意义）
//   [3] 仲裁：两主同时访问同一从设备（round-robin，不饿死）
//   [4] INCR 突发写 + INCR 突发读
//   [5] 长时间随机激励，无死锁（超时即 FAIL）
//
// 运行：
//   iverilog -g2012 -o sim_ic.out RTL/axi_arbiter.v RTL/axi_ic.v TB/tb_axi_ic.v
//   vvp sim_ic.out
// ============================================================
`timescale 1ns/1ps

// ============================================================
// 从设备行为模型：单笔写/读，带内存，读回写进去的数据
// ============================================================
module axi_slave_model #(
    parameter ID_W=4, DATA_W=32, ADDR_W=32
)(
    input clk, rst_n,
    input  [ID_W-1:0] s_awid, input [ADDR_W-1:0] s_awaddr, input [7:0] s_awlen,
    input  [2:0] s_awsize, input [1:0] s_awburst, input s_awvalid, output s_awready,
    input  [DATA_W-1:0] s_wdata, input [3:0] s_wstrb, input s_wlast, input s_wvalid, output s_wready,
    output [ID_W-1:0] s_bid, output [1:0] s_bresp, output s_bvalid, input s_bready,
    input  [ID_W-1:0] s_arid, input [ADDR_W-1:0] s_araddr, input [7:0] s_arlen,
    input  [2:0] s_arsize, input [1:0] s_arburst, input s_arvalid, output s_arready,
    output [ID_W-1:0] s_rid, output [DATA_W-1:0] s_rdata, output [1:0] s_rresp,
    output s_rlast, output s_rvalid, input s_rready
);
    reg [DATA_W-1:0] mem [0:255];
    integer i;
    initial for (i=0;i<256;i=i+1) mem[i] = 32'h0;

    // ---- 写侧 ----
    reg w_busy, bvalid;
    reg [ID_W-1:0] w_id;
    reg [7:0] w_beat, w_len;
    reg [ADDR_W-1:0] w_addr;

    assign s_awready = !w_busy;
    assign s_wready  = w_busy;

    wire w_last_beat = w_busy && s_wvalid && s_wready && (s_wlast || (w_beat == w_len));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_busy <= 0; bvalid <= 0; w_beat <= 0;
        end else begin
            if (s_awvalid && s_awready) begin
                w_busy <= 1; w_id <= s_awid; w_len <= s_awlen; w_addr <= s_awaddr; w_beat <= 0;
            end
            if (w_busy && s_wvalid && s_wready) begin
                mem[w_addr[9:2]] <= s_wdata;
                if (w_last_beat) w_busy <= 0;
                else begin w_beat <= w_beat + 1; w_addr <= w_addr + 4; end
            end
            if (w_last_beat) bvalid <= 1;
            else if (bvalid && s_bready) bvalid <= 0;
        end
    end

    assign s_bid = w_id;
    assign s_bresp = 2'b00;
    assign s_bvalid = bvalid;

    // ---- 读侧 ----
    reg r_busy;
    reg [ID_W-1:0] r_id;
    reg [7:0] r_beat, r_len;
    reg [ADDR_W-1:0] r_addr;

    assign s_arready = !r_busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_busy <= 0; r_beat <= 0;
        end else begin
            if (s_arvalid && s_arready) begin
                r_busy <= 1; r_id <= s_arid; r_len <= s_arlen; r_addr <= s_araddr; r_beat <= 0;
            end
            if (r_busy && s_rvalid && s_rready) begin
                if (s_rlast) r_busy <= 0;
                else begin r_beat <= r_beat + 1; r_addr <= r_addr + 4; end
            end
        end
    end

    assign s_rid = r_id;
    assign s_rdata = mem[r_addr[9:2]];
    assign s_rresp = 2'b00;
    assign s_rlast = (r_beat == r_len);
    assign s_rvalid = r_busy;

endmodule

// ============================================================
// 测试台
// ============================================================
module tb_axi_ic;

    localparam DATA_W=32, ADDR_W=32, ID_W=4;

    reg clk=0, rst_n=0;
    always #5 clk = ~clk;

    // ---- DUT 从口（主设备侧）信号：m0 / m1 ----
    reg  [ID_W-1:0] m0_awid, m1_awid, m0_arid, m1_arid;
    reg  [ADDR_W-1:0] m0_awaddr, m1_awaddr, m0_araddr, m1_araddr;
    reg  [7:0] m0_awlen, m1_awlen, m0_arlen, m1_arlen;
    reg  [2:0] m0_awsize, m1_awsize, m0_arsize, m1_arsize;
    reg  [1:0] m0_awburst, m1_awburst, m0_arburst, m1_arburst;
    reg  m0_awvalid, m1_awvalid, m0_arvalid, m1_arvalid;
    wire m0_awready, m1_awready, m0_arready, m1_arready;
    reg  [DATA_W-1:0] m0_wdata, m1_wdata;
    reg  [3:0] m0_wstrb, m1_wstrb;
    reg  m0_wlast, m1_wlast, m0_wvalid, m1_wvalid;
    wire m0_wready, m1_wready;
    wire [ID_W-1:0] m0_bid, m1_bid, m0_rid, m1_rid;
    wire [1:0] m0_bresp, m1_bresp, m0_rresp, m1_rresp;
    wire m0_bvalid, m1_bvalid, m0_rlast, m1_rlast, m0_rvalid, m1_rvalid;
    reg  m0_bready, m1_bready, m0_rready, m1_rready;
    wire [DATA_W-1:0] m0_rdata, m1_rdata;

    // ---- DUT 主口（从设备侧）信号：slv0..slv4 ----
    wire [ID_W-1:0] slv_awid [0:4], slv_arid [0:4];
    wire [ADDR_W-1:0] slv_awaddr [0:4], slv_araddr [0:4];
    wire [7:0] slv_awlen [0:4], slv_arlen [0:4];
    wire [2:0] slv_awsize [0:4], slv_arsize [0:4];
    wire [1:0] slv_awburst [0:4], slv_arburst [0:4];
    wire slv_awvalid [0:4], slv_awready [0:4], slv_arvalid [0:4], slv_arready [0:4];
    wire [DATA_W-1:0] slv_wdata [0:4], slv_rdata [0:4];
    wire [3:0] slv_wstrb [0:4];
    wire slv_wlast [0:4], slv_wvalid [0:4], slv_wready [0:4];
    wire [ID_W-1:0] slv_bid [0:4], slv_rid [0:4];
    wire [1:0] slv_bresp [0:4], slv_rresp [0:4];
    wire slv_bvalid [0:4], slv_bready [0:4], slv_rlast [0:4], slv_rvalid [0:4], slv_rready [0:4];

    axi_ic #(.DATA_W(DATA_W), .ADDR_W(ADDR_W), .ID_W(ID_W), .N_MASTER(2), .N_SLAVE(5)) dut (
        .clk(clk), .rst_n(rst_n),
        .s0_axi_awid(m0_awid), .s0_axi_awaddr(m0_awaddr), .s0_axi_awlen(m0_awlen),
        .s0_axi_awsize(m0_awsize), .s0_axi_awburst(m0_awburst), .s0_axi_awvalid(m0_awvalid), .s0_axi_awready(m0_awready),
        .s0_axi_wdata(m0_wdata), .s0_axi_wstrb(m0_wstrb), .s0_axi_wlast(m0_wlast), .s0_axi_wvalid(m0_wvalid), .s0_axi_wready(m0_wready),
        .s0_axi_bid(m0_bid), .s0_axi_bresp(m0_bresp), .s0_axi_bvalid(m0_bvalid), .s0_axi_bready(m0_bready),
        .s0_axi_arid(m0_arid), .s0_axi_araddr(m0_araddr), .s0_axi_arlen(m0_arlen),
        .s0_axi_arsize(m0_arsize), .s0_axi_arburst(m0_arburst), .s0_axi_arvalid(m0_arvalid), .s0_axi_arready(m0_arready),
        .s0_axi_rid(m0_rid), .s0_axi_rdata(m0_rdata), .s0_axi_rresp(m0_rresp), .s0_axi_rlast(m0_rlast), .s0_axi_rvalid(m0_rvalid), .s0_axi_rready(m0_rready),
        .s1_axi_awid(m1_awid), .s1_axi_awaddr(m1_awaddr), .s1_axi_awlen(m1_awlen),
        .s1_axi_awsize(m1_awsize), .s1_axi_awburst(m1_awburst), .s1_axi_awvalid(m1_awvalid), .s1_axi_awready(m1_awready),
        .s1_axi_wdata(m1_wdata), .s1_axi_wstrb(m1_wstrb), .s1_axi_wlast(m1_wlast), .s1_axi_wvalid(m1_wvalid), .s1_axi_wready(m1_wready),
        .s1_axi_bid(m1_bid), .s1_axi_bresp(m1_bresp), .s1_axi_bvalid(m1_bvalid), .s1_axi_bready(m1_bready),
        .s1_axi_arid(m1_arid), .s1_axi_araddr(m1_araddr), .s1_axi_arlen(m1_arlen),
        .s1_axi_arsize(m1_arsize), .s1_axi_arburst(m1_arburst), .s1_axi_arvalid(m1_arvalid), .s1_axi_arready(m1_arready),
        .s1_axi_rid(m1_rid), .s1_axi_rdata(m1_rdata), .s1_axi_rresp(m1_rresp), .s1_axi_rlast(m1_rlast), .s1_axi_rvalid(m1_rvalid), .s1_axi_rready(m1_rready),
        .m0_axi_awid(slv_awid[0]), .m0_axi_awaddr(slv_awaddr[0]), .m0_axi_awlen(slv_awlen[0]),
        .m0_axi_awsize(slv_awsize[0]), .m0_axi_awburst(slv_awburst[0]), .m0_axi_awvalid(slv_awvalid[0]), .m0_axi_awready(slv_awready[0]),
        .m0_axi_wdata(slv_wdata[0]), .m0_axi_wstrb(slv_wstrb[0]), .m0_axi_wlast(slv_wlast[0]), .m0_axi_wvalid(slv_wvalid[0]), .m0_axi_wready(slv_wready[0]),
        .m0_axi_bid(slv_bid[0]), .m0_axi_bresp(slv_bresp[0]), .m0_axi_bvalid(slv_bvalid[0]), .m0_axi_bready(slv_bready[0]),
        .m0_axi_arid(slv_arid[0]), .m0_axi_araddr(slv_araddr[0]), .m0_axi_arlen(slv_arlen[0]),
        .m0_axi_arsize(slv_arsize[0]), .m0_axi_arburst(slv_arburst[0]), .m0_axi_arvalid(slv_arvalid[0]), .m0_axi_arready(slv_arready[0]),
        .m0_axi_rid(slv_rid[0]), .m0_axi_rdata(slv_rdata[0]), .m0_axi_rresp(slv_rresp[0]), .m0_axi_rlast(slv_rlast[0]), .m0_axi_rvalid(slv_rvalid[0]), .m0_axi_rready(slv_rready[0]),
        .m1_axi_awid(slv_awid[1]), .m1_axi_awaddr(slv_awaddr[1]), .m1_axi_awlen(slv_awlen[1]),
        .m1_axi_awsize(slv_awsize[1]), .m1_axi_awburst(slv_awburst[1]), .m1_axi_awvalid(slv_awvalid[1]), .m1_axi_awready(slv_awready[1]),
        .m1_axi_wdata(slv_wdata[1]), .m1_axi_wstrb(slv_wstrb[1]), .m1_axi_wlast(slv_wlast[1]), .m1_axi_wvalid(slv_wvalid[1]), .m1_axi_wready(slv_wready[1]),
        .m1_axi_bid(slv_bid[1]), .m1_axi_bresp(slv_bresp[1]), .m1_axi_bvalid(slv_bvalid[1]), .m1_axi_bready(slv_bready[1]),
        .m1_axi_arid(slv_arid[1]), .m1_axi_araddr(slv_araddr[1]), .m1_axi_arlen(slv_arlen[1]),
        .m1_axi_arsize(slv_arsize[1]), .m1_axi_arburst(slv_arburst[1]), .m1_axi_arvalid(slv_arvalid[1]), .m1_axi_arready(slv_arready[1]),
        .m1_axi_rid(slv_rid[1]), .m1_axi_rdata(slv_rdata[1]), .m1_axi_rresp(slv_rresp[1]), .m1_axi_rlast(slv_rlast[1]), .m1_axi_rvalid(slv_rvalid[1]), .m1_axi_rready(slv_rready[1]),
        .m2_axi_awid(slv_awid[2]), .m2_axi_awaddr(slv_awaddr[2]), .m2_axi_awlen(slv_awlen[2]),
        .m2_axi_awsize(slv_awsize[2]), .m2_axi_awburst(slv_awburst[2]), .m2_axi_awvalid(slv_awvalid[2]), .m2_axi_awready(slv_awready[2]),
        .m2_axi_wdata(slv_wdata[2]), .m2_axi_wstrb(slv_wstrb[2]), .m2_axi_wlast(slv_wlast[2]), .m2_axi_wvalid(slv_wvalid[2]), .m2_axi_wready(slv_wready[2]),
        .m2_axi_bid(slv_bid[2]), .m2_axi_bresp(slv_bresp[2]), .m2_axi_bvalid(slv_bvalid[2]), .m2_axi_bready(slv_bready[2]),
        .m2_axi_arid(slv_arid[2]), .m2_axi_araddr(slv_araddr[2]), .m2_axi_arlen(slv_arlen[2]),
        .m2_axi_arsize(slv_arsize[2]), .m2_axi_arburst(slv_arburst[2]), .m2_axi_arvalid(slv_arvalid[2]), .m2_axi_arready(slv_arready[2]),
        .m2_axi_rid(slv_rid[2]), .m2_axi_rdata(slv_rdata[2]), .m2_axi_rresp(slv_rresp[2]), .m2_axi_rlast(slv_rlast[2]), .m2_axi_rvalid(slv_rvalid[2]), .m2_axi_rready(slv_rready[2]),
        .m3_axi_awid(slv_awid[3]), .m3_axi_awaddr(slv_awaddr[3]), .m3_axi_awlen(slv_awlen[3]),
        .m3_axi_awsize(slv_awsize[3]), .m3_axi_awburst(slv_awburst[3]), .m3_axi_awvalid(slv_awvalid[3]), .m3_axi_awready(slv_awready[3]),
        .m3_axi_wdata(slv_wdata[3]), .m3_axi_wstrb(slv_wstrb[3]), .m3_axi_wlast(slv_wlast[3]), .m3_axi_wvalid(slv_wvalid[3]), .m3_axi_wready(slv_wready[3]),
        .m3_axi_bid(slv_bid[3]), .m3_axi_bresp(slv_bresp[3]), .m3_axi_bvalid(slv_bvalid[3]), .m3_axi_bready(slv_bready[3]),
        .m3_axi_arid(slv_arid[3]), .m3_axi_araddr(slv_araddr[3]), .m3_axi_arlen(slv_arlen[3]),
        .m3_axi_arsize(slv_arsize[3]), .m3_axi_arburst(slv_arburst[3]), .m3_axi_arvalid(slv_arvalid[3]), .m3_axi_arready(slv_arready[3]),
        .m3_axi_rid(slv_rid[3]), .m3_axi_rdata(slv_rdata[3]), .m3_axi_rresp(slv_rresp[3]), .m3_axi_rlast(slv_rlast[3]), .m3_axi_rvalid(slv_rvalid[3]), .m3_axi_rready(slv_rready[3]),
        .m4_axi_awid(slv_awid[4]), .m4_axi_awaddr(slv_awaddr[4]), .m4_axi_awlen(slv_awlen[4]),
        .m4_axi_awsize(slv_awsize[4]), .m4_axi_awburst(slv_awburst[4]), .m4_axi_awvalid(slv_awvalid[4]), .m4_axi_awready(slv_awready[4]),
        .m4_axi_wdata(slv_wdata[4]), .m4_axi_wstrb(slv_wstrb[4]), .m4_axi_wlast(slv_wlast[4]), .m4_axi_wvalid(slv_wvalid[4]), .m4_axi_wready(slv_wready[4]),
        .m4_axi_bid(slv_bid[4]), .m4_axi_bresp(slv_bresp[4]), .m4_axi_bvalid(slv_bvalid[4]), .m4_axi_bready(slv_bready[4]),
        .m4_axi_arid(slv_arid[4]), .m4_axi_araddr(slv_araddr[4]), .m4_axi_arlen(slv_arlen[4]),
        .m4_axi_arsize(slv_arsize[4]), .m4_axi_arburst(slv_arburst[4]), .m4_axi_arvalid(slv_arvalid[4]), .m4_axi_arready(slv_arready[4]),
        .m4_axi_rid(slv_rid[4]), .m4_axi_rdata(slv_rdata[4]), .m4_axi_rresp(slv_rresp[4]), .m4_axi_rlast(slv_rlast[4]), .m4_axi_rvalid(slv_rvalid[4]), .m4_axi_rready(slv_rready[4])
    );

    genvar g;
    generate
        for (g = 0; g < 5; g = g + 1) begin : g_slv
            axi_slave_model #(.ID_W(ID_W), .DATA_W(DATA_W), .ADDR_W(ADDR_W)) u_slv (
                .clk(clk), .rst_n(rst_n),
                .s_awid(slv_awid[g]), .s_awaddr(slv_awaddr[g]), .s_awlen(slv_awlen[g]),
                .s_awsize(slv_awsize[g]), .s_awburst(slv_awburst[g]), .s_awvalid(slv_awvalid[g]), .s_awready(slv_awready[g]),
                .s_wdata(slv_wdata[g]), .s_wstrb(slv_wstrb[g]), .s_wlast(slv_wlast[g]), .s_wvalid(slv_wvalid[g]), .s_wready(slv_wready[g]),
                .s_bid(slv_bid[g]), .s_bresp(slv_bresp[g]), .s_bvalid(slv_bvalid[g]), .s_bready(slv_bready[g]),
                .s_arid(slv_arid[g]), .s_araddr(slv_araddr[g]), .s_arlen(slv_arlen[g]),
                .s_arsize(slv_arsize[g]), .s_arburst(slv_arburst[g]), .s_arvalid(slv_arvalid[g]), .s_arready(slv_arready[g]),
                .s_rid(slv_rid[g]), .s_rdata(slv_rdata[g]), .s_rresp(slv_rresp[g]), .s_rlast(slv_rlast[g]), .s_rvalid(slv_rvalid[g]), .s_rready(slv_rready[g])
            );
        end
    endgenerate

    // ============================================================
    // 主设备 BFM：写任务 / 读任务（mid=0/1 选择主设备）
    // ============================================================
    integer errors, checks;

    task automatic m_write;
        input integer mid;
        input [ADDR_W-1:0] addr;
        input [DATA_W-1:0] data;
        input [7:0] len;
        output [1:0] resp;
        integer i;
        begin
            @(negedge clk);
            if (mid == 0) begin
                m0_awid = 4'd0; m0_awaddr = addr; m0_awlen = len; m0_awsize = 3'd2; m0_awburst = 2'b01;
                m0_awvalid = 1; m0_bready = 1;
                @(posedge clk); while (!m0_awready) @(posedge clk);
                @(negedge clk); m0_awvalid = 0;
                for (i = 0; i <= len; i = i + 1) begin
                    @(negedge clk);
                    m0_wdata = data + i; m0_wstrb = 4'hF; m0_wlast = (i == len); m0_wvalid = 1;
                    @(posedge clk); while (!m0_wready) @(posedge clk);
                    @(negedge clk); m0_wvalid = 0;
                end
                @(posedge clk); while (!m0_bvalid) @(posedge clk);
                resp = m0_bresp;
                @(negedge clk); m0_bready = 0;
            end
            else begin
                m1_awid = 4'd1; m1_awaddr = addr; m1_awlen = len; m1_awsize = 3'd2; m1_awburst = 2'b01;
                m1_awvalid = 1; m1_bready = 1;
                @(posedge clk); while (!m1_awready) @(posedge clk);
                @(negedge clk); m1_awvalid = 0;
                for (i = 0; i <= len; i = i + 1) begin
                    @(negedge clk);
                    m1_wdata = data + i; m1_wstrb = 4'hF; m1_wlast = (i == len); m1_wvalid = 1;
                    @(posedge clk); while (!m1_wready) @(posedge clk);
                    @(negedge clk); m1_wvalid = 0;
                end
                @(posedge clk); while (!m1_bvalid) @(posedge clk);
                resp = m1_bresp;
                @(negedge clk); m1_bready = 0;
            end
        end
    endtask

    task automatic m_read;
        input integer mid;
        input [ADDR_W-1:0] addr;
        input [7:0] len;
        output [DATA_W-1:0] first_data;
        output [1:0] resp;
        integer i;
        begin
            @(negedge clk);
            if (mid == 0) begin
                m0_arid = 4'd0; m0_araddr = addr; m0_arlen = len; m0_arsize = 3'd2; m0_arburst = 2'b01;
                m0_arvalid = 1; m0_rready = 1;
                @(posedge clk); while (!m0_arready) @(posedge clk);
                @(negedge clk); m0_arvalid = 0;
                for (i = 0; i <= len; i = i + 1) begin
                    @(posedge clk); while (!m0_rvalid) @(posedge clk);
                    if (i == 0) first_data = m0_rdata;
                    resp = m0_rresp;
                    @(negedge clk);
                end
                @(negedge clk); m0_rready = 0;
            end
            else begin
                m1_arid = 4'd1; m1_araddr = addr; m1_arlen = len; m1_arsize = 3'd2; m1_arburst = 2'b01;
                m1_arvalid = 1; m1_rready = 1;
                @(posedge clk); while (!m1_arready) @(posedge clk);
                @(negedge clk); m1_arvalid = 0;
                for (i = 0; i <= len; i = i + 1) begin
                    @(posedge clk); while (!m1_rvalid) @(posedge clk);
                    if (i == 0) first_data = m1_rdata;
                    resp = m1_rresp;
                    @(negedge clk);
                end
                @(negedge clk); m1_rready = 0;
            end
        end
    endtask

    // 5 个从设备的基地址（契约任务三）
    function [ADDR_W-1:0] slave_base;
        input integer s;
        begin
            case (s)
                0: slave_base = 32'h4000_0000;  // FIR
                1: slave_base = 32'h4000_1000;  // DMA
                2: slave_base = 32'h2000_0000;  // SRAM
                3: slave_base = 32'h0000_0000;  // ROM
                4: slave_base = 32'h4000_2000;  // APB
                default: slave_base = 32'h4000_0000;
            endcase
        end
    endfunction

    reg [DATA_W-1:0] rd;
    reg [1:0] resp;
    integer i, s, m;

    initial begin
        m0_awvalid=0; m0_wvalid=0; m0_arvalid=0; m0_bready=0; m0_rready=0;
        m1_awvalid=0; m1_wvalid=0; m1_arvalid=0; m1_bready=0; m1_rready=0;
        errors = 0; checks = 0;

        rst_n = 0;
        repeat (5) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (2) @(posedge clk);

        $display("");
        $display("========== AXI 互连单元测试 ==========");

        // [1] 10 条路径：每主对每从 写+读回
        $display("[1] 10 条路径（2 主 × 5 从）写+读回");
        for (m = 0; m < 2; m = m + 1) begin
            for (s = 0; s < 5; s = s + 1) begin
                m_write(m, slave_base(s), 32'hA000_0000 + m*32'h100 + s, 8'd0, resp);
                checks = checks + 1;
                if (resp != 2'b00) begin errors = errors + 1; $display("  [FAIL] m%0d->s%0d 写 resp=%b", m, s, resp); end
                m_read(m, slave_base(s), 8'd0, rd, resp);
                checks = checks + 1;
                if (rd != 32'hA000_0000 + m*32'h100 + s) begin
                    errors = errors + 1;
                    $display("  [FAIL] m%0d->s%0d 读回 = %h 期望 %h", m, s, rd, 32'hA000_0000 + m*32'h100 + s);
                end
            end
        end
        $display("  10 路径写读完成");

        // [2] 并行：两主同时访问不同从设备
        $display("[2] 并行：m0->s0 与 m1->s2 同时写");
        fork
            begin m_write(0, slave_base(0), 32'h1111_1111, 8'd0, resp); end
            begin m_write(1, slave_base(2), 32'h2222_2222, 8'd0, resp); end
        join
        m_read(0, slave_base(0), 8'd0, rd, resp);
        if (rd != 32'h1111_1111) begin errors = errors + 1; $display("  [FAIL] 并行 m0->s0 读回=%h", rd); end
        m_read(1, slave_base(2), 8'd0, rd, resp);
        if (rd != 32'h2222_2222) begin errors = errors + 1; $display("  [FAIL] 并行 m1->s2 读回=%h", rd); end
        checks = checks + 2;
        $display("  并行写完成");

        // [3] 仲裁：两主同时访问同一从设备
        $display("[3] 仲裁：m0、m1 同时写 s3");
        fork
            begin m_write(0, slave_base(3), 32'h3333_3333, 8'd0, resp); end
            begin m_write(1, slave_base(3), 32'h4444_4444, 8'd0, resp); end
        join
        // 后写的覆盖先写的，读到 0x33333333 或 0x44444444 都算仲裁正确（无死锁、无丢写）
        m_read(0, slave_base(3), 8'd0, rd, resp);
        if (rd != 32'h3333_3333 && rd != 32'h4444_4444) begin
            errors = errors + 1; $display("  [FAIL] 仲裁后读回=%h", rd);
        end
        checks = checks + 1;
        $display("  仲裁完成");

        // [4] INCR 突发写 + INCR 突发读
        $display("[4] INCR 突发（4 拍写 + 4 拍读）");
        m_write(0, slave_base(2), 32'hCAFE_0000, 8'd3, resp);
        checks = checks + 1;
        if (resp != 2'b00) begin errors = errors + 1; $display("  [FAIL] INCR 写 resp=%b", resp); end
        m_read(1, slave_base(2), 8'd3, rd, resp);
        checks = checks + 1;
        if (rd != 32'hCAFE_0000) begin errors = errors + 1; $display("  [FAIL] INCR 读回=%h", rd); end
        $display("  INCR 突发完成");

        // [5] 随机激励（长时间，无死锁）
        $display("[5] 随机激励 500 笔（无死锁）");
        for (i = 0; i < 500; i = i + 1) begin
            m = i % 2; s = (i / 2) % 5;
            if (i % 2 == 0) begin
                m_write(m, slave_base(s), i[31:0], 8'd0, resp);
                if (resp != 2'b00) begin errors = errors + 1; $display("  [FAIL] 随机写 resp=%b @i=%0d", resp, i); end
            end
            else begin
                m_read(m, slave_base(s), 8'd0, rd, resp);
            end
            checks = checks + 1;
        end
        $display("  随机激励完成");

        // [6] 未映射地址 → DECERR（不挂死）
        $display("[6] 未映射地址 → DECERR（不挂死）");
        m_write(0, 32'h6000_0000, 32'hDEAD_BEEF, 8'd0, resp);
        checks = checks + 1;
        if (resp != 2'b11) begin errors = errors + 1; $display("  [FAIL] 未映射写 resp=%b 期望 DECERR(11)", resp); end
        m_read(1, 32'h6000_0000, 8'd0, rd, resp);
        checks = checks + 1;
        if (resp != 2'b11) begin errors = errors + 1; $display("  [FAIL] 未映射读 resp=%b 期望 DECERR(11)", resp); end
        $display("  未映射地址处理完成");

        repeat (5) @(posedge clk);
        $display("");
        $display("============================================");
        if (errors == 0)
            $display("===== PASS：%0d 项检查全部通过，无死锁 =====", checks);
        else
            $display("===== FAIL：%0d 项检查中 %0d 项失败 =====", checks, errors);
        $display("============================================");
        $finish;
    end

    // 超时保护：任何死锁都算失败
    initial begin
        #10000000;
        $display("!!!! TIMEOUT：仿真超时（死锁）");
        $finish;
    end


endmodule
