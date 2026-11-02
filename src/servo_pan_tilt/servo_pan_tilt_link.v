`timescale 1ns/1ps

// Independent, bounded pan/tilt pulse setup followed by a synchronized move.
// GPIO mode 01 stores pan width; 10 stores tilt width; 11 runs both together.
module servo_pan_tilt_link #(
    parameter integer CLOCKS_PER_US = 50
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk50 CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk50, FREQ_HZ 50000000, ASSOCIATED_RESET resetn" *)
    input wire clk50,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 resetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME resetn, POLARITY ACTIVE_LOW" *)
    input wire resetn,
    input wire [15:0] gpio_o,
    input wire [15:0] gpio_t,
    output wire [15:0] gpio_i,
    output reg pan_pwm = 1'b0,
    output reg tilt_pwm = 1'b0
);
    localparam integer FRAMES_PER_REQUEST = 50;
    // Width sentinels reserve two otherwise-invalid values for a smooth stream
    // session.  Normal servo widths remain bounded to 1000..2300 us.
    localparam [11:0] STREAM_START_WIDTH = 12'd4095;
    localparam [11:0] STREAM_STOP_WIDTH = 12'd4094;
    // Linux updates the two mode GPIOs separately. Require a mode to remain
    // unchanged for 20 ms so the intermediate value is never treated as a command.
    localparam integer COMMAND_STABLE_CYCLES = CLOCKS_PER_US * 20000;
    localparam integer DIV_BITS = (CLOCKS_PER_US > 1) ? $clog2(CLOCKS_PER_US) : 1;
    localparam [DIV_BITS-1:0] DIV_LAST = CLOCKS_PER_US - 1;
    reg [7:0] startup = 8'd0;
    (* ASYNC_REG = "TRUE" *) reg [1:0] reset_sync = 2'b00;
    (* ASYNC_REG = "TRUE" *) reg [1:0] request_meta = 2'b00;
    (* ASYNC_REG = "TRUE" *) reg [1:0] request_sync = 2'b00;
    reg [1:0] request_candidate = 2'b00;
    reg [20:0] request_stable_count = 21'd0;
    reg [1:0] command_sync = 2'b00;
    (* ASYNC_REG = "TRUE" *) reg [11:0] width_meta = 12'd0;
    (* ASYNC_REG = "TRUE" *) reg [11:0] width_sync = 12'd0;
    reg [11:0] pan_width = 12'd0;
    reg [11:0] tilt_width = 12'd0;
    reg [11:0] active_pan_width = 12'd0;
    reg [11:0] active_tilt_width = 12'd0;
    reg [DIV_BITS-1:0] divider = {DIV_BITS{1'b0}};
    reg [14:0] usec = 15'd0;
    reg [7:0] frame_index = 8'd0;
    reg [16:0] idle_cycles = 17'd0;
    reg armed = 1'b0;
    reg busy = 1'b0;
    reg completed = 1'b0;
    reg stream_mode = 1'b0;
    wire ready = startup[7] && reset_sync[1];
    wire tick_us = divider == DIV_LAST;
    wire width_valid = width_sync >= 12'd1000 && width_sync <= 12'd2300;
    wire stream_start = width_sync == STREAM_START_WIDTH;
    wire stream_stop = width_sync == STREAM_STOP_WIDTH;
    wire pan_width_valid = pan_width >= 12'd1000 && pan_width <= 12'd2300;
    wire tilt_width_valid = tilt_width >= 12'd1000 && tilt_width <= 12'd2300;
    wire request_valid = command_sync != 2'b00;
    wire set_pan = command_sync == 2'b01;
    wire set_tilt = command_sync == 2'b10;
    wire run_pair = command_sync == 2'b11;

    assign gpio_i = {12'b0, completed, busy, 2'b00};

    always @(posedge clk50)
        reset_sync <= {reset_sync[0], resetn};

    always @(posedge clk50)
        if (!reset_sync[1]) startup <= 8'd0;
        else if (!startup[7]) startup <= startup + 1'b1;

    // Software holds each width and mode stable before its request.
    always @(posedge clk50)
        if (!ready) begin
            request_meta <= 2'b00;
            request_sync <= 2'b00;
            request_candidate <= 2'b00;
            request_stable_count <= 21'd0;
            command_sync <= 2'b00;
            width_meta <= 12'd0;
            width_sync <= 12'd0;
        end else begin
            request_meta <= gpio_o[1:0] & ~gpio_t[1:0];
            request_sync <= request_meta;
            if (request_sync != request_candidate) begin
                request_candidate <= request_sync;
                request_stable_count <= 21'd0;
            end else if (request_stable_count < COMMAND_STABLE_CYCLES) begin
                request_stable_count <= request_stable_count + 1'b1;
            end else begin
                command_sync <= request_candidate;
            end
            width_meta <= gpio_o[15:4] & ~gpio_t[15:4];
            width_sync <= width_meta;
        end

    always @(posedge clk50)
        if (!ready) begin
            idle_cycles <= 17'd0;
            armed <= 1'b0;
        end else if (busy || request_valid) begin
            idle_cycles <= 17'd0;
            armed <= 1'b0;
        end else if (!armed) begin
            idle_cycles <= idle_cycles + 1'b1;
            if (&idle_cycles) armed <= 1'b1;
        end

    always @(posedge clk50)
        if (!ready || !busy) divider <= {DIV_BITS{1'b0}};
        else if (tick_us) divider <= {DIV_BITS{1'b0}};
        else divider <= divider + 1'b1;

    always @(posedge clk50)
        if (!ready) begin
            usec <= 15'd0;
            frame_index <= 8'd0;
            busy <= 1'b0;
            completed <= 1'b0;
            pan_width <= 12'd0;
            tilt_width <= 12'd0;
            active_pan_width <= 12'd0;
            active_tilt_width <= 12'd0;
            stream_mode <= 1'b0;
        end else if (!busy) begin
            usec <= 15'd0;
            frame_index <= 8'd0;
            if (!request_valid) completed <= 1'b0;
            if (armed && set_pan && stream_start) begin
                stream_mode <= 1'b1;
                completed <= 1'b1;
            end else if (armed && width_valid && set_pan) begin
                pan_width <= width_sync;
                stream_mode <= 1'b0;
                completed <= 1'b1;
            end else if (armed && width_valid && set_tilt) begin
                tilt_width <= width_sync;
                completed <= 1'b1;
            end else if (armed && run_pair && pan_width_valid && tilt_width_valid) begin
                active_pan_width <= pan_width;
                active_tilt_width <= tilt_width;
                busy <= 1'b1;
                completed <= 1'b0;
            end
        end else if (!stream_mode && !run_pair) begin
            busy <= 1'b0;
            completed <= 1'b0;
            frame_index <= 8'd0;
        end else if (stream_mode && run_pair && stream_stop) begin
            // A stream session keeps PWM running across all width updates.
            // The stop sentinel is accepted only with mode 11.
            busy <= 1'b0;
            completed <= 1'b1;
            stream_mode <= 1'b0;
            frame_index <= 8'd0;
        end else begin
            // While streaming, modes 01 and 10 update the stored width without
            // stopping the current PWM train.  The new width is applied at the
            // next 20 ms frame boundary.
            if (stream_mode && width_valid && set_pan)
                pan_width <= width_sync;
            else if (stream_mode && width_valid && set_tilt)
                tilt_width <= width_sync;
            if (tick_us) begin
                if (usec == 15'd19999) begin
                    usec <= 15'd0;
                    if (stream_mode) begin
                        frame_index <= 8'd0;
                        active_pan_width <= pan_width;
                        active_tilt_width <= tilt_width;
                    end else if (frame_index == FRAMES_PER_REQUEST - 1) begin
                        frame_index <= 8'd0;
                        busy <= 1'b0;
                        completed <= 1'b1;
                    end else frame_index <= frame_index + 1'b1;
                end else usec <= usec + 1'b1;
            end
        end

    always @(posedge clk50) begin
        if (!ready) begin
            pan_pwm <= 1'b0;
            tilt_pwm <= 1'b0;
        end else begin
            pan_pwm <= busy && usec < active_pan_width;
            tilt_pwm <= busy && usec < active_tilt_width;
        end
    end
endmodule
