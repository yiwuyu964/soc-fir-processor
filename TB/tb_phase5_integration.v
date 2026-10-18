`timescale 1ns/1ps
module tb_phase5_integration;
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    phase5_fabric dut(.clk(clk),.rst_n(rst_n));
    wire [191:0] dma_status_flat=dut.u_dma.eng_status;
    localparam NTAP=82, NSAMP=256, NEXP=NSAMP+NTAP-1, NRESULT=NEXP+1;
    reg [15:0] coeff[0:NTAP-1], stim[0:NSAMP-1], golden[0:NEXP-1];
    reg [31:0] q;
    integer i,ch,seed=1;
    // Check continuously so reset cannot erase earlier protocol violations.
    always @(negedge clk) if(rst_n &&
        (dut.err_cpu!==0 || dut.err_dma!==0 || dut.err_fir!==0))
        $fatal(1,"FAIL: integration AXI protocol violation");
    task hit; input [639:0] key; begin $display("COV|integration|%0s",key);end endtask
    task automatic configure;
        input integer channel;
        input [31:0] src,dst,len,ctrl;
        reg [31:0] base;
        begin
            base=32'h40001000+channel*16;
            dut.cpu.write32(base,src);dut.cpu.write32(base+4,dst);
            dut.cpu.write32(base+8,len);dut.cpu.write32(base+12,ctrl);
        end
    endtask
    task automatic wait_channel;
        input integer channel;
        input fail_expected;
        reg [31:0] status;
        integer guard;
        begin
            status=0;guard=0;
            while(!status[31] && !status[29] && guard<5000) begin
                dut.cpu.read32(32'h4000100c+channel*16,status);guard=guard+1;
            end
            if(status[30] || status[29]!==fail_expected || status[31]===fail_expected || guard>=5000)
                $fatal(1,"FAIL: channel %d status=%h",channel,status);
        end
    endtask
    initial begin
        if($value$plusargs("seed=%d",seed)) begin end
        dut.cpu.stalls=1+(seed%5);
        $readmemh("fir/coeffs.hex",coeff);$readmemh("fir/stim.hex",stim);$readmemh("fir/exp.hex",golden);
        repeat(5) @(negedge clk);rst_n=1;
        repeat(3) @(negedge clk);
        // Program coefficients through the interconnect, never by backdoor.
        for(i=0;i<NTAP;i=i+1) begin dut.cpu.tx[i]=coeff[i];dut.cpu.strobes[i]=15;end
        dut.cpu.write(32'h40000100,NTAP-1,2,1,0);
        dut.cpu.write32(32'h40000000,1);
        // 256 samples + 82 zeros = leading zero + 337 full-convolution results.
        for(i=0;i<NRESULT;i=i+1) dut.cpu.write32(32'hf00+4*i,i<NSAMP ? {16'b0,stim[i]} : 0);
        for(i=0;i<32;i=i+1) dut.cpu.write32(32'h5000+4*i,32'ha55a0000+i);
        configure(0,32'hf00,32'h40000004,NRESULT,3);
        configure(2,32'h5000,32'h6000,32,7);
        fork
            begin
                for(integer k=0;k<24;k=k+1) begin
                    dut.cpu.write32(32'h7000+4*k,32'h12340000+k);
                    dut.cpu.read32(32'h7000+4*k,q);
                    if(q!==32'h12340000+k)$fatal(1,"FAIL: CPU/DMA arbitration data corruption");
                end
            end
        join
        wait_channel(0,0);wait_channel(2,0);
        repeat(10) @(negedge clk);
        dut.cpu.read32(32'h4000000c,q);
        if(q[31:16]!==NRESULT || q[3]) $fatal(1,"FAIL: FIR result count/overflow %h",q);
        configure(1,32'h40000008,32'h2ff0,NRESULT,5);
        wait_channel(1,0);
        for(i=0;i<NRESULT;i=i+1) begin
            dut.cpu.read32(32'h2ff0+4*i,q);
            if(q[15:0] !== (i==0 ? 16'd0 : golden[i-1]))
                $fatal(1,"FAIL: FIR/DMA end-to-end sample=%d got=%h",i,q);
        end
        for(i=0;i<32;i=i+1) begin dut.cpu.read32(32'h6000+4*i,q);if(q!==32'ha55a0000+i)$fatal(1,"FAIL: parallel copy");end
        hit("fir_dma_golden_338");hit("parallel_cpu_dma");hit("dma_4k_split");
        // All six engines contend for the real SRAM port.
        for(ch=0;ch<6;ch=ch+1) begin
            for(i=0;i<32;i=i+1) dut.cpu.write32(32'h8000+ch*256+i*4,32'hf0000000+ch*256+i);
            configure(ch,32'h8000+ch*256,32'ha000+ch*256,32,6);
        end
        for(ch=0;ch<6;ch=ch+1) dut.cpu.write32(32'h4000100c+ch*16,7);
        for(ch=0;ch<6;ch=ch+1)
            if(!dma_status_flat[ch*32])$fatal(1,"FAIL: six-channel concurrency stimulus");
        for(ch=0;ch<6;ch=ch+1) wait_channel(ch,0);
        for(ch=0;ch<6;ch=ch+1) for(i=0;i<32;i=i+1) begin
            dut.cpu.read32(32'ha000+ch*256+i*4,q);
            if(q!==32'hf0000000+ch*256+i)$fatal(1,"FAIL: six channel scoreboard");
        end
        hit("six_channels");
        configure(3,32'h60000000,32'ha000,2,7);wait_channel(3,1);
        configure(4,32'h8000,32'h60000000,2,7);wait_channel(4,1);
        if(!dut.dma_irq_err)$fatal(1,"FAIL: DMA global error IRQ");
        hit("dma_read_decerr");hit("dma_write_decerr");
        configure(5,32'h8000,32'ha000,0,7);wait_channel(5,0);
        hit("zero_length");
        dut.cpu.read(32'h60000000,3,2,1,3);
        dut.cpu.read(32'h20000000,0,2,1,3);
        hit("decode_errors");
        configure(3,32'h8000,32'ha000,256,7);
        repeat(5) @(negedge clk);rst_n=0;
        repeat(5) @(negedge clk);rst_n=1;
        repeat(3) @(negedge clk);
        dut.cpu.write32(32'h9000,32'hcafebabe);dut.cpu.read32(32'h9000,q);
        if(q!==32'hcafebabe || dut.dma_irq_err || |dut.dma_irq_done)$fatal(1,"FAIL: reset recovery");
        hit("reset_active_recovery");
        dut.cpu.tx[0]=32'h8000;dut.cpu.tx[1]=32'ha000;dut.cpu.tx[2]=4;
        dut.cpu.strobes[0]=15;dut.cpu.strobes[1]=15;dut.cpu.strobes[2]=15;
        dut.cpu.write(32'h40001000,2,2,1,0);
        dut.cpu.read(32'h4000100c,3,2,0,0);
        for(i=0;i<4;i=i+1) if(dut.cpu.rx[i]!==0)$fatal(1,"FAIL: DMA config burst status");
        hit("dma_config_bursts");
        if(dut.err_cpu!==0 || dut.err_dma!==0 || dut.err_fir!==0)$fatal(1,"FAIL: protocol checker");
        $display("===== PASS: CPU-free FIR+DMA+interconnect seed=%0d =====",seed);$finish;
    end
    initial begin #10000000;$fatal(1,"TIMEOUT: CPU-free integration");end
endmodule
