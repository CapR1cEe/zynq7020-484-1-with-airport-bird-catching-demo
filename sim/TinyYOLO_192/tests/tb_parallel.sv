`timescale 1ns/1ps
module tb_parallel;
    integer feature_options=0,expected_writes,oc2,mode;
    integer out_n,out_plane,out_index,raw_index,iy,ix;
    reg signed [7:0] pool_golden,pool_candidate;
    reg [7:0] expected_byte;
    reg clk=0,rst_n=0;
    always #2.083333333 clk=~clk;
    reg [7:0] s_awaddr=0,s_araddr=0;
    reg [31:0] s_wdata=0;
    reg s_awvalid=0,s_wvalid=0,s_arvalid=0;
    reg s_rready=0;
    wire s_awready,s_wready,s_bvalid,s_arready,s_rvalid;
    wire [1:0] s_bresp,s_rresp;
    wire [31:0] s_rdata;
    wire [31:0] araddr,awaddr;
    wire [3:0] arlen;
    wire arvalid,rready,awvalid,wvalid,bready,wlast;
    wire [63:0] wdata;
    wire [7:0] wstrb;
    reg arready=0,awready=0,wready=0,rvalid=0,rlast=0,bvalid=0;
    reg [63:0] rdata;
    reg [1:0] rresp=0;
    reg inject_error=0;
    tinyyolo_allconv_closed_loop dut (
        .s00_axi_aclk(clk),.s00_axi_aresetn(rst_n),
        .s00_axi_awaddr(s_awaddr),.s00_axi_awvalid(s_awvalid),.s00_axi_awready(s_awready),
        .s00_axi_wdata(s_wdata),.s00_axi_wstrb(4'hf),.s00_axi_wvalid(s_wvalid),.s00_axi_wready(s_wready),
        .s00_axi_bresp(s_bresp),.s00_axi_bvalid(s_bvalid),.s00_axi_bready(1'b1),
        .s00_axi_araddr(s_araddr),.s00_axi_arvalid(s_arvalid),.s00_axi_arready(s_arready),
        .s00_axi_rdata(s_rdata),.s00_axi_rresp(s_rresp),.s00_axi_rvalid(s_rvalid),.s00_axi_rready(s_rready),
        .m_axi_awaddr(awaddr),.m_axi_awvalid(awvalid),.m_axi_awready(awready),
        .m_axi_wdata(wdata),.m_axi_wstrb(wstrb),.m_axi_wlast(wlast),.m_axi_wvalid(wvalid),.m_axi_wready(wready),
        .m_axi_bid(6'd0),.m_axi_bresp(2'd0),.m_axi_bvalid(bvalid),.m_axi_bready(bready),
        .m_axi_araddr(araddr),.m_axi_arlen(arlen),.m_axi_arvalid(arvalid),.m_axi_arready(arready),
        .m_axi_rdata(rdata),.m_axi_rid(6'd0),.m_axi_rresp(rresp),.m_axi_rlast(rlast),.m_axi_rvalid(rvalid),.m_axi_rready(rready));
    reg [7:0] mem[0:262143];
    reg [31:0] golden_acc[0:1023];
    reg [7:0] golden_q[0:1023];
    reg read_active=0,have_aw=0,have_w=0;
    reg [31:0] read_addr,write_addr;
    reg [63:0] write_data;
    reg [7:0] write_strb;
    integer beats=0,bus_reads=0,bus_writes=0,b;
    always @(posedge clk) begin
        if(!rst_n) begin
            arready<=0;awready<=0;wready<=0;rvalid<=0;bvalid<=0;
            read_active<=0;have_aw<=0;have_w<=0;
        end else begin
            arready<=!read_active && $urandom_range(0,3)!=0;
            awready<=!have_aw && !bvalid && $urandom_range(0,3)!=0;
            wready<=!have_w && !bvalid && $urandom_range(0,3)!=0;
            if(arvalid && arready) begin
                if(araddr<32'h100000 || araddr+8*(arlen+1)>32'h140000) $fatal(1,"read out of test RAM");
                read_active<=1;read_addr<=araddr;beats<=arlen+1;arready<=0;
                bus_reads<=bus_reads+1;
            end
            if(read_active && !rvalid && $urandom_range(0,3)!=0) begin
                for(b=0;b<8;b=b+1) rdata[b*8+:8]<=mem[read_addr-32'h100000+b];
                rvalid<=1;rlast<=beats==1;rresp<=inject_error?2'b10:2'b00;
            end
            if(rvalid && rready) begin
                rvalid<=0;read_addr<=read_addr+8;beats<=beats-1;
                if(beats==1)read_active<=0;
            end
            if(awvalid && awready) begin have_aw<=1;write_addr<=awaddr;awready<=0;end
            if(wvalid && wready) begin have_w<=1;write_data<=wdata;write_strb<=wstrb;wready<=0;end
            if(have_aw && have_w && !bvalid && $urandom_range(0,3)!=0) begin
                if(write_addr<32'h100000 || write_addr+8>32'h140000) $fatal(1,"write out of test RAM");
                for(b=0;b<8;b=b+1) if(write_strb[b])mem[write_addr-32'h100000+b]<=write_data[b*8+:8];
                have_aw<=0;have_w<=0;bvalid<=1;bus_writes<=bus_writes+1;
            end
            if(bvalid && bready)bvalid<=0;
        end
    end
    task automatic put(input [7:0] address,input [31:0] value);
        begin
            @(negedge clk);s_awaddr=address;s_wdata=value;s_awvalid=1;s_wvalid=1;
            fork
                begin do @(posedge clk);while(!s_awready);@(negedge clk);s_awvalid=0;end
                begin do @(posedge clk);while(!s_wready);@(negedge clk);s_wvalid=0;end
            join
            do @(posedge clk);while(!s_bvalid);
            @(negedge clk);
            if(s_bresp!=0)$fatal(1,"AXI-Lite write error");
        end
    endtask
    task automatic get(input [7:0] address,output [31:0] value);
        integer stall;
        begin
            @(negedge clk);s_araddr=address;s_arvalid=1;s_rready=0;
            do @(posedge clk);while(!s_arready);
            // AR payload may change after acceptance. R data must retain the
            // accepted address and remain stable throughout random stalls.
            @(negedge clk);s_arvalid=0;s_araddr=~address;
            do @(posedge clk);while(!s_rvalid);
            value=s_rdata;
            for(stall=$urandom_range(0,4);stall>0;stall=stall-1)begin
                @(negedge clk);
                if(!s_rvalid || s_rdata!==value || s_rresp!=0)$fatal(1,"AXI-Lite read response changed under backpressure");
            end
            @(negedge clk);s_rready=1;
            @(posedge clk);
            if(!s_rvalid || s_rdata!==value)$fatal(1,"AXI-Lite read response lost");
            @(negedge clk);s_rready=0;
        end
    endtask
    task automatic idle;
        reg [31:0] value;
        integer tries;
        begin
            value=0;tries=0;
            while(value!=1 && tries<5000) begin get(8'h84,value);tries=tries+1;end
            if(value!=1)$fatal(1,"HP pipeline did not drain");
        end
    endtask
    task automatic terminal(output [31:0] value);
        integer tries;
        begin
            tries=0;value=1;
            while(value==1 && tries<200000) begin
                repeat(8)@(negedge clk);get(4,value);tries=tries+1;
            end
            if(value!=2 && value!=4)$fatal(1,"controller timeout status=%h",value);
            idle();
        end
    endtask
    integer checked_cases=0,total_outputs=0,boundary_cases=0,boundary_outputs=0,config_guard_cases=0;
    task automatic run_case(input integer id,ci,co,h,w,k,pad,zx,zy);
        reg [31:0] st,value,observed;
        reg [31:0] count_low,count_high;
        reg [63:0] phase_total,cycle_total;
        integer i,n,ch;
        string name;
        begin
            idle();put(0,2);
            for(i=0;i<262144;i=i+1)mem[i]=8'ha5;
            name=$sformatf("closedloop_vectors/case%02d.mem",id);$readmemh(name,mem);
            for(i=0;i<256;i=i+1)mem['h1e000+i]=((i*i+7*i)%256)^128;
            put(8'h44,feature_options);put(8'h4c,32'h11e000);
            n=co*h*w;ch=(ci*k*k+23)/24;
            name=$sformatf("closedloop_vectors/case%02d.acc",id);$readmemh(name,golden_acc,0,n-1);
            name=$sformatf("closedloop_vectors/case%02d.q",id);$readmemh(name,golden_q,0,n-1);
            put(8,32'h100000);put(12,32'h108000);put(16,32'h118000);
            put(20,32'h119000);put(24,32'h11a000);put(28,32'h120000);put(32,32'h130000);
            put(36,ci);put(40,co);put(44,h);put(48,w);put(52,k);put(56,pad);put(60,zx);put(64,zy);
            put(0,1);terminal(st);
            get(8'h44,value);
            if(st!=2 || value!=0)$fatal(1,"closed loop case=%0d status=%h error=%h",id,st,value);
            for(i=0;i<n;i=i+1) begin
                observed={mem['h20000+i*4+3],mem['h20000+i*4+2],mem['h20000+i*4+1],mem['h20000+i*4]};
                if((!(feature_options&1) && observed!==golden_acc[i]) || ((feature_options&1) && observed!==32'ha5a5a5a5))$fatal(1,"acc case=%0d index=%0d expected=%h actual=%h",id,i,golden_acc[i],observed);
                expected_byte=(feature_options&2)?mem['h1e000+(golden_q[i]^8'h80)]:golden_q[i];
                if(!(feature_options&64) && mem['h30000+i]!==expected_byte)$fatal(1,"q case=%0d index=%0d expected=%h actual=%h",id,i,golden_q[i],mem['h30000+i]);
            end
            out_n=(feature_options&64)?n/4:n;
            if(feature_options&64) begin
                out_plane=h*w/4;
                for(out_index=0;out_index<out_n;out_index=out_index+1) begin
                    raw_index=(out_index/out_plane)*h*w+(out_index%out_plane/(w/2))*2*w+(out_index%(w/2))*2;
                    pool_golden=-128;
                    for(iy=0;iy<2;iy=iy+1)for(ix=0;ix<2;ix=ix+1)begin
                        pool_candidate=mem['h1e000+(golden_q[raw_index+iy*w+ix]^8'h80)];
                        if(pool_candidate>pool_golden)pool_golden=pool_candidate;
                    end
                    if(mem['h30000+out_index]!==pool_golden)$fatal(1,"pooled q mismatch case=%0d index=%0d expected=%h actual=%h",id,out_index,pool_golden,mem['h30000+out_index]);
                end
            end
            if(mem['h20000-1]!=8'ha5 || mem['h20000+n*4]!=8'ha5 || mem['h30000-1]!=8'ha5 || mem['h30000+out_n]!=8'ha5)$fatal(1,"write guard changed");
            get(8'h60,value);if(value!=n)$fatal(1,"output count mismatch");
            expected_writes=(feature_options&1)?0:n;
            if(feature_options&32)for(oc2=0;oc2<co;oc2=oc2+1)expected_writes=expected_writes+((oc2+1)*(out_n/co)-1)/8-(oc2*(out_n/co))/8+1;
            else expected_writes=expected_writes+out_n;
            get(8'h58,value);if(value!=expected_writes)$fatal(1,"write count mismatch");
            get(8'h5c,value);if(value!=n*ch)$fatal(1,"MAC count mismatch");
            get(8'h48,count_low);get(8'h50,count_high);cycle_total={count_high,count_low};
            phase_total=0;
            for(i=0;i<8;i=i+1)begin
                get(8'h88+i*8,count_low);get(8'h8c+i*8,count_high);
                phase_total=phase_total+{count_high,count_low};
            end
            if(phase_total!==cycle_total)$fatal(1,"profile phase sum differs from busy cycles");
            $display("PARALLEL_CASE_PASS case=%0d options=%0d cycles=%0d ci=%0d co=%0d h=%0d w=%0d k=%0d outputs=%0d",id,feature_options,cycle_total,ci,co,h,w,k,n);
            for(i=0;i<8;i=i+1)begin
                get(8'h88+i*8,count_low);get(8'h8c+i*8,count_high);
                $display("PARALLEL_PHASE case=%0d options=%0d phase=%0d cycles=%0d",id,feature_options,i,{count_high,count_low});
            end
            get(0,value);if((id==41) && (feature_options&8) && value==0)$fatal(1,"zero chunk compaction did not skip work");
            checked_cases=checked_cases+1;total_outputs=total_outputs+n;
            put(8'h44,0);
        end
    endtask

    initial begin
        repeat(6)@(negedge clk);rst_n=1;
        feature_options=0;
        run_case(30,3,7,2,5,1,0,0,-7);
        run_case(31,17,8,4,6,3,1,0,-7);
        run_case(32,17,9,4,6,3,1,0,-7);
        run_case(33,64,31,2,4,3,1,0,-7);
        run_case(34,129,32,1,1,3,1,0,-7);
        run_case(35,64,33,2,4,3,1,0,-7);
        run_case(36,64,65,2,4,1,0,0,-7);
        run_case(37,512,8,1,1,3,1,0,-7);
        run_case(38,1024,32,1,1,1,0,0,-7);
        run_case(39,17,33,4,6,3,1,0,-7);
        run_case(40,64,64,4,4,3,1,0,-7);
        run_case(41,64,33,2,4,1,0,0,-7);
        feature_options=48;
        run_case(30,3,7,2,5,1,0,0,-7);
        run_case(31,17,8,4,6,3,1,0,-7);
        run_case(32,17,9,4,6,3,1,0,-7);
        run_case(33,64,31,2,4,3,1,0,-7);
        run_case(34,129,32,1,1,3,1,0,-7);
        run_case(35,64,33,2,4,3,1,0,-7);
        run_case(36,64,65,2,4,1,0,0,-7);
        run_case(37,512,8,1,1,3,1,0,-7);
        run_case(38,1024,32,1,1,1,0,0,-7);
        run_case(39,17,33,4,6,3,1,0,-7);
        run_case(40,64,64,4,4,3,1,0,-7);
        run_case(41,64,33,2,4,1,0,0,-7);
        feature_options=56;
        run_case(30,3,7,2,5,1,0,0,-7);
        run_case(31,17,8,4,6,3,1,0,-7);
        run_case(32,17,9,4,6,3,1,0,-7);
        run_case(33,64,31,2,4,3,1,0,-7);
        run_case(34,129,32,1,1,3,1,0,-7);
        run_case(35,64,33,2,4,3,1,0,-7);
        run_case(36,64,65,2,4,1,0,0,-7);
        run_case(37,512,8,1,1,3,1,0,-7);
        run_case(38,1024,32,1,1,1,0,0,-7);
        run_case(39,17,33,4,6,3,1,0,-7);
        run_case(40,64,64,4,4,3,1,0,-7);
        run_case(41,64,33,2,4,1,0,0,-7);
        feature_options=98;
        run_case(31,17,8,4,6,3,1,0,-7);
        run_case(32,17,9,4,6,3,1,0,-7);
        run_case(33,64,31,2,4,3,1,0,-7);
        run_case(35,64,33,2,4,3,1,0,-7);
        run_case(36,64,65,2,4,1,0,0,-7);
        run_case(39,17,33,4,6,3,1,0,-7);
        run_case(40,64,64,4,4,3,1,0,-7);
        run_case(41,64,33,2,4,1,0,0,-7);
        feature_options=114;
        run_case(31,17,8,4,6,3,1,0,-7);
        run_case(32,17,9,4,6,3,1,0,-7);
        run_case(33,64,31,2,4,3,1,0,-7);
        run_case(35,64,33,2,4,3,1,0,-7);
        run_case(36,64,65,2,4,1,0,0,-7);
        run_case(39,17,33,4,6,3,1,0,-7);
        run_case(40,64,64,4,4,3,1,0,-7);
        run_case(41,64,33,2,4,1,0,0,-7);
        feature_options=122;
        run_case(31,17,8,4,6,3,1,0,-7);
        run_case(32,17,9,4,6,3,1,0,-7);
        run_case(33,64,31,2,4,3,1,0,-7);
        run_case(35,64,33,2,4,3,1,0,-7);
        run_case(36,64,65,2,4,1,0,0,-7);
        run_case(39,17,33,4,6,3,1,0,-7);
        run_case(40,64,64,4,4,3,1,0,-7);
        run_case(41,64,33,2,4,1,0,0,-7);
        $display("PARALLEL_PASS cases=%0d outputs=%0d",checked_cases,total_outputs);$finish;
    end
    always @(posedge clk) if(rst_n) begin
        if($isunknown(dut.u_control.state) || !$onehot(dut.u_control.state))
            $fatal(1,"FSM_ONEHOT_INVARIANT_FAILED");
    end
endmodule
