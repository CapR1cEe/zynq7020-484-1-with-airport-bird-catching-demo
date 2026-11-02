set root [file dirname [file dirname [file normalize [info script]]]]
set mode [lindex $argv 0]
set project [file join $root vivado TinyYOLO_192.xpr]
set reports [file join $root reports]
file mkdir $reports
set_param general.maxThreads 8
source [file join $root scripts message_policy.tcl]
proc configure_runs {root} {
    foreach source [glob [file join $root hardware g227 rtl *.v]] {
        if {![llength [get_files -quiet $source]]} {add_files -norecurse $source}
    }
    # Power assumptions affect estimation only, and must not enter synthesis.
    foreach name {critical_bram_power.xdc reset_power_activity.xdc} {
        set constraint [get_files -quiet $name]
        if {![llength $constraint]} {
            add_files -fileset constrs_1 -norecurse [file join $root hardware g227 $name]
            set constraint [get_files $name]
        }
        set_property USED_IN_SYNTHESIS false $constraint
        set_property PROCESSING_ORDER LATE $constraint
    }
    set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]
    set_property STEPS.SYNTH_DESIGN.ARGS.RESOURCE_SHARING off [get_runs synth_1]
    # Remap low-fanout synchronous controls to the D logic to reduce control
    # sets and improve packing. Keep higher-fanout controls on dedicated pins.
    set_property -dict [list {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} {-control_set_opt_threshold 10}] [get_runs synth_1]
    set impl [get_runs impl_1]
    foreach name {cleanup_unused_reset.tcl cleanup_unused_cdc_data.tcl distribute_synchronous_reset.tcl implementation_pre_opt.tcl optimize_control_fanout.tcl restore_implementation_budget.tcl implementation_pre_bitstream.tcl require_timing_closure.tcl assert_clock_topology.tcl} {
        set utility [file join $root scripts $name]
        if {![llength [get_files -quiet -of_objects [get_filesets utils_1] $utility]]} {
            add_files -fileset utils_1 -norecurse $utility
        }
    }
    set_property STEPS.OPT_DESIGN.TCL.PRE [file join $root scripts implementation_pre_opt.tcl] $impl
    set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE Explore $impl
    set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true $impl
    set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore $impl
    set_property STEPS.PHYS_OPT_DESIGN.TCL.POST [file join $root scripts optimize_control_fanout.tcl] $impl
    set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AggressiveExplore $impl
    set_property -dict [list {STEPS.ROUTE_DESIGN.ARGS.MORE OPTIONS} {-tns_cleanup}] $impl
    set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true $impl
    set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore $impl
    set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.TCL.POST [file join $root scripts restore_implementation_budget.tcl] $impl
    set_property STEPS.WRITE_BITSTREAM.TCL.PRE [file join $root scripts implementation_pre_bitstream.tcl] $impl
}
proc require_complete {name expected} {
    set run [get_runs $name]
    set status [get_property STATUS $run]
    if {[get_property PROGRESS $run] ne {100%} || $status ne $expected} {
        error "Incomplete run $name: $status"
    }
    if {[get_property NEEDS_REFRESH $run]} {error "Stale run: $name"}
}
if {$mode eq {scripts_synth} || $mode eq {scripts_impl}} {
    open_project $project
    configure_runs $root
    if {$mode eq {scripts_synth}} {
        reset_run synth_1
        update_compile_order -fileset sources_1
        report_compile_order -used_in synthesis -file [file join $reports compile_order.rpt]
        launch_runs synth_1 -scripts_only
    } else {
        require_complete synth_1 {synth_design Complete!}
        reset_run impl_1
        launch_runs impl_1 -to_step write_bitstream -scripts_only
    }
    puts "NATIVE_RUN_SCRIPTS_READY mode=$mode"
} elseif {$mode eq {prepare}} {
    create_project TinyYOLO_192 [file dirname $project] -part xc7z020clg484-1
    set_property target_language Verilog [current_project]
    add_files -norecurse [glob [file join $root hardware g227 rtl *.v]]
    add_files -fileset constrs_1 -norecurse [glob [file join $root hardware g227 *.xdc]]
    configure_runs $root
    update_compile_order -fileset sources_1
    set result [source [file join $root hardware g227 block_design.tcl]]
    if {$result ne {} && [string is integer -strict $result] && $result != 0} {error {BD generation failed}}
    validate_bd_design
    save_bd_design
    set bd [get_files Tiny_Yolo.bd]
    set_property synth_checkpoint_mode None $bd
    generate_target all $bd
    add_files -norecurse [make_wrapper -files $bd -top]
    set_property top Tiny_Yolo_wrapper [get_filesets sources_1]
    update_compile_order -fileset sources_1
    report_compile_order -used_in synthesis -file [file join $reports compile_order.rpt]
    # The .xpr and this build script are the project entry points. Avoid a
    # redundant export that only warns about already packaged local BD files.
    launch_runs synth_1 -jobs 8
    wait_on_run synth_1
    require_complete synth_1 {synth_design Complete!}
} elseif {$mode eq {resume_synth} || $mode eq {rebuild} || $mode eq {rebuild_impl}} {
    open_project $project
    configure_runs $root
    if {$mode eq {rebuild_impl}} {
        require_complete synth_1 {synth_design Complete!}
        reset_runs impl_1
    } elseif {$mode eq {rebuild}} {
        reset_runs impl_1
        reset_runs synth_1
        update_compile_order -fileset sources_1
        report_compile_order -used_in synthesis -file [file join $reports compile_order.rpt]
    }
    if {$mode ne {rebuild_impl}} {
        launch_runs synth_1 -jobs 8
        wait_on_run synth_1
        require_complete synth_1 {synth_design Complete!}
    }
} elseif {$mode eq {prepare_impl}} {
    open_project $project
    wait_on_run synth_1
    require_complete synth_1 {synth_design Complete!}
    # Let the project manager create and monitor the native run. Running a
    # generated Tcl file directly does not refresh its captured fileset state.
    launch_runs impl_1 -to_step write_bitstream -jobs 8
    wait_on_run impl_1
    require_complete impl_1 {write_bitstream Complete!}
} elseif {$mode eq {finish}} {
    open_project $project
    wait_on_run impl_1
    require_complete synth_1 {synth_design Complete!}
    require_complete impl_1 {write_bitstream Complete!}
    open_run impl_1
    report_timing_summary -delay_type min_max -report_unconstrained -file [file join $reports timing.rpt]
    report_utilization -file [file join $reports utilization.rpt]
    report_drc -file [file join $reports drc.rpt]
    report_cdc -details -file [file join $reports cdc.rpt]
    report_methodology -file [file join $reports methodology.rpt]
    report_bus_skew -file [file join $reports bus_skew.rpt]
    report_route_status -file [file join $reports route_status.rpt]
    report_clocks -file [file join $reports clocks.rpt]
    set check [open [file join $reports check_timing.rpt] w]
    puts $check [check_timing -return_string]
    close $check
    set setup [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
    set hold [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
    source [file join $root scripts require_timing_closure.tcl]
    set fp [open [file join $reports implementation.json] w]
    puts $fp [format {{"status":"BUILT","clock_mhz":240,"setup_ns":%s,"hold_ns":%s,"board_tested":false}} $setup $hold]
    close $fp
    write_checkpoint -force [file join $root firmware final_192_routed.dcp]
    write_bitstream -force [file join $root firmware final_192.bit]
    write_hw_platform -fixed -include_bit -force -file [file join $root firmware final_192.xsa]
    puts "FINAL_BUILD_COMPLETE setup_ns=$setup hold_ns=$hold"
} else {error {Expected prepare, prepare_impl or finish}}
close_project
exit
