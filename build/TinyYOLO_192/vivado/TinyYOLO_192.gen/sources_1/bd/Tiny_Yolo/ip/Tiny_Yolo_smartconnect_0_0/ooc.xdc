# aclk {FREQ_HZ 100000000 CLK_DOMAIN Tiny_Yolo_processing_system7_0_0_FCLK_CLK0 PHASE 0.0} aclk1 {FREQ_HZ 240000000 CLK_DOMAIN Tiny_Yolo_processing_system7_0_0_FCLK_CLK0 PHASE 0.0}
# Clock Domain: Tiny_Yolo_processing_system7_0_0_FCLK_CLK0
create_clock -name aclk -period 10.000 [get_ports aclk]
# Generated clocks
create_generated_clock -name aclk1 -source [get_ports aclk] -multiply_by 12 -divide_by 5 [get_ports aclk1]
