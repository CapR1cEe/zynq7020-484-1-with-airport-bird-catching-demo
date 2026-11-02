# Native post-route hook: restore only the extra setup budget added by the
# pre-implementation hook. Device jitter and original XDCs stay active.
set budget_root [file dirname [file dirname [file normalize [info script]]]]
set budget_clock [get_clocks clk_out1_Tiny_Yolo_pl_clk_0]
if {[llength $budget_clock] != 1 || abs([get_property PERIOD $budget_clock]-1000.0/240.0)>0.001} {
    error {Incorrect PL clock before restoring the implementation budget}
}
set budget_fp [open [file join $budget_root reports implementation_budget.json] r]
set budget_record [read $budget_fp]
close $budget_fp
if {[string first {APPLIED_STRICTER_IMPLEMENTATION_BUDGET} $budget_record] < 0} {
    error {Missing stricter implementation-budget receipt}
}
set budget_timing [report_timing -to $budget_clock -max_paths 1 -return_string]
if {![regexp {User Uncertainty\s+\(UU\):\s*([0-9.]+)ns} $budget_timing -> user_uncertainty] ||
    abs($user_uncertainty-0.250)>0.001} {error {Unexpected implementation user uncertainty}}
set strict_slack [get_property SLACK [get_timing_paths -to $budget_clock -delay_type max -max_paths 1]]
set_clock_uncertainty -setup 0.000 $budget_clock
set original_slack [get_property SLACK [get_timing_paths -to $budget_clock -delay_type max -max_paths 1]]
if {abs(($original_slack-$strict_slack)-0.250)>0.002} {
    error {Restoring the added setup budget produced an unexpected slack change}
}
report_timing -to $budget_clock -max_paths 10 -file [file join $budget_root reports implementation_budget_restored.rpt]
set budget_fp [open [file join $budget_root reports implementation_budget.json] w]
puts $budget_fp [format {{"status":"PASS_ORIGINAL_SETUP_BUDGET_RESTORED","scope":"uncertainty_restoration_with_original_clock_topology","clock_mhz":240,"additional_setup_uncertainty_ns":0.250,"original_user_uncertainty_ns":0.000,"restored_user_uncertainty_ns":0.000,"stricter_setup_ns":%s,"original_setup_ns":%s,"applied_before_placement":true,"clock_topology_preserved":true}} $strict_slack $original_slack]
close $budget_fp
puts "ORIGINAL_SETUP_BUDGET_RESTORED stricter_setup_ns=$strict_slack original_setup_ns=$original_slack"

# Preserve the original MMCM -> BUFG clock network. No clock-skew pass may
# release or duplicate these buffers. Final timing is checked before bitgen.
source [file join $budget_root scripts assert_clock_topology.tcl]
set clock_buffers [assert_clock_topology]
set topology_fp [open [file join $budget_root reports clock_topology_buffers.tsv] w]
puts $topology_fp "cell\tprimitive\tsite\tinput_driver\tinput_net\toutput_net"
foreach buffer $clock_buffers {
    set input_nets [get_nets -segments -of_objects [get_pins $buffer/I]]
    set input_driver [get_pins -leaf -of_objects $input_nets -filter {DIRECTION == OUT}]
    puts $topology_fp "$buffer\t[get_property REF_NAME $buffer]\t[get_property LOC $buffer]\t$input_driver\t[get_nets -of_objects [get_pins $buffer/I]]\t[get_nets -of_objects [get_pins $buffer/O]]"
}
close $topology_fp
set topology_fp [open [file join $budget_root reports clock_topology.json] w]
puts $topology_fp {{"status":"PASS_ORIGINAL_CLOCK_TOPOLOGY","clock_mhz":240,"bufg_count":3,"cascaded_bufg":false,"pl_bufg_direct_mmcm_clkout0":true,"clock_period_unchanged":true,"user_uncertainty_ns":0.000,"path_exceptions_changed":false,"warning_suppression":false}}
close $topology_fp
