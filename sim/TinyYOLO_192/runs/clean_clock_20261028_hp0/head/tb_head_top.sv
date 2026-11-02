`timescale 1ns/1ps
module tb_head_top;
    `include "head_vectors/dimensions.svh"
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
    reg [7:0] mem[0:2097151];
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
                if(araddr<32'h100000 || araddr+8*(arlen+1)>32'h300000) $fatal(1,"read out of test RAM");
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
                if(write_addr<32'h100000 || write_addr+8>32'h300000) $fatal(1,"write out of test RAM");
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
            while(value==1 && tries<3000000) begin
                repeat(8)@(negedge clk);get(4,value);tries=tries+1;
            end
            if(value!=2 && value!=4)$fatal(1,"controller timeout status=%h",value);
            idle();
        end
    endtask
    reg [31:0] gold[0:HEAD21_SIZE*HEAD21_SIZE-1];
    integer i,head,n,frame,outputs=0;
    reg [31:0] st,code,value,observed;
    string frame_name,file_name;
    initial begin
        repeat(6)@(negedge clk);rst_n=1;
        for(head=17;head<=21;head=head+4)begin
            n=head==17?HEAD17_SIZE*HEAD17_SIZE:HEAD21_SIZE*HEAD21_SIZE;
            for(frame=0;frame<3;frame=frame+1)begin
                idle();put(0,2);
                for(i=0;i<2097152;i=i+1)mem[i]=8'ha5;
                frame_name=frame==0?"bird":frame==1?"random":"bird_repeat";
                file_name=$sformatf("head_vectors/head%0d.mem",head);
                $readmemh(file_name,mem,'h80000,'h80000+524352-1);
                file_name=$sformatf("head_vectors/%s_%0d.mem",frame_name,head);
                $readmemh(file_name,mem,0,n*256-1);
                file_name=$sformatf("head_vectors/%s_%0d.gold",frame_name,head);
                $readmemh(file_name,gold,0,n-1);
                put(8,32'h100000);put(12,32'h180000);put(32,32'h280000);
                put(36,256);put(40,1);put(44,head==17?HEAD17_SIZE:HEAD21_SIZE);put(48,head==17?HEAD17_SIZE:HEAD21_SIZE);
                put(8'h44,4);put(0,1);terminal(st);get(8'h44,code);
                if(st!=2 || code!=0)$fatal(1,"head failed h=%0d frame=%s status=%h code=%h",head,frame_name,st,code);
                for(i=0;i<n;i=i+1)begin
                    observed={mem['h180000+i*4+3],mem['h180000+i*4+2],mem['h180000+i*4+1],mem['h180000+i*4]};
                    if(observed!==gold[i])$fatal(1,"head mismatch head=%0d frame=%s i=%0d got=%h expected=%h",head,frame_name,i,observed,gold[i]);
                end
                if(mem['h180000-1]!==8'ha5 || mem['h180000+n*4]!==8'ha5)$fatal(1,"head output guard modified");
                get(8'h60,value);if(value!=n)$fatal(1,"head output counter");
                get(8'h5c,value);if(value!=n*256)$fatal(1,"head terms counter");
                get(0,value);if(value==0)$fatal(1,"head zero skip absent");
                outputs=outputs+n;
                $display("HEAD_TOP_CASE_PASS head=%0d frame=%s outputs=%0d zero_skipped=%0d",head,frame_name,n,value);
            end
        end
        $display("HEAD_TOP_PASS cases=6 outputs=%0d all_bits_equal=1",outputs);$finish;
    end
    always @(posedge clk) if(rst_n) begin
        if($isunknown(dut.u_control.state) || !$onehot(dut.u_control.state))
            $fatal(1,"FSM_ONEHOT_INVARIANT_FAILED");
        if(!dut.u_control.arithmetic_reset[24] &&
           ($isunknown(dut.u_control.head.state) || !$onehot(dut.u_control.head.state)))
            $fatal(1,"HEAD_FSM_ONEHOT_INVARIANT_FAILED");
    end
endmodule
