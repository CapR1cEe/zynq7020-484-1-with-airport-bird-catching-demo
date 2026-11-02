# Dedicated scratch benchmark; run in its own Vivado batch process.
# vivado -mode batch -source characterize_tree.tcl -tclargs SKILL_DIR OUTPUT_DIR PART MHZ
# Uses a full synthesized clock network and registered traffic source/sink.
# The automatic IO placement is not a board pin plan or replacement for real XDC.
if {$argc != 4} { error "Expected SKILL_DIR OUTPUT_DIR PART MHZ" }
lassign $argv skill_dir output_dir part mhz
if {![string is double -strict $mhz] || $mhz <= 0} { error "MHZ must be positive" }
set skill_dir [file normalize $skill_dir]
set output_dir [file normalize $output_dir]
file mkdir $output_dir
set_param general.maxThreads 4
create_project -in_memory -part $part
read_verilog -sv [file join $skill_dir assets rtl signed_sum_tree_stream.sv]
read_verilog -sv [file join $skill_dir assets bench registered_tree_benchmark.sv]
set channel [open [file join $output_dir benchmark.xdc] w]
puts $channel [format {create_clock -name bench_clk -period %.6f [get_ports clk]} [expr {1000.0/$mhz}]]
puts $channel {set_clock_uncertainty 0.150 [get_clocks bench_clk]}
puts $channel {set_output_delay -clock bench_clk -max 0.500 [get_ports checksum*]}
puts $channel {set_output_delay -clock bench_clk -min 0.000 [get_ports checksum*]}
close $channel
read_xdc [file join $output_dir benchmark.xdc]
synth_design -top registered_tree_benchmark -part $part
report_utilization -file [file join $output_dir synthesis_utilization.rpt]
opt_design
place_design
route_design
source [file join $skill_dir scripts collect_reports.tcl]
ross_collect_reports [file join $output_dir reports]
# Keep full reports above, including any output-boundary failures. These scoped
# paths answer only the internal datapath question; they cannot override them.
set registers [all_registers]
report_timing -from $registers -to $registers -delay_type max -max_paths 20 -file [file join $output_dir reports internal_setup.rpt]
report_timing -from $registers -to $registers -delay_type min -max_paths 20 -file [file join $output_dir reports internal_hold.rpt]
set channel [open [file join $output_dir reports internal_metrics.tsv] w]
puts $channel "scope\tmetric\tvalue_ns"
foreach delay_type {max min} {
    set paths [get_timing_paths -from $registers -to $registers -delay_type $delay_type -max_paths 1]
    if {[llength $paths] != 1} { error "Expected a register-to-register timing path" }
    puts $channel "register_to_register_only\t${delay_type}_slack\t[get_property SLACK [lindex $paths 0]]"
}
close $channel
report_clocks -file [file join $output_dir reports clocks.rpt]
write_checkpoint -force [file join $output_dir routed.dcp]
puts "REGISTERED_TREE_CHARACTERIZATION_COMPLETE: review IO/DRC and all reports; not board signoff."
