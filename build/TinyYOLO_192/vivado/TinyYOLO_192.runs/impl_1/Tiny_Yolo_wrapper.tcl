namespace eval ::optrace {
  variable script "__PROJECT_ROOT__/vivado/TinyYOLO_192.runs/impl_1/Tiny_Yolo_wrapper.tcl"
  variable category "vivado_impl"
}

# Try to connect to running dispatch if we haven't done so already.
# This code assumes that the Tcl interpreter is not using threads,
# since the ::dispatch::connected variable isn't mutex protected.
if {![info exists ::dispatch::connected]} {
  namespace eval ::dispatch {
    variable connected false
    if {[llength [array get env XILINX_CD_CONNECT_ID]] > 0} {
      set result "true"
      if {[catch {
        if {[lsearch -exact [package names] DispatchTcl] < 0} {
          set result [load librdi_cd_clienttcl[info sharedlibextension]] 
        }
        if {$result eq "false"} {
          puts "WARNING: Could not load dispatch client library"
        }
        set connect_id [ ::dispatch::init_client -mode EXISTING_SERVER ]
        if { $connect_id eq "" } {
          puts "WARNING: Could not initialize dispatch client"
        } else {
          puts "INFO: Dispatch client connection id - $connect_id"
          set connected true
        }
      } catch_res]} {
        puts "WARNING: failed to connect to dispatch server - $catch_res"
      }
    }
  }
}
if {$::dispatch::connected} {
  # Remove the dummy proc if it exists.
  if { [expr {[llength [info procs ::OPTRACE]] > 0}] } {
    rename ::OPTRACE ""
  }
  proc ::OPTRACE { task action {tags {} } } {
    ::vitis_log::op_trace "$task" $action -tags $tags -script $::optrace::script -category $::optrace::category
  }
  # dispatch is generic. We specifically want to attach logging.
  ::vitis_log::connect_client
} else {
  # Add dummy proc if it doesn't exist.
  if { [expr {[llength [info procs ::OPTRACE]] == 0}] } {
    proc ::OPTRACE {{arg1 \"\" } {arg2 \"\"} {arg3 \"\" } {arg4 \"\"} {arg5 \"\" } {arg6 \"\"}} {
        # Do nothing
    }
  }
}

proc start_step { step } {
  set stopFile ".stop.rst"
  if {[file isfile .stop.rst]} {
    puts ""
    puts "*** Halting run - EA reset detected ***"
    puts ""
    puts ""
    return -code error
  }
  set beginFile ".$step.begin.rst"
  set platform "$::tcl_platform(platform)"
  set user "$::tcl_platform(user)"
  set pid [pid]
  set host ""
  if { [string equal $platform unix] } {
    if { [info exist ::env(HOSTNAME)] } {
      set host $::env(HOSTNAME)
    } elseif { [info exist ::env(HOST)] } {
      set host $::env(HOST)
    }
  } else {
    if { [info exist ::env(COMPUTERNAME)] } {
      set host $::env(COMPUTERNAME)
    }
  }
  set ch [open $beginFile w]
  puts $ch "<?xml version=\"1.0\"?>"
  puts $ch "<ProcessHandle Version=\"1\" Minor=\"0\">"
  puts $ch "    <Process Command=\".planAhead.\" Owner=\"$user\" Host=\"$host\" Pid=\"$pid\">"
  puts $ch "    </Process>"
  puts $ch "</ProcessHandle>"
  close $ch
}

proc end_step { step } {
  set endFile ".$step.end.rst"
  set ch [open $endFile w]
  close $ch
}

proc step_failed { step } {
  set endFile ".$step.error.rst"
  set ch [open $endFile w]
  close $ch
OPTRACE "impl_1" END { }
}

set_msg_config  -id {BD 41-1306}  -string {{The connection to interface pin </processing_system7_0/S_AXI_HP0_RDISSUECAP1_EN> is being overridden by the user with net <reset_zero_dout>. This pin will not be connected as a part of interface connection <S_AXI_HP0_FIFO_CTRL>, and might not recreate the connectivity as expected using the writ_bd_tcl command.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'S_AXI_HP0_RCOUNT' of module 'Tiny_Yolo_processing_system7_0_0' is unconnected for instance 'processing_system7_0'}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port m_sc_aclken in module sc_node_v1_0_19_top__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port aclk in module sc_util_v1_0_4_pipeline__parameterized7 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port aclken in module sc_util_v1_0_4_pipeline__parameterized7 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port areset in module sc_util_v1_0_4_pipeline__parameterized7 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port aclk in module sc_util_v1_0_4_pipeline__parameterized6 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port aclken in module sc_util_v1_0_4_pipeline__parameterized6 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port areset in module sc_util_v1_0_4_pipeline__parameterized6 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port aclk in module sc_node_v1_0_19_si_handler__parameterized2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port aclken in module sc_node_v1_0_19_si_handler__parameterized2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port areset in module sc_node_v1_0_19_si_handler__parameterized2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'S_AXI_HP0_WCOUNT' of module 'Tiny_Yolo_processing_system7_0_0' is unconnected for instance 'processing_system7_0'}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_sc_req[0] in module sc_node_v1_0_19_si_handler__parameterized2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_sc_info[0] in module sc_node_v1_0_19_si_handler__parameterized2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tvalid in module sc_node_v1_0_19_si_handler__parameterized2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[15] in module sc_node_v1_0_19_si_handler__parameterized2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[14] in module sc_node_v1_0_19_si_handler__parameterized2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[13] in module sc_node_v1_0_19_si_handler__parameterized2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[12] in module sc_node_v1_0_19_si_handler__parameterized2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[11] in module sc_node_v1_0_19_si_handler__parameterized2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[10] in module sc_node_v1_0_19_si_handler__parameterized2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[9] in module sc_node_v1_0_19_si_handler__parameterized2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'S_AXI_HP0_RACOUNT' of module 'Tiny_Yolo_processing_system7_0_0' is unconnected for instance 'processing_system7_0'}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[8] in module sc_node_v1_0_19_si_handler__parameterized2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[7] in module sc_node_v1_0_19_si_handler__parameterized2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[6] in module sc_node_v1_0_19_si_handler__parameterized2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[5] in module sc_node_v1_0_19_si_handler__parameterized2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[4] in module sc_node_v1_0_19_si_handler__parameterized2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[3] in module sc_node_v1_0_19_si_handler__parameterized2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[2] in module sc_node_v1_0_19_si_handler__parameterized2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[1] in module sc_node_v1_0_19_si_handler__parameterized2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[0] in module sc_node_v1_0_19_si_handler__parameterized2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port m_axis_arb_tready in module sc_node_v1_0_19_si_handler__parameterized2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'S_AXI_HP0_WACOUNT' of module 'Tiny_Yolo_processing_system7_0_0' is unconnected for instance 'processing_system7_0'}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port m_sc_aclken in module sc_node_v1_0_19_top__parameterized2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port aclk in module sc_util_v1_0_4_pipeline__parameterized5 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port aclken in module sc_util_v1_0_4_pipeline__parameterized5 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port areset in module sc_util_v1_0_4_pipeline__parameterized5 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port aclk in module sc_util_v1_0_4_pipeline__parameterized4 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port aclken in module sc_util_v1_0_4_pipeline__parameterized4 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port areset in module sc_util_v1_0_4_pipeline__parameterized4 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port aclk in module sc_node_v1_0_19_si_handler__parameterized1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port aclken in module sc_node_v1_0_19_si_handler__parameterized1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port areset in module sc_node_v1_0_19_si_handler__parameterized1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7023}  -string {{instance 'processing_system7_0' of module 'Tiny_Yolo_processing_system7_0_0' has 112 connections declared, but only 106 given}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_sc_req[0] in module sc_node_v1_0_19_si_handler__parameterized1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_sc_info[0] in module sc_node_v1_0_19_si_handler__parameterized1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tvalid in module sc_node_v1_0_19_si_handler__parameterized1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[15] in module sc_node_v1_0_19_si_handler__parameterized1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[14] in module sc_node_v1_0_19_si_handler__parameterized1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[13] in module sc_node_v1_0_19_si_handler__parameterized1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[12] in module sc_node_v1_0_19_si_handler__parameterized1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[11] in module sc_node_v1_0_19_si_handler__parameterized1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[10] in module sc_node_v1_0_19_si_handler__parameterized1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[9] in module sc_node_v1_0_19_si_handler__parameterized1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'mb_reset' of module 'Tiny_Yolo_ps_ctrl_reset_0' is unconnected for instance 'ps_ctrl_reset'}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[8] in module sc_node_v1_0_19_si_handler__parameterized1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[7] in module sc_node_v1_0_19_si_handler__parameterized1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[6] in module sc_node_v1_0_19_si_handler__parameterized1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[5] in module sc_node_v1_0_19_si_handler__parameterized1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[4] in module sc_node_v1_0_19_si_handler__parameterized1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[3] in module sc_node_v1_0_19_si_handler__parameterized1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[2] in module sc_node_v1_0_19_si_handler__parameterized1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[1] in module sc_node_v1_0_19_si_handler__parameterized1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[0] in module sc_node_v1_0_19_si_handler__parameterized1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port m_axis_arb_tready in module sc_node_v1_0_19_si_handler__parameterized1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'bus_struct_reset' of module 'Tiny_Yolo_ps_ctrl_reset_0' is unconnected for instance 'ps_ctrl_reset'}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-6014}  -string {{Unused sequential element local_data_q0 was removed.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-6014}  -string {{Unused sequential element local_tag_q0_rep was removed.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-3332}  -string {{Sequential element (FDRE_inst) is unused and will be removed from module proc_sys_reset.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-3332}  -string {{Sequential element (BSR_OUT_DFF[0].FDRE_BSR) is unused and will be removed from module proc_sys_reset.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-3332}  -string {{Sequential element (ACTIVE_LOW_BSR_OUT_DFF[0].FDRE_BSR_N) is unused and will be removed from module proc_sys_reset.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-3332}  -string {{Sequential element (PR_OUT_DFF[0].FDRE_PER) is unused and will be removed from module proc_sys_reset.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-3332}  -string {{Sequential element (FDRE_inst) is unused and will be removed from module proc_sys_reset__1.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-3332}  -string {{Sequential element (BSR_OUT_DFF[0].FDRE_BSR) is unused and will be removed from module proc_sys_reset__1.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-3332}  -string {{Sequential element (PR_OUT_DFF[0].FDRE_PER) is unused and will be removed from module proc_sys_reset__1.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-3332}  -string {{Sequential element (ACTIVE_LOW_PR_OUT_DFF[0].FDRE_PER_N) is unused and will be removed from module proc_sys_reset__1.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'peripheral_reset' of module 'Tiny_Yolo_ps_ctrl_reset_0' is unconnected for instance 'ps_ctrl_reset'}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-3332}  -string {{Sequential element (clk_map/psr0/U0/FDRE_inst) is unused and will be removed from module bd_6194.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-3332}  -string {{Sequential element (clk_map/psr0/U0/BSR_OUT_DFF[0].FDRE_BSR) is unused and will be removed from module bd_6194.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-3332}  -string {{Sequential element (clk_map/psr0/U0/PR_OUT_DFF[0].FDRE_PER) is unused and will be removed from module bd_6194.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-3332}  -string {{Sequential element (clk_map/psr0/U0/ACTIVE_LOW_PR_OUT_DFF[0].FDRE_PER_N) is unused and will be removed from module bd_6194.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-3332}  -string {{Sequential element (clk_map/psr_aclk/U0/FDRE_inst) is unused and will be removed from module bd_6194.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-3332}  -string {{Sequential element (clk_map/psr_aclk/U0/BSR_OUT_DFF[0].FDRE_BSR) is unused and will be removed from module bd_6194.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-3332}  -string {{Sequential element (clk_map/psr_aclk/U0/PR_OUT_DFF[0].FDRE_PER) is unused and will be removed from module bd_6194.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-3332}  -string {{Sequential element (clk_map/psr_aclk/U0/ACTIVE_LOW_PR_OUT_DFF[0].FDRE_PER_N) is unused and will be removed from module bd_6194.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-3332}  -string {{Sequential element (clk_map/psr_aclk1/U0/FDRE_inst) is unused and will be removed from module bd_6194.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-3332}  -string {{Sequential element (clk_map/psr_aclk1/U0/BSR_OUT_DFF[0].FDRE_BSR) is unused and will be removed from module bd_6194.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'peripheral_aresetn' of module 'Tiny_Yolo_ps_ctrl_reset_0' is unconnected for instance 'ps_ctrl_reset'}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-3332}  -string {{Sequential element (clk_map/psr_aclk1/U0/PR_OUT_DFF[0].FDRE_PER) is unused and will be removed from module bd_6194.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-3332}  -string {{Sequential element (clk_map/psr_aclk1/U0/ACTIVE_LOW_PR_OUT_DFF[0].FDRE_PER_N) is unused and will be removed from module bd_6194.}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:emb-plus-vpr-4616:part0:1.0 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\emb-plus-vpr-4616\1.0\board.xml as part xcve2302-sfva784-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:emb-plus-vpr-4616:part0:1.1 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\emb-plus-vpr-4616\1.1\board.xml as part xcve2302-sfva784-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:kcu105:part0:1.6 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\kcu105\1.6\board.xml as part xcku040-ffva1156-2-e specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:kcu105:part0:1.7 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\kcu105\1.7\board.xml as part xcku040-ffva1156-2-e specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:kcu116:part0:1.4 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\kcu116\1.4\board.xml as part xcku5p-ffvb676-2-e specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:kcu116:part0:1.5 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\kcu116\1.5\board.xml as part xcku5p-ffvb676-2-e specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:kcu1500:part0:1.2 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\kcu1500\1.2\board.xml as part xcku115-flvb2104-2-e specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:scu35:part0:1.0 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\scu35\1.0\board.xml as part xcsu35p-sbvb625-2-e specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7023}  -string {{instance 'ps_ctrl_reset' of module 'Tiny_Yolo_ps_ctrl_reset_0' has 10 connections declared, but only 6 given}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:v80:part0:1.0 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\v80\1.0\board.xml as part xcv80-lsva4737-2mhp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vck190:part0:2.2 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vck190\production\2.2\board.xml as part xcvc1902-vsva2197-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vck190:part0:3.0 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vck190\production\3.0\board.xml as part xcvc1902-vsva2197-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vck190:part0:3.1 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vck190\production\3.1\board.xml as part xcvc1902-vsva2197-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vck190:part0:3.2 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vck190\production\3.2\board.xml as part xcvc1902-vsva2197-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vck190:part0:3.3 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vck190\production\3.3\board.xml as part xcvc1902-vsva2197-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vck190:part0:3.4 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vck190\production\3.4\board.xml as part xcvc1902-vsva2197-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vck190_newl:part0:1.0 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vck190_newl\production\1.0\board.xml as part xcvc1902-vsva2197-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vck190_newl:part0:1.1 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vck190_newl\production\1.1\board.xml as part xcvc1902-vsva2197-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vck190_newl:part0:1.2 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vck190_newl\production\1.2\board.xml as part xcvc1902-vsva2197-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {BD 41-1306}  -string {{The connection to interface pin </processing_system7_0/S_AXI_HP0_WRISSUECAP1_EN> is being overridden by the user with net <reset_zero_dout>. This pin will not be connected as a part of interface connection <S_AXI_HP0_FIFO_CTRL>, and might not recreate the connectivity as expected using the writ_bd_tcl command.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'mb_reset' of module 'bd_6194_psr0_0' is unconnected for instance 'psr0'}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vck190_newl:part0:1.3 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vck190_newl\production\1.3\board.xml as part xcvc1902-vsva2197-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vcu108:part0:1.6 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vcu108\1.6\board.xml as part xcvu095-ffva2104-2-e specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vcu108:part0:1.7 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vcu108\1.7\board.xml as part xcvu095-ffva2104-2-e specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vcu110:part0:1.4 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vcu110\1.4\board.xml as part xcvu190-flgc2104-2-e specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vcu118:part0:2.0 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vcu118\2.0\board.xml as part xcvu9p-flga2104-2l-e specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vcu118:part0:2.3 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vcu118\2.3\board.xml as part xcvu9p-flga2104-2l-e specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vcu118:part0:2.4 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vcu118\2.4\board.xml as part xcvu9p-flga2104-2l-e specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vcu128:part0:1.0 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vcu128\production\1.0\board.xml as part xcvu37p-fsvh2892-2l-e specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vcu129:part0:1.0 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vcu129\production\1.0\board.xml as part xcvu29p-fsga2577-2l-e specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vcu1525:part0:1.3 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vcu1525\1.3\board.xml as part xcvu9p-fsgd2104-2l-e specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'bus_struct_reset' of module 'bd_6194_psr0_0' is unconnected for instance 'psr0'}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vek280:part0:1.0 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vek280\production\1.0\board.xml as part xcve2802-vsvh1760-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vek280:part0:1.1 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vek280\production\1.1\board.xml as part xcve2802-vsvh1760-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vek280:part0:1.2 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vek280\production\1.2\board.xml as part xcve2802-vsvh1760-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vek385:part0:1.0 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vek385\1.0\board.xml as part xc2ve3858-ssva2112-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vek385:part0:1.1 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vek385\1.1\board.xml as part xc2ve3858-ssva2112-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vek385_1:part0:1.0 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vek385_2\1.0\board.xml as part xc2ve3858-ssva2112-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vhk158:part0:1.0 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vhk158\production\1.0\board.xml as part xcvh1582-vsva3697-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vhk158:part0:1.1 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vhk158\production\1.1\board.xml as part xcvh1582-vsva3697-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vhk158:part0:1.2 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vhk158\production\1.2\board.xml as part xcvh1582-vsva3697-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vmk180:part0:2.2 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vmk180\production\2.2\board.xml as part xcvm1802-vsva2197-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'peripheral_reset' of module 'bd_6194_psr0_0' is unconnected for instance 'psr0'}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vmk180:part0:3.0 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vmk180\production\3.0\board.xml as part xcvm1802-vsva2197-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vmk180:part0:3.1 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vmk180\production\3.1\board.xml as part xcvm1802-vsva2197-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vmk180:part0:3.2 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vmk180\production\3.2\board.xml as part xcvm1802-vsva2197-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vmk180:part0:3.3 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vmk180\production\3.3\board.xml as part xcvm1802-vsva2197-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vmk180_newl:part0:1.0 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vmk180_newl\production\1.0\board.xml as part xcvm1802-vsva2197-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vmk180_newl:part0:1.1 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vmk180_newl\production\1.1\board.xml as part xcvm1802-vsva2197-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vpk120:part0:1.0 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vpk120\production\1.0\board.xml as part xcvp1202-vsva2785-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vpk120:part0:1.1 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vpk120\production\1.1\board.xml as part xcvp1202-vsva2785-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vpk120:part0:1.2 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vpk120\production\1.2\board.xml as part xcvp1202-vsva2785-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vpk180:part0:1.0 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vpk180\production\1.0\board.xml as part xcvp1802-lsvc4072-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'peripheral_aresetn' of module 'bd_6194_psr0_0' is unconnected for instance 'psr0'}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vpk180:part0:1.1 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vpk180\production\1.1\board.xml as part xcvp1802-lsvc4072-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vpk180:part0:1.2 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vpk180\production\1.2\board.xml as part xcvp1802-lsvc4072-2mp-e-s specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vrk160:part0:1.0 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vrk160\1.0\board.xml as part xcvr1602-vsva2488-2mp-e-s-es1 specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:vrk160:part0:1.1 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\vrk160\1.1\board.xml as part xcvr1602-vsva2488-2mp-e-s-es1 specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:zcu208ld:part0:2.0 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\zcu208ld\production\2.0\board.xml as part xczu58dr-fsvg1517-2-i specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:zcu216ld:part0:2.0 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\zcu216ld\production\2.0\board.xml as part xczu59dr-ffvf1760-2-i specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Board 49-26}  -string {{cannot add Board Part xilinx.com:zcu670ld:part0:1.0 available at C:/AMDDesigntools/2025.2/data/xhub/boards\XilinxBoardStore\boards\Xilinx\zcu670ld\1.0\board.xml as part xczu57dr-fsve1156-2-i specified in board_part file is either invalid or not available}}  -new_severity {INFO} 
set_msg_config  -id {Project 1-5713}  -string {{Board part '' set for the project  is not found. BoardPart property will be unset. Please select board from latest repo build}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_sc_info[0] in module sc_node_v1_0_19_top__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_sc_payld[0] in module sc_node_v1_0_19_top__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7023}  -string {{instance 'psr0' of module 'bd_6194_psr0_0' has 10 connections declared, but only 6 given}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_sc_req[0] in module sc_node_v1_0_19_top__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port src_clk in module xpm_cdc_single__parameterized1__1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port src_clk in module xpm_cdc_single__parameterized1__2 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'mb_reset' of module 'bd_6194_psr_aclk_0' is unconnected for instance 'psr_aclk'}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'bus_struct_reset' of module 'bd_6194_psr_aclk_0' is unconnected for instance 'psr_aclk'}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'peripheral_reset' of module 'bd_6194_psr_aclk_0' is unconnected for instance 'psr_aclk'}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'peripheral_aresetn' of module 'bd_6194_psr_aclk_0' is unconnected for instance 'psr_aclk'}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7023}  -string {{instance 'psr_aclk' of module 'bd_6194_psr_aclk_0' has 10 connections declared, but only 6 given}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'mb_reset' of module 'Tiny_Yolo_proc_sys_reset_0_0' is unconnected for instance 'proc_sys_reset_0'}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'mb_reset' of module 'bd_6194_psr_aclk1_0' is unconnected for instance 'psr_aclk1'}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'bus_struct_reset' of module 'bd_6194_psr_aclk1_0' is unconnected for instance 'psr_aclk1'}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'peripheral_reset' of module 'bd_6194_psr_aclk1_0' is unconnected for instance 'psr_aclk1'}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'peripheral_aresetn' of module 'bd_6194_psr_aclk1_0' is unconnected for instance 'psr_aclk1'}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7023}  -string {{instance 'psr_aclk1' of module 'bd_6194_psr_aclk1_0' has 10 connections declared, but only 6 given}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'M00_AXI_awprot' of module 'Tiny_Yolo_smartconnect_0_0' is unconnected for instance 'smartconnect_0'}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'M00_AXI_arprot' of module 'Tiny_Yolo_smartconnect_0_0' is unconnected for instance 'smartconnect_0'}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7023}  -string {{instance 'smartconnect_0' of module 'Tiny_Yolo_smartconnect_0_0' has 60 connections declared, but only 58 given}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-3848}  -string {{Net aresetn_out in module/entity clk_map_imp_1VTE75B does not have driver.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-6014}  -string {{Unused sequential element dest_req_ext_ff_reg was removed.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'bus_struct_reset' of module 'Tiny_Yolo_proc_sys_reset_0_0' is unconnected for instance 'proc_sys_reset_0'}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-6014}  -string {{Unused sequential element parallel_requant[1].tag_q_reg was removed.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-6014}  -string {{Unused sequential element local_store_data_reg was removed.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-6014}  -string {{Unused sequential element parallel_lane[1].read_address_reg was removed.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-6014}  -string {{Unused sequential element parallel_lane[2].read_address_reg was removed.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-6014}  -string {{Unused sequential element parallel_lane[3].read_address_reg was removed.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-6014}  -string {{Unused sequential element parallel_lane[4].read_address_reg was removed.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-6014}  -string {{Unused sequential element parallel_lane[5].read_address_reg was removed.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-6014}  -string {{Unused sequential element parallel_lane[6].read_address_reg was removed.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-6014}  -string {{Unused sequential element parallel_lane[7].read_address_reg was removed.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-6014}  -string {{Unused sequential element parallel_lane[8].read_address_reg was removed.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'peripheral_reset' of module 'Tiny_Yolo_proc_sys_reset_0_0' is unconnected for instance 'proc_sys_reset_0'}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-6014}  -string {{Unused sequential element parallel_lane[9].read_address_reg was removed.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-6014}  -string {{Unused sequential element parallel_lane[10].read_address_reg was removed.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-6014}  -string {{Unused sequential element parallel_lane[11].read_address_reg was removed.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-6014}  -string {{Unused sequential element parallel_lane[12].read_address_reg was removed.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-6014}  -string {{Unused sequential element parallel_lane[13].read_address_reg was removed.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-6014}  -string {{Unused sequential element parallel_lane[14].read_address_reg was removed.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-6014}  -string {{Unused sequential element parallel_lane[15].read_address_reg was removed.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-6014}  -string {{Unused sequential element parallel_requant[1].tag_pipe_reg was removed.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-6014}  -string {{Unused sequential element fill_write_data_reg was removed.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-6014}  -string {{Unused sequential element read_response_data_reg was removed.}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'interconnect_aresetn' of module 'Tiny_Yolo_proc_sys_reset_0_0' is unconnected for instance 'proc_sys_reset_0'}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port din[0] in module sc_util_v1_0_4_onehot_to_binary is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port aclk in module sc_util_v1_0_4_pipeline__parameterized0 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port aclken in module sc_util_v1_0_4_pipeline__parameterized0 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port areset in module sc_util_v1_0_4_pipeline__parameterized0 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port aclk in module sc_util_v1_0_4_pipeline__parameterized9 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port aclken in module sc_util_v1_0_4_pipeline__parameterized9 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port areset in module sc_util_v1_0_4_pipeline__parameterized9 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port src_clk in module xpm_cdc_single__parameterized1 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port aclk in module sc_node_v1_0_19_reg_slice3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port aclken in module sc_node_v1_0_19_reg_slice3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7023}  -string {{instance 'proc_sys_reset_0' of module 'Tiny_Yolo_proc_sys_reset_0_0' has 10 connections declared, but only 6 given}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port areset in module sc_node_v1_0_19_reg_slice3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port aclk in module sc_util_v1_0_4_pipeline__parameterized8 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port aclken in module sc_util_v1_0_4_pipeline__parameterized8 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port areset in module sc_util_v1_0_4_pipeline__parameterized8 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port aclk in module sc_node_v1_0_19_si_handler__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port aclken in module sc_node_v1_0_19_si_handler__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port areset in module sc_node_v1_0_19_si_handler__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_sc_req[0] in module sc_node_v1_0_19_si_handler__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_sc_info[0] in module sc_node_v1_0_19_si_handler__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tvalid in module sc_node_v1_0_19_si_handler__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'USB0_PORT_INDCTL' of module 'Tiny_Yolo_processing_system7_0_0' is unconnected for instance 'processing_system7_0'}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[15] in module sc_node_v1_0_19_si_handler__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[14] in module sc_node_v1_0_19_si_handler__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[13] in module sc_node_v1_0_19_si_handler__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[12] in module sc_node_v1_0_19_si_handler__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[11] in module sc_node_v1_0_19_si_handler__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[10] in module sc_node_v1_0_19_si_handler__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[9] in module sc_node_v1_0_19_si_handler__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[8] in module sc_node_v1_0_19_si_handler__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[7] in module sc_node_v1_0_19_si_handler__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[6] in module sc_node_v1_0_19_si_handler__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7071}  -string {{port 'USB0_VBUS_PWRSELECT' of module 'Tiny_Yolo_processing_system7_0_0' is unconnected for instance 'processing_system7_0'}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[5] in module sc_node_v1_0_19_si_handler__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[4] in module sc_node_v1_0_19_si_handler__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[3] in module sc_node_v1_0_19_si_handler__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[2] in module sc_node_v1_0_19_si_handler__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[1] in module sc_node_v1_0_19_si_handler__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port s_axis_arb_tdata[0] in module sc_node_v1_0_19_si_handler__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port m_axis_arb_tready in module sc_node_v1_0_19_si_handler__parameterized3 is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port aclk in module sc_util_v1_0_4_axic_register_slice is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port areset in module sc_util_v1_0_4_axic_register_slice is either unconnected or has no load}}  -new_severity {INFO} 
set_msg_config  -id {Synth 8-7129}  -string {{Port aclken in module sc_util_v1_0_4_axic_register_slice is either unconnected or has no load}}  -new_severity {INFO} 

OPTRACE "impl_1" START { ROLLUP_1 }
OPTRACE "Phase: Init Design" START { ROLLUP_AUTO }
start_step init_design
set ACTIVE_STEP init_design
set rc [catch {
  create_msg_db init_design.pb
  set_param general.maxThreads 8
  set_param general.usePosixSpawnForFork 1
  set_param chipscope.maxJobs 1
  set_param runs.launchOptions { -jobs 1  }
OPTRACE "create in-memory project" START { }
  create_project -in_memory -part xc7z020clg484-1
  set_property design_mode GateLvl [current_fileset]
  set_param project.singleFileAddWarning.threshold 0
OPTRACE "create in-memory project" END { }
OPTRACE "set parameters" START { }
  set_property webtalk.parent_dir __PROJECT_ROOT__/vivado/TinyYOLO_192.cache/wt [current_project]
  set_property parent.project_path __PROJECT_ROOT__/vivado/TinyYOLO_192.xpr [current_project]
  set_property ip_output_repo __PROJECT_ROOT__/vivado/TinyYOLO_192.cache/ip [current_project]
  set_property ip_cache_permissions {read write} [current_project]
  set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
OPTRACE "set parameters" END { }
OPTRACE "add files" START { }
  add_files -quiet __PROJECT_ROOT__/vivado/TinyYOLO_192.runs/synth_1/Tiny_Yolo_wrapper.dcp
  set_msg_config -source 4 -id {BD 41-1661} -limit 0
  set_param project.isImplRun true
  add_files __PROJECT_ROOT__/vivado/TinyYOLO_192.srcs/sources_1/bd/Tiny_Yolo/Tiny_Yolo.bd
  set_param project.isImplRun false
OPTRACE "read constraints: implementation" START { }
  read_xdc __PROJECT_ROOT__/hardware/g227/board_uart.xdc
  read_xdc __PROJECT_ROOT__/hardware/g227/critical_bram_power.xdc
  set_property processing_order LATE [get_files __PROJECT_ROOT__/hardware/g227/critical_bram_power.xdc]
  read_xdc __PROJECT_ROOT__/hardware/g227/reset_power_activity.xdc
  set_property processing_order LATE [get_files __PROJECT_ROOT__/hardware/g227/reset_power_activity.xdc]
OPTRACE "read constraints: implementation" END { }
OPTRACE "read constraints: implementation_pre" START { }
OPTRACE "read constraints: implementation_pre" END { }
OPTRACE "add files" END { }
OPTRACE "link_design" START { }
  set_param project.isImplRun true
  link_design -top Tiny_Yolo_wrapper -part xc7z020clg484-1 
OPTRACE "link_design" END { }
  set_param project.isImplRun false
OPTRACE "gray box cells" START { }
OPTRACE "gray box cells" END { }
OPTRACE "init_design_reports" START { REPORT }
OPTRACE "init_design_reports" END { }
OPTRACE "init_design_write_hwdef" START { }
OPTRACE "init_design_write_hwdef" END { }
  close_msg_db -file init_design.pb
} RESULT]
if {$rc} {
  step_failed init_design
  return -code error $RESULT
} else {
  end_step init_design
  unset ACTIVE_STEP 
}

OPTRACE "Phase: Init Design" END { }
OPTRACE "Phase: Opt Design" START { ROLLUP_AUTO }
start_step opt_design
set ACTIVE_STEP opt_design
set rc [catch {
  create_msg_db opt_design.pb
OPTRACE "Opt Design: pre hook" START { }
  set src_rc [catch { 
    puts "source __PROJECT_ROOT__/scripts/implementation_pre_opt.tcl"
    source __PROJECT_ROOT__/scripts/implementation_pre_opt.tcl
  } _RESULT] 
  if {$src_rc} { 
    set tool_flow [get_property -quiet TOOL_FLOW [current_project -quiet]]
    if { $tool_flow eq {SDx} } { 
      send_gid_msg -id 2 -ssname VPL_TCL -severity ERROR $_RESULT
      send_gid_msg -id 3 -ssname VPL_TCL -severity ERROR "sourcing script __PROJECT_ROOT__/scripts/implementation_pre_opt.tcl failed"
    } else {
      send_msg_id runtcl-1 status "$_RESULT"
      send_msg_id runtcl-2 status "sourcing script __PROJECT_ROOT__/scripts/implementation_pre_opt.tcl failed"
    }
    return -code error
  }
OPTRACE "Opt Design: pre hook" END { }
OPTRACE "read constraints: opt_design" START { }
OPTRACE "read constraints: opt_design" END { }
OPTRACE "opt_design" START { }
  opt_design 
OPTRACE "opt_design" END { }
OPTRACE "read constraints: opt_design_post" START { }
OPTRACE "read constraints: opt_design_post" END { }
OPTRACE "opt_design reports" START { REPORT }
  set_param project.isImplRun true
  generate_parallel_reports -reports { "report_drc -file Tiny_Yolo_wrapper_drc_opted.rpt -pb Tiny_Yolo_wrapper_drc_opted.pb -rpx Tiny_Yolo_wrapper_drc_opted.rpx"  }
  set_param project.isImplRun false
OPTRACE "opt_design reports" END { }
OPTRACE "Opt Design: write_checkpoint" START { CHECKPOINT }
  write_checkpoint -force Tiny_Yolo_wrapper_opt.dcp
OPTRACE "Opt Design: write_checkpoint" END { }
  close_msg_db -file opt_design.pb
} RESULT]
if {$rc} {
  step_failed opt_design
  return -code error $RESULT
} else {
  end_step opt_design
  unset ACTIVE_STEP 
}

OPTRACE "Phase: Opt Design" END { }
OPTRACE "Phase: Place Design" START { ROLLUP_AUTO }
start_step place_design
set ACTIVE_STEP place_design
set rc [catch {
  create_msg_db place_design.pb
OPTRACE "read constraints: place_design" START { }
OPTRACE "read constraints: place_design" END { }
  if { [llength [get_debug_cores -quiet] ] > 0 }  { 
OPTRACE "implement_debug_core" START { }
    implement_debug_core 
OPTRACE "implement_debug_core" END { }
  } 
OPTRACE "place_design" START { }
  set_param project.isImplRun true
  place_design -directive Explore
  set_param project.isImplRun false
OPTRACE "place_design" END { }
OPTRACE "read constraints: place_design_post" START { }
OPTRACE "read constraints: place_design_post" END { }
OPTRACE "place_design reports" START { REPORT }
  set_param project.isImplRun true
  generate_parallel_reports -reports { "report_io -file Tiny_Yolo_wrapper_io_placed.rpt" "report_utilization -file Tiny_Yolo_wrapper_utilization_placed.rpt -pb Tiny_Yolo_wrapper_utilization_placed.pb" "report_control_sets -verbose -file Tiny_Yolo_wrapper_control_sets_placed.rpt"  }
  set_param project.isImplRun false
OPTRACE "place_design reports" END { }
OPTRACE "Place Design: write_checkpoint" START { CHECKPOINT }
  write_checkpoint -force Tiny_Yolo_wrapper_placed.dcp
OPTRACE "Place Design: write_checkpoint" END { }
  close_msg_db -file place_design.pb
} RESULT]
if {$rc} {
  step_failed place_design
  return -code error $RESULT
} else {
  end_step place_design
  unset ACTIVE_STEP 
}

OPTRACE "Phase: Place Design" END { }
OPTRACE "Phase: Physical Opt Design" START { ROLLUP_AUTO }
start_step phys_opt_design
set ACTIVE_STEP phys_opt_design
set rc [catch {
  create_msg_db phys_opt_design.pb
OPTRACE "read constraints: phys_opt_design" START { }
OPTRACE "read constraints: phys_opt_design" END { }
OPTRACE "phys_opt_design" START { }
  phys_opt_design -directive AggressiveExplore
OPTRACE "phys_opt_design" END { }
OPTRACE "read constraints: phys_opt_design_post" START { }
OPTRACE "read constraints: phys_opt_design_post" END { }
OPTRACE "phys_opt_design report" START { REPORT }
OPTRACE "phys_opt_design report" END { }
OPTRACE "Post-Place Phys Opt Design: post hook" START { }
  set src_rc [catch { 
    puts "source __PROJECT_ROOT__/scripts/optimize_control_fanout.tcl"
    source __PROJECT_ROOT__/scripts/optimize_control_fanout.tcl
  } _RESULT] 
  if {$src_rc} { 
    set tool_flow [get_property -quiet TOOL_FLOW [current_project -quiet]]
    if { $tool_flow eq {SDx} } { 
      send_gid_msg -id 2 -ssname VPL_TCL -severity ERROR $_RESULT
      send_gid_msg -id 3 -ssname VPL_TCL -severity ERROR "sourcing script __PROJECT_ROOT__/scripts/optimize_control_fanout.tcl failed"
    } else {
      send_msg_id runtcl-1 status "$_RESULT"
      send_msg_id runtcl-2 status "sourcing script __PROJECT_ROOT__/scripts/optimize_control_fanout.tcl failed"
    }
    return -code error
  }
OPTRACE "Post-Place Phys Opt Design: post hook" END { }
OPTRACE "Post-Place Phys Opt Design: write_checkpoint" START { CHECKPOINT }
  write_checkpoint -force Tiny_Yolo_wrapper_physopt.dcp
OPTRACE "Post-Place Phys Opt Design: write_checkpoint" END { }
  close_msg_db -file phys_opt_design.pb
} RESULT]
if {$rc} {
  step_failed phys_opt_design
  return -code error $RESULT
} else {
  end_step phys_opt_design
  unset ACTIVE_STEP 
}

OPTRACE "Phase: Physical Opt Design" END { }
OPTRACE "Phase: Route Design" START { ROLLUP_AUTO }
  set_msg_config -source 4 -id {Route 35-39} -severity "critical warning" -new_severity warning
start_step route_design
set ACTIVE_STEP route_design
set rc [catch {
  create_msg_db route_design.pb
OPTRACE "read constraints: route_design" START { }
OPTRACE "read constraints: route_design" END { }
OPTRACE "route_design" START { }
  route_design -directive AggressiveExplore -tns_cleanup
OPTRACE "route_design" END { }
OPTRACE "read constraints: route_design_post" START { }
OPTRACE "read constraints: route_design_post" END { }
OPTRACE "route_design reports" START { REPORT }
  set_param project.isImplRun true
  generate_parallel_reports -reports { "report_drc -file Tiny_Yolo_wrapper_drc_routed.rpt -pb Tiny_Yolo_wrapper_drc_routed.pb -rpx Tiny_Yolo_wrapper_drc_routed.rpx" "report_methodology -file Tiny_Yolo_wrapper_methodology_drc_routed.rpt -pb Tiny_Yolo_wrapper_methodology_drc_routed.pb -rpx Tiny_Yolo_wrapper_methodology_drc_routed.rpx" "report_power -file Tiny_Yolo_wrapper_power_routed.rpt -pb Tiny_Yolo_wrapper_power_summary_routed.pb -rpx Tiny_Yolo_wrapper_power_routed.rpx" "report_route_status -file Tiny_Yolo_wrapper_route_status.rpt -pb Tiny_Yolo_wrapper_route_status.pb" "report_timing_summary -max_paths 10 -routable_nets -report_unconstrained -file Tiny_Yolo_wrapper_timing_summary_routed.rpt -pb Tiny_Yolo_wrapper_timing_summary_routed.pb -rpx Tiny_Yolo_wrapper_timing_summary_routed.rpx" "report_incremental_reuse -file Tiny_Yolo_wrapper_incremental_reuse_routed.rpt" "report_clock_utilization -file Tiny_Yolo_wrapper_clock_utilization_routed.rpt" "report_bus_skew -warn_on_violation -file Tiny_Yolo_wrapper_bus_skew_routed.rpt -pb Tiny_Yolo_wrapper_bus_skew_routed.pb -rpx Tiny_Yolo_wrapper_bus_skew_routed.rpx"  }
  set_param project.isImplRun false
OPTRACE "route_design reports" END { }
OPTRACE "Route Design: write_checkpoint" START { CHECKPOINT }
  write_checkpoint -force Tiny_Yolo_wrapper_routed.dcp
OPTRACE "Route Design: write_checkpoint" END { }
OPTRACE "route_design misc" START { }
  close_msg_db -file route_design.pb
} RESULT]
if {$rc} {
OPTRACE "route_design write_checkpoint" START { CHECKPOINT }
OPTRACE "route_design write_checkpoint" END { }
  write_checkpoint -force Tiny_Yolo_wrapper_routed_error.dcp
  step_failed route_design
  return -code error $RESULT
} else {
  end_step route_design
  unset ACTIVE_STEP 
}

OPTRACE "route_design misc" END { }
OPTRACE "Phase: Route Design" END { }
OPTRACE "Phase: Phys-Opt Design" START { ROLLUP_AUTO }
start_step post_route_phys_opt_design
set ACTIVE_STEP post_route_phys_opt_design
set rc [catch {
  set tool_flow [get_property -quiet TOOL_FLOW [current_project -quiet]]
  if {$tool_flow eq {SDx}} {send_msg_id {101-1} {status} {Starting optional post-route physical design optimization.} }
  create_msg_db post_route_phys_opt_design.pb
OPTRACE "phys_opt_design" START { }
  phys_opt_design -directive AggressiveExplore
OPTRACE "phys_opt_design" END { }
OPTRACE "phys_opt_design reports" START { REPORT }
  set_param project.isImplRun true
  generate_parallel_reports -reports { "report_timing_summary -max_paths 10 -report_unconstrained -warn_on_violation -file Tiny_Yolo_wrapper_timing_summary_postroute_physopted.rpt -pb Tiny_Yolo_wrapper_timing_summary_postroute_physopted.pb -rpx Tiny_Yolo_wrapper_timing_summary_postroute_physopted.rpx" "report_bus_skew -warn_on_violation -file Tiny_Yolo_wrapper_bus_skew_postroute_physopted.rpt -pb Tiny_Yolo_wrapper_bus_skew_postroute_physopted.pb -rpx Tiny_Yolo_wrapper_bus_skew_postroute_physopted.rpx"  }
  set_param project.isImplRun false
OPTRACE "phys_opt_design reports" END { }
OPTRACE "Post-Route Phys Opt Design: post hook" START { }
  set src_rc [catch { 
    puts "source __PROJECT_ROOT__/scripts/restore_implementation_budget.tcl"
    source __PROJECT_ROOT__/scripts/restore_implementation_budget.tcl
  } _RESULT] 
  if {$src_rc} { 
    set tool_flow [get_property -quiet TOOL_FLOW [current_project -quiet]]
    if { $tool_flow eq {SDx} } { 
      send_gid_msg -id 2 -ssname VPL_TCL -severity ERROR $_RESULT
      send_gid_msg -id 3 -ssname VPL_TCL -severity ERROR "sourcing script __PROJECT_ROOT__/scripts/restore_implementation_budget.tcl failed"
    } else {
      send_msg_id runtcl-1 status "$_RESULT"
      send_msg_id runtcl-2 status "sourcing script __PROJECT_ROOT__/scripts/restore_implementation_budget.tcl failed"
    }
    return -code error
  }
OPTRACE "Post-Route Phys Opt Design: post hook" END { }
OPTRACE "Post-Route Phys Opt Design: write_checkpoint" START { CHECKPOINT }
  write_checkpoint -force Tiny_Yolo_wrapper_postroute_physopt.dcp
OPTRACE "Post-Route Phys Opt Design: write_checkpoint" END { }
OPTRACE "phys_opt_design misc" START { }
  close_msg_db -file post_route_phys_opt_design.pb
  set tool_flow [get_property TOOL_FLOW [current_project]]
  if {$tool_flow eq {SDx}} {send_msg_id {101-1} {status} {Finished optional post-route physical design optimization.} }
} RESULT]
if {$rc} {
  step_failed post_route_phys_opt_design
  return -code error $RESULT
} else {
  end_step post_route_phys_opt_design
  unset ACTIVE_STEP 
}

OPTRACE "phys_opt_design misc" END { }
OPTRACE "Phase: Phys-Opt Design" END { }
OPTRACE "Phase: Write Bitstream" START { ROLLUP_AUTO }
OPTRACE "write_bitstream setup" START { }
start_step write_bitstream
set ACTIVE_STEP write_bitstream
set rc [catch {
  create_msg_db write_bitstream.pb
OPTRACE "Write Bitstream: pre hook" START { }
  set src_rc [catch { 
    puts "source __PROJECT_ROOT__/scripts/implementation_pre_bitstream.tcl"
    source __PROJECT_ROOT__/scripts/implementation_pre_bitstream.tcl
  } _RESULT] 
  if {$src_rc} { 
    set tool_flow [get_property -quiet TOOL_FLOW [current_project -quiet]]
    if { $tool_flow eq {SDx} } { 
      send_gid_msg -id 2 -ssname VPL_TCL -severity ERROR $_RESULT
      send_gid_msg -id 3 -ssname VPL_TCL -severity ERROR "sourcing script __PROJECT_ROOT__/scripts/implementation_pre_bitstream.tcl failed"
    } else {
      send_msg_id runtcl-1 status "$_RESULT"
      send_msg_id runtcl-2 status "sourcing script __PROJECT_ROOT__/scripts/implementation_pre_bitstream.tcl failed"
    }
    return -code error
  }
OPTRACE "Write Bitstream: pre hook" END { }
OPTRACE "read constraints: write_bitstream" START { }
OPTRACE "read constraints: write_bitstream" END { }
  set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
  catch { write_mem_info -force -no_partial_mmi Tiny_Yolo_wrapper.mmi }
OPTRACE "write_bitstream setup" END { }
OPTRACE "write_bitstream" START { }
  write_bitstream -force Tiny_Yolo_wrapper.bit 
OPTRACE "write_bitstream" END { }
OPTRACE "write_bitstream misc" START { }
OPTRACE "read constraints: write_bitstream_post" START { }
OPTRACE "read constraints: write_bitstream_post" END { }
  catch {write_debug_probes -quiet -force Tiny_Yolo_wrapper}
  catch {file copy -force Tiny_Yolo_wrapper.ltx debug_nets.ltx}
  close_msg_db -file write_bitstream.pb
} RESULT]
if {$rc} {
  step_failed write_bitstream
  return -code error $RESULT
} else {
  end_step write_bitstream
  unset ACTIVE_STEP 
}

OPTRACE "write_bitstream misc" END { }
OPTRACE "Phase: Write Bitstream" END { }
OPTRACE "impl_1" END { }
