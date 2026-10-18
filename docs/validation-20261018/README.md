# 2026-10-18 工程验证证据

对应 `audit/preliminary-validation` 工作区；基线 Git 版本 `354a6ed`。

- `baseline_timing.rpt` / `baseline_util.rpt`：起始版本完整顶层在 50MHz 下的综合诊断。
- `final_timing.rpt` / `final_util.rpt` / `final_route_status.rpt`：最终版本 `release50` 完整布线结果。
- `simulation_summary.json` / `simulation_run.txt`：26 项最终回归，全部通过；`fir_numeric_check.txt` 包含真实 RTL 浮点 RRMSE。
- `coverage_report.md` / `coverage_summary.json`：CPU-free 86/86 必达 bins 和 779/783 过程语句行。
- `python_tests.txt`：8 项 Python 工具测试。
- `drc_summary.txt` / `methodology_summary.txt` / `synthesis_warning_summary.txt`：告警摘要，详细分类见上层检查报告。UCIO-1 保留，板卡引脚未指定。
- `final_rtl_sha256.txt` / `final_flow_sha256.txt` / `simulation_sources_sha256.txt`：运行源码摘要。
- `check.tcl` / `soc_top.xdc` / `actual_constraints.xdc` / `run_check_snapshot.ps1`：该轮流程快照。实际运行入口位于仓库 synth 目录，快照供审阅，不从此目录直接执行。
- `final_run.txt`：器件、周期、暂存目录与退出码。大型 dcp 和完整日志保留在 build/audit/release50。

最终实测参考时钟 50MHz；WNS +0.217ns、WHS +0.036ns；可布线网络 23714/23714，路由错误 0。没有上板或生成 bitstream。
