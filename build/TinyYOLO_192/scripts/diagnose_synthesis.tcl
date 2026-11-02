# Run in the project context so Vivado reapplies scoped IP, board and clock XDCs.
# A synthesis checkpoint alone does not carry all these constraints.
set root [file dirname [file dirname [file normalize [info script]]]]
set reports [file join $root reports]
source [file join $root scripts message_policy.tcl]
set_param general.maxThreads 4
open_project [file join $root vivado TinyYOLO_192.xpr]
if {[get_property STATUS [get_runs synth_1]] ne {synth_design Complete!} ||
    [get_property NEEDS_REFRESH [get_runs synth_1]]} {
    error {Synthesis must be complete and current before diagnostics}
}
open_run synth_1
set pl_clock [get_clocks -quiet clk_out1_Tiny_Yolo_pl_clk_0]
if {[llength $pl_clock] != 1 ||
    abs([get_property PERIOD $pl_clock] - 1000.0 / 240.0) > 0.001} {
    error {Missing or incorrect 240 MHz PL clock in synthesis diagnostics}
}
report_clocks -file [file join $reports synthesis_clocks.rpt]
report_control_sets -verbose -file [file join $reports synthesis_control_sets.rpt]
set timing_text [check_timing -return_string]
set timing_fp [open [file join $reports synthesis_check_timing.rpt] w]
puts $timing_fp $timing_text
close $timing_fp
foreach check {no_clock unconstrained_internal_endpoints no_input_delay no_output_delay multiple_clock generated_clocks loops partial_input_delay partial_output_delay latch_loops} {
    if {[string first "checking $check (0)" $timing_text] < 0} {
        error "Synthesis timing constraint check did not pass: $check"
    }
}
report_drc -file [file join $reports synthesis_drc.rpt]
report_methodology -file [file join $reports synthesis_methodology.rpt]
report_cdc -details -file [file join $reports synthesis_cdc.rpt]
foreach name {synthesis_drc.rpt synthesis_methodology.rpt synthesis_cdc.rpt} {
    set fp [open [file join $reports $name] r]
    set contents [read $fp]
    close $fp
    if {[regexp -line -nocase {\|\s*(Critical Warning|Warning|Error|Critical)\s*\||^\s*\d+\s+CDC-\d+\s+(Critical|Warning|Error)\s+} $contents]} {
        error "Unresolved synthesis diagnostic in $name"
    }
}
puts {SYNTHESIS_DIAGNOSTICS_COMPLETE}
close_design
close_project
exit
