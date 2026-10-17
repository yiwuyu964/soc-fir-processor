`timescale 1ns/1ps
module phase5_axi_coverage #(parameter NAME="axi")(
    input wire clk,rst_n,
    input wire [31:0] awaddr,araddr,
    input wire [7:0] awlen,arlen,
    input wire [2:0] awsize,arsize,
    input wire [1:0] awburst,arburst,bresp,rresp,
    input wire awvalid,awready,wvalid,wready,bvalid,bready,
    input wire arvalid,arready,rvalid,rready
);
    // The same accepted transactions feed native covergroups and portable events.
`ifdef PHASE5_NATIVE_COVERAGE
    covergroup bus_cg @(posedge clk);
        option.per_instance=1;
        write_size: coverpoint awsize iff(rst_n && awvalid && awready) {bins byte_access={0};bins half={1};bins word_access={2};bins oversized={[3:7]};}
        read_size: coverpoint arsize iff(rst_n && arvalid && arready) {bins byte_access={0};bins half={1};bins word_access={2};bins oversized={[3:7]};}
        write_burst: coverpoint awburst iff(rst_n && awvalid && awready) {bins fixed_access={0};bins incr={1};bins wrap_access={2};bins reserved={3};}
        read_burst: coverpoint arburst iff(rst_n && arvalid && arready) {bins fixed_access={0};bins incr={1};bins wrap_access={2};bins reserved={3};}
        write_length: coverpoint awlen iff(rst_n && awvalid && awready) {bins single={0};bins short_burst={[1:14]};bins sixteen={15};bins long_burst={[16:254]};bins max_length={255};}
        read_length: coverpoint arlen iff(rst_n && arvalid && arready) {bins single={0};bins short_burst={[1:14]};bins sixteen={15};bins long_burst={[16:254]};bins max_length={255};}
        write_alignment: coverpoint ((awaddr & ((1<<awsize)-1))==0) iff(rst_n && awvalid && awready);
        read_alignment: coverpoint ((araddr & ((1<<arsize)-1))==0) iff(rst_n && arvalid && arready);
        write_response: coverpoint bresp iff(rst_n && bvalid && bready) {bins okay={0};bins slverr={2};bins decerr={3};}
        read_response: coverpoint rresp iff(rst_n && rvalid && rready) {bins okay={0};bins slverr={2};bins decerr={3};}
        aw_wait: coverpoint awready iff(rst_n && awvalid);
        w_wait: coverpoint wready iff(rst_n && wvalid);
        b_wait: coverpoint bready iff(rst_n && bvalid);
        ar_wait: coverpoint arready iff(rst_n && arvalid);
        r_wait: coverpoint rready iff(rst_n && rvalid);
        size_burst: cross write_size,write_burst;
    endgroup
    bus_cg cov=new;
    final $display("NATIVE_COV|%0s|%0.3f",NAME,cov.get_inst_coverage());
`endif
    always @(posedge clk) if(rst_n) begin
        if(awvalid && awready) begin
            $display("COV|%0s|aw.size.%0d",NAME,awsize);
            $display("COV|%0s|aw.burst.%0d",NAME,awburst);
            $display("COV|%0s|aw.len.%0d",NAME,awlen);
            $display("COV|%0s|aw.aligned.%0d",NAME,(awaddr & ((1<<awsize)-1))==0);
        end
        if(arvalid && arready) begin
            $display("COV|%0s|ar.size.%0d",NAME,arsize);
            $display("COV|%0s|ar.burst.%0d",NAME,arburst);
            $display("COV|%0s|ar.len.%0d",NAME,arlen);
            $display("COV|%0s|ar.aligned.%0d",NAME,(araddr & ((1<<arsize)-1))==0);
        end
        if(bvalid && bready) $display("COV|%0s|b.resp.%0d",NAME,bresp);
        if(rvalid && rready) $display("COV|%0s|r.resp.%0d",NAME,rresp);
        if(awvalid && !awready) $display("COV|%0s|stall.aw",NAME);
        if(wvalid && !wready) $display("COV|%0s|stall.w",NAME);
        if(bvalid && !bready) $display("COV|%0s|stall.b",NAME);
        if(arvalid && !arready) $display("COV|%0s|stall.ar",NAME);
        if(rvalid && !rready) $display("COV|%0s|stall.r",NAME);
    end
endmodule
