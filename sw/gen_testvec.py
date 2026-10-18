"""从 fir/ 的黄金模型向量生成 C 头文件（阶段6 软硬件协同用）。

数据来源（fir/fir_coeff.py 产出，契约 D/E）：
  fir/coeffs.hex  82 个系数（Q1.15）
  fir/stim.hex    256 个输入样本
  fir/exp.hex     337 个期望输出（完整卷积）

固件侧的用法：
  推 338 个样本（256 真实 + 82 补零）进 FIR → 得到 338 个结果，
  其中 results[1..337] 与 exp[0..336] 逐位一致（results[0] 是 flush 后的前导 0）。

用法：  python sw/gen_testvec.py
输出：  sw/fir_testvec.h
"""
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIR = HERE.parent / "fir"


def load(name, root=FIR):
    rows = [r.strip() for r in (root / name).read_text(encoding="utf-8").splitlines()]
    return [int(r, 16) & 0xFFFF for r in rows if r]


def emit_array(f, ctype, name, vals, per_line=8):
    f.write(f"static const {ctype} {name}[{len(vals)}] = {{\n")
    for i in range(0, len(vals), per_line):
        chunk = ", ".join(f"0x{v:04X}" for v in vals[i:i + per_line])
        f.write(f"    {chunk},\n")
    f.write("};\n\n")


def main():
    # --indir：向量目录。sim.ps1 把向量生成到临时目录（fir/*.hex 是 gitignore 的
    # 产物），必须用同一个目录来生成头文件，否则固件内嵌的期望值和 TB 交叉核对用的
    # exp.hex 会来自两批不同的向量 —— 阶段6 就因此报过"末项不一致"的假失败。
    import argparse
    ap = argparse.ArgumentParser(description="从黄金模型向量生成 sw/fir_testvec.h")
    ap.add_argument("--indir", default=str(FIR), help="向量目录（含 coeffs.hex/stim.hex/exp.hex）")
    args = ap.parse_args()
    root = Path(args.indir)
    coef = load("coeffs.hex", root)
    stim = load("stim.hex", root)
    exp = load("exp.hex", root)
    assert len(coef) == 82, len(coef)
    assert len(stim) == 256, len(stim)
    assert len(exp) == len(stim) + len(coef) - 1, len(exp)

    # 实测规律：FIR 是「N 个样本入 -> N 个结果出」，且第一个结果是 flush 后的前导 0。
    # 所以想拿到 exp 的 337 个有效结果，需要推 337+1 = 338 个样本（256 真实 + 82 补零）。
    samples = stim + [0x0000] * (len(exp) - len(stim) + 1)
    assert len(samples) == 338
    # DMA 按 32 位字搬，样本放低 16 位
    words = [s & 0xFFFF for s in samples]

    out = HERE / "fir_testvec.h"
    with out.open("w", encoding="utf-8", newline="\n") as f:
        f.write("/* 自动生成，请勿手改：python sw/gen_testvec.py */\n")
        f.write("/* 数据来源：fir/coeffs.hex, fir/stim.hex, fir/exp.hex（黄金模型）*/\n\n")
        f.write("#ifndef FIR_TESTVEC_H\n#define FIR_TESTVEC_H\n\n")
        f.write(f"#define TV_NCOEF    {len(coef)}u\n")
        f.write(f"#define TV_NSAMPLE  {len(words)}u\n")
        f.write(f"#define TV_NEXP     {len(exp)}u\n")
        f.write(f"#define TV_NRESULT  {len(exp) + 1}u   /* 含 flush 后的前导 0 */\n\n")
        emit_array(f, "unsigned short", "tv_coef", coef)
        emit_array(f, "unsigned int", "tv_sample", words, per_line=6)
        emit_array(f, "unsigned short", "tv_exp", exp)
        f.write("#endif /* FIR_TESTVEC_H */\n")

    print(f"wrote {out}  coef={len(coef)} sample={len(words)} exp={len(exp)}")


if __name__ == "__main__":
    main()
