// ============================================================
// uart_apb.v —— UART 的 APB 从设备封装（收发都有）
//
// 赛题原文："AHB到AXI接口桥（Cortex-M0），AXI到APB接口桥（UART）"
// 所以 UART 应该挂在【APB】这一侧。完整链路是：
//
//   Cortex-M0 ──AXI4──▶ axi_to_apb ──APB──▶ uart_apb ──串口──▶ PC
//
// 本模块把 uart_tx（发送）+ uart_rx（接收）+ 接收 FIFO 打包成一个
// APB 从设备，CPU 通过读写寄存器就能收发。
//
// ------------------------------------------------------------
// 寄存器映射（字节地址，和原来的 uart_axi.v 前两个寄存器保持一致，
// 这样 C 驱动不用改）
// ------------------------------------------------------------
//   0x000  DATA     写：低 8bit 是要发送的字节（触发一次发送）
//                   读：固定 0
//                   ※ 若发送器正忙，写入会被拒绝并返回 SLVERR，
//                     CPU 应先读 STATUS 确认 tx_busy=0
//
//   0x004  STATUS   读：[0] tx_busy     发送器忙
//                       [1] rx_valid    接收 FIFO 非空（有数据可读）
//                       [2] rx_full     接收 FIFO 满（再收会丢）
//                       [3] rx_frame_err 收到过帧错误（粘滞位，读本寄存器后清）
//
//   0x008  RXDATA   读：取出一个收到的字节；读一次弹出 FIFO 一个
//                   ※ FIFO 空时读出 0，用 STATUS.rx_valid 判断
//
// ------------------------------------------------------------
// APB 时序（IHI0024）
// ------------------------------------------------------------
//   SETUP : PSEL=1 PENABLE=0
//   ACCESS: PSEL=1 PENABLE=1，本模块在第 1 个 ACCESS 周期完成访问并拉高
//           PREADY；若主设备还没结束，PREADY 保持高，且不会重复执行访问
//           （用 active 标志保护，避免同一次传输被执行两次）。
// ============================================================
`timescale 1ns/1ps

module uart_apb #(
    parameter CLK_FREQ   = 100_000_000,
    parameter BAUD       = 115200,
    parameter FIFO_DEPTH = 16
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- APB 从设备侧（连 axi_to_apb 的 APB 口）----
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [31:0] paddr,
    input  wire [31:0] pwdata,
    input  wire [3:0]  pstrb,
    input  wire [2:0]  pprot,
    output reg  [31:0] prdata,
    output reg         pready,
    output reg         pslverr,

    // ---- 串口物理线 ----
    input  wire        rxd,
    output wire        txd
);

    localparam ADDR_DATA   = 32'h000;
    localparam ADDR_STATUS = 32'h004;
    localparam ADDR_RXDATA = 32'h008;

    // ============================================================
    // 1. 发送器
    // ============================================================
    reg  [7:0] tx_data;
    reg        tx_start;
    wire       tx_busy;

    uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .din(tx_data), .start(tx_start),
        .txd(txd), .busy(tx_busy)
    );

    // ============================================================
    // 2. 接收器
    // ============================================================
    wire [7:0] rx_byte;
    wire       rx_dv, rx_frame_err, rx_busy;

    uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_rx (
        .clk(clk), .rst_n(rst_n), .rxd(rxd),
        .dout(rx_byte), .dout_v(rx_dv),
        .frame_err(rx_frame_err), .busy(rx_busy)
    );

    // ============================================================
    // 3. 接收 FIFO：CPU 来不及读的时候先存着
    // ============================================================
    wire [7:0]                       rx_fifo_rdata;
    wire                             rx_fifo_full, rx_fifo_empty;
    wire [$clog2(FIFO_DEPTH+1)-1:0]  rx_fifo_count;
    reg                              rx_fifo_ren;

    sync_fifo #(.WIDTH(8), .DEPTH(FIFO_DEPTH)) u_rxfifo (
        .clk(clk), .rst_n(rst_n), .clr(1'b0),
        .wen(rx_dv), .wdata(rx_byte), .full(rx_fifo_full),
        .ren(rx_fifo_ren), .rdata(rx_fifo_rdata), .empty(rx_fifo_empty),
        .count(rx_fifo_count)
    );

    // ============================================================
    // 4. APB 寄存器访问
    // ============================================================
    reg active;                  // 本次传输已经执行过访问，防止重复执行
    reg rx_frame_err_sticky;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pready              <= 1'b0;
            pslverr             <= 1'b0;
            prdata              <= 32'd0;
            active              <= 1'b0;
            tx_data             <= 8'd0;
            tx_start            <= 1'b0;
            rx_fifo_ren         <= 1'b0;
            rx_frame_err_sticky <= 1'b0;
        end
        else begin
            pready      <= 1'b0;
            pslverr     <= 1'b0;
            tx_start    <= 1'b0;          // 单拍脉冲
            rx_fifo_ren <= 1'b0;          // 单拍脉冲

            // 收到帧错误就记下来，等 CPU 读 STATUS 时清
            if (rx_frame_err)
                rx_frame_err_sticky <= 1'b1;

            // PSEL 撤掉 → 本次传输结束，清掉保护标志
            if (!psel)
                active <= 1'b0;

            if (psel && penable) begin
                if (!active) begin
                    // -------- 本次传输的第一个 ACCESS 周期：执行访问 --------
                    active <= 1'b1;
                    pready <= 1'b1;

                    if (pwrite) begin
                        if (paddr == ADDR_DATA) begin
                            tx_data  <= pwdata[7:0];
                            tx_start <= 1'b1;
                            pslverr  <= tx_busy;      // 发送器忙 → 这次写入被拒
                        end
                        // 其它地址都是只读寄存器，写进去没有副作用
                    end
                    else begin
                        case (paddr)
                            ADDR_STATUS: begin
                                prdata <= {28'd0,
                                           rx_frame_err_sticky,
                                           rx_fifo_full,
                                           ~rx_fifo_empty,
                                           tx_busy};
                                rx_frame_err_sticky <= 1'b0;   // 读过就清
                            end
                            ADDR_RXDATA: begin
                                prdata      <= {24'd0, rx_fifo_rdata};
                                rx_fifo_ren <= 1'b1;           // 读一次弹一个
                            end
                            default: prdata <= 32'd0;
                        endcase
                    end
                end
                else begin
                    // -------- 主设备还没结束：保持 PREADY，不重复执行 --------
                    pready <= 1'b1;
                end
            end
        end
    end

endmodule
