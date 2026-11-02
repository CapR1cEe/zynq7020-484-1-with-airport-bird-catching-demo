# XPM retains payload registers with KEEP even when their Q has no consumer.
# These dead destinations can share a live source bit and make the router
# ignore a bus-skew group. Prune only demonstrably unused payload flops;
# retain every live CDC data/handshake register and every timing constraint.
set cdc_cleanup_root [file dirname [file dirname [file normalize [info script]]]]
set cdc_proof [open [file join $cdc_cleanup_root reports cdc_unused_data.tsv] w]
puts $cdc_proof "cell\tprimitive\tleaf_sinks\ttop_ports"
set cdc_removed 0
foreach cell [get_cells -hierarchical -filter {NAME =~ *smartconnect_0/*inst_cdc_handshake/dest_hsdata_ff_reg* && REF_NAME == FDRE}] {
    set outputs [get_pins -of_objects $cell -filter {DIRECTION == OUT}]
    if {[llength $outputs] != 1} {error "Unexpected XPM data outputs: $cell"}
    set segments [get_nets -quiet -segments -of_objects $outputs]
    if {[llength $segments]} {
        set sinks [get_pins -quiet -leaf -of_objects $segments -filter {DIRECTION == IN}]
        set ports [get_ports -quiet -of_objects $segments]
        if {[llength $sinks] || [llength $ports]} {continue}
    }
    set protected_inputs {}
    set inputs [get_nets -segments -of_objects [get_pins -of_objects $cell -filter {DIRECTION == IN}]]
    foreach input_net $inputs {
        if {[get_property DONT_TOUCH $input_net] in {1 true TRUE}} {
            lappend protected_inputs [get_property NAME $input_net]
        }
    }
    set_property DONT_TOUCH false $inputs
    if {[llength $segments]} {set_property DONT_TOUCH false $segments}
    set_property DONT_TOUCH false $cell
    set_property KEEP false $cell
    puts $cdc_proof "$cell\tFDRE\t0\t0"
    remove_cell $cell
    foreach input_name $protected_inputs {
        set surviving [get_nets -quiet -hierarchical -filter [list NAME == $input_name]]
        if {[llength $surviving]} {set_property DONT_TOUCH true $surviving}
    }
    incr cdc_removed
}
close $cdc_proof
puts "CDC_UNUSED_DATA_CLEANUP_PASS removed_flops=$cdc_removed"
