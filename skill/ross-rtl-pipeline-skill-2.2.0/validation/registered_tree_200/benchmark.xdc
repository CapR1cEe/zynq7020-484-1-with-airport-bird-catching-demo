create_clock -name bench_clk -period 5.000000 [get_ports clk]
set_clock_uncertainty 0.150 [get_clocks bench_clk]
set_output_delay -clock bench_clk -max 0.500 [get_ports checksum*]
set_output_delay -clock bench_clk -min 0.000 [get_ports checksum*]
