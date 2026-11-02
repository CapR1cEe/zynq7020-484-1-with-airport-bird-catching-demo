# SmartZynq SP2 schematic V1.3B: X2 50-MHz oscillator -> M19.
# J5 Bank35 is 3.3 V. Current user wiring: tilt H19; pan H20 is held low.
set_property -dict {PACKAGE_PIN M19 IOSTANDARD LVCMOS33} [get_ports clk50]
create_clock -name board_clk50 -period 20.000 [get_ports clk50]
set_property -dict {PACKAGE_PIN H20 IOSTANDARD LVCMOS33 DRIVE 4 SLEW SLOW} [get_ports pan_pwm]
set_property -dict {PACKAGE_PIN H19 IOSTANDARD LVCMOS33 DRIVE 4 SLEW SLOW} [get_ports tilt_pwm]
set_property -dict {PACKAGE_PIN M17 IOSTANDARD LVCMOS33} [get_ports UART_0_0_rxd]
set_property -dict {PACKAGE_PIN L17 IOSTANDARD LVCMOS33} [get_ports UART_0_0_txd]
# UART terminates in the PS asynchronous UART, outside the PWM clock domain.
set_false_path -from [get_ports UART_0_0_rxd]
set_false_path -to [get_ports UART_0_0_txd]
# Servo receivers are asynchronous. Constrain the registered output path to
# one board-clock period; the precise pulse width is checked in simulation.
set_output_delay -clock board_clk50 -max 1.0 [get_ports {pan_pwm tilt_pwm}]
set_output_delay -clock board_clk50 -min 0.0 [get_ports {pan_pwm tilt_pwm}]
