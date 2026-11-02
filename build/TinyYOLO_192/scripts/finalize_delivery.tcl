# Finish the already routed implementation after the user accepted the
# measured positive setup margin. This keeps the routed checkpoint unchanged
# and reruns only the native bitstream step plus its signoff hook.
set root [file dirname [file dirname [file normalize [info script]]]]
set project [file join $root vivado TinyYOLO_192.xpr]
set log_dir [file join $root reports]
file mkdir $log_dir
open_project $project
set impl [get_runs impl_1]
set_property STEPS.WRITE_BITSTREAM.TCL.PRE [file join $root scripts implementation_pre_bitstream.tcl] $impl
reset_run $impl -from_step write_bitstream
launch_runs $impl -to_step write_bitstream -jobs 8
wait_on_run $impl
set status [get_property STATUS $impl]
set progress [get_property PROGRESS $impl]
puts "FINALIZE_IMPL_STATUS=$status PROGRESS=$progress"
if {$status ne {write_bitstream Complete!} || $progress ne {100%}} {
    error "Final bitstream run did not complete: $status ($progress)"
}
close_project
exit
