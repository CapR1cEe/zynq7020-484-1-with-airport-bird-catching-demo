`timescale 1ns/1ps
// Exhaust every legal head geometry before DDR, plus full-width bad inputs.
// Expected geometry uses the integer product, independent of RTL partials.
module tb_head_config;
    reg clk=0,rst_n=0,start=0;
    always #2.083333333 clk=~clk;
    reg [31:0] height=1,width=1,ci=256;
    reg [31:0] src=32'h00100000,table_base=32'h00800000,dst=32'h01000000;
    wire busy,done,req_valid,req_write;
    wire [31:0] error_code,req_addr,req_low,req_high;
    wire [63:0] req_wdata;
    wire [7:0] req_wstrb;
    wire [1:0] req_kind;
    tinyyolo_head_exact dut(.clk(clk),.rst_n(rst_n),.start(start),
        .src(src),.table_base(table_base),.dst(dst),.ci(ci),.height(height),.width(width),
        .busy(busy),.done(done),.error_code(error_code),
        .req_valid(req_valid),.req_ready(1'b0),.req_write(req_write),.req_addr(req_addr),
        .req_wdata(req_wdata),.req_wstrb(req_wstrb),.req_kind(req_kind),
        .req_low(req_low),.req_high(req_high),.rsp_valid(1'b0),.rsp_data(64'd0),.rsp_error(1'b0));
    integer valid_cases=0,invalid_cases=0,h,w;
    always @(posedge clk) if(rst_n)
        if($isunknown(dut.state) || !$onehot(dut.state))
            $fatal(1,"HEAD_FSM_ONEHOT_INVARIANT_FAILED");
    task automatic check(input [31:0] test_h,test_w,test_ci,input integer expected_error);
        integer cycles,expected_plane,stall;
        reg [63:0] held_payload;
        begin
            @(negedge clk);rst_n=0;start=0;
            repeat(3)@(negedge clk);
            height=test_h;width=test_w;ci=test_ci;rst_n=1;
            @(negedge clk);start=1;
            @(negedge clk);start=0;
            cycles=0;
            while(!req_valid && !done && cycles<16)begin
                @(negedge clk);cycles=cycles+1;
            end
            if(cycles==16)$fatal(1,"head config timeout h=%h w=%h ci=%h",test_h,test_w,test_ci);
            if(expected_error!=0)begin
                if(req_valid || busy || error_code!==expected_error)
                    $fatal(1,"bad head config accessed DDR h=%h w=%h ci=%h error=%0d",test_h,test_w,test_ci,error_code);
                invalid_cases=invalid_cases+1;
            end else begin
                expected_plane=test_h*test_w;
                if(!req_valid || req_write || error_code!=0 || !busy ||
                   dut.plane!==expected_plane || dut.last_pixel!==expected_plane-1 ||
                   dut.source_end!==({1'b0,src}+expected_plane*256) ||
                   dut.dest_end!==({1'b0,dst}+expected_plane*4))
                    $fatal(1,"head geometry mismatch h=%0d w=%0d plane=%0d",test_h,test_w,dut.plane);
                held_payload={req_addr,req_high};
                for(stall=0;stall<8;stall=stall+1)begin
                    @(negedge clk);
                    if(!req_valid || req_write || {req_addr,req_high}!==held_payload ||
                       req_low!==table_base || req_addr!==table_base ||
                       req_high!==table_base+32'd524352 || req_wdata!==0 || req_wstrb!==0 || req_kind!==0)
                        $fatal(1,"head initial request changed under backpressure");
                end
                valid_cases=valid_cases+1;
            end
        end
    endtask
    initial begin
        for(h=1;h<=26;h=h+1)
            for(w=1;w<=26;w=w+1)check(h,w,256,0);
        check(0,1,256,1);check(1,0,256,1);
        check(27,1,256,1);check(1,27,256,1);
        check(32'h80000001,1,256,1);check(1,32'h80000001,256,1);
        check(32'hffffffff,26,256,1);check(26,32'hffffffff,256,1);
        check(1,1,0,1);check(1,1,255,1);check(1,1,257,1);check(1,1,32'h80000100,1);
        src=32'h00100001;check(1,1,256,1);src=32'h00100000;
        table_base=32'h00800004;check(1,1,256,1);table_base=32'h00800000;
        dst=32'h01000004;check(1,1,256,1);dst=32'h01000000;
        src=dst;check(1,1,256,4);src=32'h00100000;
        dst=src+32'd128;check(1,1,256,4);dst=32'h01000000;
        table_base=dst;check(1,1,256,4);table_base=32'h00800000;
        dst=32'h1ffefff8;check(2,2,256,4);dst=32'h01000000;
        src=32'hffffff00;check(1,1,256,4);src=32'h00100000;
        table_base=32'hffffffc0;check(1,1,256,4);table_base=32'h00800000;
        src=32'h000ffff8;check(1,1,256,4);src=32'h00100000;
        table_base=32'h000ffff8;check(1,1,256,4);table_base=32'h00800000;
        dst=32'h000ffff8;check(1,1,256,4);dst=32'h01000000;
        // Equality is legal at the exclusive DDR limit and between regions.
        src=32'h1ffeff00;check(1,1,256,0);src=32'h00100000;
        dst=src+32'd256;check(1,1,256,0);dst=32'h01000000;
        table_base=dst+32'd8;check(1,1,256,0);
        $display("HEAD_CONFIG_PASS legal=%0d invalid=%0d backpressure_cycles=8 hardware_access=0",valid_cases,invalid_cases);
        $finish;
    end
    initial begin #1000000;$fatal(1,"head config watchdog");end
endmodule
