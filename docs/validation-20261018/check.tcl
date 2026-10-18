# Reproducible full-SoC reference implementation, no board-specific pinout.
set part [lindex $argv 0]
set period [lindex $argv 1]
set mode [lindex $argv 2]
set_param general.maxThreads 4
puts "AUDIT_TOOL=[version -short] PART=$part PERIOD_NS=$period MODE=$mode"
set srcs [lsort [glob RTL/*.v]]
lappend srcs RTL/cpu/cortexm0ds/cortexm0ds_logic.v
read_verilog -sv $srcs
# Clock exists before synthesis, so optimization uses the actual target.
# XDC accepts a restricted Tcl subset. Substitute the numeric period here,
# keeping conditionals outside XDC and giving synthesis the target clock.
set xf [open soc_top.xdc r]
set constraints [string map [list "-period 20.000" "-period $period"] [read $xf]]
close $xf
set xf [open target.xdc w]
puts $xf $constraints
close $xf
read_xdc target.xdc
synth_design -top soc_top -part $part
report_utilization -hierarchical -file synth_util.rpt
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose -max_paths 10 -file synth_timing.rpt
report_timing -delay_type max -max_paths 20 -nworst 2 -file synth_paths.rpt
report_drc -file synth_drc.rpt
write_checkpoint -force synth.dcp
if {$mode eq "route"} {
    opt_design
    place_design
    phys_opt_design
    route_design
    report_utilization -hierarchical -file route_util.rpt
    report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose -max_paths 10 -file route_timing.rpt
    report_timing -delay_type max -max_paths 20 -nworst 2 -file route_paths.rpt
    report_drc -file route_drc.rpt
    report_methodology -file route_methodology.rpt
    report_route_status -file route_status.rpt
    write_checkpoint -force route.dcp
    set setup [get_timing_paths -delay_type max -max_paths 1]
    set hold [get_timing_paths -delay_type min -max_paths 1]
    if {[llength $setup] == 0 || [llength $hold] == 0} { error "No constrained register timing paths" }
    set wns [get_property SLACK $setup]
    set whs [get_property SLACK $hold]
    puts "AUDIT_ROUTE_WNS=$wns WHS=$whs"
    if {$wns < 0 || $whs < 0} { error "Routed timing failed" }
}
puts "AUDIT_DONE"
