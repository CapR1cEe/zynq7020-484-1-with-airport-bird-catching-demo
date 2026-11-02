# Keep the explicitly pipelined weight-bank read path free of automatically
# generated combinational clock enables. This changes power policy only;
# clock periods, path timing and CDC checks remain fully enforced.
set_power_opt -exclude_cells [get_cells -hierarchical -filter {REF_NAME =~ RAMB* && NAME =~ *u_control/parallel_lane*weight_bank_reg*}]
# Input-cache output registers also run unconditionally. Power gating them
# reintroduced a reset-to-REGCE timing path after the RTL was pipelined.
set_power_opt -exclude_cells [get_cells -hierarchical -filter {REF_NAME =~ RAMB* && NAME =~ *u_hp0/input_bank*data_reg*}]
# Local gather-cache reads are unconditional and already have an output
# register. Extra power gates place options/state decodes on BRAM enables.
set_power_opt -exclude_cells [get_cells -hierarchical -filter {REF_NAME =~ RAMB* && NAME =~ *u_control/local_data_reg*}]
# The fused-pool row buffer has its own unconditional registered read. Keep
# reset/state decode out of REGCEAREGCE just as for the other pipelined RAMs.
set_power_opt -exclude_cells [get_cells -hierarchical -filter {REF_NAME =~ RAMB* && NAME =~ *u_control/pool_row_reg*}]
