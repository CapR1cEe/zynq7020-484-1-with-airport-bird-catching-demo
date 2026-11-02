# Check real primitive connectivity, independently of DRC message settings.
proc assert_clock_topology {} {
    set buffers [lsort [get_cells -hierarchical -filter {REF_NAME == BUFG}]]
    if {[llength $buffers] != 3} {error "Expected three original BUFGs, found: $buffers"}
    set pl [get_cells -quiet Tiny_Yolo_i/pl_clk/inst/clkout1_buf]
    if {[llength $pl] != 1 || [get_property REF_NAME $pl] ne {BUFG}} {
        error {Missing original PL clock BUFG}
    }
    foreach buffer $buffers {
        set nets [get_nets -segments -of_objects [get_pins $buffer/I]]
        set drivers [get_pins -leaf -of_objects $nets -filter {DIRECTION == OUT}]
        if {[llength $drivers] != 1} {error "Clock input does not have one driver: $buffer $drivers"}
        set driver [get_cells -of_objects $drivers]
        set primitive [get_property REF_NAME $driver]
        if {[string match {BUF*} $primitive]} {
            error "Cascaded clock buffers are prohibited: $driver -> $buffer"
        }
        if {$buffer eq $pl && ($primitive ne {MMCME2_ADV} ||
            [get_property REF_PIN_NAME $drivers] ne {CLKOUT0})} {
            error "PL BUFG must connect directly to MMCM CLKOUT0: $drivers $primitive"
        }
    }
    set clock [get_clocks clk_out1_Tiny_Yolo_pl_clk_0]
    if {[llength $clock] != 1 || abs([get_property PERIOD $clock]-1000.0/240.0)>0.001} {
        error {PL clock must remain at 240 MHz}
    }
    puts {CLOCK_TOPOLOGY_PASS bufg_count=3 cascaded_bufg=0 pl_source=MMCM_CLKOUT0 clock_mhz=240}
    return $buffers
}
