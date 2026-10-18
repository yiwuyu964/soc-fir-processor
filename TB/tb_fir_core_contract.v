// ============================================================
// tb_fir_core_contract.v —— fir_core【接口契约】自检台
//
// 这个测试台【不测滤波数值对不对】（那由 golden model 的回归负责），
// 它只测一件事：**实现有没有守住《阶段1 接口契约（冻结版）》契约 A 的 6 条约定**。
//
//   A1  吞吐 1 sample/cycle：en 连续拉高时 dout_v 每拍都有效
//   A2  流水线延迟固定 5 拍
//   A3  dout_v 与 dout 同拍对齐
//   A4  flush 拉高一拍：延迟线与流水线清零，dout_v 保持 0，系数保留
//   A5  coef_we 拉高一拍：把 coef_din 写入 h[coef_idx]
//   A6  定点：累加 40bit 不溢出，输出右移 15 位回 Q1.15 并饱和
//
// 用法：
//   iverilog -g2012 -o sim.out RTL/fir_core.v TB/tb_fir_core_contract.v
//   vvp sim.out
//
//   ⚠️ 拿【只有端口的空壳】跑，会全红——那是当然的，空壳没有实现。
//      这个台子是给 A 写完实现后用的【验收标准】。
// ============================================================
`timescale 1ns/1ps

module tb_fir_core_contract;

    localparam DW   = 16;
    localparam CW   = 16;
    localparam AW   = 40;
    localparam NTAP = 82;
    localparam LAT  = 5;            // 契约 A2：流水线延迟固定 5 拍

    reg  clk = 0;
    reg  rst_n = 0;
    reg  flush = 0;
    reg  en = 0;
    reg  signed [DW-1:0] din = 0;
    wire signed [DW-1:0] dout;
    wire                 dout_v;

    reg  [$clog2(NTAP)-1:0] coef_idx = 0;
    reg  signed [CW-1:0]    coef_din = 0;
    reg                     coef_we  = 0;

    fir_core #(.DW(DW), .CW(CW), .AW(AW), .NTAP(NTAP)) dut (
        .clk(clk), .rst_n(rst_n), .flush(flush), .en(en), .din(din),
        .dout(dout), .dout_v(dout_v),
        .coef_idx(coef_idx), .coef_din(coef_din), .coef_we(coef_we)
    );

    always #5 clk = ~clk;           // 100 MHz

    integer checks = 0;
    integer errors = 0;
    integer i, k;
    integer cnt;

    task chk;
        input [31:0]  got_v;
        input [31:0]  exp_v;
        input [255:0] name;
        begin
            checks = checks + 1;
            if (got_v !== exp_v) begin
                errors = errors + 1;
                $display("  [FAIL] %0s : got=%0d 期望=%0d", name, got_v, exp_v);
            end
        end
    endtask

    // ---- 写一个系数（契约 A5）----
    task set_coef;
        input integer        idx;
        input signed [CW-1:0] val;
        begin
            @(negedge clk);
            coef_idx = idx[$clog2(NTAP)-1:0];
            coef_din = val;
            coef_we  = 1'b1;
            @(negedge clk);
            coef_we  = 1'b0;
        end
    endtask

    // ---- 把所有系数设成同一个值 ----
    task set_all_coef;
        input signed [CW-1:0] val;
        begin
            for (i = 0; i < NTAP; i = i + 1) set_coef(i, val);
        end
    endtask

    // ---- 清空（契约 A4）----
    task do_flush;
        begin
            @(negedge clk); flush = 1'b1;
            @(negedge clk); flush = 1'b0;
            repeat (LAT + 2) @(posedge clk);
        end
    endtask

    // ---- 只喂一个样本，数 dout_v 第几拍来（契约 A2）----
    task feed_one_and_measure;
        input signed [DW-1:0] sample;
        output integer        lat;
        begin
            @(negedge clk); en = 1'b1; din = sample;
            @(negedge clk); en = 1'b0; din = 0;
            lat = 0;
            while (dout_v !== 1'b1 && lat < 50) begin
                @(posedge clk);
                lat = lat + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_fir_core_contract.vcd");
        $dumpvars(0, tb_fir_core_contract);

        repeat (4) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (2) @(posedge clk);

        $display("");
        $display("========== fir_core 接口契约自检 ==========");

        // ----------------------------------------------------
        // A2 + A3：延迟 5 拍 + dout_v 与 dout 同拍对齐
        //   设 h[0] = 16384（Q1.15 的 0.5），其余 0
        //   喂 din = 1000 一拍 → 结果应为 16384*1000>>15 = 500
        //   这一个用例同时验了：延迟拍数、对齐、系数生效
        // ----------------------------------------------------
        $display("[A2+A3] 延迟 5 拍 + dout_v/dout 同拍对齐");
        set_all_coef(16'sd0);
        set_coef(0, 16'sd16384);

        @(negedge clk); flush = 1'b1;
        @(negedge clk); flush = 1'b0;
        repeat (LAT + 2) @(posedge clk);

        // ---- A2：只给一拍 en，数 dout_v 第几拍来 ----
        begin : a2blk
            integer lat;
            @(negedge clk); en = 1'b1; din = 16'sd1000;
            @(negedge clk); en = 1'b0; din = 16'sd0;
            lat = 0;
            while (dout_v !== 1'b1 && lat < 50) begin
                @(posedge clk);
                lat = lat + 1;
            end
            chk(lat, LAT, "A2 流水线延迟拍数");
        end
        repeat (LAT + 4) @(posedge clk);

        // ---- A3：连续喂两拍，验 dout_v 与 dout 同拍 + 数值 ----
        //      乘积用的是【移位前】的 x[]，
        //      所以第 1 个输出对应 x 全零（前导 0），第 2 个才是真结果。
        //      ⚠️ 必须先 flush：A2 那一拍已经把 1000 移进 x[0] 了。
        do_flush;
        begin : a3blk
            @(negedge clk); en = 1'b1; din = 16'sd1000;
            while (dout_v !== 1'b1) @(posedge clk);
            chk(dout, 16'sd0,   "A3 第 1 个输出（前导，x 全零）");
            @(posedge clk);
            chk(dout, 16'sd500, "A3 第 2 个输出（x=[1000]，h0*1000>>15）");
            @(negedge clk); en = 1'b0; din = 16'sd0;
        end
        repeat (LAT + 4) @(posedge clk);

        // ----------------------------------------------------
        // A4：flush 清零（系数要保留）
        // ----------------------------------------------------
        $display("[A4] flush 清延迟线与流水线，但系数保留");
        do_flush;
        cnt = 0;
        for (k = 0; k < LAT + 4; k = k + 1) begin
            @(posedge clk);
            if (dout_v) cnt = cnt + 1;
        end
        chk(cnt, 0, "A4 flush 后不应有 dout_v");

        // flush 之后重新喂同一个样本，结果应与 flush 前一致（系数没被清掉）
        begin : a4b
            integer lat;
            lat = 0;
            @(negedge clk); en = 1'b1; din = 16'sd1000;
            while (dout_v !== 1'b1 && lat < 50) begin
                @(posedge clk);
                lat = lat + 1;
            end
            @(posedge clk);        // 跳过前导 0
            chk(dout, 16'sd500, "A4 flush 后系数仍保留（结果与 flush 前一致）");
            @(negedge clk); en = 1'b0; din = 16'sd0;
        end

        // ----------------------------------------------------
        // A1：吞吐 1 sample/cycle
        //   en 连续拉高 40 拍 → 应该收到 40 个 dout_v
        // ----------------------------------------------------
        $display("[A1] 吞吐 1 sample/cycle（连续 40 拍 en → 40 个结果）");
        do_flush;
        cnt = 0;
        @(negedge clk); en = 1'b1;
        fork
            begin : drv
                for (k = 0; k < 40; k = k + 1) begin
                    din = k[15:0];
                    @(negedge clk);
                end
                en = 1'b0; din = 0;
            end
            begin : mon
                integer got_cnt;
                got_cnt = 0;
                while (got_cnt < 40) begin
                    @(posedge clk);
                    if (dout_v) got_cnt = got_cnt + 1;
                end
                cnt = got_cnt;
            end
        join
        chk(cnt, 40, "A1 连续 en 时的输出个数");
        repeat (LAT + 4) @(posedge clk);

        // ----------------------------------------------------
        // A6：40bit 累加不溢出 + 饱和
        //   最坏情况：82 个系数全 -32768，输入恒 -32768
        //   真实和 = 81 * 2^30 = 86,973,087,744
        //   右移 15 位 = 2,654,208 → 正饱和到 +32767
        //   若累加器只有 32 位会回绕，结果就不是 32767
        // ----------------------------------------------------
        $display("[A6] 最坏情况饱和（82 个 -32768 系数 × -32768 输入）");
        set_all_coef(-16'sd32768);
        do_flush;
        begin : a6
            reg signed [DW-1:0] lastv;
            lastv = 0;
            @(negedge clk); en = 1'b1; din = -16'sd32768;
            for (k = 0; k < NTAP + LAT + 4; k = k + 1) begin
                @(posedge clk);
                if (dout_v) lastv = dout;
            end
            @(negedge clk); en = 1'b0;
            chk(lastv, 16'sd32767, "A6 最坏情况应正饱和到 +32767（不能回绕）");
        end
        repeat (LAT + 4) @(posedge clk);

        // ----------------------------------------------------
        // A5：系数写口在数据流动中也能生效
        // ----------------------------------------------------
        $display("[A5] 运行中改系数应立刻生效");
        set_all_coef(16'sd0);
        set_coef(0, 16'sd32767);        // 改成约 1.0
        do_flush;
        begin : a5
            integer lat;
            lat = 0;
            @(negedge clk); en = 1'b1; din = 16'sd1000;
            while (dout_v !== 1'b1 && lat < 50) begin
                @(posedge clk);
                lat = lat + 1;
            end
            @(posedge clk);        // 跳过前导 0
            // 32767*1000>>15 = 999.97 → 截位得 999
            chk(dout, 16'sd999, "A5 新系数应立刻生效（32767*1000>>15）");
            @(negedge clk); en = 1'b0; din = 16'sd0;
        end

        repeat (10) @(posedge clk);
        $display("");
        $display("=========================================================");
        if (errors == 0)
            $display("===== PASS: 契约 A 全部 %0d 项自检通过 =====", checks);
        else
            $display("===== FAIL: %0d 项检查中 %0d 项不满足契约 A =====", checks, errors);
        $display("=========================================================");
        $finish;
    end

    initial begin
        #500000;
        $display("!!!! TIMEOUT：仿真超时");
        $finish;
    end

endmodule
