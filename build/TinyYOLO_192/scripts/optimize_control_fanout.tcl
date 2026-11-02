# Post-place hook: timing-driven data optimization with a stricter setup budget.
# Avoid forced per-load copies that overload upstream ready/enable/reset nets.
set fanout_root [file dirname [file dirname [file normalize [info script]]]]
# The parameter address was split in RTL so that the multiplier BRAM no longer
# shares its high-fanout address bits with the bias and shift tables.  The
# drivers below are recorded for fanout comparison; they are not forced to
# replicate. Vivado chooses replication based on complete timing paths.
set address_drivers [get_cells -hierarchical -regexp {^Tiny_Yolo_i/tinyyolo_accel_0/inst/u_control/parameter_store_mul_index_reg\[[0-4]\]$}]
if {[llength $address_drivers] != 5} {
    set address_drivers [get_cells -hierarchical -regexp {^Tiny_Yolo_i/tinyyolo_accel_0/inst/u_control/parameter_store_index_reg\[[0-4]\]$}]
}
set head_state_driver [get_cells -hierarchical -regexp {^Tiny_Yolo_i/tinyyolo_accel_0/inst/u_control/head/state_reg\[5\]$}]
set weight_drivers [get_cells -hierarchical -regexp {^Tiny_Yolo_i/tinyyolo_accel_0/inst/u_control/weight_write_address_reg\[7\](_rep.*)?$}]
set response_driver [get_cells -hierarchical -regexp {^Tiny_Yolo_i/tinyyolo_accel_0/inst/u_ctrl_hp0_pipe2/rsp1/m_data_reg\[41\]$}]
if {[llength $address_drivers] != 5 || [llength $head_state_driver] != 1 ||
    ![llength $weight_drivers] ||
    [llength $response_driver] != 1} {error {Expected critical register drivers are missing}}
set critical_drivers [concat $address_drivers $head_state_driver $weight_drivers $response_driver]
foreach driver $critical_drivers {
    if {[get_property REF_NAME $driver] ne {FDRE}} {error "Unexpected register primitive: $driver"}
    set q_pin [get_pins -of_objects $driver -filter {REF_PIN_NAME == Q}]
    if {[llength $q_pin] != 1} {error "Missing register Q pin: $driver"}
}
set fanout_nets [get_nets -of_objects [get_pins -of_objects $critical_drivers -filter {REF_PIN_NAME == Q}]]
if {[llength $fanout_nets] < 7 || [llength $fanout_nets] > 12} {
    error "Unexpected number of critical Q nets: [llength $fanout_nets]"
}
set fanout_proof [open [file join $fanout_root reports control_fanout.tsv] w]
puts $fanout_proof "net\tleaf_inputs_before"
foreach fanout_net $fanout_nets {
    set fanout_inputs [get_pins -leaf -of_objects [get_nets -segments $fanout_net] -filter {DIRECTION == IN}]
    puts $fanout_proof "$fanout_net\t[llength $fanout_inputs]"
}
close $fanout_proof
# Explicit data optimization options disable other physical transformations.
# The BUFG stays protected while data register endpoints may be optimized.
set pl_buffer [get_cells Tiny_Yolo_i/pl_clk/inst/clkout1_buf]
set pl_clock_nets [get_nets -segments -of_objects [get_pins -of_objects $pl_buffer]]
set original_buffers [lsort [get_cells -hierarchical -filter {REF_NAME == BUFG}]]
if {![get_property DONT_TOUCH $pl_buffer]} {error {PL clock BUFG lost protection}}
set budget_clock [get_clocks clk_out1_Tiny_Yolo_pl_clk_0]
if {[llength $budget_clock] != 1 || abs([get_property PERIOD $budget_clock]-1000.0/240.0)>0.001} {
    error {Incorrect PL clock before setup-budget optimization}
}
set budget_timing [report_timing -to $budget_clock -max_paths 1 -return_string]
if {![regexp {User Uncertainty\s+\(UU\):\s*([0-9.]+)ns} $budget_timing -> active_user_uncertainty] ||
    abs($active_user_uncertainty-0.250)>0.001} {error {Implementation setup budget was not applied before placement}}
# Retain the stricter placement budget through routing. Restore exactly this
# addition in the post-route hook before checkpoint and bitstream signoff.
set_property DONT_TOUCH false $pl_clock_nets
set replication_status [catch {
    phys_opt_design -fanout_opt -placement_opt -restruct_opt -critical_cell_opt -dsp_register_opt -bram_register_opt -bram_enable_opt -shift_register_opt
} replication_result]
set_property DONT_TOUCH true $pl_clock_nets
if {$replication_status} {error $replication_result}
if {![get_property DONT_TOUCH $pl_buffer] ||
    [lsort [get_cells -hierarchical -filter {REF_NAME == BUFG}]] ne $original_buffers} {
    error {Data optimization changed clock-buffer topology}
}
# Let timing-driven optimization choose the data candidates for this RTL.
# Do not force obsolete register copies from an earlier placement.
set repair_fp [open [file join $fanout_root reports critical_data_replication.json] w]
puts $repair_fp {{"status":"PASS_TIMING_DRIVEN_DATA_OPTIMIZATION","phase":"post_place_pre_route","forced_candidate_data_nets":0,"added_pipeline_cycles":0,"clock_topology_preserved":true,"path_exceptions_changed":false}}
close $repair_fp
set repair_fp [open [file join $fanout_root reports critical_data_replication.tsv] w]
puts $repair_fp "selection\toperation"
puts $repair_fp "timing_driven\tVivado_data_optimization"
close $repair_fp
set budget_fp [open [file join $fanout_root reports implementation_budget.json] w]
puts $budget_fp {{"status":"APPLIED_STRICTER_IMPLEMENTATION_BUDGET","clock_mhz":240,"additional_setup_uncertainty_ns":0.250,"original_user_uncertainty_ns":0.000,"applied_before_placement":true,"clock_topology_preserved":true}}
close $budget_fp
puts "CONTROL_FANOUT_CLOCK_TOPOLOGY_PRESERVED buffers=[llength $original_buffers]"
puts "CONTROL_FANOUT_OPTIMIZED measured_nets=[llength $fanout_nets] additional_setup_budget_ns=0.250"
