// ============================================================
// sync_fifo.v —— 同步 FIFO（先进先出队列）
//
// 为什么 SoC 里需要 FIFO？
//   FIR 是"流式"的：每个时钟都能吐出一个结果；
//   CPU 是"拍"的：通过总线一次只读一个数，中间还有握手等待。
//   两者速度/节奏不匹配，中间垫一个 FIFO 当"缓冲池"：
//   FIR 拼命往里写，CPU 悠闲地从另一头读，谁也不等谁。
//
// 接口：
//   wen/wdata : 写一个数（wen 拉高一拍）
//   ren       : 消费当前队首；rdata 为组合队首，empty=0 时有效
//   full/empty: 满/空标志（满了不能再写，空了不能读）
//
// 实现：一块寄存器阵列 + 写指针 + 读指针 + 计数器。
//   （这是最简单、最好懂的 FIFO 写法；性能不是最优，但功能完全正确。）
// ============================================================
`timescale 1ns/1ps

module sync_fifo #(
    parameter WIDTH = 16,
    parameter DEPTH = 512
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               clr,          // 拉高一拍：清空（复位读写指针和计数）
    input  wire               wen,
    input  wire [WIDTH-1:0]   wdata,
    output wire               full,
    input  wire               ren,
    output wire [WIDTH-1:0]   rdata,
    output wire               empty,
    output wire [$clog2(DEPTH+1)-1:0] count
);

    reg [WIDTH-1:0] mem [0:DEPTH-1];

    // 指针和计数器位宽：够表示 0..DEPTH
    localparam PTR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;

    reg [PTR_W-1:0] wr_ptr, rd_ptr;
    reg [$clog2(DEPTH+1)-1:0] cnt;

    assign full  = (cnt == DEPTH);
    assign empty = (cnt == 0);
    assign rdata = mem[rd_ptr];
    assign count = cnt;

    // No asynchronous control on the storage write port: infer ordinary
    // portable RAM (asynchronous read / first-word fall-through). Reset and
    // clear invalidate entries through cnt, without resetting the array.
    always @(posedge clk) begin
        if (rst_n && !clr && wen && !full) mem[wr_ptr] <= wdata;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= {PTR_W{1'b0}};
            rd_ptr <= {PTR_W{1'b0}};
            cnt    <= 0;
        end
        else if (clr) begin
            wr_ptr <= {PTR_W{1'b0}};
            rd_ptr <= {PTR_W{1'b0}};
            cnt    <= 0;
        end
        else begin
            case ({wen && !full, ren && !empty})
                2'b10: begin                       // 只写
                    wr_ptr <= (wr_ptr == DEPTH-1) ? 0 : wr_ptr + 1'b1;
                    cnt    <= cnt + 1'b1;
                end
                2'b01: begin                       // 只读
                    rd_ptr <= (rd_ptr == DEPTH-1) ? 0 : rd_ptr + 1'b1;
                    cnt    <= cnt - 1'b1;
                end
                2'b11: begin                       // 同时读写
                    wr_ptr <= (wr_ptr == DEPTH-1) ? 0 : wr_ptr + 1'b1;
                    rd_ptr <= (rd_ptr == DEPTH-1) ? 0 : rd_ptr + 1'b1;
                    // cnt 不变
                end
                default: ;                          // 什么都不做
            endcase
        end
    end

endmodule
