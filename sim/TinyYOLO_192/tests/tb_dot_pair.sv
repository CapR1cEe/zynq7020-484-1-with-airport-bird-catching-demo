`timescale 1ns/1ps
module tb_dot_pair;
 reg clk=0,rst_n=0,valid=0,last=0;
 always #2.083333333 clk=~clk;
 reg [127:0] a=0,w0=0,w1=0;
 wire ov,ol;wire signed [19:0] s0,s1;
 tinyyolo_dot16_pair dut(clk,rst_n,valid,last,a,w0,w1,ov,ol,s0,s1);
 integer e0[0:49999],e1[0:49999];reg el[0:49999];
 integer head=0,tail=0,i,n,t0,t1,checked=0;
 reg [12:0] valid_pipe=0,last_pipe=0;
 always @(posedge clk)begin
   if(!rst_n)begin head=0;tail=0;valid_pipe=0;last_pipe=0;end
   else begin
     valid_pipe={valid_pipe[11:0],valid};last_pipe={last_pipe[11:0],last};
     if(valid)begin
       t0=0;t1=0;
       for(i=0;i<16;i=i+1)begin
         t0=t0+$signed(a[i*8+:8])*$signed(w0[i*8+:8]);
         t1=t1+$signed(a[i*8+:8])*$signed(w1[i*8+:8]);
       end
       e0[tail]=t0;e1[tail]=t1;el[tail]=last;tail=tail+1;
     end
     #0.001;
     if(ov!==valid_pipe[12] || ol!==last_pipe[12])
       $fatal(1,"DOT16 latency mismatch: expected 13 clocks");
     if(ov)begin
       if(head>=tail || s0!==e0[head] || s1!==e1[head] || ol!==el[head])
         $fatal(1,"PAIR mismatch n=%0d got=%0d,%0d expect=%0d,%0d",checked,s0,s1,e0[head],e1[head]);
       head=head+1;checked=checked+1;
     end
   end
 end
 initial begin
   repeat(35)@(negedge clk);rst_n=1;
   for(n=0;n<40000;n=n+1)begin
     @(negedge clk);valid=$urandom_range(0,4)!=0;last=$urandom_range(0,9)==0;
     for(integer j=0;j<16;j=j+1)begin
       a[j*8+:8]=$urandom;w0[j*8+:8]=$urandom;w1[j*8+:8]=$urandom;
       if(n<8)begin a[j*8+:8]=n[0]?8'h80:8'h7f;w0[j*8+:8]=n[1]?8'h80:8'h7f;w1[j*8+:8]=n[2]?8'h80:8'h7f;valid=1;end
     end
     if(n%997==900)begin rst_n=0;valid=0;end
     if(n%997==905)rst_n=1;
   end
   @(negedge clk);valid=0;last=0;repeat(15)@(negedge clk);
   if(head!=tail)$fatal(1,"undrained pair pipeline");
   $display("PACKED_DOT_PAIR_PASS vectors=%0d signed_products=%0d reset_bubbles_last=PASS",checked,checked*32);$finish;
 end
 initial begin #300000000;$fatal(1,"pair timeout");end
endmodule
