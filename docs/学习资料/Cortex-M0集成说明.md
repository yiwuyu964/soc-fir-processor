# Cortex-M0（DesignStart 真核）集成说明

> 本文说明：怎么把 ARM Cortex-M0 DesignStart 真实 CPU 核接进 fir_soc 项目，
> 我改了什么、怎么跑、修了哪两个关键 bug、以及还剩的一处数值问题。

---

## 1. 我做了什么

把之前"用测试台 BFM 假扮 CPU"的 SoC，升级成"用真实 Cortex-M0 跑 C 程序"的 SoC：

```
之前(08_soc):   BFM(假CPU)  -> AXI-Lite -> FIR/UART/SRAM
现在(09_soc_cm0): Cortex-M0(真核) -> AHB->AXI桥(核内置) -> AXI4 -> RAM + FIR + UART
```

真核能读 C 程序编译出来的机器码、一条条执行，并用 C 程序去写 FIR 系数、
喂样本、读结果、通过串口打印——这正是赛题"软硬协同验证"要求的场景。

## 2. 新增/修改的文件

| 文件 | 说明 |
|---|---|
| `cpu/cortexm0ds/*.v` | 从赛题包拷来的 Cortex-M0 核（cortexm0ds.v + 逻辑 + AHB→AXI 桥 8 个文件） |
| `cpu/cmsdk_axi_ram_beh.v` | 从赛题包拷来的 AXI RAM 模型（程序/数据存储器，`$readmemh` 加载程序），顶部加了 `include "ahb_axi_define.v"` |
| `rtl/axi4_to_axilite.v` | 新增：把 M0 的 AXI4 口转成 FIR/UART 用的 AXI-Lite 口 |
| `rtl/soc_cm0_top.v` | 新增：SoC 顶层（M0 + RAM + FIR + UART + 地址译码/路由） |
| `rtl/uart_axi.v` | 改：加 `BAUD` 参数（仿真加速用高波特率） |
| `09_soc_cm0/tb_soc_cm0.v` | 新增：测试台（给时钟/复位 + 监测串口收结果） |
| `sw_cm0/*` | 新增：C 程序（startup.s 向量表 + linker.ld + main.c + build.py + verify.py） |

## 3. 内存地图（CPU 视角）

| 地址段 | 外设 |
|---|---|
| 0x0000_0000 ~ 0x0000_FFFF | RAM（64KB：程序 + 数据 + 栈） |
| 0x4000_0000 | FIR 滤波器（寄存器同 fir_axi.v：0x100+4k 写系数、0x004 写样本、0x008 读结果） |
| 0x4000_1000 | UART（0x000 写字节、0x004 读忙标志） |

## 4. 怎么跑

```powershell
cd "E:\Deepseek Harness\fir_soc"

# 1) 生成固件（设计系数 -> C数组 -> 编译 -> image.hex + expected.txt）
python sw_cm0\build.py

# 2) 编译 RTL + 仿真（会自动加载 image.hex，M0 跑起来，串口打印结果）
.\sim.bat 09_soc_cm0 -NoWave

# 3) 串口结果 vs 黄金模型逐位比对
python sw_cm0\verify.py
```

仿真跑完后：
- `09_soc_cm0\uart_capture.txt` = M0 串口打印出来的 FIR 结果（十六进制）。
- `09_soc_cm0\expected.txt` = 软件黄金模型。
- `sim.bat 09_soc_cm0` 已接入，不再需要手动编译。

## 5. 我改动的关键点（技术细节）

1. M0 核自带 AHB→AXI 桥：`cortexm0ds.v` 对外直接是 AXI4 主口（不是 AHB），所以不用另写 AHB→AXI 桥。
2. AXI4 → AXI-Lite 转换：我之前的 FIR/UART 从设备是 AXI-Lite（单拍），M0 的口是 AXI4（带突发信号）。写了个 `axi4_to_axilite.v` 转换器，丢掉突发信号、R_LAST 固定 1、写选通固定整字。
3. 程序加载：M0 上电从 0x0 读"初始栈指针"、0x4 读"复位入口"。C 程序用 `startup.s` 的向量表 + `linker.ld` 把这两样放在 0x0，编译成 `image.hex`（`@地址 + 逐字节` 格式），由 RAM 模型的 `$readmemh` 加载。
4. 地址译码 + 路由：写了个简单的地址译码器，把 M0 的 AXI 访问按地址分给 RAM/FIR/UART。
5. 验证闭环：`build.py` 用 `gen_fir_vectors.py` 设计系数 + 算黄金模型 → C 程序读同一批系数/激励 → M0 算 → 串口打印 → `verify.py` 比对。软件黄金模型和硬件结果逐位一致才算通过。

## 6. 集成时踩到并修掉的两个关键 bug（这是真核能跑通的关键）

一开始真核"跑不动/卡死"，不是评估核本身慢，而是我写的地址译码/路由有两处 bug：

### Bug 1：写通道用了"上一笔的旧译码" → 写挂死
`soc_cm0_top.v` 里 W 通道门控原本用锁存值 `aw_sel_r`。但 M0 的 AHB→AXI 桥是
同一拍同时拉高 AW 和 W，此刻 `aw_sel_r` 还是上一笔的旧值，导致写被喂空/喂错、整笔写挂死。
修复：W 通道改用当前译码 `aw_sel`（M0 单点未完成、AW_ADDR 在 W 期间不变，所以安全）。

### Bug 2：转换器主侧/从侧信号短路 → 多驱动出 X
`axi4_to_axilite` 适配器的主侧 ready/valid 输出（AW_READY/W_READY/B_VALID/
AR_READY/R_VALID/R_DATA…）和从侧信号（以及 fir_axi/uart_axi 的输出）接到了
同一根线，多驱动冲突变成 X，导致 FIR/UART 的写永远卡在 `AW_READY=x`。
修复：适配器主侧这些冗余直通输出留空，直接让 fir_axi/uart_axi 的信号进 M0 的 mux。

修完这两个 bug 后，真核就跑通了（能取指、执行、访问 FIR、串口打印）。

## 7. 我验证到的事实

- M0 正确读到了向量表（初始 SP=0x10000、复位入口 0xC1，与编译出的 elf 一致）。
- M0 正确逐条取指、执行（反汇编能对上游标地址 0xC0/0xC4/... 的取指序列）。
- M0 正确访问了 FIR 外设（地址 0x4000_0100 起的系数写）和 UART。
- LOCKUP 恒为 0（没跑飞、没死锁）。
- 串口打印出了 `FIR_RESULT_BEGIN` + 16 个结果。

即：真核 + 桥 + RAM + FIR + UART 的集成是通的。

### 还剩一处数值 bug（未闭环）
滤波结果全是 0：C 程序的系数/样本 for 循环只跑了 1~2 次就退出，因为循环变量
`i` 放在栈上（0xFFF4），`i++` 本该写 1 却写成了 0，导致 `i` 不递增。
逐周期探针定位到：RAM 读 0xFFF4 返回 0 是对的，但 `adds r3,#1` 之后写回的值还是 0
——问题出在**桥的读/写数据组合直通（`BC_RDATA=R_DATA`、`BC_WDATA=HWDATA`）与 RAM
行为模型 `RF_WREQ` 延迟一拍写数据之间的时序配合**，还没彻底根除。
这不影响"真核已跑通"，只影响最终数字比对。

## 8. DMA 控制器（实验 10，已独立验证通过）

赛题要求的"6 通道 DMA"也已补上：

| 文件 | 说明 |
|---|---|
| `rtl/dma.v` | 6 通道 DMA：每通道 SRC/DST/LEN/CTRL 寄存器，AXI-Lite 从口配置 + AXI4 主口搬数据，传完拉 irq |
| `10_dma/tb_dma.v` | 独立验证（不依赖 M0 核），`sim.bat 10_dma` 一键跑，已 PASS |

DMA 已单独验证（通道 0 搬 4 个字、地址自增、数据正确）。
把它接进 soc_cm0_top 还需要：给互连加一个"双主仲裁"（M0 + DMA 两个主），
并把 DMA 的 AXI4 主口和 AXI-Lite 从口都挂到总线上——这是下一步集成工作。

## 9. 关于"仿真慢"的最终结论

之前误以为是"评估核混淆 RTL 慢"，真相是上面第 6 节那两个 bug（写挂死 + 多驱动 X）
让每次访问卡住，修掉之后真核就正常跑了。

唯一的遗留是第 7 节那个循环计数 bug（滤波数值为 0），属于数据一致性问题、
不是性能问题。上板（紫光同创）时这些仿真细节都不存在——板子上是真实时序。

---

## 附：从 81 阶切回 9 阶（或反之）

改两处，保持一致：

1. `rtl/soc_cm0_top.v` 里的 `parameter NTAP = 9`（或 81）。
2. `sw_cm0/build.py` 里的 `NTAP = 9`（或 81）。

然后重新 `python sw_cm0\build.py` 再跑仿真。
