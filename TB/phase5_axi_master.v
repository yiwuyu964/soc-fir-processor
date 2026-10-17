`timescale 1ns/1ps
// One outstanding transaction per direction; writes and reads may run in parallel.
module phase5_axi_master #(parameter NAME="cpu", parameter ID=0)(
    input wire clk, rst_n,
    output reg [3:0] awid, arid,
    output reg [31:0] awaddr, araddr,
    output reg [7:0] awlen, arlen,
    output reg [2:0] awsize, arsize,
    output reg [1:0] awburst, arburst,
    output reg awvalid, arvalid,
    input wire awready, arready,
    output reg [31:0] wdata,
    output reg [3:0] wstrb,
    output reg wlast, wvalid,
    input wire wready,
    input wire [3:0] bid,rid,
    input wire [1:0] bresp,rresp,
    input wire bvalid,rvalid,rlast,
    input wire [31:0] rdata,
    output reg bready,rready
);
    initial begin awid=ID;arid=ID;awaddr=0;araddr=0;awlen=0;arlen=0;awsize=2;arsize=2;awburst=1;arburst=1;awvalid=0;arvalid=0;wdata=0;wstrb=15;wlast=0;wvalid=0;bready=0;rready=0; end
    reg [31:0] tx[0:255], rx[0:255];
    reg [3:0] strobes[0:255];
    reg [1:0] responses[0:255];
    integer stalls=3;
    integer j;
    initial for(j=0;j<256;j=j+1) begin tx[j]=0;strobes[j]=15;end
    task automatic write;
        input [31:0] addr;
        input [7:0] len;
        input [2:0] size;
        input [1:0] burst, expected;
        integer i,guard;
        begin
            @(negedge clk);
            awaddr=addr;awlen=len;awsize=size;awburst=burst;awvalid=1;bready=0;
            guard=0;
            @(posedge clk);
            while(!awready) begin @(posedge clk);guard=guard+1;if(guard>20000)$fatal(1,"TIMEOUT: %s AW",NAME);end
            @(negedge clk);awvalid=0;
            for(i=0;i<=len;i=i+1) begin
                repeat(i%3) @(negedge clk);
                wdata=tx[i];wstrb=strobes[i];wlast=(i==len);wvalid=1;
                guard=0;@(posedge clk);
                while(!wready) begin @(posedge clk);guard=guard+1;if(guard>20000)$fatal(1,"TIMEOUT: %s W",NAME);end
                @(negedge clk);wvalid=0;
            end
            wait(bvalid);
            repeat(stalls) @(negedge clk);
            if(bresp!==expected || bid!==ID) $fatal(1,"FAIL: %s B addr=%h resp=%b expected=%b id=%d",NAME,addr,bresp,expected,bid);
            bready=1;@(negedge clk);bready=0;
        end
    endtask
    task automatic read;
        input [31:0] addr;
        input [7:0] len;
        input [2:0] size;
        input [1:0] burst,expected;
        integer i,guard;
        begin
            @(negedge clk);
            araddr=addr;arlen=len;arsize=size;arburst=burst;arvalid=1;rready=0;
            guard=0;@(posedge clk);
            while(!arready) begin @(posedge clk);guard=guard+1;if(guard>20000)$fatal(1,"TIMEOUT: %s AR",NAME);end
            @(negedge clk);arvalid=0;
            for(i=0;i<=len;i=i+1) begin
                repeat(stalls) @(negedge clk);
                rready=1;guard=0;@(posedge clk);
                while(!rvalid) begin @(posedge clk);guard=guard+1;if(guard>20000)$fatal(1,"TIMEOUT: %s R",NAME);end
                rx[i]=rdata;responses[i]=rresp;
                if(rresp!==expected || rid!==ID || rlast!==(i==len))
                    $fatal(1,"FAIL: %s R addr=%h beat=%d resp=%b expected=%b",NAME,addr,i,rresp,expected);
                @(negedge clk);rready=0;
            end
        end
    endtask
    task automatic write32;
        input [31:0] addr,data;
        begin tx[0]=data;strobes[0]=15;write(addr,0,2,1,0);end
    endtask
    task automatic read32;
        input [31:0] addr;
        output [31:0] data;
        begin read(addr,0,2,1,0);data=rx[0];end
    endtask
endmodule

