# ============================================================
# synth/soc_top.xdc —— soc_top 顶层约束模板（Vivado 工程用）
#
# 只给了时钟约束，引脚约束是注释掉的占位：本工程没有绑定具体开发板，
# 引脚号必须按你手上的板子填（改 PACKAGE_PIN 那几行）。
#
# 10ns = 100MHz。实测本工程当前时序不收敛（WNS 约 -136ns），想先跑通流程
# 可以把它放宽，例如 200ns = 5MHz。
# ============================================================

# ---- 主时钟 ----
create_clock -period 10.000 -name clk [get_ports clk]

# ---- 复位 / UART（引脚按板子填，示例是占位）----
# set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVCMOS33} [get_ports clk]
# set_property -dict {PACKAGE_PIN P20 IOSTANDARD LVCMOS33} [get_ports rst_n]
# set_property -dict {PACKAGE_PIN R19 IOSTANDARD LVCMOS33} [get_ports uart_txd]
# set_property -dict {PACKAGE_PIN T19 IOSTANDARD LVCMOS33} [get_ports uart_rxd]

# ---- 异步输入：rst_n 与串口线不需要做输入延时分析 ----
set_false_path -from [get_ports rst_n]
set_false_path -from [get_ports uart_rxd]
set_false_path -to [get_ports uart_txd]
