// ============================================================
// uart_rx.v —— 简易 UART 接收器（8N1，无校验位，1 停止位）
//
// 它和 uart_tx.v 是一对：
//   uart_tx 把 CPU 写进来的字节一位一位发出去；
//   uart_rx 把 rxd 线上收到的位一位一位拼回一个字节。
//
// 赛题："CPU 正常跑通（UART 回显）"——有发还得有收，收就是这个模块。
//
// 协议（8N1）：
//   空闲 = 高；起始位 = 低；8 个数据位（先收最低位 LSB）；停止位 = 高。
//
// 采样策略（这是 UART 接收的关键）：
//   在每一位的【正中间】采样，而不是边沿。
//   检测到起始位下降沿后先等【半个比特】，正好落到起始位中点；
//   之后每等【一个完整比特】采一次，就一路落在每个数据位的中点。
//   这样对双方时钟的微小误差容忍度最大。
//
// 输入同步：
//   rxd 是异步信号，先过两级触发器同步到本时钟域，避免亚稳态。
// ============================================================
`timescale 1ns/1ps

module uart_rx #(
    parameter CLK_FREQ = 100_000_000,   // 时钟频率 Hz
    parameter BAUD     = 115200          // 波特率
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rxd,             // 串行输入线
    output reg  [7:0]  dout,            // 收到的字节
    output reg         dout_v,          // 拉高一拍：dout 有效
    output reg         frame_err,       // 拉高一拍：停止位不是高电平（帧错误）
    output reg         busy             // 1=正在接收
);

    localparam BIT_CNT = CLK_FREQ / BAUD;    // 每个比特的时钟数
    localparam HALF    = BIT_CNT / 2;        // 半比特

    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_DATA  = 2'd2;
    localparam S_STOP  = 2'd3;

    // ---- 两级同步器 ----
    reg rxd_meta, rxd_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rxd_meta <= 1'b1;
            rxd_sync <= 1'b1;
        end else begin
            rxd_meta <= rxd;
            rxd_sync <= rxd_meta;
        end
    end

    reg [1:0]  state;
    reg [15:0] bit_timer;
    reg [2:0]  bit_idx;
    reg [7:0]  shifter;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            bit_timer <= 16'd0;
            bit_idx   <= 3'd0;
            shifter   <= 8'd0;
            dout      <= 8'd0;
            dout_v    <= 1'b0;
            frame_err <= 1'b0;
            busy      <= 1'b0;
        end
        else begin
            dout_v    <= 1'b0;          // 默认是单拍脉冲
            frame_err <= 1'b0;

            case (state)
                // ------------------------------------------------
                // 空闲：等起始位的下降沿
                // ------------------------------------------------
                S_IDLE: begin
                    busy <= 1'b0;
                    if (rxd_sync == 1'b0) begin
                        // 检测到起始位，等半个比特，落到它的中点
                        busy      <= 1'b1;
                        bit_timer <= HALF - 1;
                        state     <= S_START;
                    end
                end

                // ------------------------------------------------
                // 起始位中点：再确认一次确实是低电平（防毛刺）
                // ------------------------------------------------
                S_START: begin
                    if (bit_timer == 0) begin
                        if (rxd_sync == 1'b0) begin
                            bit_timer <= BIT_CNT - 1;
                            bit_idx   <= 3'd0;
                            state     <= S_DATA;
                        end
                        else begin
                            state <= S_IDLE;     // 是毛刺，丢弃
                            busy  <= 1'b0;
                        end
                    end
                    else
                        bit_timer <= bit_timer - 1'b1;
                end

                // ------------------------------------------------
                // 8 个数据位：每个比特的中点采一次，先收 LSB
                // ------------------------------------------------
                S_DATA: begin
                    if (bit_timer == 0) begin
                        shifter[bit_idx] <= rxd_sync;
                        bit_timer        <= BIT_CNT - 1;
                        if (bit_idx == 3'd7)
                            state <= S_STOP;
                        else
                            bit_idx <= bit_idx + 1'b1;
                    end
                    else
                        bit_timer <= bit_timer - 1'b1;
                end

                // ------------------------------------------------
                // 停止位中点：检查是否为高，输出收到的字节
                // ------------------------------------------------
                S_STOP: begin
                    if (bit_timer == 0) begin
                        dout      <= shifter;
                        dout_v    <= 1'b1;
                        frame_err <= ~rxd_sync;    // 停止位应为高
                        busy      <= 1'b0;
                        state     <= S_IDLE;
                    end
                    else
                        bit_timer <= bit_timer - 1'b1;
                end
            endcase
        end
    end

endmodule
