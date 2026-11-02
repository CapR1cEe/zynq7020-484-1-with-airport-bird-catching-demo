# SmartZynq SP2 reference xillydemo.xdc, verified board console wiring.
set_property -dict {PACKAGE_PIN M17 IOSTANDARD LVCMOS33} [get_ports UART_0_rxd]
set_property -dict {PACKAGE_PIN L17 IOSTANDARD LVCMOS33} [get_ports UART_0_txd]
# UART is asynchronous and terminates inside the dedicated PS UART. It has
# no synchronous data path into accelerator/control/HP0 logic.
set_false_path -from [get_ports UART_0_rxd]
set_false_path -to [get_ports UART_0_txd]
