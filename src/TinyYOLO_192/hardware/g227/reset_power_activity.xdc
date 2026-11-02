# Vectorless power analysis assumes the observed operating mode: the PS and PL
# system resets are released while inference runs. This annotates power only;
# it neither ties reset pins nor changes timing/CDC exceptions.
set_switching_activity -static_probability 1 -toggle_rate 0 [get_nets -hierarchical -filter {NAME =~ *proc_sys_reset_0_peripheral_aresetn* || NAME =~ *ps_ctrl_reset_peripheral_aresetn* || NAME =~ *processing_system7_0_FCLK_RESET0_N*}]
