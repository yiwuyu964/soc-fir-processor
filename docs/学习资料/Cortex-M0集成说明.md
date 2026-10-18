# Cortex-M0 集成说明

> 文档信息 ｜ 类别：参考与手册类 ｜ 所属：跨阶段 ｜ 状态：在用 ｜ 索引：`docs/README.md §1.5`

本文说明真实 Cortex-M0 核是怎么接进这个 SoC 的：用了哪份 IP、走哪条总线、固件怎么装进存储器，以及集成时踩过哪几个坑。

需要交代一句背景。本文最初写的是早期原型（`fir_soc/09_soc_cm0`）的集成过程，那套目录结构已经废弃。下面按当前设计重写，历史教训保留在最后一节——它们的成因和现在这套实现是同一类问题。

## 一、用了哪份 IP

赛题指定的 Cortex-M0 核来自 ARM DesignStart，放在 `RTL/cpu/cortexm0ds/`，共 8 个文件。

这个目录下有**两个都能当 CPU 的顶层模块，接口完全不同**，选错了会白写一堆东西：

`cortexm0ds_logic.v` 是纯 AHB-Lite 核，输出 `haddr_o`/`htrans_o`/`hwrite_o`/`hsize_o`/`hburst_o`/`hwdata_o`，输入 `hrdata_i`/`hready_i`/`hresp_i`。本设计用的是它。

`cortexm0ds.v` 内部已经例化了 ARM 自带的 `ahb2axi4_if`，对外直接是 AXI4，而且**没有 ID 信号**。用它的话我们自己写的 `ahb2axi.v` 完全用不上，还得在顶层把互连从口的 ID 输入硬绑成 0。

选 `cortexm0ds_logic` 的原因很简单：赛题要求自己做 AHB→AXI 桥，用 `cortexm0ds.v` 等于把这项要求绕过去了，评分上拿不到分。而且我们自己的桥经过单独验证，出错时能定位。

## 二、总线链路

```
cortexm0ds_logic（AHB-Lite 核）
      │  AHB-Lite：haddr/htrans/hwrite/hsize/hburst/hwdata → hrdata/hready/hresp
ahb2axi（RTL/ahb2axi.v）           ← 主设备 ID 固定 0
      │  AXI4
axi_ic（RTL/axi_ic.v）+ axi_arbiter   ← 2 主 5 从
   ├─ m0 → FIR          @0x4000_0000
   ├─ m1 → DMA 配置口    @0x4000_1000
   ├─ m3 → SRAM（64KB）  @0x0000_0000   ← 注意是 m3
   ├─ m2 → 不用，接静态无效值
   └─ m4 → axi_to_apb → uart_apb @0x4000_2000
```

`m3` 还是 `m2` 这件事值得单独提醒。`axi_ic.v` 的译码函数里写的是 `a[31:16]==16'h0000 → 3'd3`，也就是说地址 `0x0` 那一段落在 **m3**，不是表格顺序上的 m2。如果把 SRAM 接到 m2，它的实际地址就变成 `0x2000_0000`，而 CPU 复位后从 `0x0` 取向量表，访问会打到悬空的 m3 上，返回 DECERR，SoC 根本起不来。

## 三、固件怎么放进去

Cortex-M0 复位后的行为是固定的：从地址 `0x0` 读初始栈指针（SP），从 `0x4` 读复位入口地址，HardFault 向量在 `0xC`。这三个值必须由向量表提供，而向量表必须在 `0x0`。

方案上做了一个简化：**SRAM 直接放在 `0x0`**，程序、数据、栈共用 64KB，不做 ROM Boot。初赛不考查 ROM/SRAM 分区，报告里注明简化处理即可。这样一来 `sw/startup.s` 的向量表就放在固件最前面，`sw/linker.ld` 把 `.text` 起始地址定在 `0x0`，SP 指向 SRAM 顶部。

固件构建链路是 `sw/build.py` → `firmware.hex`，测试台用 `$readmemh` 把 hex 装进 SRAM 数组。同时会生成 `.elf` 和 `.map`，调试时反汇编对照很方便。

这里有个必须注意的细节：`firmware.hex` 是被 gitignore 忽略的构建产物。**每次跑仿真前都要重新编译**，用旧文件会出很诡异的现象。

## 四、两个当时卡了很久的坑

这两条来自早期原型，但成因在现在这套实现里同样存在，值得记住。

**写通道用了上一笔的旧译码。** 原型里的 W 通道门控原本用锁存值 `aw_sel_r`。问题是 M0 的 AHB→AXI 桥在同一拍同时拉高 AW 和 W，此刻 `aw_sel_r` 还是上一笔的旧值，写数据就被送到了错误的从设备，整笔写挂死。改成用当前译码 `aw_sel` 就解决了——M0 的突发里 AWADDR 在 W 期间保持不变，所以当前译码是稳定的。

这个坑的教训是：AHB 的地址相位和数据相位重叠，任何"用上一拍锁存值"的思路都要先确认那一拍信号到底属于哪一笔传输。

**主从信号短路导致多驱动出 X。** 原型里的 AXI4→AXI-Lite 转换器把主侧的 ready/valid 输出和从侧信号接到了同一根线上，多驱动冲突后变成 X，结果 FIR 和 UART 的写永远卡在 `AW_READY = x`。现象是 CPU 看着在跑、但外设毫无反应。修法是把冗余的直通输出留空，让从设备的信号直接进 mux。

这两条合起来解释了一个当时很迷惑的现象：仿真慢到以为核本身有问题，实际是每次总线访问都卡住了。

## 五、当前验证状态

集成已经闭环，不是"能跑起来但数字不对"的状态：

| 检查项 | 结果 |
|---|---|
| CPU 取指执行 | 正常，LOCKUP 恒 0 |
| 读写 SRAM | 正常 |
| 访问 FIR 外设 | 正常，系数写与样本投递都对 |
| UART 回显 | `tb_soc` 13 项全过，闭环 |
| FIR 端到端 | `tb_phase6_fir_dma` 逐位一致，337 拍零误差 |
| 中断 | FIR 的 done/err、DMA 的 6 路 done 均可用 |

早期原型里那个"滤波结果全是 0"的遗留问题也早已解决。根因不在 RTL，而是构建产物 `firmware.hex` 过期：`main` 的字面量池里存放地址常量的位置被写成了 `0x696C0200` 而不是 `0x00000200`，多出来的两个字节正好是 ASCII 的 "li"，CPU 取到非法地址直接进 HardFault，停在 `Default_Handler`。重新编译固件即可。为了不再复发，`sim/sim.ps1` 里加了一步自动重建固件的逻辑。

这个故障值得单独说一句：它的现象（CPU 停在异常处理里）看起来百分之百像 RTL 有 bug，实际是构建产物的问题。排查时如果先怀疑 RTL，会绕很大一圈。

## 六、改抽头数要注意什么

现在统一是 82 抽头（81 阶）。如果要改成别的阶数，三处必须同步：

`RTL/fir_core.v` 的 `parameter NTAP`、`fir/fir_coeff.py` 的 `--taps` 默认值、以及重新生成的 `sw/fir_testvec.h`（由 `sw/gen_testvec.py` 从向量目录生成）。

三处不一致的典型现象是端到端比对全部错位——因为系数个数变了，卷积长度也跟着变。`sim/sim.ps1` 已经把向量生成和固件生成串在一起，正常流程不会踩到这个问题。
