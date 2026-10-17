# ============================================================
# synth/run_synth.tcl —— soc_top 的 Vivado 综合脚本
#
# 由 synth/run_synth.ps1 在【纯英文的临时目录】里调用，因为 Vivado 读不了
# 含中文的路径（报 "Could not open 'C' for writing"）。运行时当前目录下必须
# 有 RTL\ 子目录（源文件已拷贝进去）。
#
# 两条踩过的坑，改这里之前先读：
#   1. RTL 是 SystemVerilog 风格（多维打包数组等），必须 read_verilog -sv；
#      用纯 Verilog 模式会报 Synth 8-10976 / 8-10936。
#   2. 存储体必须写在无异步复位的时钟块里（见 RTL/axi_sram.v 第 5 节），
#      否则报 Synth 8-3391 无法推断 BRAM。
# ============================================================
# 器件型号由 run_synth.ps1 用 -tclargs 传进来；手跑时默认用下面这个
if {[llength $argv] > 0} { set part [lindex $argv 0] } else { set part xc7vx485tffg1157-1 }

set srcs {}
foreach f [lsort [glob RTL/*.v]] {
    if {[string match *cmsdk_axi_ram_beh* $f]} { continue }
    lappend srcs $f
}
puts "SRC_COUNT=[llength $srcs]"
read_verilog -sv $srcs
synth_design -top soc_top -part $part -mode out_of_context
create_clock -period 10.000 -name clk [get_ports clk]
report_utilization -file util.rpt
report_timing_summary -file timing.rpt -no_detailed_paths
write_checkpoint -force soc_top_synth.dcp
puts "SYNTH_DONE"
exit
