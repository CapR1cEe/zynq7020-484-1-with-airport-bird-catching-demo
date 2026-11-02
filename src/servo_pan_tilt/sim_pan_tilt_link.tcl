set root [file dirname [file normalize [info script]]]
file mkdir [file join $root sim_pan_tilt_link]
create_project -force Pan_Tilt_Link_Simulation [file join $root sim_pan_tilt_link project] -part xc7z020clg484-1
set_property target_language Verilog [current_project]
add_files -fileset sim_1 -norecurse [list [file join $root servo_pan_tilt_link.v] [file join $root tb_pan_tilt_link.sv]]
set_property top tb_pan_tilt_link [get_filesets sim_1]
set_property top_auto_set 0 [get_filesets sim_1]
launch_simulation -mode behavioral
run all
close_sim
close_project
exit
