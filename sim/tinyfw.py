#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tinyfw.py —— 手工汇编一段最小 Cortex-M0 固件（探针，非交付物）。

本机没装 arm-none-eabi-gcc 时，用它验证 soc_top 的两条通路：
  A. 启动 + 内存通路：写魔数到信箱
  B. 外设通路：往 UART DATA 写一个字节 'U'(0x55)
     —— 这条走 CPU → AHB→AXI → axi_ic → axi_to_apb → uart_apb → uart_txd

复位后从 0x40 顺序执行 13 条指令，字面量池在 0x80。
"""

W = {}
W[0x00] = 0x00010000          # 初始 SP
W[0x04] = 0x00000041          # 复位入口 = 0x40|1
for a in range(0x08, 0x40, 4):
    W[a] = 0x00000000

# 指令（每条 LDR 的偏移：addr = Align(PC,4) + imm, PC = 指令地址+4）
W[0x40] = 0x4910480F   # LDR r0,=0x00000F00(0x80) ; LDR r1,=0x534F4321(0x84)
W[0x44] = 0x48106001   # STR r1,[r0]              ; LDR r0,=0x00000F18(0x88)
W[0x48] = 0x60014910   # LDR r1,=0x00001000(0x8C); STR r1,[r0]
W[0x4C] = 0x49114810   # LDR r0,=0x40002000(0x90); LDR r1,=0x00000055(0x94)
W[0x50] = 0x48116001   # STR r1,[r0]  ← 写 UART DATA，发 'U' ; LDR r0,=0x00000F0C(0x98)
W[0x54] = 0x60014911   # LDR r1,=0x00000001(0x9C); STR r1,[r0]  ← 回显计数=1
W[0x58] = 0x0000E7FE   # B .（死循环）

# 字面量池
W[0x80] = 0x00000F00   # 信箱地址
W[0x84] = 0x534F4321   # 'SOC!'
W[0x88] = 0x00000F18   # 信箱+6（状态）
W[0x8C] = 0x00001000   # SMOKE_OK
W[0x90] = 0x40002000   # UART DATA（契约S §S.4：UART 基址 0x4000_2000）
W[0x94] = 0x00000055   # 要发的字节 'U'
W[0x98] = 0x00000F0C   # 信箱+3（回显计数）
W[0x9C] = 0x00000001

import sys
dst = sys.argv[1] if len(sys.argv) > 1 else "firmware.hex"
n = max(W.keys()) // 4 + 1
with open(dst, "w", encoding="ascii", newline="\n") as f:
    f.write("\n".join("%08X" % W.get(i * 4, 0) for i in range(n)) + "\n")
print("wrote %s (%d words)" % (dst, n))
