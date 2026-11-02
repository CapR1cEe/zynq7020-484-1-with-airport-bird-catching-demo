`timescale 1ns/1ps
module tb_fp_exact;
reg clk=0,rst_n=0,start=0,cast_start=0;
always #2.083333333 clk=~clk;
reg [63:0] a,b,cv;
wire done,error,cd,ce;
wire [63:0] result;
wire [31:0] cr;
reg [191:0] vectors[0:10000-1];
reg [95:0] casts[0:6000-1];
integer i,t;
tinyyolo_fp64_add dut(.clk(clk),.rst_n(rst_n),.start(start),.a(a),.b(b),.done(done),.error(error),.result(result));
tinyyolo_fp64_to_fp32 conv(.clk(clk),.rst_n(rst_n),.start(cast_start),.value(cv),.done(cd),.error(ce),.result(cr));
initial begin
 $readmemh("fp_vectors/add.hex",vectors);$readmemh("fp_vectors/cast.hex",casts);
 repeat(5)@(negedge clk);rst_n=1;
 for(i=0;i<10000;i=i+1)begin
  @(negedge clk);a=vectors[i][191:128];b=vectors[i][127:64];start=1;
  @(negedge clk);start=0;t=0;
  while(!done && t<100)begin @(negedge clk);t=t+1;end
  if(!done || error || result!==vectors[i][63:0])$fatal(1,"ADD i=%0d a=%h b=%h got=%h want=%h error=%b",i,a,b,result,vectors[i][63:0],error);
 end
 for(i=0;i<6000;i=i+1)begin
  @(negedge clk);cv=casts[i][95:32];cast_start=1;
  @(negedge clk);cast_start=0;t=0;
  while(!cd && t<20)begin @(negedge clk);t=t+1;end
  if(!cd || cr!==casts[i][31:0] || ce!==(casts[i][30:23]==8'hff))$fatal(1,"CAST i=%0d value=%h got=%h want=%h error=%b",i,cv,cr,casts[i][31:0],ce);
 end
 $display("FP_EXACT_PASS add=10000 cast=6000");$finish;
end
endmodule
