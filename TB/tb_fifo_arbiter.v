`timescale 1ns/1ps
module tb_fifo_arbiter;
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    reg [5:0] req=0;
    reg advance=0;
    wire [5:0] grant;
    axi_arbiter #(.N(6)) arb(clk,rst_n,req,advance,grant);
    reg wen=0, ren=0;
    reg [7:0] data=0;
    wire [7:0] q;
    wire full,empty;
    wire [1:0] count;
    sync_fifo #(.WIDTH(8),.DEPTH(3)) fifo(
        .clk(clk),.rst_n(rst_n),.clr(1'b0),.wen(wen),.wdata(data),
        .full(full),.ren(ren),.rdata(q),.empty(empty),.count(count));
    integer n,k;
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        // A new, higher-priority request must not replace a stalled winner.
        req=6'b100000;
        @(negedge clk); req=6'b100001;
        repeat(3) begin
            @(negedge clk);
            if(grant!==6'b100000) $fatal(1,"FAIL: stalled arbiter winner changed");
        end
        advance=1;
        @(negedge clk); advance=0; req=6'b111111;
        for(n=0;n<12;n=n+1) begin
            if(grant !== (6'b1 << (n%6))) $fatal(1,"FAIL: round-robin order %d",n);
            advance=1; @(negedge clk);
        end
        advance=0; req=0;
        // Repeat through many wraps with a non-power-of-two FIFO depth.
        for(n=0;n<5;n=n+1) begin
            for(k=0;k<3;k=k+1) begin wen=1;data=n*3+k; @(negedge clk); end
            wen=0;
            if(!full || count!=3) $fatal(1,"FAIL: FIFO full/count");
            for(k=0;k<3;k=k+1) begin
                if(q !== n*3+k) $fatal(1,"FAIL: FIFO wrap data");
                ren=1; @(negedge clk);
            end
            ren=0;
            if(!empty || count!=0) $fatal(1,"FAIL: FIFO empty/count");
        end
        wen=1;data=8'h41;@(negedge clk);wen=0;
        if(q!==8'h41)$fatal(1,"FAIL: FIFO simultaneous setup");
        wen=1;ren=1;data=8'h42;@(negedge clk);wen=0;ren=0;
        if(count!==1 || q!==8'h42)$fatal(1,"FAIL: FIFO simultaneous read/write");
        ren=1;@(negedge clk);ren=0;
        if(!empty)$fatal(1,"FAIL: FIFO simultaneous final count");
        $display("COV|arbiter|stalled_winner");
        $display("COV|arbiter|round_robin_all");
        $display("COV|fifo|non_power_two_wrap");
        $display("COV|fifo|simultaneous_read_write");
        $display("===== PASS: arbitration stability/fairness and depth-3 FIFO =====");
        $finish;
    end
    initial begin #100000; $fatal(1,"TIMEOUT: FIFO/arbiter"); end
endmodule
