`timescale 1ns/1ps

// H19 only: 150 frames at 50 Hz, then stop. Width is latched at request start.
// Internal PS GPIO bits 15:4 carry microseconds; bits 1:0 carry requests.
module servo_microtest #(
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
    output wire pan_pwm,
    output reg tilt_pwm = 1'b0
);
    localparam integer FRAMES_PER_REQUEST = 150;
    localparam integer DIV_BITS = (CLOCKS_PER_US > 1) ? $clog2(CLOCKS_PER_US) : 1;
    localparam [DIV_BITS-1:0] DIV_LAST = CLOCKS_PER_US - 1;
    reg [7:0] startup = 8'd0;
    (* ASYNC_REG = "TRUE" *) reg [1:0] reset_sync = 2'b00;
    (* ASYNC_REG = "TRUE" *) reg [1:0] request_meta = 2'b00;
    (* ASYNC_REG = "TRUE" *) reg [1:0] request_sync = 2'b00;
    (* ASYNC_REG = "TRUE" *) reg [11:0] width_meta = 12'd0;
    (* ASYNC_REG = "TRUE" *) reg [11:0] width_sync = 12'd0;
    reg [11:0] active_width = 12'd0;
    reg [DIV_BITS-1:0] divider = {DIV_BITS{1'b0}};
    reg [14:0] usec = 15'd0;
    reg [7:0] frame_index = 8'd0;
    reg [16:0] idle_cycles = 17'd0;
    reg armed = 1'b0;
    reg busy = 1'b0;
    reg completed = 1'b0;
    wire ready = startup[7] && reset_sync[1];
    wire tick_us = divider == DIV_LAST;
    wire width_valid = width_sync >= 12'd2000 && width_sync <= 12'd2500;

    assign gpio_i = {12'b0, completed, busy, 2'b00};
    assign pan_pwm = 1'b0;

    always @(posedge clk50)
        reset_sync <= {reset_sync[0], resetn};

    always @(posedge clk50)
        if (!reset_sync[1]) startup <= 8'd0;
        else if (!startup[7]) startup <= startup + 1'b1;

    // Software holds width stable for 50 ms before asserting a request.
    always @(posedge clk50)
        if (!ready) begin
            request_meta <= 2'b00;
            request_sync <= 2'b00;
            width_meta <= 12'd0;
            width_sync <= 12'd0;
        end else begin
            request_meta <= gpio_o[1:0] & ~gpio_t[1:0];
            request_sync <= request_meta;
            width_meta <= gpio_o[15:4] & ~gpio_t[15:4];
            width_sync <= width_meta;
        end

    always @(posedge clk50)
        if (!ready) begin
            idle_cycles <= 17'd0;
            armed <= 1'b0;
        end else if (busy || request_sync != 2'b00) begin
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
            active_width <= 12'd0;
        end else if (!busy) begin
            usec <= 15'd0;
            frame_index <= 8'd0;
            if (request_sync == 2'b00) completed <= 1'b0;
            if (armed && request_sync == 2'b10 && width_valid) begin
                active_width <= width_sync;
                busy <= 1'b1;
                completed <= 1'b0;
            end
        end else if (request_sync != 2'b10) begin
            busy <= 1'b0;
            completed <= 1'b0;
            frame_index <= 8'd0;
        end else if (tick_us) begin
            if (usec == 15'd19999) begin
                usec <= 15'd0;
                if (frame_index == FRAMES_PER_REQUEST - 1) begin
                    frame_index <= 8'd0;
                    busy <= 1'b0;
                    completed <= 1'b1;
                end else frame_index <= frame_index + 1'b1;
            end else usec <= usec + 1'b1;
        end

    always @(posedge clk50)
        if (!ready) tilt_pwm <= 1'b0;
        else tilt_pwm <= busy && usec < active_width;
endmodule
