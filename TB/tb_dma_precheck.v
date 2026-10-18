`timescale 1ns/1ps
// Compare every LEN and legal SIZE at byte starts around the register bank
// against the original per-beat algorithm, including address overflow.
module tb_dma_precheck;
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    phase5_fabric dut(.clk(clk),.rst_n(rst_n));
    integer offset,len,size,burst,k,checks=0;
    reg [31:0] ak;
    reg want,got;
    task verify(input [31:0] addr,input [1:0] b,input [7:0] l,input [2:0] sz);
        begin
            want=1;
            for(k=0;k<=l;k=k+1) begin
                ak=(b==0) ? addr : addr+(k*(1<<sz));
                if(!(ak[31:12]==20'h40001 && ak[11:7]==0 && ak[6:4]<6)) want=0;
            end
            got=dut.u_dma.u_regs.f_wburst_ok(addr,b,l,sz);
            if(got!==want) $fatal(1,"FAIL: precheck a=%h b=%d len=%d size=%d",addr,b,l,sz);
            checks=checks+1;
        end
    endtask
    initial begin
        for(offset=-4;offset<104;offset=offset+1)
            for(len=0;len<256;len=len+1)
                for(size=0;size<3;size=size+1)
                    for(burst=0;burst<2;burst=burst+1)
                        verify(32'h40001000+offset,burst,len,size);
        verify(32'hfffffffc,1,255,2);
        verify(32'h40000fff,1,255,2);
        verify(32'h4000105f,1,1,0);
        $display("===== PASS: DMA constant-time burst precheck equals original per-beat algorithm: %0d cases =====",checks);
        $finish;
    end
endmodule
