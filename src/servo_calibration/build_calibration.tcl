set root [file dirname [file normalize [info script]]]
file mkdir [file join $root reports]
file mkdir [file join $root firmware]
create_project Servo_Microtest [file join $root vivado] -part xc7z020clg484-1
set_property target_language Verilog [current_project]
add_files -norecurse [file join $root servo_microtest.v]
add_files -fileset constrs_1 -norecurse [file join $root servo_pins.xdc]
create_bd_design Servo_Microtest
set processing_system7_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0]
source [file join $root ps_configuration.tcl]
set_property -dict [list CONFIG.PCW_USE_M_AXI_GP0 {0} CONFIG.PCW_USE_S_AXI_HP0 {0} CONFIG.PCW_GPIO_EMIO_GPIO_ENABLE {1} CONFIG.PCW_GPIO_EMIO_GPIO_IO {16} CONFIG.PCW_EN_CLK0_PORT {0} CONFIG.PCW_EN_RST0_PORT {1}] $processing_system7_0
make_bd_intf_pins_external [get_bd_intf_pins processing_system7_0/DDR]
make_bd_intf_pins_external [get_bd_intf_pins processing_system7_0/FIXED_IO]
make_bd_intf_pins_external [get_bd_intf_pins processing_system7_0/UART_0]
set servo [create_bd_cell -type module -reference servo_microtest servo_0]
set clk50 [create_bd_port -dir I -type clk -freq_hz 50000000 clk50]
connect_bd_net $clk50 [get_bd_pins servo_0/clk50]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] [get_bd_pins servo_0/resetn]
foreach suffix {O T I} port {o t i} {
    connect_bd_net [get_bd_pins processing_system7_0/GPIO_$suffix] [get_bd_pins servo_0/gpio_$port]
}
foreach axis {pan tilt} {
    connect_bd_net [create_bd_port -dir O ${axis}_pwm] [get_bd_pins servo_0/${axis}_pwm]
}
validate_bd_design
save_bd_design
set bd [get_files Servo_Microtest.bd]
set_property synth_checkpoint_mode None $bd
generate_target all $bd
add_files -norecurse [make_wrapper -files $bd -top]
set_property top Servo_Microtest_wrapper [current_fileset]
update_compile_order -fileset sources_1

# Run directly in this batch process: Windows CScript launcher is unavailable.
synth_design -top Servo_Microtest_wrapper -part xc7z020clg484-1
write_checkpoint -force [file join $root firmware servo_microtest_synth.dcp]
opt_design
place_design
phys_opt_design
route_design
report_methodology -file [file join $root reports methodology.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $root reports timing.rpt]
report_drc -file [file join $root reports drc.rpt]
report_cdc -details -file [file join $root reports cdc.rpt]
report_io -file [file join $root reports io.rpt]
report_utilization -file [file join $root reports utilization.rpt]
set setup [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set hold [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
if {$setup eq {} || $hold eq {} || $setup < 0 || $hold < 0} {error {Microtest timing failed}}
if {[llength [get_drc_violations -quiet -filter {SEVERITY == Error || SEVERITY == {Critical Warning}}]]} {error {Microtest DRC failed}}
foreach port {pan_pwm tilt_pwm clk50} ball {H20 H19 M19} {
    if {[get_property PACKAGE_PIN [get_ports $port]] ne $ball} {error "Wrong pin for $port"}
    if {[get_property IOSTANDARD [get_ports $port]] ne {LVCMOS33}} {error "Wrong voltage for $port"}
}
write_checkpoint -force [file join $root firmware servo_microtest_routed.dcp]
write_bitstream -force [file join $root firmware servo_calibration.bit]
puts "SERVO_CALIBRATION_BUILD_PASS frames=150 range_us=2000:2500 setup_ns=$setup hold_ns=$hold"
close_project
exit
