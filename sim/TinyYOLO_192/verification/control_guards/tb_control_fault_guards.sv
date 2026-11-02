`timescale 1ns/1ps
// Fault publication must keep its original edge and priority after factoring.
module tb_control_fault_guards;
    reg clk=0,rst_n=0,head_start=0,head_rsp_valid=0,head_rsp_error=0;
    always #2.083333333 clk=~clk;
    wire head_done;
    wire [31:0] head_error;
    tinyyolo_head_exact h(.clk(clk),.rst_n(rst_n),.start(head_start),
        .src(32'h00100000),.table_base(32'h00800000),.dst(32'h01000000),
        .ci(32'd256),.height(32'd1),.width(32'd1),
        .done(head_done),.error_code(head_error),.req_ready(1'b0),
        .rsp_valid(head_rsp_valid),.rsp_data(64'd0),.rsp_error(head_rsp_error));
    tinyyolo_allconv_control c(.clk(clk),.rst_n(rst_n),
        .s_awaddr(8'd0),.s_awvalid(1'b0),.s_wdata(32'd0),.s_wstrb(4'hf),
        .s_wvalid(1'b0),.s_bready(1'b1),.s_araddr(8'd0),.s_arvalid(1'b0),.s_rready(1'b1),
        .req_ready(1'b0),.rsp_valid(1'b0),.rsp_data(64'd0),.rsp_error(1'b0),
        .hp_bursts(32'd0),.hp_beats(32'd0),.hp_input_hits(32'd0),.hp_weight_hits(32'd0),
        .hp_misses(32'd0),.hp_idle(1'b1),.profile_rdata(32'd0));
    integer checked=0,i;
    task automatic reset_all;
        begin
            @(negedge clk);rst_n=0;head_start=0;head_rsp_valid=0;head_rsp_error=0;
            repeat(4)@(negedge clk);rst_n=1;
            repeat(3)@(negedge clk);
        end
    endtask
    task automatic expect_head(input integer code);
        begin
            @(posedge clk);#0.1;
            if(h.state!==(28'd1<<22) || head_done!==1 || head_error!==code)
                $fatal(1,"head fault edge/priority code=%0d actual=%0d state=%h done=%b",
                    code,head_error,h.state,head_done);
            checked=checked+1;
            @(negedge clk);head_rsp_valid=0;head_rsp_error=0;
            head_start=1;
            @(posedge clk);#0.1;
            if(head_error!==0 || h.state!==(28'd1<<27))
                $fatal(1,"head restart did not clear fault");
            checked=checked+1;
        end
    endtask
    initial begin
        reset_all();
        // Probe every physical one-hot bit without advancing unrelated states.
        for(i=0;i<64;i=i+1)begin
            c.state=64'd1<<i;#0.01;
            if(c.invalid_state!==0)$fatal(1,"main presence bit=%0d",i);
            checked=checked+1;
        end
        c.state=64'd1;
        for(i=0;i<28;i=i+1)begin
            h.state=28'd1<<i;#0.01;
            if(h.invalid_state!==0)$fatal(1,"head presence bit=%0d",i);
            checked=checked+1;
        end
        h.state=0;expect_head(5);
        reset_all();h.state=0;h.rsp_ready=1;head_rsp_valid=1;head_rsp_error=1;
        expect_head(3);
        reset_all();h.state=28'd1<<1;h.config_bad=1;expect_head(1);
        reset_all();h.state=28'd1<<3;h.region_bad=1;expect_head(4);
        reset_all();h.state=28'd1<<15;
        force h.add_done=1'b1;force h.add_error=1'b1;
        expect_head(8);release h.add_done;release h.add_error;
        reset_all();h.state=28'd1<<18;
        force h.cast_done=1'b1;force h.cast_error=1'b1;
        expect_head(9);release h.cast_done;release h.cast_error;
        reset_all();c.state=0;
        @(posedge clk);#0.1;
        if(c.state!==(64'd1<<34) || c.error_code!==5)
            $fatal(1,"main zero state detection changed");
        checked=checked+1;
        @(negedge clk);c.clear_req=1;
        @(posedge clk);#0.1;
        if(c.state!==64'd1 || c.error_code!==0)$fatal(1,"main clear priority");
        checked=checked+1;
        reset_all();c.state=0;c.response_error_pending=1;
        @(posedge clk);#0.1;
        if(c.state!==(64'd1<<34) || c.error_code!==3)
            $fatal(1,"main bus error priority");
        checked=checked+1;
        reset_all();c.state=0;c.clear_req=1;c.response_error_pending=1;
        @(posedge clk);#0.1;
        if(c.state!==64'd1 || c.error_code!==0)$fatal(1,"main simultaneous clear");
        checked=checked+1;
        $display("CONTROL_FAULT_GUARDS_PASS checks=%0d immediate_zero_fault=1 bus_priority=1 restart=1",checked);
        $finish;
    end
    initial begin #100000;$fatal(1,"fault guard watchdog");end
endmodule
