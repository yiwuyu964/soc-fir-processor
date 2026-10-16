`timescale 1ns/1ps
module tb_soc_bus;
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    wire tx;
    soc_top dut(.clk(clk),.rst_n(rst_n),.uart_rxd(1'b1),.uart_txd(tx));
    reg awvalid=0,wvalid=0,arvalid=0;
    reg [31:0] awaddr=0,wdata=0,araddr=0;
    reg bready=0,rready=0;
    reg [31:0] q;
    reg [1:0] resp;
    integer i,guard;
    task wr;
        input [31:0] addr,data;
        begin
            @(negedge clk);awaddr=addr;awvalid=1;wdata=data;wvalid=1;bready=1;
            @(posedge clk);while(!dut.b_awready) @(posedge clk);
            @(negedge clk);awvalid=0;
            @(posedge clk);while(!dut.b_wready) @(posedge clk);
            @(negedge clk);wvalid=0;
            @(posedge clk);while(!dut.b_bvalid) @(posedge clk);
            if(dut.b_bresp!==0) $fatal(1,"FAIL: write %h",addr);
            @(negedge clk);bready=0;
        end
    endtask
    task rd;
        input [31:0] addr;
        begin
            @(negedge clk);araddr=addr;arvalid=1;rready=1;
            @(posedge clk);while(!dut.b_arready) @(posedge clk);
            @(negedge clk);arvalid=0;
            @(posedge clk);while(!dut.b_rvalid) @(posedge clk);
            q=dut.b_rdata;resp=dut.b_rresp;
            @(negedge clk);rready=0;
        end
    endtask
    initial begin
        // Isolate the CPU and drive its AXI port; DMA remains real RTL.
        force dut.h_htrans=2'b00;
        force dut.b_awvalid=awvalid; force dut.b_awaddr=awaddr;
        force dut.b_awid=0;force dut.b_awlen=0;force dut.b_awsize=2;force dut.b_awburst=1;
        force dut.b_wvalid=wvalid;force dut.b_wdata=wdata;force dut.b_wstrb=15;force dut.b_wlast=1;
        force dut.b_bready=bready;
        force dut.b_arvalid=arvalid;force dut.b_araddr=araddr;
        force dut.b_arid=0;force dut.b_arlen=0;force dut.b_arsize=2;force dut.b_arburst=1;
        force dut.b_rready=rready;
        repeat(4) @(negedge clk);rst_n=1;
        repeat(4) @(negedge clk);
        rd(32'h20000000);
        if(resp!==3) $fatal(1,"FAIL: reserved m2 must DECERR");
        // RXDATA -> SRAM: DMA's RID must survive the APB bridge.
        wr(32'h40001000,32'h40002008);
        wr(32'h40001004,32'h800);
        wr(32'h40001008,1);
        wr(32'h4000100c,5);
        guard=0;q=0;
        while(!q[31] && guard<100) begin rd(32'h4000100c);guard=guard+1;end
        if(!q[31] || q[29]) $fatal(1,"FAIL: DMA APB read completion");
        rd(32'h800);
        if(q!==0 || resp!==0) $fatal(1,"FAIL: DMA RXDATA destination");
        // SRAM -> UART DATA: DMA's BID must also survive.
        wr(32'h804,32'h55);
        wr(32'h40001010,32'h804);
        wr(32'h40001014,32'h40002000);
        wr(32'h40001018,1);
        wr(32'h4000101c,3);
        guard=0;q=0;
        while(!q[31] && guard<100) begin rd(32'h4000101c);guard=guard+1;end
        if(!q[31] || q[29]) $fatal(1,"FAIL: DMA APB write completion");
        repeat(120) @(negedge clk);
        if(!tx) $fatal(1,"FAIL: UART did not finish");
        $display("===== PASS: reserved DECERR and DMA SRAM/UART both directions =====");
        $finish;
    end
    initial begin #100000; $fatal(1,"TIMEOUT: SoC DMA/APB routing"); end
endmodule
