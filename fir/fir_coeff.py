#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fir_coeff.py —— FIR 系数设计 + 黄金模型 + 测试向量生成（契约 D / E，C 的分工）

依据 docs 里的契约：
  · 契约 A（阶段1-接口契约）：CW=16、DW=16、AW=40、NTAP=81，A6 定点规则
  · 契约 D（系数文件格式）：coeffs.vh / coeffs.hex
  · 契约 E（测试向量格式）：stim.hex / exp.hex（全卷积，NSAMP+NTAP-1）

做什么：
  1. 设计 81 阶线性相位低通 FIR（窗函数法，等价 scipy.signal.firwin）
  2. 归一化到直流增益 1.0（量化后 Σh ≈ 32768）
  3. Q1.15 量化，按契约 D 输出 coeffs.vh / coeffs.hex
  4. 黄金模型给双参考：定点参考（与 RTL 逐位一致 → exp.hex）、浮点参考（真实答案）
  5. 误差报告：最大绝对误差 / 最大相对误差，对照赛题 < 0.1%
  6. 生成 stim.hex（激励）与 exp.hex（期望输出），供 A/B 的 TB $readmemh

依赖：优先用 scipy.signal.firwin；没有 scipy 时回退到与它完全等价的纯标准库
      （math 实现的窗函数法），因此脚本在只有标准库的机器上也能跑。

用法：
    python fir/fir_coeff.py                          # 默认 81 阶 / 截止 0.12 / 256 样本
    python fir/fir_coeff.py --taps 81 --cutoff 0.12 --nsamp 256
    python fir/fir_coeff.py --window hann            # 对比不同窗函数
    python fir/fir_coeff.py --check got.hex          # 校验 RTL 导出的结果
"""

import argparse
import math
import os
import sys

# 控制台用 UTF-8 输出，避免 Windows GBK 下打印中文报错
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

# 可选依赖：scipy.signal.firwin（有则用，无则回退到等价实现）
try:
    from scipy.signal import firwin as _scipy_firwin
    HAS_SCIPY = True
except Exception:
    HAS_SCIPY = False


# ----------------------------------------------------------------------
# 1. 窗函数
# ----------------------------------------------------------------------
def window_fn(name, ntap):
    """返回长度 ntap 的窗系数列表。M = ntap-1。"""
    M = ntap - 1
    name = (name or "hamming").lower()
    if name == "hamming":
        return [0.54 - 0.46 * math.cos(2 * math.pi * n / M) for n in range(ntap)]
    if name in ("hann", "hanning"):
        return [0.5 - 0.5 * math.cos(2 * math.pi * n / M) for n in range(ntap)]
    if name == "blackman":
        return [0.42 - 0.5 * math.cos(2 * math.pi * n / M)
                + 0.08 * math.cos(4 * math.pi * n / M) for n in range(ntap)]
    raise ValueError("不支持的窗函数: %s（可选 hamming / hann / blackman）" % name)


# ----------------------------------------------------------------------
# 2. FIR 设计（窗函数法，等价 scipy.signal.firwin + 手动 DC 归一化）
# ----------------------------------------------------------------------
def design_lowpass(ntap, fc, window="hamming"):
    """
    线性相位低通 FIR。

    ntap  : 抽头数（81）
    fc    : 归一化截止频率，0 < fc < 1，1.0 = Nyquist（与 scipy.signal.firwin 同约定）
    window: 窗函数名

    理想低通冲激响应（归一化 sinc）：
        h_ideal[n] = fc·sinc(fc·(n - M/2))
                   = sin(π·fc·(n - M/2)) / (π·(n - M/2))     (n ≠ M/2)
                   = fc                                       (n = M/2)
    再乘窗、再归一化使 Σh = 1.0（直流增益 = 1）。
    """
    if ntap % 2 == 0:
        print("[提示] 抽头数为偶数，群延迟 = %.1f 个样本（半样本延迟）；赛题用奇数 81，"
              "建议保持奇数。" % ((ntap - 1) / 2.0))

    if HAS_SCIPY:
        h = list(_scipy_firwin(ntap, fc, window=window))
    else:
        w = window_fn(window, ntap)
        M = ntap - 1
        h = []
        for n in range(ntap):
            d = n - M / 2.0
            if d == 0:
                s = fc
            else:
                s = math.sin(math.pi * fc * d) / (math.pi * d)
            h.append(s * w[n])

    total = sum(h)
    h = [x / total for x in h]          # 归一化到直流增益 1.0
    return h


# ----------------------------------------------------------------------
# 3. Q1.15 量化
# ----------------------------------------------------------------------
def quantize(vals, q=15):
    """浮点 → Q1.15 定点整数：round(x·2^q)，饱和到 [-2^q, 2^q-1]。"""
    scale = 1 << q
    out = []
    for x in vals:
        v = int(round(x * scale))
        v = max(-scale, min(scale - 1, v))
        out.append(v)
    return out


# ----------------------------------------------------------------------
# 4. 黄金模型
# ----------------------------------------------------------------------
def golden_fixed(samples, coeffs, shift=15, dw=16):
    """
    定点参考（与 RTL 逐位一致）。

    acc[m] = Σ_k coeffs[k]·samples[m-k]，越界当 0；
    输出 = clamp(acc[m] >> 15, -32768, 32767)。
    用 Python int 累加，任意精度，绝不截断 —— 等价 RTL 的 40bit 累加（40bit 不溢出）。
    返回长度 = len(samples) + len(coeffs) - 1（全卷积）。
    """
    ntap = len(coeffs)
    n = len(samples)
    ymax = (1 << (dw - 1)) - 1
    ymin = -(1 << (dw - 1))

    def x(i):
        return samples[i] if 0 <= i < n else 0

    out = []
    for m in range(n + ntap - 1):
        acc = 0
        for k in range(ntap):
            acc += coeffs[k] * x(m - k)
        y = acc >> shift                     # 算术右移（floor），与 RTL 一致
        y = max(ymin, min(ymax, y))          # 饱和
        out.append(y)
    return out


def golden_float(samples_f, coeffs_f):
    """浮点参考（真实数学答案）：用未量化的系数与输入做全卷积。"""
    ntap = len(coeffs_f)
    n = len(samples_f)

    def x(i):
        return samples_f[i] if 0 <= i < n else 0.0

    out = []
    for m in range(n + ntap - 1):
        acc = 0.0
        for k in range(ntap):
            acc += coeffs_f[k] * x(m - k)
        out.append(acc)
    return out


# ----------------------------------------------------------------------
# 5. 激励设计（契约 E.7：带内 + 带外 + 满幅正弦）
# ----------------------------------------------------------------------
def make_stimulus(nsamp):
    """复合激励（连续无跳变，避免段间跳变造成的虚假饱和瞬态）。

    覆盖契约 E.7 的带内/带外/满幅三要素：
      0.05·fs 带内正弦（通带，几乎全通过）
      0.40·fs 带外正弦（阻带，被大幅衰减）
      0.03·fs 低频分量（近 DC，验证直流增益）
      n=10 冲激（验证瞬态/冲激响应，并逼近满量程）
    峰值钳到 Q1.15 范围内。
    """
    x = []
    for n in range(nsamp):
        v = (0.45 * math.sin(2 * math.pi * 0.05 * n)
             + 0.25 * math.sin(2 * math.pi * 0.40 * n)
             + 0.25 * math.sin(2 * math.pi * 0.03 * n))
        if n == 10:
            v += 0.80                       # 冲激：单拍逼近满量程，验瞬态
        v = max(-0.99997, min(0.99997, v))  # 保证不越界 Q1.15
        x.append(v)
    return x


# ----------------------------------------------------------------------
# 6. 十六进制文件读写
# ----------------------------------------------------------------------
def write_hex(path, values, bits=16):
    """写成 $readmemh 可读的十六进制，每行 4 位（16bit 二进制补码）。"""
    mask = (1 << bits) - 1
    with open(path, "w", newline="\n", encoding="utf-8") as f:
        for v in values:
            f.write("%04X\n" % (v & mask))


def read_hex(path, bits=16):
    """读回十六进制，还原成有符号整数。"""
    vals = []
    sign = 1 << (bits - 1)
    mask = (1 << bits) - 1
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            if any(c in line.lower() for c in "xz"):
                raise ValueError("Uninitialized hexadecimal sample in %s: %s" % (path, line))
            v = int(line, 16) & mask
            if v & sign:
                v -= (1 << bits)
            vals.append(v)
    return vals


def write_coeffs_vh(path, coeffs, cw=16):
    """生成 Verilog 头文件（契约 D.3：H0~H80，localparam signed [15:0]）。"""
    lines = [
        "// ============================================================",
        "// 本文件由 fir/fir_coeff.py 自动生成，不要手动修改",
        "// 81 阶 FIR 系数，Q1.15，抽头顺序 H0=h[0]（当前样本）",
        "// ============================================================",
    ]
    for k, v in enumerate(coeffs):
        literal = ("-" if v < 0 else "") + "%d'sd%d" % (cw, abs(v))
        lines.append("localparam signed [%d:0] H%d = %s;" % (cw - 1, k, literal))
    with open(path, "w", newline="\n", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


# ----------------------------------------------------------------------
# 7. 误差报告
# ----------------------------------------------------------------------
def error_report(y_fixed, y_float, q=15):
    """误差报告：返回三个口径，全部透明给出，不做任何"重定义"。

    1) 最大绝对误差（占满量程 1.0）—— 与赛题「误差 < 0.1%」对应的标准口径
    2) 最大相对误差（相对信号峰值）—— 误差占信号幅度的比例（有意义的相对误差）
    3) 逐点最大相对误差           —— 含阻带近零，会被近零参考放大，仅作参考
    """
    scale = float(1 << q)
    abs_errs = [abs(yf / scale - yfl) for yf, yfl in zip(y_fixed, y_float)]
    max_abs = max(abs_errs)                                   # 占满量程
    peak = max(abs(yfl) for yfl in y_float)                   # 信号峰值
    max_rel_peak = max_abs / peak if peak > 0 else 0.0        # 相对信号峰值

    thresh_lsb = 1.0 / scale                                  # 1 LSB
    rel_pointwise = [abs(yf / scale - yfl) / abs(yfl)
                     for yf, yfl in zip(y_fixed, y_float) if abs(yfl) > thresh_lsb]
    max_rel_pointwise = max(rel_pointwise)                    # 逐点（含阻带近零）
    return max_abs, max_rel_peak, max_rel_pointwise


# ----------------------------------------------------------------------
# 8. 主流程
# ----------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="FIR 系数设计 + 黄金模型 + 测试向量生成")
    ap.add_argument("--taps", type=int, default=81, help="抽头数（默认 81）")
    ap.add_argument("--cutoff", type=float, default=0.12, help="归一化截止频率（默认 0.12）")
    ap.add_argument("--nsamp", type=int, default=256, help="测试样本数（默认 256）")
    ap.add_argument("--window", type=str, default="hamming", help="窗函数（hamming/hann/blackman）")
    ap.add_argument("--outdir", type=str, default=None, help="输出目录，默认脚本所在目录")
    ap.add_argument("--check", type=str, default=None, help="校验模式：传入 RTL 导出的 got.hex")
    args = ap.parse_args()

    outdir = args.outdir or os.path.dirname(os.path.abspath(__file__))
    ntap, fc, nsamp = args.taps, args.cutoff, args.nsamp
    if ntap < 2 or nsamp < 1 or not 0 < fc < 1:
        ap.error("require taps >= 2, nsamp >= 1 and 0 < cutoff < 1")

    # ---- 设计 + 量化系数 ----
    h = design_lowpass(ntap, fc, args.window)
    coeffs = quantize(h)

    print("=" * 64)
    print("FIR 设计：抽头 = %d，截止 = %.3f（归一化到 Nyquist），窗 = %s"
          % (ntap, fc, args.window))
    print("设计路径：%s" % ("scipy.signal.firwin" if HAS_SCIPY
                          else "内置窗函数法（与 firwin 等价）"))
    print("=" * 64)
    print("Σh（量化） = %d  （理想 32768 = 1.0，偏差 %+.4f%%）"
          % (sum(coeffs), 100.0 * (sum(coeffs) - 32768) / 32768))
    print("系数范围  = %d .. %d" % (min(coeffs), max(coeffs)))
    symmetric = all(coeffs[k] == coeffs[ntap - 1 - k] for k in range(ntap // 2))
    print("线性相位对称 = %s" % ("成立 h[k]==h[N-1-k]" if symmetric else "不成立"))

    if args.check:
        # ---- 校验模式：把 RTL 导出的 got.hex 与黄金模型比对 ----
        got = read_hex(args.check)
        stim_path = os.path.join(outdir, "stim.hex")
        samples = read_hex(stim_path)
        exp = golden_fixed(samples, coeffs)
        print("\nRTL 导出 %d 个，黄金模型期望 %d 个" % (len(got), len(exp)))
        if len(got) > 1:
            got = got[1:]                        # 跳过流水线前导 0（契约 E.6）
        if len(got) != len(exp):
            print("FAIL: sample count mismatch: %d != %d" % (len(got), len(exp)))
            sys.exit(1)
        n = len(exp)
        bad = [(i, got[i], exp[i]) for i in range(n) if got[i] != exp[i]]
        if not bad:
            print("\n===== PASS：前 %d 个样本与黄金模型逐位一致 =====" % n)
        else:
            print("\n===== FAIL：%d / %d 个样本不一致 =====" % (len(bad), n))
            for i, g, e in bad[:10]:
                print("   样本 %3d：RTL = %6d，期望 = %6d" % (i, g, e))
        if bad:
            sys.exit(1)
        return

    # ---- 生成模式 ----
    x_float = make_stimulus(nsamp)               # 浮点激励（给浮点参考用）
    x_int = quantize(x_float)                    # 量化激励（stim.hex）

    y_fixed = golden_fixed(x_int, coeffs)        # 定点参考（exp.hex，逐位一致）
    y_float = golden_float(x_float, h)           # 浮点参考（真实答案）

    max_abs, max_rel_peak, max_rel_pt = error_report(y_fixed, y_float)
    print("\n--- 误差报告（定点 vs 浮点）---")
    print("  最大绝对误差（占满量程 1.0）  = %.6f%%" % (max_abs * 100))
    print("  最大相对误差（相对信号峰值）  = %.6f%%" % (max_rel_peak * 100))
    print("  逐点最大相对误差（含阻带近零）= %.3f%%（被近零参考放大，不采用）"
          % (max_rel_pt * 100))
    ok = max_abs < 0.001
    print("  赛题要求 < 0.1%%（按占满量程的绝对误差）→  %s"
          % ("✅ 达标" if ok else "❌ 不达标"))

    # ---- 写文件 ----
    os.makedirs(outdir, exist_ok=True)
    write_coeffs_vh(os.path.join(outdir, "coeffs.vh"), coeffs)
    write_hex(os.path.join(outdir, "coeffs.hex"), coeffs)
    write_hex(os.path.join(outdir, "stim.hex"), x_int)
    write_hex(os.path.join(outdir, "exp.hex"), y_fixed)

    print("\n已生成（在 %s）：" % outdir)
    print("  coeffs.vh   (%d 个系数，localparam H0~H%d)" % (ntap, ntap - 1))
    print("  coeffs.hex  (%d 个系数，供 $readmemh)" % ntap)
    print("  stim.hex    (%d 个激励样本)" % len(x_int))
    print("  exp.hex     (%d 个期望输出 = %d+%d-1 全卷积)" % (len(y_fixed), nsamp, ntap))
    print("\n注意：*.hex 已被 .gitignore 排除（不进 git），需要时重跑本脚本重新生成。")


if __name__ == "__main__":
    main()
