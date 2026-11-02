set root [file dirname [file dirname [file normalize [info script]]]]
source [file join $root scripts message_policy.tcl]
open_project [file join $root vivado TinyYOLO_192.xpr]
update_compile_order -fileset sources_1
if {[get_property PART [current_project]] ne {xc7z020clg484-1}} {error {Wrong FPGA part}}
if {[get_property TOP [get_filesets sources_1]] ne {Tiny_Yolo_wrapper}} {error {Wrong top module}}
set sources [get_files -compile_order sources -used_in synthesis]
set checked 0
foreach source $sources {
    set path [file normalize [get_property NAME $source]]
    if {![file isfile $path]} {error "Missing active source: $path"}
    set prefix [string tolower "[file normalize $root]/"]
    if {[string first $prefix [string tolower $path]] != 0} {
        error "Active source is outside the delivery: $path"
    }
    incr checked
}
set constraints [get_files -of_objects [get_filesets constrs_1]]
foreach source $constraints {
    set path [file normalize [get_property NAME $source]]
    if {![file isfile $path] || [string first $prefix [string tolower $path]] != 0} {
        error "Missing or external constraint: $path"
    }
}
report_ip_status -file [file join $root reports ip_status.rpt]
if {[llength [get_ips -quiet -filter {IS_LOCKED == 1}]]} {error {Project contains locked IP}}
set synth_status [get_property STATUS [get_runs synth_1]]
set impl_status [get_property STATUS [get_runs impl_1]]
if {$synth_status ne {synth_design Complete!}} {error "Unexpected synthesis status: $synth_status"}
if {$impl_status ne {write_bitstream Complete!}} {error "Unexpected implementation status: $impl_status"}
foreach name {synth_1 impl_1} {
    if {[get_property NEEDS_REFRESH [get_runs $name]]} {error "Stale run: $name"}
}
set hook [file normalize [get_property STEPS.OPT_DESIGN.TCL.PRE [get_runs impl_1]]]
if {![file isfile $hook] || [string first $prefix [string tolower $hook]] != 0} {
    error "Missing or external implementation pre-opt hook: $hook"
}
if {![llength [get_files -quiet -of_objects [get_filesets utils_1] $hook]]} {
    error {Implementation pre-opt hook is missing from utils_1}
}
set fanout_hook [file normalize [get_property STEPS.PHYS_OPT_DESIGN.TCL.POST [get_runs impl_1]]]
if {![file isfile $fanout_hook] || [string first $prefix [string tolower $fanout_hook]] != 0 ||
    ![llength [get_files -quiet -of_objects [get_filesets utils_1] $fanout_hook]]} {
    error {Implementation post-place hook is missing, external, or unregistered}
}
set cleanup [file join $root scripts cleanup_unused_reset.tcl]
set budget_hook [file normalize [get_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.TCL.POST [get_runs impl_1]]]
if {![file isfile $budget_hook] || [string first $prefix [string tolower $budget_hook]] != 0 ||
    ![llength [get_files -quiet -of_objects [get_filesets utils_1] $budget_hook]]} {
    error {Implementation budget restore hook is missing, external, or unregistered}
}
if {![file isfile $cleanup] || ![llength [get_files -quiet -of_objects [get_filesets utils_1] $cleanup]]} {
    error {Reset cleanup dependency is missing from utils_1}
}
set fp [open [file join $root reports project_open.json] w]
open_run impl_1
source [file join $root scripts assert_clock_topology.tcl]
assert_clock_topology
report_clock_utilization -file [file join $root reports clock_utilization.rpt]
puts $fp [format {{"status":"PASS_PROJECT_OPEN","source_count":%d,"part":"xc7z020clg484-1","top":"Tiny_Yolo_wrapper","all_active_sources_local":true,"pre_opt_hook_in_utils":true,"post_place_hook_in_utils":true,"cleanup_dependency_local":true,"clock_topology_checked":true,"cascaded_bufg":false,"synthesis":"%s","implementation":"%s"}} $checked $synth_status $impl_status]
close $fp
puts "FINAL_PROJECT_OPEN_PASS source_count=$checked root=$root"
close_project
exit
