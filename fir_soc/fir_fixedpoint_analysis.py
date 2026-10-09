#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FIR 定点方案计算器 —— 任务 5《FIR 定点方案说明书》的所有数字都由本脚本复算。

对应文档: docs/任务5-FIR定点方案说明书.md

用法:
    python fir_fixedpoint_analysis.py
    python fir_fixedpoint_analysis.py --coeffs 08_soc/coeffs.vh
    python fir_fixedpoint_analysis.py --taps 81 --cw 16 --dw 16

只做算术推导，不做仿真，不需要 numpy / scipy / pip。
"""

import argparse
import io
import math
import os
import re
import sys


# ----------------------------------------------------------------------
# 1. 解析 coeffs.vh
# ----------------------------------------------------------------------
def read_text(path):
    raw = open(path, 'rb').read()
    try:
        return raw.decode('utf-8')
    except UnicodeDecodeError:
        return raw.decode('gbk', 'replace')


def parse_coeffs(path):
    """从 coeffs.vh 里取出 81 个 Q1.15 整数系数。

    兼容两种写法:
        localparam signed [CW-1:0] H0 = 16'sd20;      ->  +20
        localparam signed [CW-1:0] H1 = -16'sd9;      ->   -9
    """
    txt = read_text(path)
    vals = []
    for m in re.finditer(r"=\s*(-?)16'sd(-?\d+)", txt):
        sgn = -1 if m.group(1) == '-' else 1
        vals.append(sgn * int(m.group(2)))
    return vals


# ----------------------------------------------------------------------
# 2. 位宽推导
# ----------------------------------------------------------------------
def bits_needed(magnitude):
    """覆盖 [-magnitude, +magnitude] 所需的有符号位宽。"""
    if magnitude <= 0:
        return 1
    return int(math.floor(math.log2(magnitude))) + 2      # 1 符号位 + 量值位


def signed_range(w):
    return -(1 << (w - 1)), (1 << (w - 1)) - 1


def width_report(vals, cw, dw):
    n = len(vals)
    xmax = 1 << (dw - 1)              # |x| <= 32768

    out = {}
    out['ntap'] = n
    out['sum_h'] = sum(vals)
    out['sum_abs_h'] = sum(abs(v) for v in vals)
    out['min_h'] = min(vals)
    out['max_h'] = max(vals)
    out['n_neg'] = sum(1 for v in vals if v < 0)
    out['symmetric'] = all(vals[k] == vals[n - 1 - k] for k in range(n))

    # ---- 乘积 ----
    out['prod_w'] = dw + cw
    out['prod_min'] = -(1 << (dw - 1)) * ((1 << (cw - 1)) - 1)
    out['prod_max'] = (1 << (dw - 1)) * (1 << (cw - 1))       # (-2^15)*(-2^15) = 2^30
    out['prod_fits'] = out['prod_max'] <= signed_range(dw + cw)[1]

    # ---- 累加: 任意系数的最坏界 ----
    worst_any = xmax * n * xmax
    out['acc_worst_any'] = worst_any
    out['acc_w_any'] = bits_needed(worst_any)

    # ---- 累加: 本组系数的实际最坏界 ----
    worst_this = xmax * out['sum_abs_h']
    out['acc_worst_this'] = worst_this
    out['acc_w_this'] = bits_needed(worst_this)

    # ---- 对称折叠 ----
    half = n // 2
    mid = (n - 1) // 2
    sa = sum(abs(vals[k]) for k in range(half))
    out['sym_half'] = half
    out['sym_sum_abs'] = sa
    out['sym_center'] = vals[mid]
    out['sym_pre_w'] = dw + 1                                  # 17 bit 预加器
    out['sym_prod_w'] = dw + 1 + cw                            # 33 bit
    out['sym_worst_any'] = (1 << dw) * (half * (1 << (cw - 1))) + (1 << (dw - 1)) * (1 << (cw - 1))
    out['sym_worst_this'] = (1 << dw) * sa + (1 << (dw - 1)) * abs(vals[mid])
    out['sym_w_any'] = bits_needed(out['sym_worst_any'])
    out['sym_w_this'] = bits_needed(out['sym_worst_this'])
    return out


# ----------------------------------------------------------------------
# 3. 误差预算
# ----------------------------------------------------------------------
def error_report(r, cw, dw):
    lsb_frac = 2.0 ** -(dw - 1)                    # 1 LSB 占满量程
    dc_err = abs(r['sum_h'] - (1 << (cw - 1))) / float(1 << (cw - 1))
    coef_q = 0.5 * lsb_frac                        # 单系数 ±0.5 LSB
    items = [
        ('系数量化 (Q1.15, 单系数 ±0.5 LSB)', coef_q * 100),
        ('系数和偏差 (直流增益)', dc_err * 100),
        ('乘积 / 累加 (32 bit x 40 bit, 全程精确)', 0.0),
        ('输出截位 (1 LSB)', lsb_frac * 100),
    ]
    total = sum(v for _, v in items)
    return items, total, lsb_frac * 100


# ----------------------------------------------------------------------
# 4. 打印
# ----------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description='FIR 定点方案计算器（任务 5）')
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument('--coeffs', type=str, default=None,
                    help='coeffs.vh 路径，默认 08_soc/coeffs.vh')
    ap.add_argument('--taps', type=int, default=81)
    ap.add_argument('--cw', type=int, default=16, help='系数位宽，默认 16')
    ap.add_argument('--dw', type=int, default=16, help='数据位宽，默认 16')
    args = ap.parse_args()

    path = args.coeffs
    if path is None:
        for cand in ('08_soc/coeffs.vh', '05_fir81/coeffs.vh', '04_fir9/coeffs.vh'):
            p = os.path.join(here, cand)
            if os.path.exists(p):
                path = p
                break
    if not path or not os.path.exists(path):
        print('[错误] 找不到 coeffs.vh，请用 --coeffs 指定')
        return 1

    vals = parse_coeffs(path)
    if not vals:
        print('[错误] %s 里没解析到系数' % path)
        return 1

    r = width_report(vals, args.cw, args.dw)
    hdr = '=' * 66

    print(hdr)
    print('FIR 定点方案计算器 —— 任务 5《FIR 定点方案说明书》')
    print(hdr)
    print('系数文件 : %s' % os.path.relpath(path, here))
    print('抽头数   : %d' % r['ntap'])
    print('系数位宽 : CW = %d  (Q1.15)' % args.cw)
    print('数据位宽 : DW = %d  (Q1.15)' % args.dw)
    print('')

    print('--- 1. 系数统计 ---')
    print('  Σ h[k]        = %8d   (理想 1.0 = %d, 偏差 %+.4f%%)'
          % (r['sum_h'], 1 << (args.cw - 1),
             100.0 * (r['sum_h'] - (1 << (args.cw - 1))) / (1 << (args.cw - 1))))
    print('  Σ |h[k]|      = %8d   ( = %.4f x %d )'
          % (r['sum_abs_h'], r['sum_abs_h'] / float(1 << (args.cw - 1)), 1 << (args.cw - 1)))
    print('  系数范围      = %d .. %d   (负系数 %d 个)' % (r['min_h'], r['max_h'], r['n_neg']))
    print('  线性相位对称  = %s' % ('成立 h[k] == h[N-1-k]' if r['symmetric'] else '不成立'))
    print('')

    print('--- 2. 乘积位宽 ---')
    print('  16 x 16 有符号 -> %d bit' % r['prod_w'])
    print('  乘积范围      = %d .. %d' % (r['prod_min'], r['prod_max']))
    print('  是否精确容纳  = %s' % ('是（无溢出、无截断）' if r['prod_fits'] else '否'))
    print('')

    print('--- 3. 累加器位宽（防溢出的核心）---')
    print('  [任意可配系数] 2^%d * %d * 2^%d = %d'
          % (args.dw - 1, r['ntap'], args.dw - 1, r['acc_worst_any']))
    print('                 = 2^%.3f  ->  有符号 %d bit 是硬下限'
          % (math.log2(r['acc_worst_any']), r['acc_w_any']))
    print('  [本组系数]     2^%d * %d = %d'
          % (args.dw - 1, r['sum_abs_h'], r['acc_worst_this']))
    print('                 = 2^%.3f  ->  有符号 %d bit'
          % (math.log2(r['acc_worst_this']), r['acc_w_this']))
    print('  >>> 设计取值 AW = 40 bit（下限 %d，余量 %d bit）'
          % (r['acc_w_any'], 40 - r['acc_w_any']))
    print('')

    print('--- 4. 对称折叠（决赛结构，41 乘法器）---')
    print('  预加器 s = x[k] + x[80-k] : %d bit, |s| <= %d'
          % (r['sym_pre_w'], 1 << (r['sym_pre_w'] - 1)))
    print('  乘积 17 x 16              : %d bit' % r['sym_prod_w'])
    print('  Σ|h[0..%d]| = %d , h[%d] = %d' % (r['sym_half'] - 1, r['sym_sum_abs'], 40, r['sym_center']))
    print('  [任意系数] 最坏累加 = %d = 2^%.3f -> %d bit'
          % (r['sym_worst_any'], math.log2(r['sym_worst_any']), r['sym_w_any']))
    print('  [本组系数] 最坏累加 = %d = 2^%.3f -> %d bit'
          % (r['sym_worst_this'], math.log2(r['sym_worst_this']), r['sym_w_this']))
    print('  >>> 对称折叠不改变累加器下限，AW = 40 依然成立')
    print('')

    items, total, lsb_pct = error_report(r, args.cw, args.dw)
    print('--- 5. 误差预算（占满量程百分比）---')
    for name, pct in items:
        print('  %-42s %8.4f%%' % (name, pct))
    print('  %-42s %8.4f%%' % ('合计（最坏叠加）', total))
    print('  赛题要求 < 0.1%%，余量 %.1f 倍' % (0.1 / total if total else float('inf')))
    print('')

    print('--- 6. 结论 ---')
    print('  数据/系数 : Q1.15, 16 bit')
    print('  乘积      : 32 bit (Q2.30)，精确')
    print('  累加器    : 40 bit（硬下限 %d bit）' % r['acc_w_any'])
    print('  输出      : 算术右移 15 位 + 饱和到 16 bit')
    print('  结构      : 初赛 直接型 81 乘法器 / 决赛 对称型 41 乘法器')
    print('  流水线    : 初赛 5 级 / 决赛 6 级，吞吐 1 sample/cycle')
    print(hdr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
