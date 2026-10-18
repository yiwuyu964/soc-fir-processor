# Legacy Tcl entry point. Run from an ASCII staging directory containing RTL/,
# soc_top.xdc and check.tcl. Prefer synth/run_synth.bat in the repository.
if {[llength $argv] == 0} { set argv [list xc7z020clg400-1 20.0 route] }
if {[llength $argv] == 1} { lappend argv 20.0 route }
if {[llength $argv] == 2} { lappend argv route }
source [file join [file dirname [info script]] check.tcl]
