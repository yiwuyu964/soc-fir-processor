`timescale 1ns/1ps
module tb_sram_offset;
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    reg av=0,wv=0,rv=0,rr=0;
    reg [31:0] a=0,d=0;
    wire awready,wready,bvalid,arready,rvalid,rlast;
    wire [31:0] q;
    wire [1:0] br,rresp;
    axi_sram #(.SRAM_BYTES(64),.BASE_ADDR(32'h1004)) dut(
        .clk(clk),.rst_n(rst_n),
        .s_axi_awid(4'd3),.s_axi_awaddr(a),.s_axi_awlen(8'd0),
        .s_axi_awsize(3'd2),.s_axi_awburst(2'b01),.s_axi_awvalid(av),.s_axi_awready(awready),
        .s_axi_wdata(d),.s_axi_wstrb(4'hf),.s_axi_wlast(1'b1),.s_axi_wvalid(wv),.s_axi_wready(wready),
        .s_axi_bid(),.s_axi_bresp(br),.s_axi_bvalid(bvalid),.s_axi_bready(1'b1),
        .s_axi_arid(4'd3),.s_axi_araddr(a),.s_axi_arlen(8'd0),
        .s_axi_arsize(3'd2),.s_axi_arburst(2'b01),.s_axi_arvalid(rv),.s_axi_arready(arready),
        .s_axi_rid(),.s_axi_rdata(q),.s_axi_rresp(rresp),.s_axi_rlast(rlast),
        .s_axi_rvalid(rvalid),.s_axi_rready(rr));
    integer i;
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        for(i=0;i<2;i=i+1) begin
            @(negedge clk);a=32'h1004+i*60;d=32'h1234+i;av=1;
            @(posedge clk);while(!awready) @(posedge clk);
            @(negedge clk);av=0;wv=1;
            @(posedge clk);while(!wready) @(posedge clk);
            @(negedge clk);wv=0;
            @(posedge clk);while(!bvalid) @(posedge clk);
            if(br!==0) $fatal(1,"FAIL: relocated SRAM write response");
            @(negedge clk);
            if(dut.mem[i*15]!==32'h1234+i) $fatal(1,"FAIL: SRAM index must subtract BASE_ADDR");
            rv=1;
            @(posedge clk);while(!arready) @(posedge clk);
            @(negedge clk);rv=0;
            wait(rvalid);
            repeat(3) begin
                @(negedge clk);
                if(q!==32'h1234+i || rresp!==0 || !rlast) $fatal(1,"FAIL: relocated SRAM read");
            end
            rr=1;@(negedge clk);rr=0;
        end
        $display("===== PASS: SRAM base-relative indexing and stalled reads =====");
        $finish;
    end
    initial begin #100000;$fatal(1,"TIMEOUT: SRAM base offset");end
endmodule
