"""生成 docs/README.md —— 文档总索引。

扫描 docs/*.md，按类分组生成索引表，并输出命名/格式约定。

用法：
    python sim/gen_docs_index.py

新增、改名、删除 docs 下的文档后重跑本脚本即可刷新索引。
"""
import re
import sys
from pathlib import Path

DOCS = Path(__file__).resolve().parent.parent / "docs"
ORDER = ["契约类", "分工类", "任务类", "验证与报告类", "参考与手册类"]


def classify(name):
    if name.startswith("契约"):
        return "契约类"
    if re.match(r"^阶段\d+-三人分工", name) or re.match(r"^阶段\d+-任务.*交接", name):
        return "分工类"
    if name.startswith("任务"):
        return "任务类"
    if re.match(r"^阶段\d+-", name) or name.startswith("初赛"):
        return "验证与报告类"
    return "参考与手册类"


def title_of(path):
    for line in path.read_text(encoding="utf-8-sig").splitlines()[:10]:
        if line.startswith("# "):
            return line[2:].strip()
    return path.stem


def main():
    rows = []
    for p in sorted(DOCS.glob("*.md")):
        if p.name == "README.md":
            continue
        rows.append((classify(p.name), p.name, title_of(p),
                     len(p.read_text(encoding="utf-8-sig").splitlines())))

    out = ["# docs 文档总索引", "",
           "> 本文件由 `python sim/gen_docs_index.py` 扫描 `docs/*.md` 自动生成。",
           "> **新增 / 改名 / 删除文档后请重跑该脚本**，否则索引会和实际不符。", ""]

    out += ["## 0. 命名与格式约定", "", "### 0.1 命名", "",
            "| 类别 | 命名规范 | 例子 |", "|---|---|---|",
            "| 契约类 | `契约<标识>-<主题>.md`，标识取 A/B/C/D/E/S/AB 或数字，**全库唯一** | `契约C-AXI ID编码.md` |",
            "| 分工类 | `阶段N-三人分工.md`；交接文档 `阶段N-任务X交接文档.md` | `阶段4-三人分工.md` |",
            "| 任务类 | `任务N-<主题>.md`（阿拉伯数字 + 短横线） | `任务3-地址映射与中断分配.md` |",
            "| 验证与报告类 | 阶段交付物 `阶段N-<主题>.md`；一次性证据 `<主题>-YYYYMMDD.md` | `阶段5-覆盖率报告.md` |",
            "| 参考与手册类 | 自由命名，必须自解释 | `怎么跑仿真.md` |", "",
            "> ⚠️ 分隔符统一用短横线 `-`，不要用下划线 `_`。", "",
            "### 0.2 格式", "",
            "每份文档的**标题下第一行**必须是一行「文档信息」：", "",
            "```",
            "> **文档信息** ｜ 类别：<契约类/分工类/任务类/验证与报告类/参考与手册类>",
            "> ｜ 所属：<阶段N/跨阶段> ｜ 状态：<冻结/在用/快照/参考> ｜ 索引：`docs/README.md §1.x`",
            "```", "",
            "各类正文的必备章节：", "",
            "| 类别 | 必备章节 |", "|---|---|",
            "| 契约类 | 目的与范围 → 接口/格式/编码定义 → 时序或约束 → 验证方式 → 冻结状态与变更记录 |",
            "| 分工类 | 阶段目标 → A/B/C 各自任务与交付物 → 依赖关系 → 验收标准 |",
            "| 任务类 | 依据（引用了哪份契约）→ 正文规格 → 对应 RTL 文件 → 对应验证用例 |",
            "| 验证与报告类 | 结论数字 → 明细表 → 复现命令 → 范围与限制 |",
            "| 参考与手册类 | 用途 → 适用对象 → 正文 |", "",
            "**通用硬性要求**：首行是唯一一级标题 `# …`；编码 UTF-8（带 BOM）；",
            "数据用 Markdown 管道表；命令放 ```powershell 代码块；跨文档引用写成 `docs/文件名.md §章节`。", "",
            "## 1. 索引", ""]

    n = 0
    for cls in ORDER:
        sub = [r for r in rows if r[0] == cls]
        if not sub:
            continue
        n += 1
        out += [f"### 1.{n} {cls}（{len(sub)} 份）", "",
                "| 文档 | 标题 | 行数 |", "|---|---|---:|"]
        for _, name, t, ln in sub:
            out.append(f"| [`{name}`]({name}) | {t} | {ln} |")
        out.append("")

    out += ["## 2. 非 Markdown 材料", ""]
    for p in sorted(DOCS.iterdir()):
        if p.is_file() and p.suffix != ".md":
            out.append(f"- `{p.name}`（{p.stat().st_size} 字节）")
    for p in sorted(DOCS.iterdir()):
        if p.is_dir():
            cnt = len([x for x in p.rglob("*") if x.is_file()])
            out.append(f"- `{p.name}/`（{cnt} 个文件）")
    out.append("")

    out += ["## 3. 建议阅读顺序", "",
            "| 顺序 | 文档 | 为什么先读它 |", "|---|---|---|",
            "| 1 | `赛题全景与行动手册.md` | 建立全局认识：赛题要什么、模块怎么分 |",
            "| 2 | `契约1-接口契约（冻结版）.md`、`契约A~E`、`契约S-soc顶层端口.md` | 所有接口的**权威来源**，改动前须全队确认 |",
            "| 3 | `任务3-地址映射与中断分配.md`、`任务4-模块接口信号清单.md` | 地址表与端口表，写 RTL / 固件都要查 |",
            "| 4 | `阶段N-三人分工.md` | 各阶段谁做什么、验收标准 |",
            "| 5 | `阶段5-验证计划.md`、`阶段5-覆盖率报告.md` | 验证怎么做、做到什么程度 |",
            "| 6 | `怎么跑仿真.md` | 上手把仿真跑起来 |", ""]

    (DOCS / "README.md").write_text("\n".join(out) + "\n", encoding="utf-8-sig")
    print(f"wrote {DOCS / 'README.md'}  ({len(rows)} 个 md 文档)")
    for cls in ORDER:
        sub = [r for r in rows if r[0] == cls]
        print(f"  {cls}: {len(sub)}")


if __name__ == "__main__":
    sys.exit(main())
