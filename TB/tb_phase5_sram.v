`timescale 1ns/1ps
module tb_phase5_sram;
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    wire [3:0] awid;
    wire [31:0] awaddr;
    wire [7:0] awlen;
    wire [2:0] awsize;
    wire [1:0] awburst;
    wire awvalid;
    wire awready;
    wire [31:0] wdata;
    wire [3:0] wstrb;
    wire wlast;
    wire wvalid;
    wire wready;
    wire [3:0] bid;
    wire [1:0] bresp;
    wire bvalid;
    wire bready;
    wire [3:0] arid;
    wire [31:0] araddr;
    wire [7:0] arlen;
    wire [2:0] arsize;
    wire [1:0] arburst;
    wire arvalid;
    wire arready;
    wire [3:0] rid;
    wire [31:0] rdata;
    wire [1:0] rresp;
    wire rlast;
    wire rvalid;
    wire rready;
    phase5_axi_master #(.NAME("sram"),.ID(3)) master(.clk(clk),.rst_n(rst_n),.awid(awid),
        .awaddr(awaddr),
        .awlen(awlen),
        .awsize(awsize),
        .awburst(awburst),
        .awvalid(awvalid),
        .awready(awready),
        .wdata(wdata),
        .wstrb(wstrb),
        .wlast(wlast),
        .wvalid(wvalid),
        .wready(wready),
        .bid(bid),
        .bresp(bresp),
        .bvalid(bvalid),
        .bready(bready),
        .arid(arid),
        .araddr(araddr),
        .arlen(arlen),
        .arsize(arsize),
        .arburst(arburst),
        .arvalid(arvalid),
        .arready(arready),
        .rid(rid),
        .rdata(rdata),
        .rresp(rresp),
        .rlast(rlast),
        .rvalid(rvalid),
        .rready(rready));
    axi_sram dut(.clk(clk),.rst_n(rst_n),.s_axi_awid(awid),
        .s_axi_awaddr(awaddr),
        .s_axi_awlen(awlen),
        .s_axi_awsize(awsize),
        .s_axi_awburst(awburst),
        .s_axi_awvalid(awvalid),
        .s_axi_awready(awready),
        .s_axi_wdata(wdata),
        .s_axi_wstrb(wstrb),
        .s_axi_wlast(wlast),
        .s_axi_wvalid(wvalid),
        .s_axi_wready(wready),
        .s_axi_bid(bid),
        .s_axi_bresp(bresp),
        .s_axi_bvalid(bvalid),
        .s_axi_bready(bready),
        .s_axi_arid(arid),
        .s_axi_araddr(araddr),
        .s_axi_arlen(arlen),
        .s_axi_arsize(arsize),
        .s_axi_arburst(arburst),
        .s_axi_arvalid(arvalid),
        .s_axi_arready(arready),
        .s_axi_rid(rid),
        .s_axi_rdata(rdata),
        .s_axi_rresp(rresp),
        .s_axi_rlast(rlast),
        .s_axi_rvalid(rvalid),
        .s_axi_rready(rready));
    phase5_axi_coverage #(.NAME("sram")) cov(.clk(clk),.rst_n(rst_n),.awaddr(awaddr),
        .araddr(araddr),
        .awlen(awlen),
        .arlen(arlen),
        .awsize(awsize),
        .arsize(arsize),
        .awburst(awburst),
        .arburst(arburst),
        .bresp(bresp),
        .rresp(rresp),
        .awvalid(awvalid),
        .awready(awready),
        .wvalid(wvalid),
        .wready(wready),
        .bvalid(bvalid),
        .bready(bready),
        .arvalid(arvalid),
        .arready(arready),
        .rvalid(rvalid),
        .rready(rready));
    task hit; input [639:0] key; begin $display("COV|sram|%0s",key);end endtask
    integer sz,bt,i,n,lane,mask,addr;
    reg [31:0] expected;
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        for(sz=0;sz<3;sz=sz+1) for(bt=0;bt<2;bt=bt+1) begin
            for(i=0;i<16;i=i+1) begin master.tx[i]=32'h11223344+i;master.strobes[i]=15;end
            addr=32'h200+sz*128+bt*64;
            master.write(addr,3,sz,bt,0);
            master.read(addr,3,sz,bt,0);
            // Word transfers permit whole-word comparison; narrow lane checks follow.
            if(sz==2) for(i=0;i<4;i=i+1) begin
                expected=32'h11223344+(bt==0?3:i);
                if(master.rx[i]!==expected) $fatal(1,"FAIL: SRAM burst scoreboard");
            end
        end
        hit("size_burst_matrix");
        for(i=0;i<256;i=i+1) begin master.tx[i]=32'habc00000+i;master.strobes[i]=15;end
        master.write(32'h1000,255,2,1,0);master.read(32'h1000,255,2,1,0);
        for(i=0;i<256;i=i+1) if(master.rx[i]!==32'habc00000+i)$fatal(1,"FAIL: max INCR scoreboard");
        master.write(32'h2000,15,2,0,0);master.read(32'h2000,15,2,0,0);
        hit("max_lengths");
        master.write32(32'h300,32'hdeadbeef);
        for(lane=0;lane<4;lane=lane+1) begin
            master.tx[0]=32'h5a5a5a5a;master.strobes[0]=1<<lane;
            master.write(32'h300+lane,0,0,1,0);
        end
        master.read32(32'h300,expected);
        if(expected!==32'h5a5a5a5a)$fatal(1,"FAIL: byte lane scoreboard");
        master.strobes[0]=0;master.tx[0]=0;
        master.write(32'h300,0,2,1,0);master.read32(32'h300,expected);
        if(expected!==32'h5a5a5a5a)$fatal(1,"FAIL: zero WSTRB side effect");
        hit("byte_lanes_zero_strobe");
        // Legal unaligned AXI INCR: first address 0x301, next address 0x304.
        master.tx[0]=32'h88776600;master.strobes[0]=14;
        master.tx[1]=32'hccbbaa99;master.strobes[1]=15;
        master.write(32'h301,1,2,1,0);
        master.read(32'h300,1,2,1,0);
        if(master.rx[0]!==32'h8877665a || master.rx[1]!==32'hccbbaa99)
            $fatal(1,"FAIL: unaligned AXI INCR must align subsequent beats");
        master.read(32'h301,1,2,1,0);
        if(master.rx[1]!==32'hccbbaa99)$fatal(1,"FAIL: unaligned read stepping");
        hit("unaligned_incr");
        master.write32(32'hffc,32'h12345678);
        master.tx[0]=0;master.tx[1]=0;master.strobes[0]=15;
        master.write(32'hffc,1,2,1,2);
        master.read(32'hffc,1,2,1,2);
        master.read32(32'hffc,expected);
        if(expected!==32'h12345678)$fatal(1,"FAIL: rejected burst changed SRAM");
        hit("cross_4k_no_side_effect");
        master.write(32'h10000,0,2,1,3);master.read(32'h10000,0,2,1,3);
        master.write(32'h400,3,2,2,2);master.read(32'h400,3,2,2,2);
        master.write(32'h400,0,2,3,2);master.read(32'h400,0,2,3,2);
        master.write(32'h400,0,3,1,2);master.read(32'h400,0,3,1,2);
        master.write(32'h400,16,2,0,2);master.read(32'h400,16,2,0,2);
        hit("unsupported_and_out_of_range");
        master.write32(32'hfffc,32'hcafebabe);master.read32(32'hfffc,expected);
        if(expected!==32'hcafebabe)$fatal(1,"FAIL: final SRAM word");
        master.tx[0]=32'h55000000;master.strobes[0]=8;
        master.write(32'hffff,0,2,1,0);master.read(32'hffff,0,2,1,0);
        if(master.rx[0]!==32'h55febabe)$fatal(1,"FAIL: unaligned final-byte access range");
        hit("last_word");
        $display("===== PASS: phase5 SRAM directed boundaries and scoreboard =====");$finish;
    end
    initial begin #5000000;$fatal(1,"TIMEOUT: SRAM phase5");end
endmodule
