# Implementation pre-opt hook. Prune only reset flops whose Q has no leaf
# sink or top-level port. Do this before placement/routing so the normal
# optimizer and router rebuild all affected physical resources.
set cleanup_root [file dirname [file dirname [file normalize [info script]]]]
set cleanup_report [open [file join $cleanup_root reports reset_cleanup.tsv] w]
puts $cleanup_report "net\tdriver\tleaf_sinks\tprimitive"
set cleanup_count 0
set cleanup_more 1
while {$cleanup_more} {
    set cleanup_more 0
    foreach reset_net [get_nets -hierarchical -filter {NAME =~ */s_sc_areset || NAME =~ */s_sc_areset_pipe* || NAME =~ */u_control/arithmetic_reset*}] {
        set segments [get_nets -segments $reset_net]
        set leaves [get_pins -quiet -leaf -of_objects $segments]
        if {[llength [filter $leaves {DIRECTION == IN}]] ||
            [llength [get_ports -quiet -of_objects $segments]]} {continue}
        set drivers [filter $leaves {DIRECTION == OUT}]
        if {![llength $drivers]} {continue}
        if {[llength $drivers] != 1} {error "Unexpected reset drivers: $reset_net"}
        set cell [get_cells -of_objects $drivers]
        set primitive [get_property REF_NAME $cell]
        if {$primitive ni {FDRE FDCE FDPE FDSE}} {error "Unexpected reset primitive: $cell"}
        if {[llength [get_pins -of_objects $cell -filter {DIRECTION == OUT}]] != 1} {
            error "Unexpected reset output pins: $cell"
        }
        # Removing a cell also disconnects its inputs. Temporarily unlock
        # those nets, then restore every surviving input net's protection.
        set protected_inputs {}
        set inputs [get_nets -segments -of_objects [get_pins -of_objects $cell -filter {DIRECTION == IN}]]
        foreach input_net $inputs {
            if {[get_property DONT_TOUCH $input_net] in {1 true TRUE}} {
                lappend protected_inputs [get_property NAME $input_net]
            }
        }
        set_property DONT_TOUCH false $inputs
        set_property DONT_TOUCH false $segments
        set_property DONT_TOUCH false $cell
        puts $cleanup_report "$reset_net\t$cell\t0\t$primitive"
        puts "RESET_PRUNE_NO_LOAD net=$reset_net driver=$cell"
        remove_cell $cell
        foreach input_name $protected_inputs {
            set surviving [get_nets -quiet -hierarchical -filter [list NAME == $input_name]]
            if {[llength $surviving]} {set_property DONT_TOUCH true $surviving}
        }
        incr cleanup_count
        set cleanup_more 1
    }
}
close $cleanup_report
puts "RESET_UNUSED_CLEANUP_PASS removed_flops=$cleanup_count"
