`timescale 1ns/1ps
module tb_closedloop;
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
            @(negedge clk);s_awaddr=address;s_wdata=value;s_awvalid=0;s_wvalid=0;
            fork
                begin
                    repeat($urandom_range(0,4))@(negedge clk);s_awvalid=1;
                    do @(posedge clk);while(!s_awready);
                    @(negedge clk);s_awvalid=0;s_awaddr=~address;
                end
                begin
                    repeat($urandom_range(0,4))@(negedge clk);s_wvalid=1;
                    do @(posedge clk);while(!s_wready);
                    @(negedge clk);s_wvalid=0;s_wdata=~value;
                end
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
                if(observed!==golden_acc[i])$fatal(1,"acc case=%0d index=%0d expected=%h actual=%h",id,i,golden_acc[i],observed);
                if(mem['h30000+i]!==golden_q[i])$fatal(1,"q case=%0d index=%0d expected=%h actual=%h",id,i,golden_q[i],mem['h30000+i]);
            end
            if(mem['h20000-1]!=8'ha5 || mem['h20000+n*4]!=8'ha5 || mem['h30000-1]!=8'ha5 || mem['h30000+n]!=8'ha5)$fatal(1,"write guard changed");
            get(8'h60,value);if(value!=n)$fatal(1,"output count mismatch");
            get(8'h58,value);if(value!=2*n)$fatal(1,"write count mismatch");
            get(8'h5c,value);if(value!=n*ch)$fatal(1,"MAC count mismatch");
            get(8'h48,count_low);get(8'h50,count_high);cycle_total={count_high,count_low};
            phase_total=0;
            for(i=0;i<8;i=i+1)begin
                get(8'h88+i*8,count_low);get(8'h8c+i*8,count_high);
                phase_total=phase_total+{count_high,count_low};
            end
            if(phase_total!==cycle_total)$fatal(1,"profile phase sum differs from busy cycles");
            $display("CLOSEDLOOP_CASE_PASS case=%0d ci=%0d co=%0d h=%0d w=%0d k=%0d outputs=%0d",id,ci,co,h,w,k,n);
            checked_cases=checked_cases+1;total_outputs=total_outputs+n;
        end
    endtask
    task automatic check_profile_clear_contract;
        reg [31:0] value;
        begin
            idle();
            put(0,2);
            put(0,2);
            get(8'h88,value);
            if(value!=0)$fatal(1,"profile clear was not visible after registered idle clear");
            get(8'h8c,value);
            if(value!=0)$fatal(1,"profile high word was not cleared");
            $display("PROFILE_CLEAR_CONTRACT_PASS counters=15 start_clear=1");
        end
    endtask
    reg [31:0] status,value;
    integer locality_cases=0,locality_outputs=0;
    task automatic locality_case(input integer revision);
        integer i,j,c,oc,y,x,ky,kx,tap,ch,index,acc_value,magnitude,rounded,q_value ,n;
        reg [31:0] st,code,observed,bias;
        begin
            idle();put(0,2);inject_error=0;
            for(i=0;i<262144;i=i+1)mem[i]=8'ha5;
            // Nonuniform data spans both sides of 8-byte boundaries and
            // unaligned channel planes. Revision 1 changes the same addresses
            // after a completed START to exercise local-cache invalidation.
            for(i=0;i<17*3*31;i=i+1)mem[i]=(i*13+revision*5)%15-7;
            for(oc=0;oc<17;oc=oc+1)begin
                for(tap=0;tap<168;tap=tap+1)
                    mem['h8000+oc*168+tap]=tap<153?(tap*7+oc*3)%5-2:0;
                bias=oc-8;
                for(j=0;j<4;j=j+1)begin
                    mem['h18000+oc*4+j]=bias[j*8+:8];mem['h1c000+oc*4+j]=j==0?1:0;
                end
                for(j=0;j<8;j=j+1)mem['h19000+oc*8+j]=j==0?1:0;
            end
            put(8,32'h100000);put(12,32'h108000);put(16,32'h118000);
            put(20,32'h119000);put(24,32'h11c000);put(28,32'h120000);put(32,32'h130000);
            put(36,17);put(40,17);put(44,3);put(48,31);put(52,3);put(56,1);put(60,0);put(64,0);
            put(0,1);terminal(st);get(8'h44,code);
            if(st!=2 || code!=0)$fatal(1,"locality status=%h code=%h",st,code);
            for(oc=0;oc<17;oc=oc+1)for(y=0;y<3;y=y+1)for(x=0;x<31;x=x+1)begin
                acc_value=oc-8;
                for(c=0;c<17;c=c+1)for(ky=0;ky<3;ky=ky+1)for(kx=0;kx<3;kx=kx+1)begin
                    tap=c*9+ky*3+kx;
                    if(y+ky>=1 && y+ky<4 && x+kx>=1 && x+kx<32)
                        acc_value=acc_value+$signed(mem[c*93+(y+ky-1)*31+x+kx-1])*$signed(mem['h8000+oc*168+tap]);
                end
                magnitude=acc_value<0?-acc_value:acc_value;
                rounded=magnitude/2+((magnitude%2!=0) && ((magnitude/2)%2!=0));
                q_value=acc_value<0?-rounded:rounded;
                if(q_value>127)q_value=127;if(q_value < -128)q_value=-128;
                index=oc*93+y*31+x;
                observed={mem['h20000+index*4+3],mem['h20000+index*4+2],mem['h20000+index*4+1],mem['h20000+index*4]};
                if(observed!==acc_value || mem['h30000+index]!==q_value[7:0])
                    $fatal(1,"locality revision=%0d index=%0d acc=%h expected=%h q=%h expected_q=%h",revision,index,observed,acc_value,mem['h30000+index],q_value[7:0]);
            end
            n=17*93;
            if(mem['h20000-1]!=8'ha5 || mem['h20000+n*4]!=8'ha5 || mem['h30000-1]!=8'ha5 || mem['h30000+n]!=8'ha5)$fatal(1,"locality output guard changed");
            locality_cases=locality_cases+1;locality_outputs=locality_outputs+n;
            $display("LOCALITY_CASE_PASS revision=%0d outputs=%0d",revision,n);
        end
    endtask
    task automatic overflow_guard(input bit negative,input bit final_only=0,input integer fault_lane=0);
        integer i,oc,before_writes;
        reg [31:0] st,code,bias;
        begin
            idle();put(0,2);put(8'h44,0);inject_error=0;
            for(i=0;i<262144;i=i+1)mem[i]=8'ha5;
            // Cover an intermediate overflow that cancels, and overflow only
            // on the final chunk. Select late lanes and the second DSP batch
            // to expose a stale/misaligned registered overflow selection.
            for(i=0;i<48;i=i+1)mem[i]=8'd127;
            for(oc=0;oc<=fault_lane;oc=oc+1)begin
                for(i=0;i<48;i=i+1)
                    mem['h8000+oc*48+i]=oc!=fault_lane || (final_only && i<24)?8'd0:
                        (final_only?(negative?8'hff:8'h01):((i<24)^negative?8'h01:8'hff));
                bias=oc==fault_lane?(negative?32'h80000008:32'h7ffffff8):32'd0;
                for(i=0;i<4;i=i+1)mem['h18000+oc*4+i]=bias[i*8+:8];
                for(i=0;i<8;i=i+1)mem['h19000+oc*8+i]=i==0?8'd1:8'd0;
                for(i=0;i<4;i=i+1)mem['h1a000+oc*4+i]=i==0?8'd1:8'd0;
            end
            put(8,32'h100000);put(12,32'h108000);put(16,32'h118000);
            put(20,32'h119000);put(24,32'h11a000);put(28,32'h120000);put(32,32'h130000);
            put(36,48);put(40,fault_lane+1);put(44,1);put(48,1);put(52,1);put(56,0);put(60,0);put(64,0);
            before_writes=bus_writes;put(0,1);terminal(st);get(8'h44,code);
            if(st!=4 || code!=7 || bus_writes!=before_writes+2*fault_lane ||
                mem['h20000+4*fault_lane]!=8'ha5 || mem['h30000+fault_lane]!=8'ha5)
                $fatal(1,"overflow guard failed negative=%0d final_only=%0d lane=%0d",negative,final_only,fault_lane);
            $display("OVERFLOW_GUARD_PASS negative=%0d final_only=%0d lane=%0d faulting_output_untouched=1",negative,final_only,fault_lane);
        end
    endtask
    task automatic boundary_case(input integer ci,co,h,w,k,pad);
        integer i,j,oc,ch,n,taps,acc_value,q_value;
        reg [31:0] st,code,observed;
        begin
            idle();put(0,2);inject_error=0;
            for(i=0;i<262144;i=i+1)mem[i]=8'ha5;
            taps=ci*k*k;ch=(taps+23)/24;n=co*h*w;
            for(i=0;i<ci*h*w;i=i+1)mem[i]=8'd2;
            for(i=0;i<co*ch*24;i=i+1)mem['h8000+i]=8'd1;
            for(oc=0;oc<co;oc=oc+1)begin
                for(j=0;j<4;j=j+1)begin mem['h18000+oc*4+j]=0;mem['h1c000+oc*4+j]=j==0?1:0;end
                for(j=0;j<8;j=j+1)mem['h19000+oc*8+j]=j==0?1:0;
            end
            put(8,32'h100000);put(12,32'h108000);put(16,32'h118000);
            put(20,32'h119000);put(24,32'h11c000);put(28,32'h120000);put(32,32'h130000);
            put(36,ci);put(40,co);put(44,h);put(48,w);put(52,k);put(56,pad);put(60,0);put(64,0);
            put(0,1);terminal(st);get(8'h44,code);
            if(st!=2 || code!=0)$fatal(1,"boundary case failed ci=%0d co=%0d h=%0d w=%0d k=%0d status=%h error=%h",ci,co,h,w,k,st,code);
            // k3 case is a single padded pixel: only the center coefficient
            // contributes. k1 boundary cases have no spatial padding.
            acc_value=2*ci;q_value=ci>127?127:ci;
            for(i=0;i<n;i=i+1)begin
                observed={mem['h20000+i*4+3],mem['h20000+i*4+2],mem['h20000+i*4+1],mem['h20000+i*4]};
                if(observed!==acc_value || mem['h30000+i]!==q_value[7:0])$fatal(1,"boundary arithmetic index=%0d acc=%h",i,observed);
            end
            if(mem['h20000-1]!=8'ha5 || mem['h20000+n*4]!=8'ha5 || mem['h30000-1]!=8'ha5 || mem['h30000+n]!=8'ha5)$fatal(1,"boundary output guard changed");
            get(8'h60,code);if(code!=n)$fatal(1,"boundary output counter");
            get(8'h5c,code);if(code!=n*ch)$fatal(1,"boundary MAC counter");
            boundary_cases=boundary_cases+1;boundary_outputs=boundary_outputs+n;
            $display("BOUNDARY_CASE_PASS ci=%0d co=%0d h=%0d w=%0d k=%0d outputs=%0d",ci,co,h,w,k,n);
        end
    endtask
    task automatic parameter_guard(input [63:0] coefficient,input integer shift_value,input bit valid_parameter);
        integer i,oc,before_writes;
        reg [31:0] st,code;
        begin
            idle();put(0,2);put(8'h44,0);inject_error=0;
            for(i=0;i<262144;i=i+1)mem[i]=0;
            for(oc=0;oc<2;oc=oc+1)begin
                mem['h18000+oc*4]=2;
                for(i=0;i<8;i=i+1)mem['h19000+oc*8+i]=(oc==1)?coefficient[i*8+:8]:(i==0?1:0);
                for(i=0;i<4;i=i+1)mem['h1a000+oc*4+i]=(oc==1)?(shift_value>>(i*8)):(i==0?1:0);
            end
            put(8,32'h100000);put(12,32'h108000);put(16,32'h118000);
            put(20,32'h119000);put(24,32'h11a000);put(28,32'h120000);put(32,32'h130000);
            put(36,1);put(40,2);put(44,1);put(48,1);put(52,1);put(56,0);put(60,0);put(64,0);
            before_writes=bus_writes;put(0,1);terminal(st);get(8'h44,code);
            if(valid_parameter)begin
                if(st!=2 || code!=0 || mem['h30000]!=1 || mem['h30001]!=2)
                    $fatal(1,"maximum coefficient or tagged parameter read failed");
            end else if(st!=4 || code!=6 || bus_writes!=before_writes)
                $fatal(1,"invalid coefficient/shift accepted coefficient=%h shift=%0d status=%h error=%h",coefficient,shift_value,st,code);
            $display("PARAMETER_GUARD_PASS coefficient=%h shift=%0d accepted=%0d",coefficient,shift_value,valid_parameter);
        end
    endtask
    task automatic config_guard(input [7:0] address,input [31:0] data,input [31:0] expected_error,
                                input [6:0] check_options=0);
        integer before_reads,before_writes;
        reg [31:0] st,code;
        begin
            idle();put(0,2);
            put(8,32'h100000);put(12,32'h108000);put(16,32'h118000);
            put(20,32'h119000);put(24,32'h11c000);put(28,32'h120000);put(32,32'h130000);
            put(36,1);put(40,1);put(44,1);put(48,1);put(52,1);put(56,0);put(60,0);put(64,0);
            put(8'h44,{25'd0,check_options});
            put(address,data);before_reads=bus_reads;before_writes=bus_writes;
            put(0,1);terminal(st);get(8'h44,code);
            if(st!=4 || code!=expected_error || bus_reads!=before_reads || bus_writes!=before_writes)
                $fatal(1,"config guard addr=%0d data=%h status=%h error=%h",address,data,st,code);
            config_guard_cases=config_guard_cases+1;
            $display("CONFIG_GUARD_PASS address=%0d data=%h error=%0d no_DDR=1",address,data,expected_error);
        end
    endtask
    task automatic size_guard(input integer ci,h,w,k,pad);
        integer before_reads,before_writes;
        reg [31:0] st,code;
        begin
            idle();put(0,2);
            put(8,32'h100000);put(12,32'h108000);put(16,32'h118000);
            put(20,32'h119000);put(24,32'h11c000);put(28,32'h120000);put(32,32'h130000);
            put(36,ci);put(40,1);put(44,h);put(48,w);put(52,k);put(56,pad);put(60,0);put(64,0);
            before_reads=bus_reads;before_writes=bus_writes;
            put(0,1);terminal(st);get(8'h44,code);
            if(st!=4 || code!=2 || bus_reads!=before_reads || bus_writes!=before_writes)
                $fatal(1,"derived size guard ci=%0d h=%0d w=%0d k=%0d status=%h error=%h",ci,h,w,k,st,code);
            config_guard_cases=config_guard_cases+1;
            $display("DERIVED_SIZE_GUARD_PASS ci=%0d h=%0d w=%0d k=%0d no_DDR=1",ci,h,w,k);
        end
    endtask
    initial begin
        repeat(30)@(negedge clk);rst_n=1;
        idle();get(8'h4c,value);if(value!=32'h47325502)$fatal(1,"ABI changed");
        check_profile_clear_contract();
        `include "closedloop_cases.svh"
        overflow_guard(0);overflow_guard(1);
        overflow_guard(0,1,0);overflow_guard(1,1,0);
        overflow_guard(0,1,15);overflow_guard(1,1,15);
        overflow_guard(0,1,16);overflow_guard(1,1,16);
        boundary_case(1,1024,1,1,1,0);
        boundary_case(1024,1,1,1,1,0);
        boundary_case(512,1,1,1,3,1);
        boundary_case(1,1,1,845,1,0);
        boundary_case(1,1,416,1,1,0);
        locality_case(0);locality_case(1);
        parameter_guard(64'h0000000fffffffff,36,1);
        parameter_guard(64'd0,36,0);
        parameter_guard(64'h0000001000000000,36,0);
        parameter_guard(64'h8000000000000001,36,0);
        parameter_guard(64'd1,0,0);parameter_guard(64'd1,63,0);
        parameter_guard(64'd1,256,0);
        config_guard(36,0,2);config_guard(36,1025,2);
        config_guard(40,0,2);config_guard(40,1025,2);
        config_guard(44,0,2);config_guard(44,417,2);
        config_guard(48,0,2);config_guard(48,846,2);
        config_guard(52,2,2);config_guard(56,1,2);
        config_guard(60,128,2);config_guard(64,32'hffffff7f,2);
        config_guard(36,32'h80000001,2);config_guard(40,32'h80000001,2);
        config_guard(44,32'h80000001,2);config_guard(48,32'h80000001,2);
        config_guard(52,32'h80000001,2);config_guard(56,32'h80000000,2);
        config_guard(8,32'h100001,1);config_guard(12,32'h108004,1);
        config_guard(16,32'h118004,1);config_guard(20,32'h119004,1);
        config_guard(24,32'h11c004,1);config_guard(28,32'h120004,1);config_guard(32,32'h130001,1);
        config_guard(8,32'h000ff000,4);config_guard(8,32'h1fff0000,4);
        config_guard(28,32'h1fff0000,4);config_guard(32,32'h1fff0000,4);
        config_guard(32,32'h120000,4);
        config_guard(8'h4c,32'h1ffeff08,1,7'd2);
        config_guard(8'h4c,32'h1fff0000,1,7'd2);
        config_guard(8'h4c,32'hffffff00,1,7'd2);
        idle();put(8'h44,0);
        size_guard(1,416,417,1,0);
        size_guard(513,1,1,3,1);
        size_guard(1024,1,1,3,1);
        put(44,1);put(48,1);put(52,1);put(56,0);
        put(0,2);put(8,32'h100001);put(0,1);terminal(status);get(8'h44,value);
        if(status!=4 || value!=1)$fatal(1,"unaligned input guard failed");
        put(0,2);put(8,32'h100000);inject_error=1;
        put(0,1);terminal(status);get(8'h44,value);
        if(status!=4 || value!=3)$fatal(1,"HP read error propagation failed");
        inject_error=0;
        $display("LOCALITY_PASS cases=%0d outputs=%0d cross_word=1 cross_row=1 groups=2 START_invalidation=1",locality_cases,locality_outputs);
        $display("CLOSEDLOOP_PASS cases=%0d outputs=%0d boundary_cases=%0d boundary_outputs=%0d config_guards=%0d bus_reads=%0d bus_writes=%0d guards=4 profile_sum=1",checked_cases,total_outputs,boundary_cases,boundary_outputs,config_guard_cases,bus_reads,bus_writes);
        $finish;
    end
    initial begin #100000000; $fatal(1,"closed loop watchdog timeout");end
    always @(posedge clk) if(rst_n) begin
        if((dut.u_control.state[20] || dut.u_control.state[60]) &&
           {dut.u_control.macs_add_hi+{15'd0,dut.u_control.macs_add_lo[16]},
            dut.u_control.macs_add_lo[15:0]}!==(dut.u_control.macs+dut.u_control.chunks))
            $fatal(1,"MACS_COUNT_PIPELINE_STALE");
        if(dut.u_control.state[39] &&
           dut.u_control.result_overflow!==dut.u_control.accumulator_overflow[dut.u_control.local_oc[3:0]])
            $fatal(1,"SELECTED_OVERFLOW_PIPELINE_STALE");
        if(dut.u_control.state[23] && dut.u_control.accumulated_last &&
           dut.u_control.accum_overflow_now[0] && !dut.u_control.accumulator_overflow[0])
            $fatal(1,"FINAL_OVERFLOW_NOT_RETIRED_BEFORE_SELECTION");
        if(dut.u_control.state[13] &&
           (dut.u_control.pixel_left_border!==(dut.u_control.px==0) ||
            dut.u_control.pixel_top_border!==(dut.u_control.py==0)))
            $fatal(1,"PIXEL_BORDER_FLAGS_STALE");
        if(dut.u_control.state[30] && !dut.u_control.local_oc_is_last &&
           {dut.u_control.output_offset_hi+{15'd0,dut.u_control.output_offset_lo[16]},
            dut.u_control.output_offset_lo[15:0]}!==
           (dut.u_control.output_channel_offset+dut.u_control.plane))
            $fatal(1,"OUTPUT_CHANNEL_OFFSET_PIPELINE_STALE");
        if(dut.u_control.state[18] && dut.u_control.gather_pending && dut.u_control.rsp_valid)
            $fatal(1,"GATHER_SECOND_RESPONSE_DURING_COMMIT");
        if($isunknown(dut.u_control.state) || !$onehot(dut.u_control.state))
            $fatal(1,"FSM_ONEHOT_INVARIANT_FAILED state=%h next=%h code=%d oc=%d qready=%b qdone=%b accov=%h",dut.u_control.state,dut.u_control.state_next,dut.u_control.state_code,dut.u_control.local_oc,dut.u_control.q_ready,dut.u_control.q_done,dut.u_control.accumulator_overflow);
    end
endmodule
