`timescale 1ns/1ps
module reset_retime_tb;
    reg clk = 0;
    reg enable = 0;
    reg data_in = 0;
    reg reset_in = 0;
    wire original_q, inverse_q;
    integer i;
    integer seed = 32'h19224024;
    always #2.083333 clk = ~clk;
    FDRE #(.INIT(1'b0)) original (
        .C(clk), .CE(enable), .D(data_in), .R(reset_in), .Q(original_q));
    FDSE #(.INIT(1'b1)) transformed (
        .C(clk), .CE(enable), .D(~data_in), .S(reset_in), .Q(inverse_q));
    initial begin
        #101;
        if (inverse_q !== ~original_q) begin
            $display("ERROR: Reset initialization differs");
            $fatal;
        end
        for (i=0; i<4096; i=i+1) begin
            @(negedge clk);
            if (i<64) {reset_in, enable, data_in} = i[2:0];
            else {reset_in, enable, data_in} = $random(seed);
            @(posedge clk);
            #0.2;
            if (inverse_q !== ~original_q) begin
                $display("ERROR: Reset cycle differs at %d", i);
                $fatal;
            end
        end
        $display("PASS_RESET_RETIMING_UNISIM cycles=4096 init_complement=1 ce_and_reset_checked=1");
        $finish;
    end
endmodule
