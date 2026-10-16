// AHB-Lite to AXI4 bridge. Each accepted NONSEQ/SEQ is serialized as
// one AXI beat; BUSY/IDLE do not create transfers. HWDATA is captured
// in its data phase. ERROR uses HRESP=1 with HREADY low then high.
`timescale 1ns/1ps

module ahb2axi #(
    parameter ADDR_W = 32,
    parameter DATA_W = 32,
    parameter ID_W   = 4
)(
    input  wire                 clk,
    input  wire                 rst_n,

    // ---- AHB-Lite 从口（任务四 1.2 / 0.4，接 Cortex-M0）----
    input  wire                 HSEL,
    input  wire [ADDR_W-1:0]    HADDR,
    input  wire [1:0]           HTRANS,
    input  wire                 HWRITE,
    input  wire [2:0]           HSIZE,
    input  wire [2:0]           HBURST,
    input  wire [3:0]           HPROT,
    input  wire [DATA_W-1:0]    HWDATA,
    output wire [DATA_W-1:0]    HRDATA,
    output wire                 HREADY,
    output wire                 HRESP,

    // ---- AXI4 主口（任务四 0.3，主设备 ID=0）----
    output wire [ID_W-1:0]      m_axi_awid,
    output wire [ADDR_W-1:0]    m_axi_awaddr,
    output wire [7:0]           m_axi_awlen,
    output wire [2:0]           m_axi_awsize,
    output wire [1:0]           m_axi_awburst,
    output wire                 m_axi_awvalid,
    input  wire                 m_axi_awready,
    output wire [DATA_W-1:0]    m_axi_wdata,
    output wire [DATA_W/8-1:0]  m_axi_wstrb,
    output wire                 m_axi_wlast,
    output wire                 m_axi_wvalid,
    input  wire                 m_axi_wready,
    input  wire [ID_W-1:0]      m_axi_bid,
    input  wire [1:0]           m_axi_bresp,
    input  wire                 m_axi_bvalid,
    output wire                 m_axi_bready,
    output wire [ID_W-1:0]      m_axi_arid,
    output wire [ADDR_W-1:0]    m_axi_araddr,
    output wire [7:0]           m_axi_arlen,
    output wire [2:0]           m_axi_arsize,
    output wire [1:0]           m_axi_arburst,
    output wire                 m_axi_arvalid,
    input  wire                 m_axi_arready,
    input  wire [ID_W-1:0]      m_axi_rid,
    input  wire [DATA_W-1:0]    m_axi_rdata,
    input  wire [1:0]           m_axi_rresp,
    input  wire                 m_axi_rlast,
    input  wire                 m_axi_rvalid,
    output wire                 m_axi_rready
);

    // Serialize AHB data phases. Each accepted NONSEQ/SEQ becomes one AXI
    // beat; use the master's actual address so WRAP, BUSY, early termination
    // and undefined-length INCR do not require guessing a future burst length.
    localparam IDLE=0, W_CAPTURE=1, W_SEND=2, W_RESP=3,
               R_ADDR=4, R_DATA=5, ERROR_FIRST=6, COMPLETE=7;
    reg [2:0] state;
    reg [ADDR_W-1:0] addr;
    reg [2:0] size;
    reg [DATA_W-1:0] wdata, rdata;
    reg aw_done, w_done, resp_err;

    assign HREADY = (state == IDLE || state == COMPLETE);
    assign HRESP = resp_err;
    assign HRDATA = rdata;
    wire accept_addr = HREADY && HSEL && HTRANS[1];
    wire aw_hs = m_axi_awvalid && m_axi_awready;
    wire w_hs = m_axi_wvalid && m_axi_wready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            addr <= 0; size <= 2; wdata <= 0; rdata <= 0;
            aw_done <= 0; w_done <= 0; resp_err <= 0;
        end else if (accept_addr) begin
            addr <= HADDR;
            size <= HSIZE;
            aw_done <= 0; w_done <= 0; resp_err <= 0;
            state <= HWRITE ? W_CAPTURE : R_ADDR;
        end else case (state)
            IDLE: resp_err <= 0;
            W_CAPTURE: begin wdata <= HWDATA; state <= W_SEND; end
            W_SEND: begin
                if (aw_hs) aw_done <= 1;
                if (w_hs) w_done <= 1;
                if ((aw_done || aw_hs) && (w_done || w_hs)) state <= W_RESP;
            end
            W_RESP: if (m_axi_bvalid) begin
                resp_err <= m_axi_bresp[1];
                state <= m_axi_bresp[1] ? ERROR_FIRST : COMPLETE;
            end
            R_ADDR: if (m_axi_arready) state <= R_DATA;
            R_DATA: if (m_axi_rvalid) begin
                rdata <= m_axi_rdata;
                resp_err <= m_axi_rresp[1];
                state <= m_axi_rresp[1] ? ERROR_FIRST : COMPLETE;
            end
            ERROR_FIRST: state <= COMPLETE; // HRESP=1, HREADY=0 then HREADY=1
            COMPLETE: begin state <= IDLE; resp_err <= 0; end
            default: state <= IDLE;
        endcase
    end

    assign m_axi_awid = 0;
    assign m_axi_awaddr = addr;
    assign m_axi_awlen = 0;
    assign m_axi_awsize = size;
    assign m_axi_awburst = 2'b01;
    assign m_axi_awvalid = (state == W_SEND) && !aw_done;
    assign m_axi_wdata = wdata;
    assign m_axi_wstrb = ((1 << (1 << size)) - 1) << addr[1:0];
    assign m_axi_wlast = 1'b1;
    assign m_axi_wvalid = (state == W_SEND) && !w_done;
    assign m_axi_bready = (state == W_RESP);
    assign m_axi_arid = 0;
    assign m_axi_araddr = addr;
    assign m_axi_arlen = 0;
    assign m_axi_arsize = size;
    assign m_axi_arburst = 2'b01;
    assign m_axi_arvalid = (state == R_ADDR);
    assign m_axi_rready = (state == R_DATA);
endmodule
