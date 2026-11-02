`timescale 1ns/1ps
module tb_shift56_jam;
    reg clk=0;
    always #2.083333333 clk=~clk;
    reg [55:0] value=0;
    reg [10:0] distance=0;
    wire [55:0] result56;
    wire [27:0] result28;
    wire result1;
    reg [55:0] expected[0:2];
    integer cycles=0,checked=0,bit_index,amount,i;
    integer seed=32'h19224024;
    tinyyolo_shift56_jam a(.clk(clk),.value(value),.distance(distance),.result(result56));
    tinyyolo_shift56_jam #(.RESULT_WIDTH(28)) b(.clk(clk),.value(value),.distance(distance),.result(result28));
    tinyyolo_shift56_jam #(.RESULT_WIDTH(1)) c(.clk(clk),.value(value),.distance(distance),.result(result1));
    function automatic [55:0] reference_shift(input [55:0] operand,input [10:0] shift);
        reg [55:0] shifted;
        reg sticky;
        integer j;
        begin
            shifted=operand>>shift;
            sticky=0;
            for(j=0;j<56;j=j+1)
                if(j<shift)sticky=sticky|operand[j];
            reference_shift=shifted|{55'd0,sticky};
        end
    endfunction
    always @(posedge clk) begin
        expected[2]=expected[1];
        expected[1]=expected[0];
        expected[0]=reference_shift(value,distance);
        cycles=cycles+1;
        #0.1;
        if(cycles>=3)begin
            if(result56!==expected[2] || result28!==expected[2][27:0] || result1!==expected[2][0])
                $fatal(1,"SHIFT56_MISMATCH cycle=%0d got56=%h got28=%h expected=%h",cycles,result56,result28,expected[2]);
            checked=checked+1;
        end
    end
    initial begin
        for(amount=0;amount<2048;amount=amount+1)begin
            for(bit_index=0;bit_index<56;bit_index=bit_index+1)begin
                @(negedge clk);value=56'd1<<bit_index;distance=amount;
            end
            @(negedge clk);value=56'd0;distance=amount;
            @(negedge clk);value=56'hffffffffffffff;distance=amount;
        end
        for(i=0;i<4096;i=i+1)begin
            @(negedge clk);value={$random(seed),$random(seed)};distance=$random(seed);
        end
        repeat(3)@(negedge clk);
        $display("SHIFT56_JAM_PASS checked=%0d distances=2048 single_bits=56 widths=56,28,1 latency=3 ii=1",checked);
        $finish;
    end
endmodule
