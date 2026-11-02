# Finalize delivery directly from the measured post-route checkpoint.
# This avoids the Windows runme.bat/cscript wrapper and does not rerun place/route.
set root [file dirname [file dirname [file normalize [info script]]]]
set reports [file join $root reports]
set firmware [file join $root firmware]
file mkdir $reports
file mkdir $firmware

open_project [file join $root vivado TinyYOLO_192.xpr]
open_checkpoint [file join $root vivado TinyYOLO_192.runs impl_1 Tiny_Yolo_wrapper_postroute_physopt.dcp]

# Recreate the signoff reports from the exact checkpoint being delivered.
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $reports timing_final_checkpoint.rpt]
report_timing -delay_type max -max_paths 20 -sort_by slack -file [file join $reports timing_worst20_final.rpt]
report_timing -delay_type min -max_paths 10 -sort_by slack -file [file join $reports hold_worst10_final.rpt]
report_utilization -file [file join $reports utilization_final_checkpoint.rpt]
report_drc -file [file join $reports drc_final_checkpoint.rpt]
report_cdc -details -file [file join $reports cdc_final_checkpoint.rpt]
report_methodology -file [file join $reports methodology_final_checkpoint.rpt]
report_bus_skew -warn_on_violation -file [file join $reports bus_skew_final_checkpoint.rpt]
report_route_status -file [file join $reports route_status_final_checkpoint.rpt]
report_clocks -file [file join $reports clocks_final_checkpoint.rpt]
set check [open [file join $reports check_timing_final_checkpoint.rpt] w]
puts $check [check_timing -return_string]
close $check

# The signoff hook writes timing_closure.json and enforces non-negative setup/hold.
source [file join $root scripts require_timing_closure.tcl]

write_checkpoint -force [file join $firmware final_192_routed.dcp]
write_bitstream -force [file join $firmware final_192.bit]
write_hw_platform -fixed -include_bit -force -file [file join $firmware final_192.xsa]

set setup [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set hold [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
set fp [open [file join $reports implementation.json] w]
puts $fp [format {{"status":"BUILT_FROM_POSTROUTE_CHECKPOINT","clock_mhz":240,"setup_ns":%s,"hold_ns":%s,"minimum_setup_margin_target_ns":0.0,"board_tested":false,"checkpoint":"vivado/TinyYOLO_192.runs/impl_1/Tiny_Yolo_wrapper_postroute_physopt.dcp"}} $setup $hold]
close $fp

puts "FINAL_DELIVERY_FROM_CHECKPOINT_PASS setup_ns=$setup hold_ns=$hold"
close_design
close_project
exit
