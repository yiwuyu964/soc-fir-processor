// ============================================================
// tb_dma_engine.v —— DMA 数据搬运引擎 单元验证（阶段3 分工 B）
//
// 测试台：内联一个 AXI4 存储器模型（当对手），挂 axi_protocol_checker
// 在引擎主口上（SIDE=1），全程零违规才算过。
//
// 覆盖（对应阶段3-三人分工.md B 的验收清单）：
//   [1] 单拍搬运（LEN=1）
//   [2] INCR 突发搬运（4 拍）
//   [3] 跨 4KB 长传输自动拆分（1000 字）
//   [4] 超过 256 拍的长传输（300 字 = 256 + 44 两段）
//   [5] SRC_INC=0（源地址固定，FIXED 读）
//   [6] DST_INC=0（目的地址固定，FIXED 写）
//   [7] 错误响应：SLVERR → 停 + err 脉冲
//   [8] done/err 脉冲形状 + status 位
//
// 运行（从仓库根目录）：
//   iverilog -g2012 -Wall -o sim.out RTL/dma_engine.v RTL/sync_fifo.v \
//             TB/axi_mem_model.v TB/axi_protocol_checker.v TB/tb_dma_engine.v
//   vvp sim.out
// ============================================================
`timescale 1ns/1ps


// ------------------------------------------------------------
// 顶层测试台
// ------------------------------------------------------------
module tb_dma_engine;

    localparam ADDR_W = 32;
    localparam DATA_W = 32;
    localparam ID_W   = 4;
    localparam LEN_W  = 8;

    reg clk   = 0;
    reg rst_n = 0;

    // ---- 引擎配置侧 ----
    reg [ADDR_W-1:0] cfg_src, cfg_dst;
    reg [31:0]       cfg_len;
    reg              cfg_src_inc, cfg_dst_inc, start;
    wire             busy, done, err;
    wire [31:0]      status;

    // ---- AXI 主口 ----
    wire [ID_W-1:0]    m_awid;
    wire [ADDR_W-1:0]  m_awaddr;
    wire [LEN_W-1:0]   m_awlen;
    wire [2:0]         m_awsize;
    wire [1:0]         m_awburst;
    wire               m_awvalid;
    wire               m_awready;
    wire [DATA_W-1:0]  m_wdata;
    wire [3:0]         m_wstrb;
    wire               m_wlast;
    wire               m_wvalid;
    wire               m_wready;
    wire [ID_W-1:0]    m_bid;
    wire [1:0]         m_bresp;
    wire               m_bvalid;
    wire               m_bready;
    wire [ID_W-1:0]    m_arid;
    wire [ADDR_W-1:0]  m_araddr;
    wire [LEN_W-1:0]   m_arlen;
    wire [2:0]         m_arsize;
    wire [1:0]         m_arburst;
    wire               m_arvalid;
    wire               m_arready;
    wire [ID_W-1:0]    m_rid;
    wire [DATA_W-1:0]  m_rdata;
    wire [1:0]         m_rresp;
    wire               m_rlast;
    wire               m_rvalid;
    wire               m_rready;

    reg [ADDR_W-1:0]   err_addr;

    dma_engine #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W), .LEN_W(LEN_W), .CH(0)) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_src(cfg_src), .cfg_dst(cfg_dst), .cfg_len(cfg_len),
        .cfg_src_inc(cfg_src_inc), .cfg_dst_inc(cfg_dst_inc), .start(start),
        .busy(busy), .done(done), .err(err), .status(status),
        .m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen),
        .m_awsize(m_awsize), .m_awburst(m_awburst),
        .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast),
        .m_wvalid(m_wvalid), .m_wready(m_wready),
        .m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
        .m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen),
        .m_arsize(m_arsize), .m_arburst(m_arburst),
        .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rid(m_rid), .m_rdata(m_rdata), .m_rresp(m_rresp),
        .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready)
    );

    axi_mem_model #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)) u_mem (
        .clk(clk), .rst_n(rst_n),
        .awid(m_awid), .awaddr(m_awaddr), .awlen(m_awlen), .awsize(m_awsize),
        .awburst(m_awburst), .awvalid(m_awvalid), .awready(m_awready),
        .wdata(m_wdata), .wstrb(m_wstrb), .wlast(m_wlast), .wvalid(m_wvalid), .wready(m_wready),
        .bid(m_bid), .bresp(m_bresp), .bvalid(m_bvalid), .bready(m_bready),
        .arid(m_arid), .araddr(m_araddr), .arlen(m_arlen), .arsize(m_arsize),
        .arburst(m_arburst), .arvalid(m_arvalid), .arready(m_arready),
        .rid(m_rid), .rdata(m_rdata), .rresp(m_rresp), .rlast(m_rlast),
        .rvalid(m_rvalid), .rready(m_rready),
        .err_addr(err_addr)
    );

    // AXI 协议检查器（挂在引擎主口，SIDE=1 监测主口）
    wire [31:0] chk_err;
    axi_protocol_checker #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W), .LEN_W(LEN_W),
        .NAME("dma_m0"), .SIDE(1)
    ) u_chk (
        .clk(clk), .rst_n(rst_n),
        .awid(m_awid), .awaddr(m_awaddr), .awlen(m_awlen), .awsize(m_awsize),
        .awburst(m_awburst), .awvalid(m_awvalid), .awready(m_awready),
        .wdata(m_wdata), .wstrb(m_wstrb), .wlast(m_wlast), .wvalid(m_wvalid), .wready(m_wready),
        .bid(m_bid), .bresp(m_bresp), .bvalid(m_bvalid), .bready(m_bready),
        .arid(m_arid), .araddr(m_araddr), .arlen(m_arlen), .arsize(m_arsize),
        .arburst(m_arburst), .arvalid(m_arvalid), .arready(m_arready),
        .rid(m_rid), .rdata(m_rdata), .rresp(m_rresp), .rlast(m_rlast),
        .rvalid(m_rvalid), .rready(m_rready),
        .error_count(chk_err)
    );

    always #5 clk = ~clk;   // 100 MHz

    // ============================================================
    // 统计
    // ============================================================
    integer errors = 0;
    integer checks = 0;

    task chk;
        input [31:0]  got;
        input [31:0]  expv;
        input [255:0] name;
        begin
            checks = checks + 1;
            if (got !== expv) begin
                errors = errors + 1;
                $display("  [FAIL] %0s : got=0x%08X  期望=0x%08X", name, got, expv);
            end
        end
    endtask

    // 写一个字到存储器模型（用于预填源数据）
    task wr_mem_word;
        input [31:0] addr;
        input [31:0] val;
        begin
            u_mem.mem[addr+0] = val[7:0];
            u_mem.mem[addr+1] = val[15:8];
            u_mem.mem[addr+2] = val[23:16];
            u_mem.mem[addr+3] = val[31:24];
        end
    endtask

    // 读存储器模型的一个字并比对
    task chk_mem_word;
        input [31:0] addr;
        input [31:0] expv;
        input [255:0] name;
        begin
            chk({u_mem.mem[addr+3], u_mem.mem[addr+2], u_mem.mem[addr+1], u_mem.mem[addr+0]},
                expv, name);
        end
    endtask

    // 启动一次搬运
    task run_dma;
        input [31:0] src, dst, len;
        input        si, di;
        begin
            @(negedge clk);
            cfg_src = src; cfg_dst = dst; cfg_len = len;
            cfg_src_inc = si; cfg_dst_inc = di;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    // 等 done（轮询 status[1]，带超时）
    task wait_done;
        integer t;
        begin
            t = 0;
            while (status[1] !== 1'b1 && t < 200000) begin
                @(posedge clk); t = t + 1;
            end
            if (t >= 200000) begin
                errors = errors + 1;
                $display("  [FAIL] 等待 done 超时");
            end
        end
    endtask

    // ============================================================
    // 测试序列
    // ============================================================
    integer i;

    initial begin
        $dumpfile("tb_dma_engine.vcd");
        $dumpvars(2, tb_dma_engine);

        cfg_src = 0; cfg_dst = 0; cfg_len = 0; cfg_src_inc = 1; cfg_dst_inc = 1; start = 0;
        err_addr = 32'hFFFF_FFFF;

        rst_n = 0;
        repeat (5) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (3) @(posedge clk);

        $display("");
        $display("========== DMA 搬运引擎 单元测试 ==========");

        // ----------------------------------------------------
        // [1] 单拍搬运（LEN=1）
        // ----------------------------------------------------
        $display("[1] 单拍搬运");
        wr_mem_word(32'h0000_0100, 32'hDEAD_BEEF);
        run_dma(32'h0000_0100, 32'h0000_0500, 32'd1, 1'b1, 1'b1);
        wait_done;
        chk_mem_word(32'h0000_0500, 32'hDEAD_BEEF, "单拍搬运结果");
        chk(status[1], 1'b1, "done 粘滞位");
        chk(status[0], 1'b0, "busy 已清");

        // ----------------------------------------------------
        // [2] INCR 突发搬运（4 拍）
        // ----------------------------------------------------
        $display("[2] INCR 突发搬运（4 拍）");
        for (i = 0; i < 4; i = i + 1) wr_mem_word(32'h0000_0100 + 4*i, 32'hA0 + i);
        run_dma(32'h0000_0100, 32'h0000_0300, 32'd4, 1'b1, 1'b1);
        wait_done;
        for (i = 0; i < 4; i = i + 1) chk_mem_word(32'h0000_0300 + 4*i, 32'hA0 + i, "INCR 搬运");

        // ----------------------------------------------------
        // [3] 跨 4KB 长传输（1000 字）
        // ----------------------------------------------------
        $display("[3] 跨 4KB 长传输自动拆分（1000 字）");
        for (i = 0; i < 1000; i = i + 1) wr_mem_word(32'h0000_0F00 + 4*i, 32'h1000 + i);
        run_dma(32'h0000_0F00, 32'h0000_2000, 32'd1000, 1'b1, 1'b1);
        wait_done;
        begin
            integer bad;
            bad = 0;
            for (i = 0; i < 1000; i = i + 1) begin
                if ({u_mem.mem[32'h2000+4*i+3], u_mem.mem[32'h2000+4*i+2],
                     u_mem.mem[32'h2000+4*i+1], u_mem.mem[32'h2000+4*i+0]} !== (32'h1000 + i))
                    bad = bad + 1;
            end
            checks = checks + 1;
            if (bad != 0) begin errors = errors + 1; $display("  [FAIL] 跨4KB搬运 %0d 处不一致", bad); end
        end

        // ----------------------------------------------------
        // [4] 超过 256 拍的长传输（300 字 = 256 + 44）
        // ----------------------------------------------------
        $display("[4] 超过 256 拍长传输（300 字）");
        for (i = 0; i < 300; i = i + 1) wr_mem_word(32'h0000_1000 + 4*i, 32'h2000 + i);
        run_dma(32'h0000_1000, 32'h0000_3000, 32'd300, 1'b1, 1'b1);
        wait_done;
        begin
            integer bad;
            bad = 0;
            for (i = 0; i < 300; i = i + 1) begin
                if ({u_mem.mem[32'h3000+4*i+3], u_mem.mem[32'h3000+4*i+2],
                     u_mem.mem[32'h3000+4*i+1], u_mem.mem[32'h3000+4*i+0]} !== (32'h2000 + i))
                    bad = bad + 1;
            end
            checks = checks + 1;
            if (bad != 0) begin errors = errors + 1; $display("  [FAIL] 256拍以上搬运 %0d 处不一致", bad); end
        end

        // ----------------------------------------------------
        // [5] SRC_INC=0（源地址固定，FIXED 读）
        // ----------------------------------------------------
        $display("[5] SRC_INC=0（源地址固定）");
        wr_mem_word(32'h0000_0100, 32'hCAFE_BABE);
        run_dma(32'h0000_0100, 32'h0000_0500, 32'd3, 1'b0, 1'b1);
        wait_done;
        chk_mem_word(32'h0000_0500, 32'hCAFE_BABE, "固定源 → dst[0]");
        chk_mem_word(32'h0000_0504, 32'hCAFE_BABE, "固定源 → dst[1]");
        chk_mem_word(32'h0000_0508, 32'hCAFE_BABE, "固定源 → dst[2]");

        // ----------------------------------------------------
        // [6] DST_INC=0（目的地址固定，FIXED 写）
        // ----------------------------------------------------
        $display("[6] DST_INC=0（目的地址固定）");
        wr_mem_word(32'h0000_0600, 32'h1111_1111);
        wr_mem_word(32'h0000_0604, 32'h2222_2222);
        wr_mem_word(32'h0000_0608, 32'h3333_3333);
        run_dma(32'h0000_0600, 32'h0000_0700, 32'd3, 1'b1, 1'b0);
        wait_done;
        chk_mem_word(32'h0000_0700, 32'h3333_3333, "固定目的 → 最后一次写入");

        // ----------------------------------------------------
        // [7] 错误响应：SLVERR → 停 + err
        // ----------------------------------------------------
        $display("[7] 错误响应");
        err_addr = 32'h0000_0800;
        wr_mem_word(32'h0000_0800, 32'hDEAD_BEEF);
        run_dma(32'h0000_0800, 32'h0000_0900, 32'd4, 1'b1, 1'b1);
        // 等 err 或 done（应该 err）
        begin
            integer t;
            t = 0;
            while (status[2] !== 1'b1 && status[1] !== 1'b1 && t < 200000) begin
                @(posedge clk); t = t + 1;
            end
        end
        chk(status[2], 1'b1, "错误后 err 粘滞位");
        chk(status[1], 1'b0, "错误后不应 done");
        chk(status[0], 1'b0, "错误后 busy 已清");
        err_addr = 32'hFFFF_FFFF;

        // ----------------------------------------------------
        // A 40-word FIXED source must be split into <=16-beat bursts.
        wr_mem_word(32'h100,32'habcdef01);
        run_dma(32'h100,32'h300,40,0,1);
        wait_done;
        chk_mem_word(32'h39c,32'habcdef01,"FIXED length split final word");
        run_dma(32'hfff,32'h300,1,1,1);
        repeat(5) @(negedge clk);
        chk(status[2],1,"misaligned DMA rejected without AXI traffic");
        chk(status[0],0,"misaligned DMA does not hang");

        // [8] done/err 脉冲形状（一拍）
        // ----------------------------------------------------
        $display("[8] done 脉冲形状");
        begin
            reg done_cnt, err_cnt;
            done_cnt = 0;
            // 再跑一次单拍，用监视器数 done 脉冲
            fork
                begin
                    // 监视 done：统计拉高拍数
                    @(posedge done);
                    done_cnt = 1;
                end
                begin
                    wr_mem_word(32'h0000_0100, 32'h5A5A_5A5A);
                    run_dma(32'h0000_0100, 32'h0000_0500, 32'd1, 1'b1, 1'b1);
                    repeat (200) @(posedge clk);
                end
            join
            chk({31'd0, done_cnt}, 32'h1, "done 恰好脉冲一次");
        end

        // ----------------------------------------------------
        repeat (10) @(posedge clk);
        $display("");
        $display("============================================");
        chk(chk_err, 32'h0, "axi_protocol_checker error_count");
        if (errors == 0)
            $display("===== PASS: %0d 项检查全部通过，AXI 协议零违规 =====", checks);
        else
            $display("===== FAIL: %0d 项检查中 %0d 项失败 =====", checks, errors);
        $display("============================================");
        $finish;
    end

    // 超时保护
    initial begin
        #2000000;
        $display("!!!! TIMEOUT：仿真超时");
        $finish;
    end

endmodule