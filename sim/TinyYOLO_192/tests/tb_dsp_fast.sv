`timescale 1ns/1ps
module tb_dsp_fast;
    reg clk=0,rst_n=0,load=0,valid=0,last=0;
    always #2.083333333 clk=~clk;
    reg signed [24:0] a=0;
    reg signed [17:0] b=0;
    reg signed [31:0] bias=0;
    reg signed [19:0] term=0;
    wire signed [42:0] real_mul[0:1], fast_mul[0:1];
    wire signed [31:0] real_sum,fast_sum;
    wire real_overflow,fast_overflow,real_valid,fast_valid,real_last,fast_last;
    genvar r;
    generate for(r=0;r<2;r=r+1) begin: mul_test
        tinyyolo_dsp_mul #(.INPUT_REG(r)) physical(.clk(clk),.rst_n(rst_n),.a(a),.b(b),.product(real_mul[r]));
        fast_tinyyolo_dsp_mul #(.INPUT_REG(r)) modeled(.clk(clk),.rst_n(rst_n),.a(a),.b(b),.product(fast_mul[r]));
    end endgenerate
    tinyyolo_dsp_accum32 physical_acc(.clk(clk),.rst_n(rst_n),.load(load),.bias(bias),.valid(valid),.last(last),.term(term),
        .sum(real_sum),.overflow(real_overflow),.out_valid(real_valid),.out_last(real_last));
    fast_tinyyolo_dsp_accum32 modeled_acc(.clk(clk),.rst_n(rst_n),.load(load),.bias(bias),.valid(valid),.last(last),.term(term),
        .sum(fast_sum),.overflow(fast_overflow),.out_valid(fast_valid),.out_last(fast_last));
    integer i,j,checked=0,resets=0,loads=0,overflows=0,math_checks=0;
    reg signed [47:0] math_acc=0;
    reg signed [47:0] math_result[0:2];
    reg [2:0] math_valid=0,math_last=0;
    initial begin
        // UNISIM global startup reset is asserted for the first 100 ns.
        repeat(30)@(negedge clk);
        for(i=0;i<40000;i=i+1)begin
            rst_n=(i%401>3);load=$urandom_range(0,7)==0;
            valid=$urandom_range(0,3)!=0;last=$urandom_range(0,7)==0;
            a=$urandom;b=$urandom;bias=$urandom;term=$urandom;
            if(i%11==0)begin bias=32'sh7fffffff;term=20'sh7ffff;end
            if(i%13==0)begin bias=32'sh80000000;term=20'sh80000;end
            if(i%17==0)begin a=25'sh1000000;b=18'sh20000;end
            // Independent arithmetic scoreboard: the input command retires
            // three edges later. This catches a shared wrapper latency bug
            // that a real/fast primitive lockstep alone cannot expose.
            if(!rst_n)begin math_acc=0;math_valid=0;math_last=0;end
            else if(load)math_acc={{16{bias[31]}},bias};
            else if(valid)math_acc=math_acc+{{28{term[19]}},term};
            @(posedge clk);#1;
            if(real_mul[0]!==fast_mul[0] || real_mul[1]!==fast_mul[1])
                $fatal(1,"FAST_DSP_MUL_MISMATCH cycle=%0d real0=%h fast0=%h real1=%h fast1=%h",i,real_mul[0],fast_mul[0],real_mul[1],fast_mul[1]);
            if({real_sum,real_overflow,real_valid,real_last}!=={fast_sum,fast_overflow,fast_valid,fast_last})
                $fatal(1,"FAST_DSP_ACC_MISMATCH cycle=%0d real=%h fast=%h valid=%b/%b last=%b/%b",i,real_sum,fast_sum,real_valid,fast_valid,real_last,fast_last);
            if(real_valid!==math_valid[2])
                $fatal(1,"DSP_RETIRE_VALID_MISMATCH cycle=%0d actual=%b expected=%b",i,real_valid,math_valid[2]);
            if(math_valid[2])begin
                if(real_sum!==math_result[2][31:0] ||
                   real_overflow!==(math_result[2]!={{16{math_result[2][31]}},math_result[2][31:0]}) ||
                   real_last!==math_last[2])
                    $fatal(1,"DSP_RETIRE_MATH_MISMATCH cycle=%0d actual=%h expected=%h overflow=%b last=%b/%b",
                        i,real_sum,math_result[2],real_overflow,real_last,math_last[2]);
                math_checks=math_checks+1;
            end
            for(j=2;j>0;j=j-1)math_result[j]=math_result[j-1];
            math_result[0]=math_acc;
            math_valid={math_valid[1:0],(rst_n && valid && !load)};
            math_last={math_last[1:0],(rst_n && last)};
            checked=checked+1;resets=resets+!rst_n;loads=loads+load;overflows=overflows+real_overflow;
            @(negedge clk);
        end
        if(resets<100 || loads<100 || overflows<10 || math_checks<20000)$fatal(1,"FAST_DSP_INSUFFICIENT_COVERAGE");
        $display("FAST_DSP_LOCKSTEP_PASS cycles=%0d mul_configs=2 accum=1 resets=%0d loads=%0d overflows=%0d math_checks=%0d",checked,resets,loads,overflows,math_checks);
        $finish;
    end
endmodule
