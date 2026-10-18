`timescale 1ns/1ps
// Independent direct convolution scoreboard. Instantiate the DEFAULT core:
// a regression to 81 taps must fail the isolated final-tap impulse case.
module tb_fir_asymmetric;
    localparam N=82, LAT=5;
    reg clk=0, rst_n=0, flush=0, en=0, coef_we=0;
    reg signed [15:0] din=0, coef_din=0;
    reg [6:0] coef_idx=0;
    wire signed [15:0] dout;
    wire dout_v;
    fir_core dut(.clk(clk),.rst_n(rst_n),.flush(flush),.en(en),.din(din),
        .coef_idx(coef_idx),.coef_din(coef_din),.coef_we(coef_we),.dout(dout),.dout_v(dout_v));
    always #5 clk=~clk;
    reg signed [15:0] h[0:N-1], history[0:N-1], expected[0:4095];
    reg [LAT-1:0] valid_model=0;
    reg [31:0] rng=32'h5a170082;
    integer wr=0,rd=0,checks=0,i,k,mode;
    reg signed [63:0] acc,scaled;

    always @(posedge clk) begin
        if(!rst_n || flush) valid_model=0;
        else valid_model={valid_model[LAT-2:0],en};
        #1;
        if(rst_n) begin
            if(dout_v !== valid_model[LAT-1]) $fatal(1,"FAIL: latency/valid bubbles");
            if(dout_v) begin
                if(rd>=wr || dout !== expected[rd])
                    $fatal(1,"FAIL: asymmetric sample %d got=%d expected=%d",rd,dout,expected[rd]);
                rd=rd+1;checks=checks+1;
            end
        end
    end
    task write_coef(input integer idx, input signed [15:0] value);
        begin
            @(negedge clk);coef_we=1;coef_idx=idx;coef_din=value;
            @(negedge clk);coef_we=0;h[idx]=value;
        end
    endtask
    task clear_history;
        begin
            @(negedge clk);flush=1;en=0;
            for(integer j=0;j<N;j=j+1) history[j]=0;
            wr=0;rd=0;
            @(negedge clk);flush=0;
        end
    endtask
    task sample(input signed [15:0] value,input enabled);
        begin
            @(negedge clk);en=enabled;din=value;
            if(enabled) begin
                acc=0;
                for(integer j=0;j<N;j=j+1) acc=acc+$signed(history[j])*$signed(h[j]);
                scaled=acc >>> 15;
                expected[wr]=(scaled>32767) ? 16'sd32767 :
                             (scaled< -32768) ? -16'sd32768 : scaled;
                wr=wr+1;
                for(integer j=N-1;j>0;j=j-1) history[j]=history[j-1];
                history[0]=value;
            end
        end
    endtask
    task drain;
        begin
            sample(0,0);
            repeat(LAT+2) @(negedge clk);
            if(rd!=wr) $fatal(1,"FAIL: missing asymmetric results %d/%d",rd,wr);
        end
    endtask
    initial begin
        for(i=0;i<N;i=i+1) begin h[i]=0;history[i]=0;end
        repeat(3) @(negedge clk);rst_n=1;
        // h[81] alone: the 82nd coefficient is independently programmable.
        for(i=0;i<N;i=i+1) write_coef(i,0);
        write_coef(N-1,16384);
        clear_history;
        sample(12000,1);
        for(i=0;i<N+3;i=i+1) sample(0,1);
        drain;
        // All independent signed coefficients, continuous throughput and gaps.
        for(i=0;i<N;i=i+1) write_coef(i,((i*7919+1237)%8192)-4096);
        for(mode=0;mode<2;mode=mode+1) begin
            clear_history;
            for(i=0;i<300;i=i+1) begin
                rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
                sample($signed(rng[15:0]) >>> 2,(mode==0 || (i%5)!=2));
            end
            for(i=0;i<N;i=i+1) sample(0,1);
            drain;
        end
        // Change an asymmetric coefficient while the pipeline is active.
        clear_history;
        for(i=0;i<100;i=i+1) begin
            sample(1000,1);
            if(i==40) begin
                sample(0,0);
                write_coef(81,-12000);
            end
        end
        drain;
        // Cancel pending samples on flush; coefficients must survive.
        sample(999,1);sample(777,1);clear_history;
        for(i=0;i<N+4;i=i+1) sample(-1000,1);
        drain;
        $display("===== PASS: default 82 taps, final-tap impulse, arbitrary asymmetric coefficients, latency, throughput, gaps, live update and flush: %0d results =====",checks);
        $finish;
    end
    initial begin #200000; $fatal(1,"TIMEOUT: asymmetric FIR"); end
endmodule
