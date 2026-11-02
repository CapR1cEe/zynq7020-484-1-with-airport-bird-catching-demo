set root [file dirname [file dirname [file normalize [info script]]]]
source [file join $root scripts message_policy.tcl]
open_project [file join $root vivado TinyYOLO_192.xpr]
if {[get_property STATUS [get_runs synth_1]] ne {synth_design Complete!} ||
    [get_property NEEDS_REFRESH [get_runs synth_1]]} {error {Current synthesis is required}}
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -scripts_only
puts {CORRECTED_IMPLEMENTATION_SCRIPTS_READY}
close_project
exit
