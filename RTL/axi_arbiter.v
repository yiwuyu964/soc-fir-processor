// ============================================================
// axi_arbiter.v —— 通用 round-robin 仲裁器（可参数化 N 路）
//
// 阶段2 分工 A 的复用子模块：AXI 互连里 5 个通道的仲裁都用它。
//
// 特性：
//   · round-robin（轮转），不是固定优先级 —— 保证没有请求者被饿死
//   · 空闲时组合选择；等待 advance 时锁住 grant，保证背压下载荷稳定
//   · 指针只在 advance（授权被消费 = 握手完成）那一拍前进，
//     下一轮从"刚被服务的请求者的下一个"开始，公平轮转
//
// 用法（AW 通道为例）：
//   req     = 各主设备的 AWVALID &（地址译码命中本从设备）
//   advance = 本从设备 AW 握手（AWVALID & AWREADY）
//   grant   = 一热授权，接 AW 信号 mux 与 AWREADY 回选
// ============================================================
`timescale 1ns/1ps

module axi_arbiter #(
    parameter N = 2                       // 请求者数量（N>=1）
)(
    input  wire          clk,
    input  wire          rst_n,
    input  wire [N-1:0]  req,             // 请求向量（组合）
    input  wire          advance,         // 授权消费（握手完成），指针前进
    output wire [N-1:0]  grant            // 一热授权（组合，无请求时全 0）
);

    localparam PW = (N > 1) ? $clog2(N) : 1;   // 指针位宽

    reg  [PW-1:0] ptr;                    // round-robin 指针
    reg  [N-1:0]  g;
    reg  [N-1:0]  held;
    reg           locked;
    reg           found;
    integer       i;
    integer       k;

    // Scan constant request indices in two ranges. A runtime % N on a
    // 32-bit loop expression infers a large divider for N=6; fixed bit
    // selects plus a pointer mask preserve round-robin without division.
    always @* begin
        g     = {N{1'b0}};
        found = 1'b0;
        for (i = 0; i < N; i = i + 1) begin
            if (!found && (i >= ptr) && req[i]) begin
                g[i] = 1'b1;
                found = 1'b1;
            end
        end
        for (i = 0; i < N; i = i + 1) begin
            if (!found && req[i]) begin
                g[i] = 1'b1;
                found = 1'b1;
            end
        end
    end

    assign grant = locked ? held : g;

    // ---- 指针：授权被消费后，下一轮从"下一个请求者"开始 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ptr <= {PW{1'b0}};
            held <= {N{1'b0}};
            locked <= 1'b0;
        end else if (advance) begin
            locked <= 1'b0;
            for (k = 0; k < N; k = k + 1)
                if (grant[k]) ptr <= (k == N-1) ? 0 : k + 1;
        end else if (!locked && |g) begin
            held <= g;
            locked <= 1'b1;
        end
    end

endmodule
