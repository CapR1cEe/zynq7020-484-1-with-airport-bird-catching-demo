# In the PL domain, NOT(FDRE(D)) is exactly FDSE(NOT(D)), with
# identical clock/enable, S=R and complemented INIT. The source D already
# has an inverter, so the two inversions cancel. This changes no reset edge.
# Apply before placement so every replica can be placed near its consumers.
set reset_root [file dirname [file dirname [file normalize [info script]]]]
set reset_original [get_cells -hierarchical -filter {NAME == Tiny_Yolo_i/proc_sys_reset_0/U0/ACTIVE_LOW_PR_OUT_DFF[0].FDRE_PER_N}]
if {[llength $reset_original] != 1 || [get_property REF_NAME $reset_original] ne {FDRE}} {
    error {Unexpected PL peripheral reset source}
}
foreach property {IS_C_INVERTED IS_D_INVERTED IS_R_INVERTED} {
    if {[get_property $property $reset_original] ni {0 false FALSE 1'b0 1'h0}} {
        error "Unsupported reset source polarity: $property"
    }
}
set reset_inputs [dict create]
foreach pin {C CE D R} {
    dict set reset_inputs $pin [get_nets -of_objects [get_pins -of_objects $reset_original -filter [list REF_PIN_NAME == $pin]]]
}
set reset_init [get_property INIT $reset_original]
if {$reset_init eq {1'b0}} {set reset_complement_init 1'b1} elseif {$reset_init eq {1'b1}} {
    set reset_complement_init 1'b0
} else {error {Unsupported reset initialization}}
set reset_d_inverter [get_cells -of_objects [get_pins -leaf -of_objects [get_nets -segments [dict get $reset_inputs D]] -filter {DIRECTION == OUT}]]
if {[llength $reset_d_inverter] != 1 || [get_property REF_NAME $reset_d_inverter] ne {LUT1} ||
    [get_property INIT $reset_d_inverter] ne {2'h1}} {error {Reset source D is not an exact inverter}}
set reset_positive_data [get_nets -of_objects [get_pins -of_objects $reset_d_inverter -filter {REF_PIN_NAME == I0}]]
set reset_qnets [get_nets -segments -of_objects [get_pins -of_objects $reset_original -filter {REF_PIN_NAME == Q}]]
# Trace the complete transparent LUT tree before changing it. Synthesis may
# represent MAX_FANOUT buffers as cascaded LUT1 identities; count actual
# endpoints rather than buffers that opt_design will later remove.
set reset_tree_cells [dict create]
set reset_tree_endpoints [dict create]
proc collect_reset_tree {nets parity} {
    global reset_tree_cells reset_tree_endpoints
    foreach pin [lsort -unique [get_pins -leaf -of_objects [get_nets -segments $nets] -filter {DIRECTION == IN}]] {
        if {![string match {Tiny_Yolo_i/tinyyolo_accel_0/inst/*} $pin]} {
            if {$parity != 0} {error "Unexpected reset inverter branch outside the accelerator: $pin"}
            continue
        }
        set cell [get_cells -of_objects $pin]
        set ref [get_property REF_NAME $cell]
        set init [get_property -quiet INIT $cell]
        if {$ref eq {LUT1} && $init in {2'h1 2'h2}} {
            if {[dict exists $reset_tree_cells $cell]} {
                if {[dict get $reset_tree_cells $cell parity] != $parity} {error {Inconsistent reset tree polarity}}
                continue
            }
            set output [get_nets -segments -of_objects [get_pins -of_objects $cell -filter {REF_PIN_NAME == O}]]
            dict set reset_tree_cells $cell [dict create parity $parity init $init nets $output]
            set next_parity [expr {$parity ^ ($init eq {2'h1})}]
            collect_reset_tree $output $next_parity
        } else {
            if {[dict exists $reset_tree_endpoints $pin] && [dict get $reset_tree_endpoints $pin] != $parity} {
                error {Inconsistent reset endpoint polarity}
            }
            dict set reset_tree_endpoints $pin $parity
        }
    }
}
collect_reset_tree $reset_qnets 0
set reset_affected $reset_qnets
dict for {pin net} $reset_inputs {set reset_affected [concat $reset_affected [get_nets -segments $net]]}
set reset_protected [filter $reset_affected {DONT_TOUCH == 1}]
set_property DONT_TOUCH false $reset_affected
set reset_proof [open [file join $reset_root reports synchronous_reset_distribution.tsv] w]
puts $reset_proof "operation\tcell\tdetail\tloads"
set reset_groups {}
set reset_high_pins {}
set reset_complemented_pins {}
set reset_low_pins {}
set reset_removed 0
set reset_buffers 0
set reset_rewritten 0
set reset_retained 0
dict for {sink parity} $reset_tree_endpoints {
    set cell [get_cells -of_objects $sink]
    set ref [get_property REF_NAME $cell]
    if {$parity == 1} {
        lappend reset_high_pins $sink
        puts $reset_proof "KEEP_POSITIVE_INPUT\t$cell\t$sink:$ref\t1"
    } elseif {[regexp {^LUT([1-6])$} $ref unused width]} {
        # Complement this one input's complete truth table. This preserves
        # every other input, including additional reset inputs on this LUT.
        set old_init [get_property INIT $cell]
        if {![regexp {^I([0-5])$} [get_property REF_PIN_NAME $sink] unused input_index]} {error {Invalid LUT reset input}}
        if {![regexp {^[0-9]+'h([0-9a-fA-F]+)$} $old_init unused init_hex]} {error {Invalid LUT INIT}}
        set old_value [expr 0x$init_hex]
        set new_value 0
        set mask [expr {1 << $input_index}]
        set size [expr {1 << $width}]
        for {set address 0} {$address < $size} {incr address} {
            set bit [expr {($old_value >> ($address ^ $mask)) & 1}]
            set new_value [expr {$new_value | ($bit << $address)}]
        }
        # Tcl's default %X conversion truncates to 32 bits on Windows.
        # LUT6 needs all 64 truth-table bits, including the upper half.
        set new_init [format "%d'h%llX" $size $new_value]
        regexp {^[0-9]+'h([0-9a-fA-F]+)$} $new_init unused checked_hex
        if {[expr 0x$checked_hex] != $new_value} {
            error "LUT INIT formatting lost bits: $cell $new_init"
        }
        set_property INIT $new_init $cell
        set applied_init [get_property INIT $cell]
        if {![regexp {^[0-9]+'h([0-9a-fA-F]+)$} $applied_init unused applied_hex] ||
            [expr 0x$applied_hex] != $new_value} {
            error "LUT INIT readback differs: $cell $applied_init"
        }
        puts $reset_proof "COMPLEMENT_INPUT\t$cell\t$sink:$old_init:$new_init\t1"
        lappend reset_complemented_pins $sink
        incr reset_rewritten
    } else {
        # Direct RAM enables (and any other positive-enable primitives) keep
        # their original active-low reset value and original source register.
        puts $reset_proof "RETAIN_DIRECT_INPUT\t$cell\t$sink:$ref\t1"
        lappend reset_low_pins $sink
        incr reset_retained
    }
}
if {[dict size $reset_tree_cells] < 3 || $reset_rewritten < 30} {error {Unexpected PL reset distribution structure}}
disconnect_net -pinlist [dict keys $reset_tree_endpoints]
if {[llength $reset_low_pins]} {
    connect_net -hierarchical -net [get_nets -of_objects [get_pins -of_objects $reset_original -filter {REF_PIN_NAME == Q}]] -objects $reset_low_pins
}
dict for {cell metadata} $reset_tree_cells {
    set init [dict get $metadata init]
    set output [dict get $metadata nets]
    set loads [get_pins -quiet -leaf -of_objects $output -filter {DIRECTION == IN}]
    if {[llength $output]} {set_property DONT_TOUCH false $output}
    if {$init eq {2'h1}} {set operation BYPASS_INVERTER; incr reset_removed} else {set operation BYPASS_BUFFER; incr reset_buffers}
    puts $reset_proof "$operation\t$cell\t$init\t[llength $loads]"
    set_property DONT_TOUCH false $cell
}
remove_cell [dict keys $reset_tree_cells]
foreach {pins limit} [list [lsort $reset_high_pins] 64 [lsort $reset_complemented_pins] 8] {
    for {set first 0} {$first < [llength $pins]} {incr first $limit} {
        lappend reset_groups [lrange $pins $first [expr {$first+$limit-1}]]
    }
}
set reset_replica_index 0
set reset_load_count 0
foreach loads $reset_groups {
    set ff [create_cell -reference FDSE "Tiny_Yolo_i/tinyyolo_accel_0/inst/reset_positive_ff_$reset_replica_index"]
    set_property INIT $reset_complement_init $ff
    foreach {target source} {C C CE CE S R} {
        connect_net -hierarchical -net [dict get $reset_inputs $source] -objects [get_pins -of_objects $ff -filter [list REF_PIN_NAME == $target]]
    }
    connect_net -hierarchical -net $reset_positive_data -objects [get_pins -of_objects $ff -filter {REF_PIN_NAME == D}]
    set net [create_net "Tiny_Yolo_i/tinyyolo_accel_0/inst/reset_positive_q_$reset_replica_index"]
    connect_net -net $net -objects [get_pins -of_objects $ff -filter {REF_PIN_NAME == Q}]
    connect_net -hierarchical -net $net -objects $loads
    set_property DONT_TOUCH true $ff
    foreach {target source} {C C CE CE S R D POSITIVE_DATA} {
        if {$source eq {POSITIVE_DATA}} {set expected_net $reset_positive_data} else {set expected_net [dict get $reset_inputs $source]}
        set expected [lsort [get_pins -leaf -of_objects [get_nets -segments $expected_net] -filter {DIRECTION == OUT}]]
        set actual [lsort [get_pins -leaf -of_objects [get_nets -segments -of_objects [get_pins -of_objects $ff -filter [list REF_PIN_NAME == $target]]] -filter {DIRECTION == OUT}]]
        if {$expected ne $actual} {error "Reset replica input differs: $ff $target"}
    }
    puts $reset_proof "IDENTICAL_FDSE\t$ff\tINIT=$reset_complement_init;C=[dict get $reset_inputs C];CE=[dict get $reset_inputs CE];S=[dict get $reset_inputs R];D=$reset_positive_data\t[llength $loads]"
    incr reset_load_count [llength $loads]
    incr reset_replica_index
}
close $reset_proof
if {[llength $reset_protected]} {set_property DONT_TOUCH true $reset_protected}
set reset_receipt [open [file join $reset_root reports synchronous_reset_distribution.json] w]
puts $reset_receipt [format {{"status":"PASS_SAME_EDGE_RESET_DISTRIBUTION","source":"%s","replicas":%d,"bypassed_inverters":%d,"flattened_buffers":%d,"preserved_low_inputs":%d,"complemented_lut_inputs":%d,"loads":%d,"maximum_replica_fanout":64,"added_reset_cycles":0,"clock_enable_data_set_and_init_checked":true,"path_exceptions_changed":false}} $reset_original $reset_replica_index $reset_removed $reset_buffers $reset_retained $reset_rewritten $reset_load_count]
close $reset_receipt
puts "SAME_EDGE_RESET_DISTRIBUTION_PASS replicas=$reset_replica_index removed_inverters=$reset_removed flattened_buffers=$reset_buffers retained_low_inputs=$reset_retained rewritten_inputs=$reset_rewritten loads=$reset_load_count added_cycles=0"
