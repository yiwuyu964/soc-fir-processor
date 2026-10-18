# 阶段 3 契约 A：`dma_regs` → `dma` 顶层的配置总线

> **状态**：待三人确认 → 确认后冻结（语义已与 [契约AB-DMA内部接口.md](契约AB-DMA内部接口.md) 对齐）
> **依据**：`docs/阶段3-三人分工.md` §2.1、`docs/任务三_地址映射与中断分配.md` §4.2、
> [契约AB-DMA内部接口.md](契约AB-DMA内部接口.md)（**语义以它为准**）
> **维护**：A（配置通路与顶层集成）
>
> 这是阶段 3 要冻结的**第一个内部接口**（第二个是契约 B 的 `dma_engine` 端口）。
> 语义的完整/权威定义在契约AB；本文只把「配置总线」这一条单独列清楚。

---

## A.0 范围

定义 `dma_regs`（AXI4 从口 + 24 个寄存器）与 `dma` 顶层之间**唯一的配置通路**。
它是 6 通道配置的「展平」出口：6 个通道 × 32bit，拼成一条宽向量，不经过数组端口
（保证可移植、例化时不用管数组端口的方向歧义）。

- `dma_regs` 是**输出方**（配置）＋**输入方**（状态回读）。
- `dma` 顶层是**输入方**（配置）＋**输出方**（状态回读）。

---

## A.1 信号清单（5 条，全部展平成 `[6*32-1:0]`）

```verilog
// dma_regs 输出 → dma 顶层（配置）
output wire [6*32-1:0] cfg_src;    // 每通道源地址，通道 ch 占 [ch*32 +: 32]
output wire [6*32-1:0] cfg_dst;    // 每通道目的地址
output wire [6*32-1:0] cfg_len;    // 每通道传输字数（32bit 字个数）
output wire [6*32-1:0] cfg_ctrl;   // 每通道控制：bit0 START / bit1 SRC_INC / bit2 DST_INC

// dma_regs 输入 ← dma 顶层（状态回读）
input  wire [6*32-1:0] st_status;  // 每通道状态：bit0 BUSY / bit1 DONE / bit2 ERR
```

| 信号 | 方向（相对 dma_regs） | 位宽 | 每通道含义 |
|---|---|---|---|
| `cfg_src` | 输出 | 192 | 源地址（字节地址） |
| `cfg_dst` | 输出 | 192 | 目的地址（字节地址） |
| `cfg_len` | 输出 | 192 | 传输字数（32bit 字个数） |
| `cfg_ctrl` | 输出 | 192 | 控制字（位布局见 A.2） |
| `st_status` | 输入 | 192 | 状态字（位布局见 A.2） |

---

## A.2 位布局与切片约定

**切片**：通道 `ch`（0~5）占用 `[ch*32 +: 32]`，即 `cfg_xxx[ch*32+31 : ch*32]`。

**`cfg_ctrl[ch]`**：

| 位 | 名称 | 说明 |
|---|---|---|
| [0] | START | **一拍脉冲**（不是电平）：`dma_regs` 在 CPU 写 CTRL[0]=1 的下一拍产一拍高电平，其余恒 0（契约AB §1.2） |
| [1] | SRC_INC | 1 = 源地址每次传输递增 4（字节）；0 = 固定地址 |
| [2] | DST_INC | 1 = 目的地址每次传输递增 4；0 = 固定地址 |
| [31:3] | 保留 | 读回 0 |

**`st_status[ch]`**：

| 位 | 名称 | 说明 |
|---|---|---|
| [0] | BUSY | 通道正在搬运 |
| [1] | DONE | 传输完成 |
| [2] | ERR | 传输出错（AXI 回 SLVERR） |
| [31:3] | 保留 | 读回 0 |

---

## A.3 寄存器映射（外部 AXI 视角，基址 `0x4000_1000`）

每通道 16 字节，通道 N 的寄存器在 `0x10·N + 偏移`：

| 偏移 | 名称 | 访问 | 说明 |
|---|---|---|---|
| `0x00` | SRC | W | 源地址（字节） |
| `0x04` | DST | W | 目的地址（字节） |
| `0x08` | LEN | W | 传输字数（32bit 字个数） |
| `0x0C` | CTRL | W/R | 写：bit0 START（自清）/ bit1 SRC_INC / bit2 DST_INC；读：bit29 ERR / bit30 BUSY / bit31 DONE |

> ✅ CTRL 读语义已由契约AB §1.4 定死：`[31]=DONE`（←`st_status[ch][1]`）、`[30]=BUSY`（←`st_status[ch][0]`）、
> `[29]=ERR`（←`st_status[ch][2]`）、`[1]=SRC_INC`、`[2]=DST_INC`、`[0]=恒 0`。满足任务三 4.2 的「bit31 DONE」。

---

## A.4 语义

1. **START**：`cfg_ctrl[ch][0]` 是 **dma_regs 已生成的一拍脉冲**（不是电平）。CPU 写 `CTRL[ch][0]=1`
   后，`dma_regs` 在下一拍产生一个时钟周期的高电平，且 START 位**自动清 0**（读回恒 0）。
   顶层把该脉冲**直接接** `dma_engine` 的 `start`，**不做边沿检测**（契约AB §1.2 / §1.4）。
2. **SRC_INC / DST_INC**：电平信号，对应「三种传输场景」的地址是否递增
   （存储器↔存储器 = 1/1；存储器↔FIR 的 DIN = 1/0；FIR 的 DOUT↔存储器 = 0/1；
   UART↔存储器 同理）。
3. **BUSY / DONE / ERR**：`dma_engine` 上报的电平状态，由顶层汇总进 `st_status`。
   - `DONE` 是**传输完成**（不是中断）；中断 `irq_done[ch]` 由顶层另行生成（契约 §2.4）。
   - `ERR` 是**出错**；中断 `irq_err` 由顶层另行生成。

---

## A.5 与契约 B 的衔接（A 在顶层做展开）

`dma_regs` 只给**展平向量**，`dma_engine`（契约 B）要的是**单通道标量**。
由 `dma` 顶层（A）负责展开，映射关系固定如下：

| 契约 A（展平） | 契约 B（每通道标量） |
|---|---|
| `cfg_src[ch*32 +: 32]` | `cfg_src`（该通道实例的 32bit 源地址） |
| `cfg_dst[ch*32 +: 32]` | `cfg_dst` |
| `cfg_len[ch*32 +: 32]` | `cfg_len[31:0]` |
| `cfg_ctrl[ch*32 + 1]`（SRC_INC） | `cfg_src_inc` |
| `cfg_ctrl[ch*32 + 2]`（DST_INC） | `cfg_dst_inc` |
| `cfg_ctrl[ch*32 + 0]`（START 一拍脉冲） | `start`（一拍脉冲，直连，不做边沿检测） |
| `st_status[ch*32 +: 32]` | `busy` / `done` / `err` / `status` 汇总 |

---

## A.6 待确认项（已确认 ✅）

1. ✅ **CTRL 的 bit31 DONE 映射**：契约AB §1.4 已定 —— CPU 读 CTRL 时，
   `[31]=DONE`（←`st_status[ch][1]`）、`[30]=BUSY`（←`st_status[ch][0]`）、`[29]=ERR`（←`st_status[ch][2]`）、
   `[1]=SRC_INC`、`[2]=DST_INC`、`[0]=恒 0`。与本文原建议一致。
2. ✅ **START 的脉冲/自清**：契约AB §1.2/§1.4 已定 —— `cfg_ctrl[ch][0]` 是 `dma_regs` 生成的
   **一拍脉冲**，START 位**自清**（读回恒 0），顶层直连 `start`，不做边沿检测。与本文原建议一致。
