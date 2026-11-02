`timescale 1ns/1ps
module tb_pan_tilt_link;
    reg clk = 0;
    always #10 clk = ~clk;
    reg resetn = 0;
    reg [15:0] gpio_o = 0;
    reg [15:0] gpio_t = 16'h000c;
    wire [15:0] status;
    wire pan, tilt;
    servo_pan_tilt_link #(.CLOCKS_PER_US(1)) dut(
        clk, resetn, gpio_o, gpio_t, status, pan, tilt);
    integer cycle = 0;

    always @(negedge clk) begin
        cycle = cycle + 1;
    end

    task clocks(input integer n);
        repeat(n) begin @(negedge clk); #1; end
    endtask

    task configure_axis(input [1:0] mode, input integer width);
        begin
            gpio_o = width << 4;
            clocks(131100);
            if (status[3:2] || pan || tilt)
                $fatal(1, "Unexpected status before axis setup");
            gpio_o = (width << 4) | mode;
            while (!status[3] && !status[2]) clocks(1);
            if (!status[3] || status[2] || pan || tilt)
                $fatal(1, "Axis width setup was not acknowledged safely");
            gpio_o = width << 4;
            while (status[3]) clocks(1);
            clocks(131100);
            if (status[3:2] || pan || tilt)
                $fatal(1, "Axis setup did not return to idle");
        end
    endtask

    task run_pair(input integer pan_width, input integer tilt_width);
        integer pan_pulses, tilt_pulses;
        integer pan_rise, tilt_rise, previous_pan_rise, previous_tilt_rise;
        reg pan_prev, tilt_prev;
        begin
            // Match Linux sysfs updates: the first mode bit briefly changes
            // before the second write. The filter must ignore this transient.
            gpio_o[1:0] = 2'b01;
            clocks(100);
            if (status[3:2] || pan || tilt)
                $fatal(1, "Intermediate mode was incorrectly accepted");
            gpio_o[1:0] = 2'b11;
            while (!status[2]) clocks(1);
            pan_pulses=0; tilt_pulses=0;
            pan_rise=0; tilt_rise=0;
            previous_pan_rise=-1; previous_tilt_rise=-1;
            pan_prev=0; tilt_prev=0;
            while (!status[3]) begin
                if (pan && !pan_prev) begin
                    pan_rise=cycle;
                    if (previous_pan_rise >= 0 && pan_rise-previous_pan_rise != 20000)
                        $fatal(1, "Pan frame period is not 20000 us ticks");
                    previous_pan_rise=pan_rise;
                    pan_pulses=pan_pulses+1;
                end
                if (!pan && pan_prev && cycle-pan_rise != pan_width)
                    $fatal(1, "Wrong pan pulse width");
                if (tilt && !tilt_prev) begin
                    tilt_rise=cycle;
                    if (previous_tilt_rise >= 0 && tilt_rise-previous_tilt_rise != 20000)
                        $fatal(1, "Tilt frame period is not 20000 us ticks");
                    previous_tilt_rise=tilt_rise;
                    tilt_pulses=tilt_pulses+1;
                end
                if (!tilt && tilt_prev && cycle-tilt_rise != tilt_width)
                    $fatal(1, "Wrong tilt pulse width");
                if (pan && tilt && pan_rise != tilt_rise)
                    $fatal(1, "Axes did not start pulses simultaneously");
                pan_prev=pan; tilt_prev=tilt;
                clocks(1);
            end
            if (pan_prev || tilt_prev || pan_pulses != 50 || tilt_pulses != 50 ||
                status[2] || pan || tilt)
                $fatal(1, "Wrong simultaneous frame count or final state");
            clocks(50000);
            if (!status[3] || status[2] || pan || tilt)
                $fatal(1, "Held pair request retriggered");
            $display("PAN_TILT_PAIR_PASS pan_us=%0d tilt_us=%0d frames=50", pan_width, tilt_width);
            gpio_o[1:0]=2'b00;
            while (status[3]) clocks(1);
            clocks(131100);
        end
    endtask

    task move_pair(input integer pan_width, input integer tilt_width);
        begin
            configure_axis(2'b01, pan_width);
            configure_axis(2'b10, tilt_width);
            run_pair(pan_width, tilt_width);
        end
    endtask

    initial begin
        clocks(10);
        resetn=1;
        clocks(200000);
        if (status[3:2] || pan || tilt) $fatal(1, "Stale request on reset");
        move_pair(1480, 2150);
        move_pair(1450, 2200);
        $display("PAN_TILT_LINK_RTL_PASS independent_widths synchronized start home_return");
        $finish;
    end

    initial begin
        #(64'd8000000000);
        $fatal(1, "Pan-tilt linked simulation timeout");
    end
endmodule
