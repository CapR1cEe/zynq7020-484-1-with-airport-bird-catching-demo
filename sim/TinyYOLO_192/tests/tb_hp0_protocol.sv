`timescale 1ns/1ps
module tb_hp0_protocol;
    reg clk=0,rst_n=0,invalidate=0;
    always #2.083333333 clk=~clk;
    reg req_valid=0,req_write=0,rsp_ready=0;
    wire req_ready,rsp_valid,rsp_error,idle;
    reg [31:0] req_addr=0,req_low=0,req_high=0;
    reg [1:0] req_kind=0;
    wire [63:0] rsp_data;
    wire [31:0] araddr,awaddr;
    wire [3:0] arlen;
    wire arvalid,rready,awvalid,wvalid,bready;
    wire [63:0] wdata;
    wire [7:0] wstrb;
    reg arready=1,awready=0,wready=0,rvalid=0,rlast=0,bvalid=0;
    reg [63:0] rdata=0;
    reg [5:0] rid=0,bid=0;
    reg [1:0] rresp=0,bresp=0;
    wire [31:0] read_bursts,read_beats,input_hits,weight_hits,read_misses;
    tinyyolo_hp0_burst_cache dut(.*,.req_wdata(64'hfedcba9876543210),.req_wstrb(8'h5a));
    function automatic [63:0] pattern(input [31:0] address);
        pattern={address ^ 32'h55aa55aa,address ^ 32'h01234567};
    endfunction
    integer cases=0,transactions=0;
    always @(posedge clk) if(rst_n && arvalid && arready) transactions<=transactions+1;
    task automatic wait_idle;
        integer n;
        begin
            n=0;
            while(!idle && n<4200) begin @(negedge clk);n=n+1;end
            if(!idle)$fatal(1,"HP idle timeout state=%0d",dut.state);
        end
    endtask
    task automatic submit(input [31:0] address,low,high,input [1:0] kind,input bit wr);
        begin
            wait_idle();@(negedge clk);
            req_addr=address;req_low=low;req_high=high;req_kind=kind;req_write=wr;req_valid=1;
            do @(posedge clk);while(!req_ready);
            @(negedge clk);req_valid=0;
        end
    endtask
    task automatic response(input bit error,input [63:0] data,input bit check_data);
        reg [63:0] held;
        integer n;
        begin
            n=0;
            while(!rsp_valid && n<100)begin @(negedge clk);n=n+1;end
            if(!rsp_valid || rsp_error!==error)$fatal(1,"response/error mismatch case=%0d",cases);
            if(check_data && rsp_data!==data)$fatal(1,"return data mismatch case=%0d got=%h expected=%h",cases,rsp_data,data);
            held=rsp_data;
            repeat(9)begin
                @(negedge clk);
                if(!rsp_valid || rsp_data!==held || rsp_error!==error || idle || req_ready)
                    $fatal(1,"HP response changed under backpressure");
            end
            rsp_ready=1;@(negedge clk);rsp_ready=0;
            wait_idle();cases=cases+1;
        end
    endtask
    // Modes: 0 success; 1 RID; 2 RRESP; 3 early last; 4 late last;
    // 5 invalidate while filling. A poison must never publish a valid tag.
    task automatic read_case(input [31:0] address,low,high,input [1:0] kind,
                             input integer mode,input integer expected_len);
        reg [31:0] base;
        integer n,count,actual_count;
        begin
            submit(address,low,high,kind,0);n=0;
            while(!arvalid && n<40)begin @(negedge clk);n=n+1;end
            if(!arvalid || arlen+1!=expected_len)$fatal(1,"missing/wrong AR case=%0d len=%0d",cases,arlen+1);
            base=araddr;count=arlen+1;
            if(base<low || base+8*count>high || base[11:0]+8*count>4096)$fatal(1,"burst escaped bounds");
            @(posedge clk);@(negedge clk);
            actual_count=mode==3?1:(mode==4?count+2:count);
            for(n=0;n<actual_count;n=n+1)begin
                // No bubbles on most beats: test the registered READY/skid.
                if(n==2)repeat(3)@(negedge clk);
                rvalid=1;rdata=pattern(base+n*8);rid=mode==1 && n==0?6'd3:6'd0;
                rresp=mode==2 && n==count-1?2'd2:2'd0;
                rlast=n==actual_count-1;
                if(mode==5 && n==0)invalidate=1;
                do @(posedge clk);while(!rready);
                @(negedge clk);rvalid=0;invalidate=0;
                if(mode==4 && n==count-1)begin
                    repeat(12)begin
                        @(negedge clk);
                        if(rsp_valid || idle || req_ready)$fatal(1,"missing RLAST released transaction");
                    end
                end
            end
            rid=0;rresp=0;rlast=0;
            response(mode>=1 && mode<=4,pattern(address),mode==0 || mode==5);
        end
    endtask
    task automatic cache_hit(input [31:0] address,low,high,input [1:0] kind);
        integer before_ar;
        begin
            before_ar=transactions;submit(address,low,high,kind,0);
            response(0,pattern(address),1);
            if(transactions!=before_ar)$fatal(1,"expected cache hit issued AR");
        end
    endtask
    task automatic write_case(input integer order,input [5:0] id,input [1:0] resp);
        bit aw_done,w_done;
        integer cycle;
        begin
            submit(32'h101018,32'h101000,32'h101040,2,1);
            aw_done=0;w_done=0;cycle=0;
            while(!(aw_done && w_done) && cycle<30)begin
                @(negedge clk);awready=order!=0 || cycle>7;wready=order!=1 || cycle>7;
                @(posedge clk);
                if(awvalid && awready)begin
                    if(awaddr!=32'h101018)$fatal(1,"wrong AW");aw_done=1;
                end
                if(wvalid && wready)begin
                    if(wdata!==64'hfedcba9876543210 || wstrb!==8'h5a)$fatal(1,"wrong W");w_done=1;
                end
                cycle=cycle+1;
            end
            if(!aw_done || !w_done)$fatal(1,"write handshake timeout");
            @(negedge clk);awready=0;wready=0;bid=id;bresp=resp;bvalid=1;
            do @(posedge clk);while(!bready);
            @(negedge clk);bvalid=0;bid=0;bresp=0;
            response(id!=0 || resp!=0,0,0);
        end
    endtask
    // Reset on the edge that retires a private RAM token. The old contents
    // must remain invisible: the next request must miss and refill all beats.
    task automatic reset_private_pending(input [1:0] cache_kind);
        reg [31:0] base;
        integer n,limit;
        begin
            base=32'h108000+cache_kind*32'h1000;
            submit(base,base,base+64,cache_kind,0);
            wait(arvalid);@(posedge clk);@(negedge clk);
            limit=cache_kind==1?1:8;
            for(n=0;n<limit;n=n+1)begin
                rvalid=1;rlast=n==7;rdata=pattern(base+n*8);
                do @(posedge clk);while(!rready);
                @(negedge clk);rvalid=0;
            end
            n=0;
            while(!(cache_kind==1?dut.fill_weight_valid:
                    (dut.tag_write_pending && (|dut.tag_write_data_q[22:15]))) && n<40)begin
                @(negedge clk);n=n+1;
            end
            if(n==40)$fatal(1,"missing pending private cache write kind=%0d",cache_kind);
            rst_n=0;rlast=0;
            repeat(4)@(negedge clk);
            if(rsp_valid || req_ready)$fatal(1,"private fill survived reset kind=%0d",cache_kind);
            rst_n=1;wait_idle();
            if(rsp_valid)$fatal(1,"private fill produced stale response kind=%0d",cache_kind);
            read_case(base,base,base+64,cache_kind,0,8);
            cache_hit(base+56,base,base+64,cache_kind);
        end
    endtask
    integer mode,before_ar;
    initial begin
        repeat(30)@(negedge clk);rst_n=1;wait_idle();
        // Full/partial lines, page edge, every beat selected, input and weight.
        read_case('h101018,'h101000,'h101040,2,0,8);
        cache_hit('h101000,'h101000,'h101040,2);
        cache_hit('h101038,'h101000,'h101040,2);
        read_case('h102ff8,'h102ff0,'h103000,2,0,2);
        cache_hit('h102ff0,'h102ff0,'h103000,2);
        read_case('h102fe8,'h102fc0,'h103000,2,0,8); // absent bit in shortened mask
        read_case('h103020,'h103000,'h103040,1,0,8);
        cache_hit('h103038,'h103000,'h103040,1);
        read_case('h104008,'h104000,'h104010,0,0,1);
        for(mode=1;mode<=4;mode=mode+1)begin
            read_case('h105000+mode*64,'h105000+mode*64,'h105040+mode*64,2,mode,8);
            read_case('h105000+mode*64,'h105000+mode*64,'h105040+mode*64,2,0,8);
        end
        read_case('h106018,'h106000,'h106040,2,5,8);
        read_case('h106018,'h106000,'h106040,2,0,8); // invalidate was deferred and completed
        write_case(0,0,0);write_case(1,0,0);write_case(2,1,0);write_case(2,0,2);
        read_case('h101018,'h101000,'h101040,2,0,8);
        // Invalid request must stop before native AXI and before serving a hit.
        before_ar=transactions;submit('h101019,'h101000,'h101040,2,0);response(1,0,0);
        submit('h101018,'h101020,'h101040,2,0);response(1,0,0);
        if(transactions!=before_ar)$fatal(1,"invalid request issued AR");
        // System reset clears a buffered read response and its cache-fill token.
        submit('h107000,'h107000,'h107040,2,0);
        wait(arvalid);@(posedge clk);@(negedge clk);
        rvalid=1;rlast=0;rdata=pattern('h107000);
        do @(posedge clk);while(!rready);
        @(negedge clk);rvalid=0;rst_n=0;
        repeat(4)@(negedge clk);rst_n=1;wait_idle();
        if(rsp_valid)$fatal(1,"stale response survived system reset");
        read_case('h107000,'h107000,'h107040,2,0,8);
        reset_private_pending(1);
        reset_private_pending(2);
        $display("HP0_PROTOCOL_PASS cases=%0d poison_modes=4 late_RLAST_drain=1 deferred_invalidate=1 reset_flush=1 reset_private_pending=2",cases);
        $finish;
    end
    initial begin #2000000;$fatal(1,"HP protocol watchdog");end
endmodule
