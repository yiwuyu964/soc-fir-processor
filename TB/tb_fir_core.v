// ============================================================
// tb_fir_core.v —— fir_core 全量回归（与软件黄金模型逐位比对）
//
// 验的是【数值正确性】，和 TB/tb_fir_core_contract.v（验行为约定）分工不同：
//   本文件      ：81 阶 × 256 个样本，和黄金模型的 337 个输出逐位比对
//   契约自检台  ：只验 A1~A6 六条接口约定，不依赖外部文件
//
// 数据来源（在 fir/ 目录下，由 fir/fir_coeff.py 生成，见契约 D/E）：
//   coeffs.hex  82 个 Q1.15 系数（测试台通过 coef 写口写进去，不 `include）
//   stim.hex    256 个输入样本
//   exp.hex     337 个期望输出（全卷积长度 = 样本数 + 抽头数 - 1）
//
// 运行（从仓库根目录）：
//   python fir/fir_coeff.py --taps 81 --cutoff 0.12 --nsamp 256
//   iverilog -g2012 -o sim.out RTL/fir_core.v TB/tb_fir_core.v && vvp sim.out
//
// 比对约定（必须和 fir/fir_coeff.py 一致，见契约 E.6）：
//   第 1 个 dout_v 输出 = 全零输入的卷积结果（一个前导 0）
//   第 2 个 dout_v 输出 = exp[0]
//   即：  got[i+1] == exp[i]
// ============================================================
`timescale 1ns/1ps

module tb_fir_core;

    localparam DW    = 16;
    localparam CW    = 16;
    localparam AW    = 40;
    localparam NTAP  = 82;
    localparam LAT   = 5;                       // 契约 A2
    localparam NSAMP = 256;
    localparam NEXP  = NSAMP + NTAP - 1;        // 全卷积长度 = 337

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

    always #5 clk = ~clk;                       // 100 MHz

    reg signed [CW-1:0] coeffs [0:NTAP-1];
    reg signed [DW-1:0] stim   [0:NSAMP-1];
    reg signed [DW-1:0] exp    [0:NEXP-1];
    reg signed [DW-1:0] got    [0:NEXP+16];

    integer cap    = 0;
    integer errors = 0;
    integer checks = 0;
    integer m, i;

    // ---- 采集 DUT 输出 ----
    always @(posedge clk) begin
        if (rst_n && dout_v && (cap <= NEXP + 8)) begin
            got[cap] = dout;
            cap      = cap + 1;
        end
    end

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

    initial begin
        $dumpfile("tb_fir_core.vcd");
        $dumpvars(0, tb_fir_core);

        // 路径按契约 D.4 / E.2 的写法：从【仓库根目录】运行
        $readmemh("fir/coeffs.hex", coeffs);
        $readmemh("fir/stim.hex",   stim);
        $readmemh("fir/exp.hex",    exp);

        for (i = 0; i <= NEXP + 16; i = i + 1) got[i] = {DW{1'b0}};

        repeat (4) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (2) @(posedge clk);

        $display("");
        $display("========== fir_core 全量回归（81 阶 vs 黄金模型）==========");

        // ----------------------------------------------------
        // 1) 通过 coef 写口写入 82 个系数（契约 A5）
        // ----------------------------------------------------
        $display("[1] 通过 coef 端口写入 %0d 个系数", NTAP);
        for (i = 0; i < NTAP; i = i + 1) begin
            @(negedge clk);
            coef_idx = i[$clog2(NTAP)-1:0];
            coef_din = coeffs[i];
            coef_we  = 1'b1;
        end
        @(negedge clk); coef_we = 1'b0;
        repeat (2) @(posedge clk);

        // ----------------------------------------------------
        // 2) 清空，然后连续喂 NSAMP 个样本
        // ----------------------------------------------------
        @(negedge clk); flush = 1'b1;
        @(negedge clk); flush = 1'b0;
        repeat (LAT + 2) @(posedge clk);
        cap = 0;

        $display("[2] 连续喂 %0d 个样本", NSAMP);
        @(negedge clk); en = 1'b1;
        for (m = 0; m < NSAMP; m = m + 1) begin
            din = stim[m];
            @(negedge clk);
        end

        // 排空延迟线 + 流水线
        din = 0;
        repeat (NTAP + LAT + 8) @(negedge clk);

        // ----------------------------------------------------
        // 3) 逐位比对
        // ----------------------------------------------------
        $display("[3] 采集到 %0d 个输出，黄金模型期望 %0d 个", cap, NEXP);

        if (cap < NEXP) begin
            errors = errors + 1;
            $display("  [FAIL] 输出个数不足：只有 %0d 个，应有 %0d 个", cap, NEXP);
        end

        for (i = 0; i < NEXP; i = i + 1) begin
            if (got[i+1] !== exp[i]) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("  [MISMATCH] 第 %0d 个样本: RTL = %0d, 黄金模型 = %0d",
                             i, got[i+1], exp[i]);
            end
        end
        checks = checks + 1;

        $writememh("got.hex", got);

        $display("");
        $display("=========================================================");
        if (errors == 0)
            $display("===== PASS: %0d 个样本与黄金模型逐位一致 =====", NEXP);
        else
            $display("===== FAIL: %0d 处不一致 =====", errors);
        $display("=========================================================");
        $finish;
    end

    initial begin
        #2000000;
        $display("!!!! TIMEOUT：仿真超时");
        $finish;
    end

endmodule
