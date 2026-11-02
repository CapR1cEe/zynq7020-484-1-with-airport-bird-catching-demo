`timescale 1ns/1ps
// Exercise full legal spatial magnitude without simulating 173056 pixels.
// DDR is permanently backpressured; only pre-transaction size guards run.
module tb_size_pipeline;
    reg clk=0,rst_n=0;
    always #2.083333333 clk=~clk;
    reg [7:0] awaddr=0,araddr=0;
    reg [31:0] wdata=0;
    reg awvalid=0,wvalid=0;
    wire awready,wready,bvalid,req_valid;
    tinyyolo_allconv_control dut(.clk(clk),.rst_n(rst_n),
        .s_awaddr(awaddr),.s_awvalid(awvalid),.s_awready(awready),
        .s_wdata(wdata),.s_wstrb(4'hf),.s_wvalid(wvalid),.s_wready(wready),
        .s_bvalid(bvalid),.s_bready(1'b1),.s_araddr(araddr),.s_arvalid(1'b0),.s_rready(1'b1),
        .req_valid(req_valid),.req_ready(1'b0),.rsp_valid(1'b0),.rsp_data(64'd0),.rsp_error(1'b0),
        .hp_bursts(32'd0),.hp_beats(32'd0),.hp_input_hits(32'd0),.hp_weight_hits(32'd0),
        .hp_misses(32'd0),.hp_idle(1'b1),.profile_rdata(32'd0));
    task automatic put(input [7:0] address,input [31:0] value);
        begin
            @(negedge clk);awaddr=address;wdata=value;awvalid=1;wvalid=1;
            fork
                begin do @(posedge clk);while(!awready);@(negedge clk);awvalid=0;end
                begin do @(posedge clk);while(!wready);@(negedge clk);wvalid=0;end
            join
            do @(posedge clk);while(!bvalid);
            @(negedge clk);
        end
    endtask
    integer checked=0;
    task automatic run_case(input integer ci,co,h,w,k,input integer expect_fault);
        integer n,taps,chunks,cycles;
        begin
            @(negedge clk);rst_n=0;repeat(8)@(negedge clk);rst_n=1;
            put(8'h08,32'h00100000);put(8'h0c,32'h00800000);
            put(8'h10,32'h02000000);put(8'h14,32'h02010000);put(8'h18,32'h02020000);
            put(8'h1c,32'h10000000);put(8'h20,32'h11000000);
            put(8'h24,ci);put(8'h28,co);put(8'h2c,h);put(8'h30,w);
            put(8'h34,k);put(8'h38,k==3?1:0);put(8'h3c,0);put(8'h40,0);
            put(8'h44,0);put(8'h00,1);
            cycles=0;
            while(!req_valid && !dut.state[dut.FAULT] && cycles<300)begin
                @(negedge clk);cycles=cycles+1;
                if($isunknown(dut.state) || !$onehot(dut.state))$fatal(1,"size onehot");
            end
            if(cycles==300)$fatal(1,"size pipeline timeout");
            if(expect_fault)begin
                if(req_valid || dut.error_code!=2)$fatal(1,"derived size guard failed");
            end else begin
                n=h*w;taps=ci*k*k;chunks=(taps+23)/24;
                if(dut.state[dut.FAULT] || dut.plane!==n || dut.src_bytes!==n*ci ||
                   dut.q_bytes!==n*co || dut.acc_bytes!==n*co*4 || dut.weight_bytes!==co*chunks*24)
                    $fatal(1,"size product mismatch h=%0d w=%0d ci=%0d co=%0d plane=%0d src=%0d q=%0d acc=%0d weights=%0d",
                        h,w,ci,co,dut.plane,dut.src_bytes,dut.q_bytes,dut.acc_bytes,dut.weight_bytes);
            end
            checked=checked+1;
        end
    endtask
    initial begin
        repeat(30)@(negedge clk);
        run_case(1,1,416,416,1,0);
        run_case(1,1,155,845,1,0);
        run_case(512,1024,26,26,3,0);
        run_case(1024,1024,13,13,1,0);
        run_case(513,1,1,1,3,1);
        run_case(1024,1,1,1,3,1);
        run_case(1,1,416,845,1,1);
        $display("SIZE_PIPELINE_PASS cases=%0d full_plane=173056 signed_boundary=131072 hardware_access=0",checked);
        $finish;
    end
endmodule
