// Phase5 AHB unit regression: real pipelined data phases and stalled AXI peer.
`timescale 1ns/1ps


// ------------------------------------------------------------
// 顶层测试台
// ------------------------------------------------------------
module tb_phase5_ahb;

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

    axi_mem_model #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W), .STALL_CYCLES(5)) u_slave (
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
    integer errors=0;
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

`ifdef PHASE5_NATIVE_COVERAGE
    covergroup ahb_cg @(posedge clk);
        option.per_instance=1;
        burst: coverpoint HBURST iff(rst_n && HREADY && HSEL && HTRANS[1]) {bins types[]={[0:7]};}
        size: coverpoint HSIZE iff(rst_n && HREADY && HSEL && HTRANS[1]) {bins byte_access={0};bins half={1};bins word_access={2};bins oversized={3};}
        alignment: coverpoint ((HADDR & ((1<<HSIZE)-1))==0) iff(rst_n && HREADY && HSEL && HTRANS[1]);
        response: coverpoint HRESP iff(rst_n && HREADY);
        ready: coverpoint HREADY iff(rst_n && HSEL);
        transfer: coverpoint HTRANS iff(rst_n && HREADY) {bins idle={0};bins busy={1};bins nonseq={2};bins seq={3};}
        size_burst: cross size,burst;
    endgroup
    ahb_cg cov=new;
    final $display("NATIVE_COV|ahb|%0.3f",cov.get_inst_coverage());
`endif
    always @(posedge clk) if(rst_n) begin
        if(HSEL && HREADY && HTRANS[1]) begin
            $display("COV|ahb|burst.%0d",HBURST);
            $display("COV|ahb|size.%0d",HSIZE);
        end
        if(!HREADY) $display("COV|ahb|wait");
        if(HREADY && HRESP) $display("COV|ahb|error_complete");
        if(!HREADY && HRESP) $display("COV|ahb|error_first");
        if(HREADY && HTRANS==1) $display("COV|ahb|busy");
    end
    task automatic transfer;
        input [31:0] address,data;
        input wr;
        input [2:0] burst,size;
        input [1:0] trans;
        input expected_error;
        reg [31:0] sampled;
        integer guard;
        begin
            @(negedge clk);HADDR=address;HSIZE=size;HBURST=burst;HWRITE=wr;HTRANS=trans;
            @(posedge clk);while(!HREADY) @(posedge clk);
            @(negedge clk);HTRANS=1;HWDATA=data;
            guard=0;@(posedge clk);
            while(!HREADY) begin @(posedge clk);guard=guard+1;if(guard>100)$fatal(1,"TIMEOUT: AHB data");end
            sampled=HRDATA;
            if(HRESP!==expected_error)$fatal(1,"FAIL: AHB response %h",address);
            if(!wr && !expected_error) begin
                case(size)
                    0: if(((sampled>>(8*address[1:0]))&255)!==(data&255)) $fatal(1,"FAIL: AHB byte lane");
                    1: if(((sampled>>(8*address[1:0]))&65535)!==(data&65535)) $fatal(1,"FAIL: AHB half lane");
                    2: if(sampled!==data)$fatal(1,"FAIL: AHB word");
                endcase
            end
            @(negedge clk);HTRANS=1;
            repeat(2) @(negedge clk);
        end
    endtask
    function [31:0] beat_address;
        input [31:0] start;
        input integer beat,size,burst,n;
        integer span,base;
        begin
            span=n*(1<<size);base=(start/span)*span;
            if(burst==2 || burst==4 || burst==6) beat_address=base+((start-base+beat*(1<<size))%span);
            else beat_address=start+beat*(1<<size);
        end
    endfunction
    integer bt,sz,n,k,a;
    initial begin
        HSEL=1;HADDR=0;HTRANS=0;HWRITE=0;HSIZE=2;HBURST=0;HPROT=0;HWDATA=0;err_addr=32'hffffffff;
        repeat(5) @(negedge clk);rst_n=1;
        for(bt=0;bt<8;bt=bt+1) for(sz=0;sz<3;sz=sz+1) begin
            n=bt==0?1:bt==1?3:bt<4?4:bt<6?8:16;
            for(k=0;k<n;k=k+1) begin
                a=beat_address(32'h600+bt*128+(1<<sz),k,sz,bt,n);
                transfer(a,32'h55555555+k*32'h01010101,1,bt,sz,k==0?2:3,0);
            end
            for(k=0;k<n;k=k+1) begin
                a=beat_address(32'h600+bt*128+(1<<sz),k,sz,bt,n);
                transfer(a,32'h55555555+k*32'h01010101,0,bt,sz,k==0?2:3,0);
            end
        end
        $display("COV|ahb|size_burst_matrix");
        err_addr=32'h500;
        transfer(32'h500,32'h22222222,1,0,2,2,1);
        transfer(32'h500,0,0,0,2,2,1);
        err_addr=32'hffffffff;
        transfer(32'h401,0,1,0,1,2,1);
        transfer(32'h402,0,0,0,2,2,1);
        transfer(32'h400,0,0,0,3,2,1);
        $display("COV|ahb|invalid_alignment_size");
        transfer(32'h404,32'h12345678,1,0,2,2,0);
        transfer(32'h404,32'h12345678,0,0,2,2,0);
        if(errors)$fatal(1,"FAIL: AHB protocol monitor");
        $display("===== PASS: AHB all HBURST x HSIZE, BUSY, stalls, errors =====");$finish;
    end
    initial begin #5000000;$fatal(1,"TIMEOUT: AHB phase5");end
endmodule
