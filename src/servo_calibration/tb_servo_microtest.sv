`timescale 1ns/1ps
module tb_servo_microtest;
    reg clk = 0;
    always #10 clk = ~clk;
    reg resetn = 0;
    reg [15:0] gpio_o = 0;
    reg [15:0] gpio_t = 16'h000c;
    wire [15:0] status;
    wire pan, tilt;
    servo_microtest #(.CLOCKS_PER_US(1)) dut(clk,resetn,gpio_o,gpio_t,status,pan,tilt);
    reg prod_reset = 0;
    reg [15:0] prod_o = 0;
    wire [15:0] prod_status;
    wire prod_pan, prod_tilt;
    servo_microtest production(clk,prod_reset,prod_o,16'h000c,prod_status,prod_pan,prod_tilt);
    integer cycle = 0;
    reg production_checked = 0;

    always @(negedge clk) begin
        cycle = cycle + 1;
        if (pan || prod_pan) $fatal(1,"Pan output must stay low");
    end
    task clocks(input integer n);
        repeat(n) begin @(negedge clk); #1; end
    endtask
    task idle_width(input integer width);
        gpio_o = width << 4;
        clocks(131100);
        if (status[3:2] || tilt) $fatal(1,"Idle output or status is not clear");
    endtask
    task sequence_at(input integer width);
        integer pulses, rise, start, previous_rise;
        idle_width(width);
        pulses=0; previous_rise=-1;
        gpio_o[1]=1;
        while (!status[2]) clocks(1);
        start=cycle;
        while (!status[3]) begin
            if (tilt) begin
                rise=cycle;
                if (previous_rise >= 0 && rise-previous_rise != 20000)
                    $fatal(1,"Frame period is not 20000 ticks");
                previous_rise=rise;
                while (tilt) clocks(1);
                if (cycle-rise != width) $fatal(1,"Wrong pulse width");
                pulses=pulses+1;
                // Changing the configuration while busy must not change this target.
                if (pulses==1) gpio_o[15:4]=(width==2000 ? 2500 : 2000);
            end else clocks(1);
        end
        if (pulses!=150 || cycle-start!=3000000 || status[2] || tilt)
            $fatal(1,"Wrong frame count or request length");
        clocks(50000);
        if (!status[3] || status[2] || tilt) $fatal(1,"Held request retriggered");
        $display("CALIBRATION_SEQUENCE_PASS width_us=%0d pulses=150 frame_us=20000 latched_width held_no_retrigger",width);
    endtask

    initial begin
        gpio_o=(2250 << 4) | 2;
        clocks(10); resetn=1;
        clocks(200000);
        if (status[3:2] || tilt) $fatal(1,"Stale request triggered");
        idle_width(2250); gpio_o[0]=1; clocks(200000);
        if (status[3:2] || tilt) $fatal(1,"Pan request triggered");
        idle_width(2250); gpio_o[1:0]=3; clocks(200000);
        if (status[3:2] || tilt) $fatal(1,"Conflicting request triggered");
        idle_width(1999); gpio_o[1]=1; clocks(200000);
        if (status[3:2] || tilt) $fatal(1,"Below-range width triggered");
        idle_width(2501); gpio_o[1]=1; clocks(200000);
        if (status[3:2] || tilt) $fatal(1,"Above-range width triggered");
        sequence_at(2250);
        sequence_at(2000);
        sequence_at(2500);
        idle_width(2250); gpio_t=16'hffff; gpio_o[1]=1; clocks(200000);
        if (status[3:2] || tilt) $fatal(1,"Tri-state request triggered");
        gpio_t=16'h000c;
        idle_width(2250); gpio_o[1]=1; clocks(100);
        if (!status[2] || !tilt) $fatal(1,"Abort test did not start");
        gpio_o[1]=0; clocks(8);
        if (status[3:2] || tilt) $fatal(1,"Release did not abort");
        idle_width(2250); gpio_o[1]=1; clocks(100);
        resetn=0; clocks(8);
        if (status[3:2] || tilt) $fatal(1,"Reset did not stop");
        $display("CALIBRATION_GUARDS_PASS stale pan conflict width_range tristate abort reset");
        wait(production_checked);
        $display("CALIBRATION_RTL_PASS");
        $finish;
    end

    initial begin : production_check
        time request_start, pulse_start, previous_start;
        integer pulses;
        clocks(10); prod_reset=1;
        prod_o=2250 << 4;
        clocks(200000);
        prod_o[1]=1;
        @(posedge prod_status[2]); request_start=$time;
        previous_start=0;
        for (pulses=0;pulses<150;pulses=pulses+1) begin
            @(posedge prod_tilt); pulse_start=$time;
            if (pulses>0 && pulse_start-previous_start != 20000000)
                $fatal(1,"Production frame period is not 20 ms");
            previous_start=pulse_start;
            @(negedge prod_tilt);
            if ($time-pulse_start != 2250000) $fatal(1,"Production width is not 2250 us");
        end
        @(posedge prod_status[3]);
        if ($time-request_start != 64'd3000000000) $fatal(1,"Production request is not 3 seconds");
        clocks(1000000);
        if (prod_status[2] || prod_tilt || !prod_status[3]) $fatal(1,"Production request retriggered");
        production_checked=1;
        $display("CALIBRATION_PRODUCTION_PASS clk_mhz=50 width_us=2250 pulse_clocks=112500 pulses=150 frame_us=20000 total_ms=3000");
    end
    initial begin
        #(64'd4000000000);
        $fatal(1,"Calibration simulation timeout");
    end
endmodule
