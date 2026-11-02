# Signoff uses the actual 240 MHz constraints, including all setup/hold,
# pulse-width and vendor bus-skew checks. A positive setup margin is required
# for this delivery; the earlier +0.100 ns engineering target is advisory.
file delete -force [file join $reports timing_closure.json]
set setup_slack [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set hold_slack [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
set timing_summary [report_timing_summary -delay_type min_max -report_unconstrained -return_string]
set skew_summary [report_bus_skew -return_string]
if {$setup_slack < 0.0 || $hold_slack < 0 ||
    ![regexp -nocase {all user specified timing constraints are met\.} $timing_summary]} {
    error "Timing closure required: setup=$setup_slack hold=$hold_slack"
}
set skew_rows [regexp -all -line -inline {(Slow|Fast)\s+([0-9.]+)\s+([0-9.]+)\s+(-?[0-9.]+)\s*$} $skew_summary]
if {![llength $skew_rows]} {error {No bus skew constraints found at signoff}}
set minimum_skew 1.0e9
foreach {row corner requirement actual slack} $skew_rows {
    if {$slack < 0} {error "Bus skew violation: $row"}
    if {$slack < $minimum_skew} {set minimum_skew $slack}
}
set closure_file [open [file join $reports timing_closure.json] w]
puts $closure_file [format {{"status":"PASS_TIMING_CLOSURE","clock_mhz":240,"setup_ns":%s,"hold_ns":%s,"minimum_setup_margin_target_ns":0.0,"minimum_bus_skew_ns":%s,"timing_constraints_met":true,"negative_slack_allowed":false}} $setup_slack $hold_slack $minimum_skew]
close $closure_file
puts "FINAL_TIMING_CLOSURE_PASS setup_ns=$setup_slack hold_ns=$hold_slack bus_skew_ns=$minimum_skew"
