# 阶段 4 契约 S：`soc_top` 对外端口（冻结版）

> **状态**：⬜ 待三人确认 → 确认后冻结
> **依据**：[阶段4-三人分工.md](阶段4-三人分工.md) §1、
> [任务三_地址映射与中断分配.md](任务三_地址映射与中断分配.md)、
> [任务四_模块接口信号清单.md](任务四_模块接口信号清单.md)、
> [契约C-AXI ID编码.md](契约C-AXI ID编码.md)
> **维护**：A（SoC 顶层集成）
>
> 本契约是阶段 4 **唯一**需要开会冻结的接口。C 的 `TB/tb_soc.v` 必须按 §S.1 例化。

---

## S.0 范围

`soc_top` 是整片 SoC 的顶层，**对外只有 4 根信号线**。内部把阶段 1~3 的模块按 §S.4 的地址映射连起来。

内部怎么连是 A 的实现细节；但下面三样同样是**冻结项**（别人要按它写代码/测试）：

- **§S.1 的端口** —— C 的 `tb_soc.v` 按它例化；
- **§S.4 的地址映射** —— C 的 `sw/linker.ld` 和驱动按它编址；
- **§S.5 的中断分配** —— C 的 `sw/startup.s` 向量表和 ISR 按它排。

---

## S.1 模块头（冻结，逐字照抄）

```verilog
module soc_top #(
    parameter ADDR_W     = 32,
    parameter DATA_W     = 32,
    parameter ID_W       = 4,
    parameter SRAM_BYTES = 65536,       // 片内 SRAM 大小（64KB）
    parameter CLK_FREQ   = 100_000_000, // 时钟频率（Hz），给 UART 算波特率用
    parameter UART_DIV   = 10           // UART 分频：BAUD = CLK_FREQ / UART_DIV
)(
    input  wire clk,        // 单一时钟域（仿真里可用 100MHz，综合目标 50MHz）
    input  wire rst_n,      // 低有效异步复位
    output wire uart_txd,   // UART 发送（对外引脚）
    input  wire uart_rxd    // UART 接收（对外引脚）
);
```

---

## S.2 端口语义

| 端口 | 方向 | 位宽 | 语义 | 空闲电平 |
|---|---|---|---|---|
| `clk` | in | 1 | 全片**单一时钟域**，所有模块共用一个时钟 | — |
| `rst_n` | in | 1 | 低有效复位，**异步置位、同步释放**（见 S.7） | 高 |
| `uart_txd` | out | 1 | UART 发送线（对 PC 的 RX） | 高（UART 空闲态） |
| `uart_rxd` | in | 1 | UART 接收线（对 PC 的 TX） | 高 |

> **对外没有其它信号**：没有 SWD、没有 GPIO、没有外部存储器接口。

---

## S.3 参数语义

| 参数 | 默认 | 语义 | 透传给谁 |
|---|---|---|---|
| `ADDR_W` | 32 | 地址位宽 | 所有子模块 |
| `DATA_W` | 32 | 数据位宽 | 所有子模块 |
| `ID_W` | 4 | AXI ID 位宽（与互连、契约C 一致） | `axi_ic` / `dma` |
| `SRAM_BYTES` | 65536 | 片内 SRAM 字节数（64KB） | `axi_sram`（B 已交付，挂在互连 **m3**） |
| `CLK_FREQ` | 100_000_000 | 时钟频率（Hz） | `uart_apb`（算波特率用） |
| `UART_DIV` | 10 | UART 分频系数 | `uart_apb`：**内部换算** `BAUD = CLK_FREQ / UART_DIV` |

---

## S.4 地址映射（冻结）

**以现有互连译码为准**（`RTL/axi_ic.v` 的 `f_decode`，阶段 2 已冻结、已测 527 项）：

| 基地址 | 大小 | 模块 | 互连主口 | 说明 |
|---|---|---|---|---|
| `0x0000_0000` | 64KB | **片内 SRAM**（程序+数据+栈） | **`m3`** | 方案 B：CPU 复位后从这里取向量表 |
| `0x2000_0000` | 64KB | （预留 / 未用） | `m2` | 方案 B 下空出，tie-off |
| `0x4000_0000` | 4KB | ⑤ 81 阶 FIR | `m0` | |
| `0x4000_1000` | 4KB | ⑥ DMA 配置口 | `m1` | |
| `0x4000_2000` | 64KB | ④ AXI→APB 桥（内含 UART） | `m4` | UART 绝对地址 = `0x4000_2000` |

**主设备**：CPU（AHB/AXI 桥，**ID = 0**）、DMA 数据口（**ID = `{CH[2:0], 1'b1}`**，见契约C）。

**内部寄存器偏移**（相对各自基址，详见任务三 §4）：

| 模块 | 偏移 | 寄存器 |
|---|---|---|
| FIR | `0x000` / `0x004` / `0x008` / `0x00C` / `0x100+` | CTRL(W) / DIN(W) / DOUT(R) / **STATUS(R)** / COEF(W) |
| DMA | `0x00+0x10·N` … `0x0C+0x10·N` | SRC / DST / LEN / CTRL（契约AB §1） |
| UART | `0x000` / `0x004` | DATA(W) / STATUS(R) |

> ✅ 分工文档早期版本这里写错过（写成 `m2`），**已在 `3a61f0a` 修正为 `m3`**；本表与其一致。

---

## S.5 中断向量分配（冻结，来源：任务三 §5.2）

CPU 的 `IRQ[31:0]` 输入按下表连线（IRQ 号 = 异常号 − 16）：

| IRQ | 中断源 | `soc_top` 里的来源 | 类型 |
|---|---|---|---|
| `IRQ0` | FIR 滤波完成 | `fir.irq_done` | 电平 |
| `IRQ1` | FIR 错误（溢出/读空） | `fir.irq_err` | 电平 |
| `IRQ2`~`IRQ7` | DMA 通道 0~5 完成 | `dma.irq_done[5:0]` | 电平 |
| `IRQ8` | DMA 全局错误 | `dma.irq_err` | 电平 |
| `IRQ9`~`IRQ10` | 预留空档 | 恒 0 | — |
| `IRQ11` / `IRQ12` | UART RX / TX 完成 | ⚠️ **当前 `uart_apb.v` 无中断输出** → 恒 0 | — |
| `IRQ13`~`IRQ31` | 预留空档 | 恒 0 | — |

> 排序规则（任务三 §1）：完成中断号 < 错误中断号；同模块中断号连续。

---

## S.6 决策 D1：ROM Boot 不做（方案 B）

**决定：采用方案 B —— 片内 SRAM 放在 `0x0000_0000`，程序 / 数据 / 栈共用 64KB，不做 ROM。**

理由（分工文档 §1）：M0 复位后从 `0x0` 取初始栈指针、`0x4` 取复位入口，只要 `0x0` 有可读存储器即可启动；
初赛不考查 ROM/SRAM 分区，报告里注明「初赛简化处理」即可。**省一个 `axi_rom.v` 模块和半天调试。**

**带来的约束**：

1. SRAM 必须挂在互连**译码到 `0x0` 的那条主口（`m3`）**上 —— 见 S.10-②；
2. C 的 `linker.ld` 里 `.text/.data/.bss/栈` 全部落在 `0x0000_0000` 起的 64KB 内；
3. 固件必须**能被 `$readmemh` 直接装进 SRAM**（C 的 `tb_soc.v` 用层次化引用或后门写入）。

---

## S.7 时钟与复位

- **单一时钟域**：全片只用 `clk`，模块之间无跨时钟域，不需要同步器。
- **时钟频率**：仿真建议 100MHz（周期 10ns）；综合目标 50MHz。
- **复位**：`rst_n` 低有效。要求 **异步置位、同步释放**（`soc_top` 内部做两级同步释放后
  再分发给各模块的同步复位；M0 的 `ARESETn` 直接用 `rst_n`，它是异步复位输入）。
- **复位期间**：所有 AXI `VALID` 必须为 0（协议检查器规则 R1）。

---

## S.8 SWD 调试口

**本 IP（`cortexm0ds.v`，DesignStart macro cell）不暴露 SWD/SWDIO/SWCLK 端口** —— 已核对
`RTL/cpu/cortexm0ds/`，该目录下无任何 SWD 引脚。

所以分工文档 §1 那句「SWD 仿真里不接、A 在顶层固定电平」**在本 IP 上无需处理**（没有可接的脚）。

---

## S.9 内部集成要点（A 实现，列出以便对齐）

```
   cortexm0ds_logic.v（AHB-Lite 核）
          │ AHB-Lite
   ahb2axi.v                        ← 主设备 ID = 0（契约C）
          │ AXI4
   axi_ic.v + axi_arbiter.v         ← 2 主 × 5 从
     ├─ m0 → fir.v            @0x4000_0000
     ├─ m1 → dma.v            @0x4000_1000
     ├─ m2 →（预留，tie-off）
     ├─ m3 → axi_sram.v       @0x0000_0000   ← B 已交付
     └─ m4 → axi_to_apb.v ──APB──► uart_apb.v @0x4000_2000
```

模块清单与来源：

| 模块 | 文件 | 来源 |
|---|---|---|
| Cortex-M0 核 | `RTL/cpu/cortexm0ds/cortexm0ds_logic.v` | 赛题指定 IP |
| AHB→AXI 桥 | `RTL/ahb2axi.v` | 阶段2 B |
| AXI 互连 + 仲裁 | `RTL/axi_ic.v` + `RTL/axi_arbiter.v` | 阶段2 A |
| FIR | `RTL/fir.v` + `RTL/fir_core.v` | 阶段1 |
| DMA | `RTL/dma.v` + `dma_regs.v` + `dma_engine.v` | 阶段3 |
| 片内 SRAM | `RTL/axi_sram.v` | 阶段4 B |
| AXI→APB 桥 | `RTL/axi_to_apb.v` | 阶段1 |
| UART | `RTL/uart_apb.v` + `uart_rx.v` + `uart_tx.v` | 阶段1 |

**B 的 SRAM 已交付**（`RTL/axi_sram.v`）：A 直接接互连 **`m3_axi_*`** 即可；若一时还没合上，可先用「端口齐全、读恒 0」的空壳占位。

---

## S.10 与分工文档的 4 处不一致（✅ 已全部拍定并写回文档）

写本契约时逐条对照 RTL 发现 4 处，**已全部拍定并写回 `docs/阶段4-三人分工.md`**：

| # | 原问题 | 结论 | 落在哪 |
|---|---|---|---|
| ① | CPU 走 AHB-Lite 还是 AXI 含糊 | 采用 **`cortexm0ds_logic.v`（AHB-Lite）+ 我们的 `ahb2axi.v`（补 ID=0）**；`cortexm0ds.v`（自带 ARM 桥、对外 AXI 且无 ID）**不采用** | 分工文档 §2.1 框图 + 注释 |
| ② | 「SRAM @`0x0` 挂 `m2`」 | **改挂 `m3`**（互连译码 `0x0 → m3`）；`m2` 留空并接静态无效值 | 分工文档 §1（提交 `3a61f0a`） |
| ③ | 契约 S 的 `UART_DIV` 透不到 `uart_apb` | **新增 `CLK_FREQ` 参数**，内部换算 `BAUD = CLK_FREQ / UART_DIV` | 分工文档 §1 + 本契约 §S.1 / §S.3 |
| ④ | 「M0 的 SWD 顶层固定电平」 | 本 IP **无 SWD 端口**，该条作废 | 分工文档 §1 |

---

## S.11 依赖方与改动流程

**谁依赖本契约**：

| 依赖方 | 依赖什么 | 出错的后果 |
|---|---|---|
| **A**（`RTL/soc_top.v`） | 按 §S.1/S.4/S.5 连线 | 顶层编译不过 / 地址错 |
| **B**（`RTL/axi_sram.v`） | `SRAM_BYTES` 参数、AXI4 从口 | 例化不上 |
| **C**（`TB/tb_soc.v` + `sw/`） | 按 §S.1 例化、按 §S.4 编址、按 §S.5 排中断 | 固件跑飞 / 回显测不了 |

**要改这份契约怎么办**（不许私自改）：

1. 群里发起，说明**为什么要改**；
2. **三人同意**（涉及任务三/四的，通知对应的人）；
3. 本文升版本，写明改了什么、为什么；
4. **同步更新** `docs/阶段4-三人分工.md` 的对应段落；
5. 通知全队。

---

## S.12 验收（本契约相关）

- [ ] `soc_top.v` 编译通过（`iverilog -g2012 -Wall` 零告警）
- [ ] 端口/参数与 §S.1 **逐字一致**（C 的 `tb_soc.v` 能直接例化）
- [ ] 地址映射与 §S.4 逐条一致（C 的 `sw/` 能正确定位外设）
- [ ] 中断连线与 §S.5 逐条一致（IRQ0~IRQ8 接上，其余恒 0）
- [x] §S.10 的 4 处不一致**已全部拍定并写回分工文档** ✅

---

## S.12 【C 补充，请 A 确认】TB 需要的两处内部命名

`TB/tb_soc.v` 要通过**层次化引用**访问 `soc_top` 的内部信号，因此下面两处命名
必须固定。这两条不影响功能，但**改了 TB 就编译不过**，所以按契约对待。

| # | 要求 | TB 用它干什么 |
|---|---|---|
| ① | 片内 SRAM 的实例名必须是 **`u_sram`**（存储阵列沿用 `axi_sram.v` 的 `mem`） | `$readmemh` 装固件；读冒烟测试信箱（`dut.u_sram.mem[...]`）|
| ② | AHB→AXI 桥的实例名必须是 **`u_ahb2axi`** | 在它的 AXI 主口 `m_axi_*` 上挂 AXI 协议检查器（CPU 侧最繁忙的路径）|

举例（A 写 soc_top 时按这个命名即可）：

```verilog
axi_sram #(...) u_sram    ( ... );      // 名字必须是 u_sram
ahb2axi  #(...) u_ahb2axi ( ... );      // 名字必须是 u_ahb2axi
```

**为什么用层次化引用而不是加端口**：契约S §S.2 明确写了"对外只有 4 根信号线"，
为了测试而加调试端口会破坏这个冻结项。层次化引用是仿真专用手段，
不进综合网表，对 `soc_top` 的可综合性零影响。

> 补充人：C（阶段4 分工 C，`TB/tb_soc.v`）
> 状态：⬜ 待 A 确认后并入冻结版
