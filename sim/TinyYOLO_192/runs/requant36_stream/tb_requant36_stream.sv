`timescale 1ns/1ps
module tb_requant36_stream;
    reg clk=0;
    always #2.083333333 clk=~clk;
    reg rst_n=0,in_valid=0;
    reg signed [31:0] accumulator=0;
    reg [35:0] multiplier=0;
    reg [5:0] shift=1;
    reg signed [7:0] zero_point=0;
    reg [7:0] in_tag=0;
    wire out_valid;
    wire signed [7:0] result;
    wire [7:0] out_tag;
    tinyyolo_requant36_stream #(.TAG_BITS(8)) dut(.*);
    reg [13:0] expect_valid=0;
    reg [7:0] expect_result[0:13],expect_tag[0:13];
    reg [67:0] expect_product[0:13];
    reg [7:0] next_result;
    reg [67:0] next_product;
    integer source,count=0,checks=0,products=0,cycle=0,fields,j;
    always @(posedge clk)begin
        for(j=13;j>0;j=j-1)begin
            expect_result[j]=expect_result[j-1];expect_tag[j]=expect_tag[j-1];
            expect_product[j]=expect_product[j-1];
        end
        expect_result[0]=next_result;expect_tag[0]=in_tag;expect_product[0]=next_product;
        if(!rst_n)expect_valid=0;
        else expect_valid={expect_valid[12:0],in_valid};
        #1;
        if(out_valid!==expect_valid[13])$fatal(1,"REQUANT_VALID cycle=%0d",cycle);
        if(expect_valid[9])begin
            if(dut.product!==expect_product[9])
                $fatal(1,"REQUANT_PRODUCT cycle=%0d expected=%h actual=%h",cycle,expect_product[9],dut.product);
            products=products+1;
        end
        if(out_valid)begin
            if(result!==expect_result[13] || out_tag!==expect_tag[13])
                $fatal(1,"REQUANT_STREAM cycle=%0d expected=%h,%h actual=%h,%h",cycle,
                    expect_result[13],expect_tag[13],result,out_tag);
            checks=checks+1;
        end
        cycle=cycle+1;
    end
    initial begin
        source=$fopen("vectors.txt","r");
        if(!source)$fatal(1,"VECTORS_MISSING");
        repeat(16)@(negedge clk);
        while(!$feof(source))begin
            // Dense runs prove II=1. Reset also interrupts full, dense pipes;
            // a valid token on the first release clock must still survive.
            @(negedge clk);
            fields=$fscanf(source,"%h %h %d %h %h %h\n",accumulator,multiplier,shift,
                zero_point,next_result,next_product);
            if(fields!=6)$fatal(1,"VECTOR_SYNTAX");
            rst_n=count%257>=3;
            in_valid=count%97<80 || count%3!=0;
            in_tag=count;
            count=count+1;
        end
        @(negedge clk);in_valid=0;rst_n=1;
        repeat(32)@(negedge clk);
        if(count<30833 || checks<count*8/10 || products<count*8/10)
            $fatal(1,"REQUANT_COVERAGE count=%0d checks=%0d products=%0d",count,checks,products);
        $display("REQUANT36_STREAM_PASS vectors=%0d results=%0d products=%0d latency=14 II=1",count,checks,products);
        $finish;
    end
    initial begin #100000000; $fatal(1,"REQUANT_TIMEOUT"); end
endmodule
