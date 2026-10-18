// ============================================================
// fir_core.v —— 81 阶可配置系数 FIR 数据通路（7 级加法树 + 5 级流水）
//
// ============================================================
// 【接口契约】docs/阶段1-接口契约（冻结版）.md  §契约 A
// ============================================================
//   ⚠️ 端口一旦冻结就不许改。要改端口 = 改契约 = 全队重新确认 + 版本升级。
//
// 【行为约定 A1~A6】（TB/tb_fir_core_contract.v 会自动验证这 6 条）
//   A1  吞吐 1 sample/cycle ：en 连续拉高时 dout_v 每拍都有效
//   A2  流水线延迟固定 5 拍
//   A3  dout_v 与 dout 同拍对齐（dout_v=1 那一拍 dout 就是它标记的结果）
//   A4  flush 拉高一拍：延迟线与流水线清零，dout_v 保持 0；系数保留
//   A5  coef_we 拉高一拍：把 coef_din 写入 h[coef_idx]，运行中改也立刻生效
//   A6  定点：乘积 Q2.30 精确，累加 40bit 不溢出，输出右移 15 位回 Q1.15 并饱和
//
//   ⚠️ 补充说明（B 包 AXI 外壳时必须知道）：
//      乘积用的是【移位前】的 x[]，所以每次 flush 之后，
//      第 1 个 dout_v 输出对应"延迟线全零"，恒为 0（前导 0）。
//      真正的第 i 个样本结果出现在第 i+1 个 dout_v 上。
//      C 驱动里那句 (void)REG32(FIR_DOUT); 就是在丢掉这个前导 0。
//
// 【验收】
//   TB/tb_fir_core_contract.v  契约自检（6 条约定，不依赖外部文件）
//   TB/tb_fir_core.v           全量回归（vs golden model，逐位一致）
//
// ============================================================
// 【定点约定】（必须和黄金模型 fir/fir_coeff.py 完全一致，见契约 D/E）
// ============================================================
//   数据 din / 系数 h 都是 Q1.15：真实值 = 整数 / 2^15
//   乘积 = X*H / 2^30（精确，不截位）
//   累加 40 bit（81 项下限 38，取 40 留余量）
//   输出右移 15 位回 Q1.15，并饱和到 [-32768, 32767]
//
// ============================================================
// 【为什么这么设计】累加结构：81 级串行链 → 7 级加法树 + 5 级流水
// ============================================================
//   串行链（错误做法）：
//       always @(*) begin sum = 0; for (k=0;k<NTAP;k=k+1) sum = sum + p[k]; end
//       综合出来是一条 81 级的串行进位链，关键路径约 32~65 ns，
//       对应 Fmax 只有 15~31 MHz —— 25 MHz 都没余量，50 MHz 必然不收敛。
//
//   加法树（本实现）：
//       82 → 41 → 21 → 11 → 6 → 3 → 2 → 1   共 7 级
//       同样的 80 个加法器，面积几乎不变，组合深度从 81 级降到 7 级。
//
//   再切成 3 段打拍，每段只剩 2~3 级加法：
//       S1  82 个 16x16 有符号乘法            → 打拍
//       S2  加法树第 1~3 级（82→41→21→11）    → 打拍
//       S3  加法树第 4~5 级（11→6→3）         → 打拍
//       S4  加法树第 6~7 级（3→2→1）          → 打拍
//       S5  右移 15 位 + 溢出判断 + 饱和       → 打拍
//
//   吞吐量不变（仍 1 sample/cycle），代价是延迟从 1 拍变成 LAT=5 拍。
//   输出序列本身没有变，只是整体往后平移，所以旧的 testbench 比对约定不用改。
//
// ============================================================
// 【决赛预留】对称系数优化 81→41 次乘加
// ============================================================
//   线性相位 FIR 的系数是对称的（h[k] == h[81-1-k]），可以先把对称的两个样本
//   相加（预加法器），再做一次乘法，乘法器数量从 81 降到 41。
//   本阶段【不实现】，只预留：
//     · 参数 SYMMETRIC（默认 0 = 关闭）
//     · 加法树的结构已经是"每级减半"，改成对称版只需替换乘法级，树不用动
//   决赛实现时走 docs/任务5-FIR定点方案说明书.md §5.3 / §5.4 的方案 A。
// ============================================================
`timescale 1ns/1ps

module fir_core #(
    parameter DW        = 16,       // 数据位宽 Q1.15
    parameter CW        = 16,       // 系数位宽 Q1.15
    parameter AW        = 40,       // 累加器位宽（81 阶下限 38，取 40）
    parameter NTAP      = 82,       // 81st order = 82 independently writable taps
    parameter SYMMETRIC = 0         // 【决赛预留】1 = 启用对称折叠（本阶段不实现）
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    flush,       // 清空延迟线与流水线（系数保留）
    input  wire                    en,          // 每拍处理一个样本
    input  wire signed [DW-1:0]    din,
    output wire signed [DW-1:0]    dout,
    output wire                    dout_v,      // dout 有效标志（与 dout 同拍）

    // ---- 系数写口（契约 A5）----
    input  wire [$clog2(NTAP)-1:0] coef_idx,    // 第几个系数
    input  wire signed [CW-1:0]    coef_din,    // 系数值（Q1.15）
    input  wire                    coef_we      // 写使能，拉高一拍
);

    // ============================================================
    // 0. 常量
    // ============================================================
    localparam LAT   = 5;           // 契约 A2：流水线总延迟（拍）
    localparam SHIFT = CW - 1;      // = 15，累加结果右移回 Q1.15

    integer i;

    // ============================================================
    // 1. 系数寄存器 + 样本延迟线
    // ============================================================
    reg signed [CW-1:0] h [0:NTAP-1];
    reg signed [DW-1:0] x [0:NTAP-1];

    // ============================================================
    // 2. 并行乘法（组合），并符号扩展到累加器位宽 AW
    //    注意：pe 用的是【移位前】的 x[]，这正是滤波需要的 x[n-k]
    // ============================================================
    wire signed [DW+CW-1:0] p  [0:NTAP-1];
    wire signed [AW-1:0]    pe [0:NTAP-1];

    genvar g;
    generate
        for (g = 0; g < NTAP; g = g + 1) begin : g_mul
            assign p[g]  = x[g] * h[g];
            assign pe[g] = {{(AW-DW-CW){p[g][DW+CW-1]}}, p[g]};
        end
    endgenerate

    // ============================================================
    // 3. 加法树每层的节点数：82 → 41 → 21 → 11 → 6 → 3 → 2 → 1
    //    （NTAP=9 时是 9→5→3→2→1，多出来的层自动退化成直通）
    // ============================================================
    localparam L1 = (NTAP + 1) / 2;
    localparam L2 = (L1   + 1) / 2;
    localparam L3 = (L2   + 1) / 2;
    localparam L4 = (L3   + 1) / 2;
    localparam L5 = (L4   + 1) / 2;
    localparam L6 = (L5   + 1) / 2;
    localparam L7 = (L6   + 1) / 2;

    // ============================================================
    // 4. 流水线寄存器
    // ============================================================
    reg signed [AW-1:0] s1 [0:NTAP-1];      // S1：乘法结果
    reg signed [AW-1:0] r2 [0:L3-1];        // S2：加法树第 1~3 级之后
    reg signed [AW-1:0] r3 [0:L5-1];        // S3：加法树第 4~5 级之后
    reg signed [AW-1:0] r4;                 // S4：加法树第 6~7 级之后（只剩一个数）

    // en 的流水线：每一级寄存器的时钟使能都要跟着样本一起走，
    // 否则样本喂得不连续时，流水线各级会互相对不齐。
    reg [LAT-1:0] en_pipe;

    // ============================================================
    // 5. 系数写入（契约 A5）
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < NTAP; i = i + 1) h[i] <= {CW{1'b0}};
        end
        else if (coef_we) begin
            h[coef_idx] <= coef_din;
        end
    end

    // ============================================================
    // 6. 样本延迟线（契约 A4：flush 清空延迟线，但不动系数）
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < NTAP; i = i + 1) x[i] <= {DW{1'b0}};
        end
        else if (flush) begin
            for (i = 0; i < NTAP; i = i + 1) x[i] <= {DW{1'b0}};
        end
        else if (en) begin
            for (i = NTAP-1; i > 0; i = i - 1) x[i] <= x[i-1];
            x[0] <= din;
        end
    end

    // ============================================================
    // 7. en 打拍：给流水线各级当使能
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)         en_pipe <= {LAT{1'b0}};
        else if (flush)     en_pipe <= {LAT{1'b0}};
        else                en_pipe <= {en_pipe[LAT-2:0], en};
    end

    // ============================================================
    // 8. S1：乘法结果打拍
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < NTAP; i = i + 1) s1[i] <= {AW{1'b0}};
        end
        else if (flush) begin
            for (i = 0; i < NTAP; i = i + 1) s1[i] <= {AW{1'b0}};
        end
        else if (en) begin
            for (i = 0; i < NTAP; i = i + 1) s1[i] <= pe[i];
        end
    end

    // ============================================================
    // 9. 加法树（组合，7 级）
    //    ⚠️ 第 4~5 级必须从【打拍后的 r2】出发，第 6~7 级必须从【r3】出发。
    //       如果写成从 n3 / n5 出发，r2 / r3 会变成死逻辑，
    //       组合链一路串到底，流水线就白打了（功能还是对的，但时序没改善）。
    // ============================================================
    wire signed [AW-1:0] n1 [0:L1-1];
    wire signed [AW-1:0] n2 [0:L2-1];
    wire signed [AW-1:0] n3 [0:L3-1];
    wire signed [AW-1:0] n4 [0:L4-1];
    wire signed [AW-1:0] n5 [0:L5-1];
    wire signed [AW-1:0] n6 [0:L6-1];
    wire signed [AW-1:0] n7 [0:L7-1];

    generate
        for (g = 0; g < L1; g = g + 1) begin : g_l1
            if (2*g + 1 < NTAP) assign n1[g] = s1[2*g] + s1[2*g+1];
            else                assign n1[g] = s1[2*g];
        end
        for (g = 0; g < L2; g = g + 1) begin : g_l2
            if (2*g + 1 < L1) assign n2[g] = n1[2*g] + n1[2*g+1];
            else              assign n2[g] = n1[2*g];
        end
        for (g = 0; g < L3; g = g + 1) begin : g_l3
            if (2*g + 1 < L2) assign n3[g] = n2[2*g] + n2[2*g+1];
            else              assign n3[g] = n2[2*g];
        end
        // ↓ 从打拍后的 r2 出发
        for (g = 0; g < L4; g = g + 1) begin : g_l4
            if (2*g + 1 < L3) assign n4[g] = r2[2*g] + r2[2*g+1];
            else              assign n4[g] = r2[2*g];
        end
        for (g = 0; g < L5; g = g + 1) begin : g_l5
            if (2*g + 1 < L4) assign n5[g] = n4[2*g] + n4[2*g+1];
            else              assign n5[g] = n4[2*g];
        end
        // ↓ 从打拍后的 r3 出发
        for (g = 0; g < L6; g = g + 1) begin : g_l6
            if (2*g + 1 < L5) assign n6[g] = r3[2*g] + r3[2*g+1];
            else              assign n6[g] = r3[2*g];
        end
        for (g = 0; g < L7; g = g + 1) begin : g_l7
            if (2*g + 1 < L6) assign n7[g] = n6[2*g] + n6[2*g+1];
            else              assign n7[g] = n6[2*g];
        end
    endgenerate

    // ============================================================
    // 10. S2 / S3 / S4：把加法树切成三段打拍
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < L3; i = i + 1) r2[i] <= {AW{1'b0}};
        end
        else if (flush) begin
            for (i = 0; i < L3; i = i + 1) r2[i] <= {AW{1'b0}};
        end
        else if (en_pipe[0]) begin
            for (i = 0; i < L3; i = i + 1) r2[i] <= n3[i];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < L5; i = i + 1) r3[i] <= {AW{1'b0}};
        end
        else if (flush) begin
            for (i = 0; i < L5; i = i + 1) r3[i] <= {AW{1'b0}};
        end
        else if (en_pipe[1]) begin
            for (i = 0; i < L5; i = i + 1) r3[i] <= n5[i];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          r4 <= {AW{1'b0}};
        else if (flush)      r4 <= {AW{1'b0}};
        else if (en_pipe[2]) r4 <= n7[0];
    end

    // ============================================================
    // 11. S5：截位回 Q1.15 + 溢出判断 + 饱和（契约 A6）
    // ============================================================
    wire signed [DW-1:0] y_trunc = r4[SHIFT+DW-1 : SHIFT];

    // 被截掉的高位如果不是符号扩展，说明结果超出 Q1.15 范围
    wire overflow = (r4[AW-1 : SHIFT+DW] != {{(AW-SHIFT-DW){r4[SHIFT+DW-1]}}});

    // 饱和：正溢出给 +32767，负溢出给 -32768（不是回绕！）
    wire signed [DW-1:0] y_sat = overflow
                               ? (r4[AW-1] ? {1'b1, {DW-1{1'b0}}}
                                           : {1'b0, {DW-1{1'b1}}})
                               : y_trunc;

    // 契约里 dout 声明为 wire，所以这里用内部寄存器 + 连续赋值，
    // 而不是把端口改成 reg —— 【端口声明属于契约，不许改】。
    reg signed [DW-1:0] dout_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)              dout_r <= {DW{1'b0}};
        else if (flush)          dout_r <= {DW{1'b0}};
        else if (en_pipe[LAT-2]) dout_r <= y_sat;
    end

    assign dout = dout_r;

    // ============================================================
    // 12. dout_v（契约 A3）
    //     ⚠️ 必须用【组合】输出，不能写成 dout_v <= en_pipe[LAT-1]。
    //        写成寄存器的话，它会比 dout 晚一拍拉高，
    //        下游就会在 dout_v=1 那一拍读到"下一个"数据，整体错位。
    //        组合输出保证 dout_v=1 的那一拍，dout 正好是它标记的结果。
    // ============================================================
    assign dout_v = en_pipe[LAT-1];

endmodule
