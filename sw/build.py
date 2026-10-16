#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sw/build.py —— 编译 Cortex-M0 固件（阶段4 分工 C）

做什么：
  1. 自动探测 arm-none-eabi-gcc（PATH + 常见安装位置，找不到就给清楚的提示）
  2. 编译 startup.s + main.c，链接脚本 linker.ld
  3. 产出三种文件：
       firmware.elf   —— 调试用
       firmware.bin   —— 原始二进制
       firmware.hex   —— 【给 tb_soc.v 的 $readmemh 用】
                         格式：每行一个 32bit 小端字（8 位十六进制），从字 0 开始。
                         这是最可移植的写法，不依赖 objcopy 的 verilog/intel 格式。

用法（在仓库根目录）：
    python sw/build.py
    python sw/build.py --check     只探测工具链，不编译

⚠️ 本机没装 ARM 工具链时，脚本会明确告诉你装什么、去哪装，而不是丢一堆报错。
"""

import argparse
import glob
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

SRCS = [os.path.join(HERE, "startup.s"), os.path.join(HERE, "main.c")]
LD   = os.path.join(HERE, "linker.ld")
ELF  = os.path.join(HERE, "firmware.elf")
BIN  = os.path.join(HERE, "firmware.bin")
HEX  = os.path.join(HERE, "firmware.hex")

# Cortex-M0 的编译选项：
#   -mcpu=cortex-m0 -mthumb   目标架构
#   -nostdlib -nostartfiles   我们自带启动代码，不用标准库的
#   -ffreestanding            独立环境（没有操作系统）
#   -Os                       体积优先（SRAM 只有 64KB）
CFLAGS = [
    "-mcpu=cortex-m0", "-mthumb",
    "-nostdlib", "-nostartfiles", "-ffreestanding",
    "-Os", "-g3",
    "-Wall", "-Wextra",
    "-ffunction-sections", "-fdata-sections",
]
LDFLAGS = ["-Wl,--gc-sections", "-Wl,-Map=" + os.path.join(HERE, "firmware.map")]


def find_toolchain():
    """返回 (gcc, objcopy)，找不到就返回 (None, None)。"""
    # 1) PATH 里
    gcc = shutil.which("arm-none-eabi-gcc")
    if gcc:
        sibling = os.path.join(os.path.dirname(gcc), "arm-none-eabi-objcopy" + (".exe" if os.name == "nt" else ""))
        objcopy = sibling if os.path.isfile(sibling) else shutil.which("arm-none-eabi-objcopy")
        return gcc, objcopy

    # 2) 常见安装位置（含 ARM 官方安装器的版本化目录）
    patterns = [
        r"C:\Program Files (x86)\Arm GNU Toolchain arm-none-eabi\*\bin\arm-none-eabi-gcc.exe",
        r"C:\Program Files\Arm GNU Toolchain arm-none-eabi\*\bin\arm-none-eabi-gcc.exe",
        r"C:\Program Files (x86)\GNU Arm Embedded Toolchain\*\bin\arm-none-eabi-gcc.exe",
        r"C:\Program Files\GNU Arm Embedded Toolchain\*\bin\arm-none-eabi-gcc.exe",
        os.path.expanduser(r"~\AppData\Local\ArmGnuToolchain\*\bin\arm-none-eabi-gcc.exe"),
        r"C:\gcc-arm-none-eabi\bin\arm-none-eabi-gcc.exe",
        r"D:\gcc-arm-none-eabi\bin\arm-none-eabi-gcc.exe",
        r"E:\gcc-arm-none-eabi\bin\arm-none-eabi-gcc.exe",
        "/usr/bin/arm-none-eabi-gcc",
        "/opt/gcc-arm-none-eabi/bin/arm-none-eabi-gcc",
    ]
    for pat in patterns:
        for hit in sorted(glob.glob(pat)):
            ob = os.path.join(os.path.dirname(hit), "arm-none-eabi-objcopy.exe")
            if not os.path.exists(ob):
                ob = os.path.join(os.path.dirname(hit), "arm-none-eabi-objcopy")
            return hit, (ob if os.path.exists(ob) else None)

    return None, None


def hint_missing():
    print()
    print("=" * 70)
    print("  找不到 arm-none-eabi-gcc —— 固件没法编译")
    print("=" * 70)
    print()
    print("  本项目的 SoC 用 Cortex-M0，需要 ARM 的裸机工具链（不是 keil、不是 mingw）。")
    print()
    print("  下载（免费，约 150MB）：")
    print("    https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads")
    print("    选 “Arm GNU Toolchain ... for Windows (x86_64) hosted” 里的")
    print("    “...-mingw-w64-i686-arm-none-eabi.exe”")
    print()
    print("  安装时【务必勾选 “Add path to environment variable”】，装完重开终端。")
    print()
    print("  装好后验证：")
    print("    arm-none-eabi-gcc --version")
    print()
    print("  如果你装在了别的地方，改本脚本的 find_toolchain() 里 patterns 即可。")
    print()


def bin_to_word_hex(bin_path, hex_path):
    """把二进制转成 $readmemh 能读的格式：每行一个 32bit 小端字。"""
    with open(bin_path, "rb") as f:
        data = f.read()
    # 补齐到 4 字节的整数倍
    if len(data) % 4:
        data += b"\x00" * (4 - len(data) % 4)
    lines = []
    for i in range(0, len(data), 4):
        w = data[i] | (data[i + 1] << 8) | (data[i + 2] << 16) | (data[i + 3] << 24)
        lines.append("%08X" % w)
    with open(hex_path, "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    return len(data) // 4


def run(cmd):
    print("  $ " + " ".join(cmd))
    r = subprocess.run(cmd, cwd=REPO)
    if r.returncode != 0:
        print("\n❌ 命令失败（退出码 %d）" % r.returncode)
        sys.exit(1)


def main():
    ap = argparse.ArgumentParser(description="编译 Cortex-M0 固件")
    ap.add_argument("--check", action="store_true", help="只探测工具链，不编译")
    ap.add_argument("--clang", help="Optional ARM-capable clang executable")
    ap.add_argument("--lld", help="ELF ld.lld executable (with --clang)")
    args = ap.parse_args()

    if args.clang:
        clang = os.path.abspath(args.clang)
        lld = args.lld or shutil.which("ld.lld") or os.path.join(os.path.dirname(clang), "ld.lld.exe")
        objcopy = os.path.join(os.path.dirname(clang), "llvm-objcopy.exe" if os.name == "nt" else "llvm-objcopy")
        if not all(os.path.isfile(p) for p in (clang, lld, objcopy)):
            ap.error("--clang requires clang, ELF ld.lld and adjacent llvm-objcopy")
        if args.check:
            print("clang: " + clang + "\nlld: " + lld)
            return
        objs = []
        for src in SRCS:
            obj = os.path.splitext(src)[0] + ".o"
            flags = ["-ffreestanding", "-Os", "-Wall", "-Wextra"] if src.endswith('.c') else []
            run([clang, "--target=arm-none-eabi", "-mcpu=cortex-m0", "-mthumb"] +
                flags + ["-c", src, "-o", obj])
            objs.append(obj)
        run([lld, "-T", LD, "--gc-sections", "-Map=" + os.path.join(HERE, "firmware.map"),
             "-o", ELF] + objs)
        run([objcopy, "-O", "binary", ELF, BIN])
        bin_to_word_hex(BIN, HEX)
        print("Built C firmware: " + HEX)
        return

    gcc, objcopy = find_toolchain()

    if args.check or gcc is None:
        if gcc:
            print("✅ 找到工具链：")
            print("     gcc     : " + gcc)
            print("     objcopy : " + (objcopy or "（没找到，可能装得不全）"))
            if args.check:
                return
        else:
            hint_missing()
            sys.exit(1)

    if objcopy is None:
        print("❌ 找到了 gcc 但没找到 arm-none-eabi-objcopy，工具链装得不全。")
        sys.exit(1)

    print("工具链 : " + gcc)
    print("源码   : " + ", ".join(os.path.relpath(s, REPO) for s in SRCS))
    print("链接   : " + os.path.relpath(LD, REPO))
    print()

    print("[1/3] 编译 + 链接 ...")
    run([gcc] + CFLAGS + ["-T", LD] + LDFLAGS + ["-o", ELF] + SRCS)

    print("[2/3] 转二进制 ...")
    run([objcopy, "-O", "binary", ELF, BIN])

    print("[3/3] 转 $readmemh 格式 ...")
    words = bin_to_word_hex(BIN, HEX)

    print()
    print("=" * 70)
    print("  编译成功")
    print("=" * 70)
    print("  %-16s %8d 字节" % ("firmware.elf", os.path.getsize(ELF)))
    print("  %-16s %8d 字节" % ("firmware.bin", os.path.getsize(BIN)))
    print("  %-16s %8d 字节  (%d 个字)" % ("firmware.hex", os.path.getsize(HEX), words))
    print()
    print("  下一步：跑仿真")
    print("      sim\\sim.cmd -Only soc")
    print()
    if words > 16384:
        print("  ⚠️ 固件超过 64KB SRAM 容量（%d 字 > 16384 字）！" % words)
        sys.exit(1)


if __name__ == "__main__":
    main()
