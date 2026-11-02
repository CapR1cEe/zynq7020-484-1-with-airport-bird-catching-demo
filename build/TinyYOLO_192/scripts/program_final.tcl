# Temporary JTAG configuration only. Quiesce DMA and unload its driver first.
set root [file dirname [file dirname [file normalize [info script]]]]
set bitfile [file join $root firmware final_192.bit]
if {![file isfile $bitfile]} {error {Build final_192.bit before programming}}
open_hw_manager
connect_hw_server -url localhost:3121
set targets [get_hw_targets]
if {[llength $targets] != 1} {error {Connect exactly one JTAG target}}
current_hw_target [lindex $targets 0]
open_hw_target
set devices [get_hw_devices -filter {PART == xc7z020}]
if {[llength $devices] != 1} {error {Expected exactly one xc7z020 device}}
set device [lindex $devices 0]
current_hw_device $device
set_property PROGRAM.FILE $bitfile $device
puts "TY_FINAL_PROGRAM_FILE=$bitfile"
program_hw_devices $device
refresh_hw_device $device
report_property $device
puts {TY_FINAL_JTAG_PROGRAM_COMPLETE}
close_hw_target
disconnect_hw_server
close_hw_manager
exit
