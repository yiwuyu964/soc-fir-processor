`timescale 1ns/1ps
module tb_uart_apb_edges;
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    reg psel=0,penable=0,pwrite=0;
    reg [31:0] paddr=0,pwdata=0;
    reg [3:0] pstrb=15;
    wire [31:0] prdata;
    wire pready,pslverr,txd;
    uart_apb #(.CLK_FREQ(100),.BAUD(5)) dut(
        .clk(clk),.rst_n(rst_n),.psel(psel),.penable(penable),
        .pwrite(pwrite),.paddr(paddr),.pwdata(pwdata),.pstrb(pstrb),
        .pprot(3'd0),.prdata(prdata),.pready(pready),.pslverr(pslverr),
        .rxd(1'b1),.txd(txd));
    integer starts=0;
    always @(posedge clk) if(rst_n && dut.tx_start) starts=starts+1;
    task access;
        input wr;
        input [31:0] addr,data;
        input [3:0] strb;
        input error;
        begin
            // Keep PSEL asserted between requests, as allowed by APB.
            @(negedge clk);psel=1;penable=0;pwrite=wr;paddr=addr;pwdata=data;pstrb=strb;
            @(negedge clk);penable=1;
            @(posedge clk);while(!pready) @(posedge clk);
            if(pslverr!==error) $fatal(1,"FAIL: APB response addr=%h",addr);
            @(negedge clk);penable=0;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        access(1,0,8'h55,0,0);
        if(starts!=0) $fatal(1,"FAIL: zero-strobe write sent data");
        access(1,0,8'h55,1,0);
        access(1,0,8'h99,1,1);
        // Failed busy writes must not queue a transmission.
        if(starts!=1) $fatal(1,"FAIL: busy write generated start");
        access(0,4,0,15,0);
        if(prdata[0]!==1) $fatal(1,"FAIL: consecutive APB setup not recognized");
        access(0,8,0,15,0);
        if(prdata!==0) $fatal(1,"FAIL: empty RXDATA must read zero");
        access(0,0,0,15,0);
        if(prdata!==0) $fatal(1,"FAIL: DATA read must return zero");
        @(negedge clk);psel=0;
        repeat(220) @(negedge clk);
        if(starts!=1 || !txd) $fatal(1,"FAIL: unexpected transmission");
        $display("===== PASS: APB consecutive setup, strobe, busy and empty RX =====");
        $finish;
    end
    initial begin #100000; $fatal(1,"TIMEOUT: UART APB edges"); end
endmodule
