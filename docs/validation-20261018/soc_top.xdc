# Reference implementation at 50 MHz; check.tcl may override period via argv.
# No board selected. Automatically assigned package pins must not be used
# to program an arbitrary board.
create_clock -period 20.000 -name clk [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports {clk rst_n uart_rxd uart_txd}]
# Except only asynchronous external inputs. Internal reset recovery/removal
# and synchronizer stage-to-stage paths remain timed.
set_false_path -from [get_ports rst_n]
set_false_path -from [get_ports uart_rxd]
# Keep the registered UART output timed with a conservative zero delay.
set_output_delay -clock clk -max 0.0 [get_ports uart_txd]
set_output_delay -clock clk -min 0.0 [get_ports uart_txd]
