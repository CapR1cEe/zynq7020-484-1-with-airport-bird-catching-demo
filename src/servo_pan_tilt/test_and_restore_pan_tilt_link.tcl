set root [file dirname [file normalize [info script]]]
if {[llength $argv] != 1} {error {Expected one run directory}}
set runroot [file normalize [lindex $argv 0]]
set testbit [file join $root firmware servo_pan_tilt_link.bit]
set original {}
if {[info exists ::env(TINYYOLO_RESTORE_BIT)]} {
    set original [file normalize $::env(TINYYOLO_RESTORE_BIT)]
} else {
    set ancestor $root
    while {1} {
        foreach relative {firmware/final_192.bit board/TinyYOLO_192/firmware/final_192.bit TinyYOLO_192/firmware/final_192.bit} {
            set candidate [file join $ancestor $relative]
            if {[file isfile $candidate]} {set original $candidate; break}
        }
        if {$original ne {}} {break}
        set parent [file dirname $ancestor]
        if {$parent eq $ancestor} {error {Set TINYYOLO_RESTORE_BIT to the inference bitstream}}
        set ancestor $parent
    }
}
foreach path [list $testbit $original] {
    if {![file isfile $path] || [file size $path] < 1024} {error "Missing bitstream: $path"}
}
proc configured {device bitfile} {
    set_property PROGRAM.FILE $bitfile $device
    program_hw_devices $device
    refresh_hw_device $device
    set done [get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $device]
    set crc [get_property REGISTER.CONFIG_STATUS.BIT00_CRC_ERROR $device]
    puts "PAN_TILT_LINK_CONFIG file=$bitfile done=$done crc=$crc"
    if {$done ne {1} || $crc ne {0}} {error {FPGA configuration check failed}}
}
proc mark {name} {
    global runroot
    set stream [open [file join $runroot $name] w]
    puts $stream [clock seconds]
    close $stream
}
open_hw_manager
connect_hw_server -url localhost:3121
if {[llength [get_hw_targets]] != 1} {error {Expected one cable}}
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set devices [get_hw_devices -filter {PART == xc7z020}]
if {[llength $devices] != 1} {error {Expected one xc7z020}}
set device [lindex $devices 0]
current_hw_device $device
set failed [catch {
    mark programming_started.flag
    configured $device $testbit
    mark test_programmed.flag
    set deadline [expr {[clock seconds] + 2100}]
    while {![file exists [file join $runroot restore_requested.flag]]} {
        if {[clock seconds] >= $deadline} {error {Serial controller timeout; restoring original}}
        after 50
    }
} failure]
configured $device $original
mark inference_restored.flag
puts {PAN_TILT_LINK_ORIGINAL_RESTORED}
close_hw_target
disconnect_hw_server
close_hw_manager
if {$failed} {error $failure}
exit
