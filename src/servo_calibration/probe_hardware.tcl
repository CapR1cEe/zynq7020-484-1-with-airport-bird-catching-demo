open_hw_manager
connect_hw_server -url localhost:3121
if {[llength [get_hw_targets]] != 1} {error {Expected one cable}}
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set devices [get_hw_devices -filter {PART == xc7z020}]
if {[llength $devices] != 1} {error {Expected one xc7z020}}
set device [lindex $devices 0]
refresh_hw_device $device
puts "SERVO_JTAG_PREFLIGHT part=[get_property PART $device] done=[get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $device] crc_error=[get_property REGISTER.CONFIG_STATUS.BIT00_CRC_ERROR $device]"
close_hw_target
disconnect_hw_server
close_hw_manager
exit
