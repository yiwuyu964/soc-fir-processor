#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
build.py —— 一键生成 Cortex-M0 固件并转成 image.hex

流程：
  1. 用 gen_fir_vectors.py 设计 81 阶系数 + 生成激励/黄金模型
  2. 把系数和激励写成 fir_data.h（C 数组），黄金模型写成 expected.txt
  3. 用 arm-none-eabi-gcc 编译 startup.s + main.c → fir.elf
  4. objcopy 转成裸二进制 fir.bin
  5. 转成 CMSDK RAM 模型 $readmemh 认识的 image.hex（@地址 + 逐字节）

用法：
  python build.py

找不到工具链时：
  设置环境变量 ARM_GCC_DIR 指向工具链的 bin 目录，例如
    set ARM_GCC_DIR=C:\Users\你\Desktop\gcc-arm-none-eabi-10.3-2021.10\bin
"""
import glob
import os
import shutil
import subprocess
import sys

SW_DIR   = os.path.dirname(os.path.abspath(__file__))
ROOT     = os.path.dirname(SW_DIR)
SOC_DIR  = os.path.join(ROOT, "09_soc_cm0")

sys.path.insert(0, ROOT)
import gen_fir_vectors as g

NTAP  = 9           # 抽头数：9=调试快；81=赛题（DesignStart 核仿真极慢）
NSAMP = 8           # 测试样本数（保持仿真快）
CUTOFF = 0.15


# ----------------------------------------------------------------------
# 工具链自动探测（不再写死某一台机器的路径）
# ----------------------------------------------------------------------
def _probe(d):
    """目录 d 里同时有 gcc 和 objcopy 才算数，返回 (gcc, objcopy)。"""
    if not d:
        return None
    gcc = os.path.join(d, "arm-none-eabi-gcc.exe")
    obj = os.path.join(d, "arm-none-eabi-objcopy.exe")
    if os.path.isfile(gcc) and os.path.isfile(obj):
        return gcc, obj
    return None


def find_toolchain():
    cands = []

    # 1) 环境变量（优先级最高，换机器只改这一个）
    env = os.environ.get("ARM_GCC_DIR")
    if env:
        cands.append(env)

    # 2) 系统 PATH
    for name in ("arm-none-eabi-gcc", "arm-none-eabi-gcc.exe"):
        p = shutil.which(name)
        if p:
            cands.append(os.path.dirname(p))
            break

    # 3) 团队已知的固定位置
    cands += [
        r"E:\JetBrains\GNU Arm Embedded Toolchain\10 2021.10\bin",
        r"C:\Program Files (x86)\Arm GNU Toolchain arm-none-eabi\10.3 2021.10\bin",
        r"C:\Program Files\Arm GNU Toolchain arm-none-eabi\10.3 2021.10\bin",
    ]

    # 4) 常见解压位置（通配匹配版本号）
    for pat in (
        r"~\Desktop\gcc-arm-none-eabi-*\bin",
        r"~\gcc-arm-none-eabi-*\bin",
        r"D:\apps\gcc-arm-none-eabi-*\bin",
        r"E:\apps\gcc-arm-none-eabi-*\bin",
        r"E:\*\GNU Arm Embedded Toolchain\*\bin",
        r"C:\gcc-arm-none-eabi-*\bin",
    ):
        cands += glob.glob(os.path.expanduser(pat))

    for d in cands:
        r = _probe(d)
        if r:
            return r
    return None, None


def main():
    gcc, objcopy = find_toolchain()
    if not gcc:
        print("错误：找不到 arm-none-eabi 工具链（需要 arm-none-eabi-gcc 和 objcopy）")
        print("")
        print("解决办法：设置环境变量 ARM_GCC_DIR 指向工具链的 bin 目录，例如")
        print(r"  set ARM_GCC_DIR=C:\Users\你\Desktop\gcc-arm-none-eabi-10.3-2021.10\bin")
        print("或者把工具链的 bin 目录加进系统 PATH。")
        return 1
    print("工具链   : %s" % gcc)

    # ---- 1. 设计系数 ----
    h = g.quantize(g.design_lowpass(NTAP, CUTOFF))

    # ---- 2. 激励：一个冲激 + 一串 0 ----
    x = [32767 if i == 0 else 0 for i in range(NSAMP)]

    # ---- 3. 黄金模型 ----
    exp = g.golden_fir(x, h)

    # ---- 4. 写 fir_data.h ----
    with open(os.path.join(SW_DIR, "fir_data.h"), "w", encoding="utf-8") as f:
        f.write("/* 由 build.py 自动生成，勿手改 */\n")
        f.write("#ifndef FIR_DATA_H\n#define FIR_DATA_H\n#include <stdint.h>\n")
        f.write("#define NTAP %d\n#define NSAMP %d\n" % (NTAP, NSAMP))
        f.write("static const int16_t h[NTAP] = {\n  " +
                ", ".join(str(v) for v in h) + "\n};\n")
        f.write("static const int16_t x[NSAMP] = {\n  " +
                ", ".join(str(v) for v in x) + "\n};\n")
        f.write("#endif\n")

    # ---- 5. 写 expected.txt（4 位十六进制补码，和 C 的打印一致）----
    with open(os.path.join(SOC_DIR, "expected.txt"), "w") as f:
        for v in exp:
            f.write("%04X\n" % (v & 0xFFFF))

    # ---- 6. 编译 ----
    cmd = [gcc, "-mcpu=cortex-m0", "-mthumb", "-nostartfiles", "-ffreestanding",
           "-T", os.path.join(SW_DIR, "linker.ld"),
           "-o", os.path.join(SW_DIR, "fir.elf"),
           os.path.join(SW_DIR, "startup.s"),
           os.path.join(SW_DIR, "main.c")]
    print("compile :", " ".join(cmd[1:4]) + " ...")
    subprocess.check_call(cmd)

    # ---- 7. objcopy → 裸二进制 ----
    subprocess.check_call([objcopy, "-O", "binary",
                           os.path.join(SW_DIR, "fir.elf"),
                           os.path.join(SW_DIR, "fir.bin")])

    # ---- 8. 转 image.hex（@地址 + 每行 16 字节）----
    data = open(os.path.join(SW_DIR, "fir.bin"), "rb").read()
    lines = ["@00000000"]
    for i in range(0, len(data), 16):
        chunk = data[i:i + 16]
        lines.append(" ".join("%02X" % b for b in chunk))
    out = os.path.join(SOC_DIR, "image.hex")
    with open(out, "w") as f:
        f.write("\n".join(lines) + "\n")

    print("OK: 固件 %d 字节 -> %s" % (len(data), out))
    print("    黄金模型 %d 个输出 -> %s" % (len(exp), os.path.join(SOC_DIR, "expected.txt")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
