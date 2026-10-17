// CPU-free verification fixture: production RTL, independently wired.
`timescale 1ns/1ps
module phase5_fabric(input wire clk,rst_n);
    localparam ADDR_W=32, DATA_W=32, ID_W=4, LEN_W=8, SRAM_BYTES=65536;
    localparam CLK_FREQ=100000000, UART_DIV=10;
    wire rst_n_sync=rst_n;
    wire uart_txd;
    wire uart_rxd=1'b1;
    wire              fir_irq_done, fir_irq_err;
    wire [5:0]        dma_irq_done;
    wire              dma_irq_err;
    wire [31:0]       irq_lines;
    wire [ID_W-1:0]      b_awid, b_arid;
    wire [ADDR_W-1:0]    b_awaddr, b_araddr;
    wire [LEN_W-1:0]     b_awlen, b_arlen;
    wire [2:0]           b_awsize, b_arsize;
    wire [1:0]           b_awburst, b_arburst;
    wire                 b_awvalid, b_awready, b_arvalid, b_arready;
    wire [DATA_W-1:0]    b_wdata;
    wire [DATA_W/8-1:0]  b_wstrb;
    wire                 b_wlast, b_wvalid, b_wready;
    wire [ID_W-1:0]      b_bid, b_rid;
    wire [1:0]           b_bresp, b_rresp;
    wire                 b_bvalid, b_bready, b_rlast, b_rvalid, b_rready;
    wire [DATA_W-1:0]    b_rdata;
    wire [ID_W-1:0]      dm_awid, dm_arid;
    wire [ADDR_W-1:0]    dm_awaddr, dm_araddr;
    wire [LEN_W-1:0]     dm_awlen, dm_arlen;
    wire [2:0]           dm_awsize, dm_arsize;
    wire [1:0]           dm_awburst, dm_arburst;
    wire                 dm_awvalid, dm_awready, dm_arvalid, dm_arready;
    wire [DATA_W-1:0]    dm_wdata;
    wire [DATA_W/8-1:0]  dm_wstrb;
    wire                 dm_wlast, dm_wvalid, dm_wready;
    wire [ID_W-1:0]      dm_bid, dm_rid;
    wire [1:0]           dm_bresp, dm_rresp;
    wire                 dm_bvalid, dm_bready, dm_rlast, dm_rvalid, dm_rready;
    wire [DATA_W-1:0]    dm_rdata;
    wire [ID_W-1:0]      f_awid, f_arid;
    wire [ADDR_W-1:0]    f_awaddr, f_araddr;
    wire [LEN_W-1:0]     f_awlen, f_arlen;
    wire [2:0]           f_awsize, f_arsize;
    wire [1:0]           f_awburst, f_arburst;
    wire                 f_awvalid, f_awready, f_arvalid, f_arready;
    wire [DATA_W-1:0]    f_wdata;
    wire [DATA_W/8-1:0]  f_wstrb;
    wire                 f_wlast, f_wvalid, f_wready;
    wire [ID_W-1:0]      f_bid, f_rid;
    wire [1:0]           f_bresp, f_rresp;
    wire                 f_bvalid, f_bready, f_rlast, f_rvalid, f_rready;
    wire [DATA_W-1:0]    f_rdata;
    wire [ID_W-1:0]      dc_awid, dc_arid;
    wire [ADDR_W-1:0]    dc_awaddr, dc_araddr;
    wire [LEN_W-1:0]     dc_awlen, dc_arlen;
    wire [2:0]           dc_awsize, dc_arsize;
    wire [1:0]           dc_awburst, dc_arburst;
    wire                 dc_awvalid, dc_awready, dc_arvalid, dc_arready;
    wire [DATA_W-1:0]    dc_wdata;
    wire [DATA_W/8-1:0]  dc_wstrb;
    wire                 dc_wlast, dc_wvalid, dc_wready;
    wire [ID_W-1:0]      dc_bid, dc_rid;
    wire [1:0]           dc_bresp, dc_rresp;
    wire                 dc_bvalid, dc_bready, dc_rlast, dc_rvalid, dc_rready;
    wire [DATA_W-1:0]    dc_rdata;
    wire [ID_W-1:0]      m2_bid, m2_rid;
    wire [1:0]           m2_bresp, m2_rresp;
    wire                 m2_awready, m2_wready, m2_bvalid, m2_arready, m2_rlast, m2_rvalid;
    wire [DATA_W-1:0]    m2_rdata;
    wire [ID_W-1:0]      sr_awid, sr_arid;
    wire [ADDR_W-1:0]    sr_awaddr, sr_araddr;
    wire [LEN_W-1:0]     sr_awlen, sr_arlen;
    wire [2:0]           sr_awsize, sr_arsize;
    wire [1:0]           sr_awburst, sr_arburst;
    wire                 sr_awvalid, sr_awready, sr_arvalid, sr_arready;
    wire [DATA_W-1:0]    sr_wdata;
    wire [DATA_W/8-1:0]  sr_wstrb;
    wire                 sr_wlast, sr_wvalid, sr_wready;
    wire [ID_W-1:0]      sr_bid, sr_rid;
    wire [1:0]           sr_bresp, sr_rresp;
    wire                 sr_bvalid, sr_bready, sr_rlast, sr_rvalid, sr_rready;
    wire [DATA_W-1:0]    sr_rdata;
    wire [ADDR_W-1:0]    ap_awaddr, ap_araddr;
    wire [LEN_W-1:0]     ap_awlen, ap_arlen;
    wire [2:0]           ap_awsize, ap_arsize;
    wire [1:0]           ap_awburst, ap_arburst;
    wire                 ap_awvalid, ap_awready, ap_arvalid, ap_arready;
    wire [DATA_W-1:0]    ap_wdata;
    wire                 ap_wlast, ap_wvalid, ap_wready;
    wire [1:0]           ap_bresp, ap_rresp;
    wire                 ap_bvalid, ap_bready, ap_rlast, ap_rvalid, ap_rready;
    wire [DATA_W-1:0]    ap_rdata;
    wire [ID_W-1:0]      ap_awid, ap_arid;
    reg [ID_W-1:0]       ap_bid, ap_rid;
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin ap_bid <= 0; ap_rid <= 0; end
        else begin
            if (ap_awvalid && ap_awready) ap_bid <= ap_awid;
            if (ap_arvalid && ap_arready) ap_rid <= ap_arid;
        end
    end
    wire                 p_psel, p_penable, p_pwrite, p_pready, p_pslverr;
    wire [ADDR_W-1:0]    p_paddr;
    wire [DATA_W-1:0]    p_pwdata, p_prdata;
    wire [DATA_W/8-1:0]  p_pstrb;
    wire [2:0]           p_pprot;
    axi_ic #(.DATA_W(DATA_W), .ADDR_W(ADDR_W), .ID_W(ID_W), .N_MASTER(2),
             .N_SLAVE(5), .M2_RESERVED(1)) u_ic (
        .clk(clk), .rst_n(rst_n_sync),
        .s0_axi_awid(b_awid), .s0_axi_awaddr(b_awaddr), .s0_axi_awlen(b_awlen),
        .s0_axi_awsize(b_awsize), .s0_axi_awburst(b_awburst),
        .s0_axi_awvalid(b_awvalid), .s0_axi_awready(b_awready),
        .s0_axi_wdata(b_wdata), .s0_axi_wstrb(b_wstrb), .s0_axi_wlast(b_wlast),
        .s0_axi_wvalid(b_wvalid), .s0_axi_wready(b_wready),
        .s0_axi_bid(b_bid), .s0_axi_bresp(b_bresp), .s0_axi_bvalid(b_bvalid), .s0_axi_bready(b_bready),
        .s0_axi_arid(b_arid), .s0_axi_araddr(b_araddr), .s0_axi_arlen(b_arlen),
        .s0_axi_arsize(b_arsize), .s0_axi_arburst(b_arburst),
        .s0_axi_arvalid(b_arvalid), .s0_axi_arready(b_arready),
        .s0_axi_rid(b_rid), .s0_axi_rdata(b_rdata), .s0_axi_rresp(b_rresp),
        .s0_axi_rlast(b_rlast), .s0_axi_rvalid(b_rvalid), .s0_axi_rready(b_rready),
        .s1_axi_awid(dm_awid), .s1_axi_awaddr(dm_awaddr), .s1_axi_awlen(dm_awlen),
        .s1_axi_awsize(dm_awsize), .s1_axi_awburst(dm_awburst),
        .s1_axi_awvalid(dm_awvalid), .s1_axi_awready(dm_awready),
        .s1_axi_wdata(dm_wdata), .s1_axi_wstrb(dm_wstrb), .s1_axi_wlast(dm_wlast),
        .s1_axi_wvalid(dm_wvalid), .s1_axi_wready(dm_wready),
        .s1_axi_bid(dm_bid), .s1_axi_bresp(dm_bresp), .s1_axi_bvalid(dm_bvalid), .s1_axi_bready(dm_bready),
        .s1_axi_arid(dm_arid), .s1_axi_araddr(dm_araddr), .s1_axi_arlen(dm_arlen),
        .s1_axi_arsize(dm_arsize), .s1_axi_arburst(dm_arburst),
        .s1_axi_arvalid(dm_arvalid), .s1_axi_arready(dm_arready),
        .s1_axi_rid(dm_rid), .s1_axi_rdata(dm_rdata), .s1_axi_rresp(dm_rresp),
        .s1_axi_rlast(dm_rlast), .s1_axi_rvalid(dm_rvalid), .s1_axi_rready(dm_rready),
        .m0_axi_awid(f_awid), .m0_axi_awaddr(f_awaddr), .m0_axi_awlen(f_awlen),
        .m0_axi_awsize(f_awsize), .m0_axi_awburst(f_awburst),
        .m0_axi_awvalid(f_awvalid), .m0_axi_awready(f_awready),
        .m0_axi_wdata(f_wdata), .m0_axi_wstrb(f_wstrb), .m0_axi_wlast(f_wlast),
        .m0_axi_wvalid(f_wvalid), .m0_axi_wready(f_wready),
        .m0_axi_bid(f_bid), .m0_axi_bresp(f_bresp), .m0_axi_bvalid(f_bvalid), .m0_axi_bready(f_bready),
        .m0_axi_arid(f_arid), .m0_axi_araddr(f_araddr), .m0_axi_arlen(f_arlen),
        .m0_axi_arsize(f_arsize), .m0_axi_arburst(f_arburst),
        .m0_axi_arvalid(f_arvalid), .m0_axi_arready(f_arready),
        .m0_axi_rid(f_rid), .m0_axi_rdata(f_rdata), .m0_axi_rresp(f_rresp),
        .m0_axi_rlast(f_rlast), .m0_axi_rvalid(f_rvalid), .m0_axi_rready(f_rready),
        .m1_axi_awid(dc_awid), .m1_axi_awaddr(dc_awaddr), .m1_axi_awlen(dc_awlen),
        .m1_axi_awsize(dc_awsize), .m1_axi_awburst(dc_awburst),
        .m1_axi_awvalid(dc_awvalid), .m1_axi_awready(dc_awready),
        .m1_axi_wdata(dc_wdata), .m1_axi_wstrb(dc_wstrb), .m1_axi_wlast(dc_wlast),
        .m1_axi_wvalid(dc_wvalid), .m1_axi_wready(dc_wready),
        .m1_axi_bid(dc_bid), .m1_axi_bresp(dc_bresp), .m1_axi_bvalid(dc_bvalid), .m1_axi_bready(dc_bready),
        .m1_axi_arid(dc_arid), .m1_axi_araddr(dc_araddr), .m1_axi_arlen(dc_arlen),
        .m1_axi_arsize(dc_arsize), .m1_axi_arburst(dc_arburst),
        .m1_axi_arvalid(dc_arvalid), .m1_axi_arready(dc_arready),
        .m1_axi_rid(dc_rid), .m1_axi_rdata(dc_rdata), .m1_axi_rresp(dc_rresp),
        .m1_axi_rlast(dc_rlast), .m1_axi_rvalid(dc_rvalid), .m1_axi_rready(dc_rready),
        .m2_axi_awid(), .m2_axi_awaddr(), .m2_axi_awlen(), .m2_axi_awsize(), .m2_axi_awburst(),
        .m2_axi_awvalid(), .m2_axi_awready(1'b0),
        .m2_axi_wdata(), .m2_axi_wstrb(), .m2_axi_wlast(), .m2_axi_wvalid(), .m2_axi_wready(1'b0),
        .m2_axi_bid(4'd0), .m2_axi_bresp(2'd0), .m2_axi_bvalid(1'b0), .m2_axi_bready(),
        .m2_axi_arid(), .m2_axi_araddr(), .m2_axi_arlen(), .m2_axi_arsize(), .m2_axi_arburst(),
        .m2_axi_arvalid(), .m2_axi_arready(1'b0),
        .m2_axi_rid(4'd0), .m2_axi_rdata(32'd0), .m2_axi_rresp(2'd0),
        .m2_axi_rlast(1'b0), .m2_axi_rvalid(1'b0), .m2_axi_rready(),
        .m3_axi_awid(sr_awid), .m3_axi_awaddr(sr_awaddr), .m3_axi_awlen(sr_awlen),
        .m3_axi_awsize(sr_awsize), .m3_axi_awburst(sr_awburst),
        .m3_axi_awvalid(sr_awvalid), .m3_axi_awready(sr_awready),
        .m3_axi_wdata(sr_wdata), .m3_axi_wstrb(sr_wstrb), .m3_axi_wlast(sr_wlast),
        .m3_axi_wvalid(sr_wvalid), .m3_axi_wready(sr_wready),
        .m3_axi_bid(sr_bid), .m3_axi_bresp(sr_bresp), .m3_axi_bvalid(sr_bvalid), .m3_axi_bready(sr_bready),
        .m3_axi_arid(sr_arid), .m3_axi_araddr(sr_araddr), .m3_axi_arlen(sr_arlen),
        .m3_axi_arsize(sr_arsize), .m3_axi_arburst(sr_arburst),
        .m3_axi_arvalid(sr_arvalid), .m3_axi_arready(sr_arready),
        .m3_axi_rid(sr_rid), .m3_axi_rdata(sr_rdata), .m3_axi_rresp(sr_rresp),
        .m3_axi_rlast(sr_rlast), .m3_axi_rvalid(sr_rvalid), .m3_axi_rready(sr_rready),
        .m4_axi_awid(ap_awid), .m4_axi_awaddr(ap_awaddr), .m4_axi_awlen(ap_awlen),
        .m4_axi_awsize(ap_awsize), .m4_axi_awburst(ap_awburst),
        .m4_axi_awvalid(ap_awvalid), .m4_axi_awready(ap_awready),
        .m4_axi_wdata(ap_wdata), .m4_axi_wstrb(), .m4_axi_wlast(ap_wlast),
        .m4_axi_wvalid(ap_wvalid), .m4_axi_wready(ap_wready),
        .m4_axi_bid(ap_bid), .m4_axi_bresp(ap_bresp), .m4_axi_bvalid(ap_bvalid), .m4_axi_bready(ap_bready),
        .m4_axi_arid(ap_arid), .m4_axi_araddr(ap_araddr), .m4_axi_arlen(ap_arlen),
        .m4_axi_arsize(ap_arsize), .m4_axi_arburst(ap_arburst),
        .m4_axi_arvalid(ap_arvalid), .m4_axi_arready(ap_arready),
        .m4_axi_rid(ap_rid), .m4_axi_rdata(ap_rdata), .m4_axi_rresp(ap_rresp),
        .m4_axi_rlast(ap_rlast), .m4_axi_rvalid(ap_rvalid), .m4_axi_rready(ap_rready)
    );
    fir #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)) u_fir (
        .clk(clk), .rst_n(rst_n_sync),
        .s_axi_awid(f_awid), .s_axi_awaddr(f_awaddr), .s_axi_awlen(f_awlen),
        .s_axi_awsize(f_awsize), .s_axi_awburst(f_awburst),
        .s_axi_awvalid(f_awvalid), .s_axi_awready(f_awready),
        .s_axi_wdata(f_wdata), .s_axi_wstrb(f_wstrb), .s_axi_wlast(f_wlast),
        .s_axi_wvalid(f_wvalid), .s_axi_wready(f_wready),
        .s_axi_bid(f_bid), .s_axi_bresp(f_bresp), .s_axi_bvalid(f_bvalid), .s_axi_bready(f_bready),
        .s_axi_arid(f_arid), .s_axi_araddr(f_araddr), .s_axi_arlen(f_arlen),
        .s_axi_arsize(f_arsize), .s_axi_arburst(f_arburst),
        .s_axi_arvalid(f_arvalid), .s_axi_arready(f_arready),
        .s_axi_rid(f_rid), .s_axi_rdata(f_rdata), .s_axi_rresp(f_rresp),
        .s_axi_rlast(f_rlast), .s_axi_rvalid(f_rvalid), .s_axi_rready(f_rready),
        .irq_done(fir_irq_done), .irq_err(fir_irq_err)
    );
    dma #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W), .LEN_W(LEN_W), .NCH(6)) u_dma (
        .clk(clk), .rst_n(rst_n_sync),
        .s_axi_awid(dc_awid), .s_axi_awaddr(dc_awaddr), .s_axi_awlen(dc_awlen),
        .s_axi_awsize(dc_awsize), .s_axi_awburst(dc_awburst),
        .s_axi_awvalid(dc_awvalid), .s_axi_awready(dc_awready),
        .s_axi_wdata(dc_wdata), .s_axi_wstrb(dc_wstrb), .s_axi_wlast(dc_wlast),
        .s_axi_wvalid(dc_wvalid), .s_axi_wready(dc_wready),
        .s_axi_bid(dc_bid), .s_axi_bresp(dc_bresp), .s_axi_bvalid(dc_bvalid), .s_axi_bready(dc_bready),
        .s_axi_arid(dc_arid), .s_axi_araddr(dc_araddr), .s_axi_arlen(dc_arlen),
        .s_axi_arsize(dc_arsize), .s_axi_arburst(dc_arburst),
        .s_axi_arvalid(dc_arvalid), .s_axi_arready(dc_arready),
        .s_axi_rid(dc_rid), .s_axi_rdata(dc_rdata), .s_axi_rresp(dc_rresp),
        .s_axi_rlast(dc_rlast), .s_axi_rvalid(dc_rvalid), .s_axi_rready(dc_rready),
        .m_axi_awid(dm_awid), .m_axi_awaddr(dm_awaddr), .m_axi_awlen(dm_awlen),
        .m_axi_awsize(dm_awsize), .m_axi_awburst(dm_awburst),
        .m_axi_awvalid(dm_awvalid), .m_axi_awready(dm_awready),
        .m_axi_wdata(dm_wdata), .m_axi_wstrb(dm_wstrb), .m_axi_wlast(dm_wlast),
        .m_axi_wvalid(dm_wvalid), .m_axi_wready(dm_wready),
        .m_axi_bid(dm_bid), .m_axi_bresp(dm_bresp), .m_axi_bvalid(dm_bvalid), .m_axi_bready(dm_bready),
        .m_axi_arid(dm_arid), .m_axi_araddr(dm_araddr), .m_axi_arlen(dm_arlen),
        .m_axi_arsize(dm_arsize), .m_axi_arburst(dm_arburst),
        .m_axi_arvalid(dm_arvalid), .m_axi_arready(dm_arready),
        .m_axi_rid(dm_rid), .m_axi_rdata(dm_rdata), .m_axi_rresp(dm_rresp),
        .m_axi_rlast(dm_rlast), .m_axi_rvalid(dm_rvalid), .m_axi_rready(dm_rready),
        .irq_done(dma_irq_done), .irq_err(dma_irq_err)
    );
    axi_sram #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W),
        .SRAM_BYTES(SRAM_BYTES), .BASE_ADDR(32'h0000_0000)
    ) u_sram (
        .clk(clk), .rst_n(rst_n_sync),
        .s_axi_awid(sr_awid), .s_axi_awaddr(sr_awaddr), .s_axi_awlen(sr_awlen),
        .s_axi_awsize(sr_awsize), .s_axi_awburst(sr_awburst),
        .s_axi_awvalid(sr_awvalid), .s_axi_awready(sr_awready),
        .s_axi_wdata(sr_wdata), .s_axi_wstrb(sr_wstrb), .s_axi_wlast(sr_wlast),
        .s_axi_wvalid(sr_wvalid), .s_axi_wready(sr_wready),
        .s_axi_bid(sr_bid), .s_axi_bresp(sr_bresp), .s_axi_bvalid(sr_bvalid), .s_axi_bready(sr_bready),
        .s_axi_arid(sr_arid), .s_axi_araddr(sr_araddr), .s_axi_arlen(sr_arlen),
        .s_axi_arsize(sr_arsize), .s_axi_arburst(sr_arburst),
        .s_axi_arvalid(sr_arvalid), .s_axi_arready(sr_arready),
        .s_axi_rid(sr_rid), .s_axi_rdata(sr_rdata), .s_axi_rresp(sr_rresp),
        .s_axi_rlast(sr_rlast), .s_axi_rvalid(sr_rvalid), .s_axi_rready(sr_rready)
    );
    axi_to_apb #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .TIMEOUT(0),
                 .BASE_ADDR(32'h4000_2000)) u_axi2apb (
        .clk(clk), .rst_n(rst_n_sync),
        .awvalid(ap_awvalid), .awready(ap_awready), .awaddr(ap_awaddr),
        .awlen(ap_awlen), .awsize(ap_awsize), .awburst(ap_awburst),
        .wvalid(ap_wvalid), .wready(ap_wready), .wdata(ap_wdata), .wlast(ap_wlast),
        .bresp(ap_bresp), .bvalid(ap_bvalid), .bready(ap_bready),
        .arvalid(ap_arvalid), .arready(ap_arready), .araddr(ap_araddr),
        .arlen(ap_arlen), .arsize(ap_arsize), .arburst(ap_arburst),
        .rdata(ap_rdata), .rresp(ap_rresp), .rlast(ap_rlast), .rvalid(ap_rvalid), .rready(ap_rready),
        .psel(p_psel), .penable(p_penable), .paddr(p_paddr), .pwrite(p_pwrite),
        .pwdata(p_pwdata), .pstrb(p_pstrb), .pprot(p_pprot),
        .prdata(p_prdata), .pready(p_pready), .pslverr(p_pslverr)
    );
    uart_apb #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD    (CLK_FREQ / UART_DIV)
    ) u_uart (
        .clk(clk), .rst_n(rst_n_sync),
        .psel(p_psel), .penable(p_penable), .pwrite(p_pwrite), .paddr(p_paddr),
        .pwdata(p_pwdata), .pstrb(p_pstrb), .pprot(p_pprot),
        .prdata(p_prdata), .pready(p_pready), .pslverr(p_pslverr),
        .rxd(uart_rxd), .txd(uart_txd)
    );
    assign irq_lines = { 23'b0,           
                         dma_irq_err,     
                         dma_irq_done,    
                         fir_irq_err,     
                         fir_irq_done };  
    wire [31:0] err_cpu,err_dma,err_fir;
    phase5_axi_master #(.NAME("cpu")) cpu(.clk(clk),.rst_n(rst_n),
        .awid(b_awid),
        .awaddr(b_awaddr),
        .awlen(b_awlen),
        .awsize(b_awsize),
        .awburst(b_awburst),
        .awvalid(b_awvalid),
        .awready(b_awready),
        .wdata(b_wdata),
        .wstrb(b_wstrb),
        .wlast(b_wlast),
        .wvalid(b_wvalid),
        .wready(b_wready),
        .bid(b_bid),
        .bresp(b_bresp),
        .bvalid(b_bvalid),
        .bready(b_bready),
        .arid(b_arid),
        .araddr(b_araddr),
        .arlen(b_arlen),
        .arsize(b_arsize),
        .arburst(b_arburst),
        .arvalid(b_arvalid),
        .arready(b_arready),
        .rid(b_rid),
        .rdata(b_rdata),
        .rresp(b_rresp),
        .rlast(b_rlast),
        .rvalid(b_rvalid),
        .rready(b_rready));
    axi_protocol_checker #(.NAME("p5_cpu"),.ALLOW_WRAP(1)) chk_cpu(.clk(clk),.rst_n(rst_n),
        .awid(b_awid),
        .awaddr(b_awaddr),
        .awlen(b_awlen),
        .awsize(b_awsize),
        .awburst(b_awburst),
        .awvalid(b_awvalid),
        .awready(b_awready),
        .wdata(b_wdata),
        .wstrb(b_wstrb),
        .wlast(b_wlast),
        .wvalid(b_wvalid),
        .wready(b_wready),
        .bid(b_bid),
        .bresp(b_bresp),
        .bvalid(b_bvalid),
        .bready(b_bready),
        .arid(b_arid),
        .araddr(b_araddr),
        .arlen(b_arlen),
        .arsize(b_arsize),
        .arburst(b_arburst),
        .arvalid(b_arvalid),
        .arready(b_arready),
        .rid(b_rid),
        .rdata(b_rdata),
        .rresp(b_rresp),
        .rlast(b_rlast),
        .rvalid(b_rvalid),
        .rready(b_rready),.error_count(err_cpu));
    phase5_axi_coverage #(.NAME("cpu")) cov_cpu(.clk(clk),.rst_n(rst_n),
        .awaddr(b_awaddr),
        .araddr(b_araddr),
        .awlen(b_awlen),
        .arlen(b_arlen),
        .awsize(b_awsize),
        .arsize(b_arsize),
        .awburst(b_awburst),
        .arburst(b_arburst),
        .bresp(b_bresp),
        .rresp(b_rresp),
        .awvalid(b_awvalid),
        .awready(b_awready),
        .wvalid(b_wvalid),
        .wready(b_wready),
        .bvalid(b_bvalid),
        .bready(b_bready),
        .arvalid(b_arvalid),
        .arready(b_arready),
        .rvalid(b_rvalid),
        .rready(b_rready));
    axi_protocol_checker #(.NAME("p5_dma"),.ALLOW_WRAP(1)) chk_dma(.clk(clk),.rst_n(rst_n),
        .awid(dm_awid),
        .awaddr(dm_awaddr),
        .awlen(dm_awlen),
        .awsize(dm_awsize),
        .awburst(dm_awburst),
        .awvalid(dm_awvalid),
        .awready(dm_awready),
        .wdata(dm_wdata),
        .wstrb(dm_wstrb),
        .wlast(dm_wlast),
        .wvalid(dm_wvalid),
        .wready(dm_wready),
        .bid(dm_bid),
        .bresp(dm_bresp),
        .bvalid(dm_bvalid),
        .bready(dm_bready),
        .arid(dm_arid),
        .araddr(dm_araddr),
        .arlen(dm_arlen),
        .arsize(dm_arsize),
        .arburst(dm_arburst),
        .arvalid(dm_arvalid),
        .arready(dm_arready),
        .rid(dm_rid),
        .rdata(dm_rdata),
        .rresp(dm_rresp),
        .rlast(dm_rlast),
        .rvalid(dm_rvalid),
        .rready(dm_rready),.error_count(err_dma));
    phase5_axi_coverage #(.NAME("dma")) cov_dma(.clk(clk),.rst_n(rst_n),
        .awaddr(dm_awaddr),
        .araddr(dm_araddr),
        .awlen(dm_awlen),
        .arlen(dm_arlen),
        .awsize(dm_awsize),
        .arsize(dm_arsize),
        .awburst(dm_awburst),
        .arburst(dm_arburst),
        .bresp(dm_bresp),
        .rresp(dm_rresp),
        .awvalid(dm_awvalid),
        .awready(dm_awready),
        .wvalid(dm_wvalid),
        .wready(dm_wready),
        .bvalid(dm_bvalid),
        .bready(dm_bready),
        .arvalid(dm_arvalid),
        .arready(dm_arready),
        .rvalid(dm_rvalid),
        .rready(dm_rready));
    axi_protocol_checker #(.NAME("p5_fir"),.ALLOW_WRAP(1)) chk_fir(.clk(clk),.rst_n(rst_n),
        .awid(f_awid),
        .awaddr(f_awaddr),
        .awlen(f_awlen),
        .awsize(f_awsize),
        .awburst(f_awburst),
        .awvalid(f_awvalid),
        .awready(f_awready),
        .wdata(f_wdata),
        .wstrb(f_wstrb),
        .wlast(f_wlast),
        .wvalid(f_wvalid),
        .wready(f_wready),
        .bid(f_bid),
        .bresp(f_bresp),
        .bvalid(f_bvalid),
        .bready(f_bready),
        .arid(f_arid),
        .araddr(f_araddr),
        .arlen(f_arlen),
        .arsize(f_arsize),
        .arburst(f_arburst),
        .arvalid(f_arvalid),
        .arready(f_arready),
        .rid(f_rid),
        .rdata(f_rdata),
        .rresp(f_rresp),
        .rlast(f_rlast),
        .rvalid(f_rvalid),
        .rready(f_rready),.error_count(err_fir));
    phase5_axi_coverage #(.NAME("fir")) cov_fir(.clk(clk),.rst_n(rst_n),
        .awaddr(f_awaddr),
        .araddr(f_araddr),
        .awlen(f_awlen),
        .arlen(f_arlen),
        .awsize(f_awsize),
        .arsize(f_arsize),
        .awburst(f_awburst),
        .arburst(f_arburst),
        .bresp(f_bresp),
        .rresp(f_rresp),
        .awvalid(f_awvalid),
        .awready(f_awready),
        .wvalid(f_wvalid),
        .wready(f_wready),
        .bvalid(f_bvalid),
        .bready(f_bready),
        .arvalid(f_arvalid),
        .arready(f_arready),
        .rvalid(f_rvalid),
        .rready(f_rready));
endmodule
