# Community ROSS helper: collect reports from the currently open design.
# This procedure does not modify constraints or run synthesis/implementation.
proc ross_collect_reports {output_dir} {
    if {[llength [info commands current_design]] == 0} {
        error "Vivado Tcl is required; no reports were collected"
    }
    if {[catch {current_design} design] || $design eq ""} {
        error "Open the intended synthesized or routed design first"
    }
    set output_dir [file normalize $output_dir]
    file mkdir $output_dir
    set index [open [file join $output_dir report_index.tsv] w]
    puts $index "report\tstatus\tdetail"
    set reports {
        {timing_summary.rpt {report_timing_summary -delay_type min_max -report_unconstrained}}
        {setup_paths.rpt {report_timing -delay_type max -max_paths 20 -path_type full_clock_expanded}}
        {hold_paths.rpt {report_timing -delay_type min -max_paths 20 -path_type full_clock_expanded}}
        {utilization.rpt {report_utilization -hierarchical}}
        {methodology.rpt {report_methodology}}
        {drc.rpt {report_drc}}
        {clock_interaction.rpt {report_clock_interaction}}
        {cdc.rpt {report_cdc}}
        {bus_skew.rpt {report_bus_skew}}
    }
    set failures 0
    foreach spec $reports {
        lassign $spec filename command
        set target [file join $output_dir $filename]
        # Report command options differ. In particular, timing/CDC/clock
        # reports do not accept the write_checkpoint-style -force switch.
        if {[catch {uplevel #0 [concat $command [list -file $target]]} reason]} {
            incr failures
            set reason [string map [list "\t" " " "\n" " " "\r" " "] $reason]
            puts $index "$filename\tFAILED_OR_UNSUPPORTED\t$reason"
        } else {
            puts $index "$filename\tCOLLECTED_REVIEW_REQUIRED\t$target"
        }
    }
    close $index
    puts "Report collection complete: $failures command(s) failed or unsupported; review report_index.tsv and report contents."
    return $failures
}
