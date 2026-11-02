# Protect the original clock topology during placement and data replication.
# Clock-buffer replication and cascading are prohibited at every stage.
set implementation_root [file dirname [file dirname [file normalize [info script]]]]
source [file join $implementation_root scripts cleanup_unused_reset.tcl]
source [file join $implementation_root scripts cleanup_unused_cdc_data.tcl]
source [file join $implementation_root scripts distribute_synchronous_reset.tcl]
set pl_buffer [get_cells -hierarchical -filter {NAME == Tiny_Yolo_i/pl_clk/inst/clkout1_buf}]
if {[llength $pl_buffer] != 1 || [get_property REF_NAME $pl_buffer] ne {BUFG}} {
    error {Expected exactly one PL output BUFG before implementation}
}
set_property DONT_TOUCH true $pl_buffer
set pl_clock_nets [get_nets -segments -of_objects [get_pins -of_objects $pl_buffer]]
if {[llength $pl_clock_nets] < 2} {error {PL clock input/output nets are missing}}
set_property DONT_TOUCH true $pl_clock_nets
puts "PL_CLOCK_BUFFER_PROTECTED cell=$pl_buffer primitive=BUFG"
source [file join $implementation_root scripts assert_clock_topology.tcl]
assert_clock_topology
# Placement must see the same extra setup budget as routing. Applying this
# only after placement leaves already marginal reset and address routes.
set budget_clock [get_clocks clk_out1_Tiny_Yolo_pl_clk_0]
if {[llength $budget_clock] != 1 || abs([get_property PERIOD $budget_clock]-1000.0/240.0)>0.001} {
    error {Incorrect PL clock before applying the implementation budget}
}
set original_timing [report_timing -to $budget_clock -max_paths 1 -return_string]
if {[regexp {User Uncertainty\s+\(UU\):\s*([0-9.]+)ns} $original_timing -> original_user_uncertainty] &&
    $original_user_uncertainty != 0.0} {error {Unexpected pre-existing PL user uncertainty}}
set_clock_uncertainty -setup 0.250 $budget_clock
puts {SETUP_BUDGET_APPLIED_BEFORE_PLACEMENT additional_setup_budget_ns=0.250}
