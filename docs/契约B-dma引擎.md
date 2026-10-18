# 阶段 3 契约 B：`dma_engine` 的端口（单通道数据搬运引擎）

> **状态**：待三人确认 → 确认后冻结
> **依据**：`docs/阶段3-三人分工.md` §2.2、
> [契约AB-DMA内部接口.md](契约AB-DMA内部接口.md) §2（**语义以它为准**）、
> [契约C-AXI ID编码.md](契约C-AXI ID编码.md)（AXI ID）
> **维护**：B（数据搬运引擎）
>
> 这是阶段 3 要冻结的**第二个内部接口**（第一个是契约 A 的配置总线）。
> 语义的完整/权威定义在契约AB；本文只把「dma_engine 端口」这一条单独列清楚，
> 并把它**要发出去的 AXI 事务规格**钉死，方便评审和 B 的实现对照。

---

## B.0 范围

定义 6 通道 DMA 里**每个通道的数据搬运引擎** `dma_engine` 的对外端口与行为。
它由 `dma` 顶层（A）实例化 6 次（`CH=0..5`），对外是一个标准 AXI4 主口。

- **配置侧**：吃**单通道标量**配置（契约 A 的展平向量由顶层解包后送入，见 B.8）。
- **数据侧**：标准 AXI4 主口，ID 按契约 C 编码（`{CH[2:0], 1'b1}`）。

---

## B.1 端口清单（完整，29 个 AXI 信号）

```verilog
module dma_engine #(
    parameter ADDR_W = 32,
    parameter DATA_W = 32,
    parameter ID_W   = 4,
    parameter LEN_W  = 8,
    parameter CH     = 0            // 通道号，用于生成 AXI ID（契约 C）
)(
    input  wire                clk,
    input  wire                rst_n,

    // ---- 配置（来自 dma_regs，顶层解包后送入）----
    input  wire [ADDR_W-1:0]   cfg_src,
    input  wire [ADDR_W-1:0]   cfg_dst,
    input  wire [31:0]         cfg_len,       // 传输字数（32bit 字个数）
    input  wire                cfg_src_inc,   // 0 = 源地址保持（UART/FIR 固定地址）
    input  wire                cfg_dst_inc,   // 0 = 目的地址保持
    input  wire                start,         // 一拍脉冲，顶层直连，不做边沿检测

    // ---- 状态 ----
    output wire                busy,
    output reg                 done,          // 完成脉冲（一拍）
    output reg                 err,           // 错误脉冲（一拍）
    output wire [31:0]         status,        // bit0 BUSY / bit1 DONE / bit2 ERR

    // ---- AXI4 主口（标准信号，交给顶层仲裁）----
    output wire [ID_W-1:0]     m_awid,
    output wire [ADDR_W-1:0]   m_awaddr,
    output wire [LEN_W-1:0]    m_awlen,
    output wire [2:0]          m_awsize,
    output wire [1:0]          m_awburst,
    output wire                m_awvalid,
    input  wire                m_awready,
    output wire [DATA_W-1:0]   m_wdata,
    output wire [DATA_W/8-1:0] m_wstrb,
    output wire                m_wlast,
    output wire                m_wvalid,
    input  wire                m_wready,
    input  wire [ID_W-1:0]     m_bid,
    input  wire [1:0]          m_bresp,
    input  wire                m_bvalid,
    output wire                m_bready,
    output wire [ID_W-1:0]     m_arid,
    output wire [ADDR_W-1:0]   m_araddr,
    output wire [LEN_W-1:0]    m_arlen,
    output wire [2:0]          m_arsize,
    output wire [1:0]          m_arburst,
    output wire                m_arvalid,
    input  wire                m_arready,
    input  wire [ID_W-1:0]     m_rid,
    input  wire [DATA_W-1:0]   m_rdata,
    input  wire [1:0]          m_rresp,
    input  wire                m_rlast,
    input  wire                m_rvalid,
    output wire                m_rready
);
```

---

## B.2 端口语义（对照契约AB §2.3 / §2.4）

| 信号 | 类型 | 语义 |
|---|---|---|
| `start` | 输入，一拍脉冲 | 引擎在 `start` 有效那一拍**锁存配置**并开始；`busy=1` 时到来的 `start` 忽略；与复位同时有效时复位优先 |
| `busy` | 输出，电平 | `start` 被接受后**下一拍**拉高；最后一个写响应（B）到达或错误后拉低。与 `status[0]` 完全一致 |
| `done` | 输出，一拍脉冲 | 传输成功完成时拉高一拍（给中断逻辑用，避免重复触发） |
| `err` | 输出，一拍脉冲 | 发生错误时拉高一拍 |
| `status[1]`(DONE) | 输出，电平 | **保持**，直到下一次 `start` 被接受时清除（给寄存器读回用） |
| `status[2]`(ERR) | 输出，电平 | **保持**，直到下一次 `start` 被接受时清除 |

> 为什么 `done` 是脉冲、`status[DONE]` 是保持：脉冲给中断用，保持给 CPU 读回用。

---

## B.3 引擎发出的 AXI 事务（钉死，契约AB §2.5）

| 信号 | 值 | 说明 |
|---|---|---|
| `m_awsize` / `m_arsize` | `3'b010` | 每次传输 4 字节（一个字） |
| `m_wstrb` | `4'hF` | 整字写，永远是 4 位全 1 |
| `m_awlen` / `m_arlen` | `0 ~ 255` | 单个突发 1 ~ 256 拍 |
| `m_awid` / `m_arid` | `{CH[2:0], 1'b1}` | 契约 C |

**突发类型**（✅ 已确认，v1 定稿）：

| 场景 | `m_arburst` / `m_awburst` |
|---|---|
| `cfg_src_inc=1` / `cfg_dst_inc=1` | `2'b01`（INCR），地址每拍 +4 |
| `cfg_src_inc=0` / `cfg_dst_inc=0` | `2'b00`（FIXED），地址**保持不变**（FIR DIN/DOUT、UART 固定地址） |

> 已确认：固定地址用 FIXED 突发（`契约AB §2.5` 已同步更新）。

---

## B.4 突发拆分（契约AB §2.5，引擎负责，顶层不管）

1. 单个突发**不超过 256 拍**；
2. **不跨 4KB 边界** —— 拆点时取「距离下一个 4KB 边界还剩几个字」和「还剩几个字」的较小值；
3. 最后一个突发可以短于 256 拍。

> 举例：从 `0x4000_0FF0` 传 100 个字 → 第一段只能 4 拍（到 `0x4000_0FFF` 边界），
> 之后按 256 拍拆，最后一段是余数。

---

## B.5 配置锁存（契约AB §2.6）

引擎必须在 `start` 那一拍把 `cfg_src / cfg_dst / cfg_len / cfg_src_inc / cfg_dst_inc`
**锁存到内部寄存器**，整个传输过程只用锁存值。

**这样 `busy` 期间 CPU 改寄存器不影响正在跑的传输。**

---

## B.6 错误处理（契约AB §2.7）

**哪些算错误**：`BRESP/RRESP = SLVERR` 或 `DECERR`。

**发生错误时引擎要做的（顺序）**：
1. 停止发起新的 AXI 事务；
2. 把已发出的读写事务**收尾**（不能半路扔下，否则协议违规——尤其读突发必须收完所有 R 拍）；
3. 拉 `err` 一拍；
4. `status[2]` 置 1、`busy` 拉低；
5. 已搬过去的数据**不回滚**（DMA 不做原子性保证）。

---

## B.7 AXI 握手行为（契约AB §2.8）

- `m_awvalid / m_wvalid / m_arvalid`：一旦拉高就必须保持到握手（AXI 规范 A3.2.1）；
- `m_bready / m_rready`：能收就收，不做无谓背压；
- **VALID 不许等 READY**（组合依赖）—— 由 `TB/axi_protocol_checker.v` 代码审查；
- 顶层仲裁未授权时：引擎**保持 VALID 不变**（不许撤销），等授权。

---

## B.8 与契约 A 的衔接（A 在顶层做展开）

`dma_regs` 只给展平向量，`dma_engine` 要的是单通道标量，由 `dma` 顶层负责展开：

| 契约 A（展平） | 契约 B（每通道标量） |
|---|---|
| `cfg_src[ch*32 +: 32]` | `cfg_src`（该通道实例的 32bit 源地址） |
| `cfg_dst[ch*32 +: 32]` | `cfg_dst` |
| `cfg_len[ch*32 +: 32]` | `cfg_len[31:0]` |
| `cfg_ctrl[ch*32 + 1]`（SRC_INC） | `cfg_src_inc` |
| `cfg_ctrl[ch*32 + 2]`（DST_INC） | `cfg_dst_inc` |
| `cfg_ctrl[ch*32 + 0]`（START 一拍脉冲） | `start`（直连，不做边沿检测） |
| `st_status[ch*32 +: 32]` | `busy` / `done` / `err` / `status` 汇总 |

> 引擎状态 `status`（bit0 BUSY / bit1 DONE / bit2 ERR）由顶层打包进 `st_status[ch*32 +: 32]`，
> 再由 `dma_regs` 映射进 `CTRL[31:29]`（契约AB §1.4）。

---

## B.9 待确认项

| # | 事项 | 说明 | 建议 |
|---|---|---|---|
| 1 | `LEN=0` 语义 | `LEN=0` = 传 0 个字（不是 AXI 的 1 拍）；要传 1 个字写 `LEN=1`（契约AB §1.5 A-1） | 采纳 |
| 2 | `DONE`/`ERR` 只在下一次 `start` 清除 | 不加 W1C 位（契约AB §5 #4） | 采纳 |

---

## B.10 改动流程

**不许私自改。** 要改：

1. 群里发起，说明为什么；
2. 三人同意；
3. 本文升版本（v1 → v2）；
4. **同步更新** `契约AB-DMA内部接口.md` §2 和 `docs/阶段3-三人分工.md` §2.2 的端口表；
5. 通知全队。
