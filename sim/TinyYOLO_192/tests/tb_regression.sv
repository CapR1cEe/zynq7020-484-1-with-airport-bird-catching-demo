`timescale 1ns/1ps
module tb_regression;
    reg clk=0;
    always #2.083333333 clk=~clk;
    reg rst_n=0;
    reg req_v=0,req_ready=0,rsp_v=0,rsp_ready=0;
    wire req_r,req_out_v,rsp_r,rsp_out_v,empty;
    reg [170:0] req_in;
    wire [170:0] req_out;
    reg [64:0] rsp_in;
    wire [64:0] rsp_out;
    tinyyolo_ctrl_hp0_pipe2 pipe2 (
        .clk(clk),.rst_n(rst_n),.req_in_valid(req_v),.req_in_ready(req_r),
        .req_in_write(req_in[170]),.req_in_addr(req_in[169:138]),
        .req_in_wdata(req_in[137:74]),.req_in_wstrb(req_in[73:66]),
        .req_in_kind(req_in[65:64]),.req_in_low(req_in[63:32]),.req_in_high(req_in[31:0]),
        .req_out_valid(req_out_v),.req_out_ready(req_ready),
        .req_out_write(req_out[170]),.req_out_addr(req_out[169:138]),
        .req_out_wdata(req_out[137:74]),.req_out_wstrb(req_out[73:66]),
        .req_out_kind(req_out[65:64]),.req_out_low(req_out[63:32]),.req_out_high(req_out[31:0]),
        .rsp_in_valid(rsp_v),.rsp_in_ready(rsp_r),.rsp_in_error(rsp_in[64]),.rsp_in_data(rsp_in[63:0]),
        .rsp_out_valid(rsp_out_v),.rsp_out_ready(rsp_ready),
        .rsp_out_error(rsp_out[64]),.rsp_out_data(rsp_out[63:0]),.empty(empty));
    reg [170:0] req_queue[0:24999];
    reg [64:0] rsp_queue[0:24999];
    integer req_cycle[0:24999],rsp_cycle[0:24999];
    integer qp=0,qc=0,rp=0,rc=0,cycle;
    reg hold_req=0,hold_rsp=0,stall_req=0,stall_rsp=0;
    reg [170:0] stable_req;
    reg [64:0] stable_rsp;
    reg pipe_done=0,dot_done=0,rne_done=0;

    initial begin
        // UNISIM glbl holds GSR for its initial 100 ns.
        repeat(30) @(negedge clk);
        rst_n=1;
        for(cycle=0;cycle<22000;cycle=cycle+1) begin
            @(negedge clk);
            if(!hold_req) begin
                req_v=(cycle<21000) && ((cycle<100) || ($urandom_range(0,3)!=0));
                req_in={$urandom,$urandom,$urandom,$urandom,$urandom,$urandom};
            end
            if(!hold_rsp) begin
                rsp_v=(cycle<21000) && ((cycle<100) || ($urandom_range(0,2)!=0));
                rsp_in={$urandom,$urandom,$urandom};
            end
            req_ready=(cycle<100 || cycle>=21000) ? 1 : ($urandom_range(0,5)>1);
            rsp_ready=(cycle<100 || cycle>=21000) ? 1 : ($urandom_range(0,5)>2);
            // Prolonged independent stalls stress all skid slots.
            if(cycle>=1000 && cycle<1100) req_ready=0;
            if(cycle>=3000 && cycle<3200) rsp_ready=0;
            @(posedge clk);
            if(stall_req && (!req_out_v || req_out!==stable_req)) $fatal(1,"request changed under stall");
            if(stall_rsp && (!rsp_out_v || rsp_out!==stable_rsp)) $fatal(1,"response changed under stall");
            if(req_v && req_r) begin req_queue[qp]=req_in;req_cycle[qp]=cycle;qp=qp+1;end
            if(rsp_v && rsp_r) begin rsp_queue[rp]=rsp_in;rsp_cycle[rp]=cycle;rp=rp+1;end
            if(req_out_v && req_ready) begin
                if(qc>=qp || req_out!==req_queue[qc]) $fatal(1,"request lost/reordered at %d",cycle);
                if(cycle-req_cycle[qc]<2 || (cycle<100 && cycle-req_cycle[qc]!=2)) $fatal(1,"request latency is not two stages");
                qc=qc+1;
            end
            if(rsp_out_v && rsp_ready) begin
                if(rc>=rp || rsp_out!==rsp_queue[rc]) $fatal(1,"response lost/reordered at %d",cycle);
                if(cycle-rsp_cycle[rc]<2 || (cycle<100 && cycle-rsp_cycle[rc]!=2)) $fatal(1,"response latency is not two stages");
                rc=rc+1;
            end
            hold_req=req_v && !req_r;hold_rsp=rsp_v && !rsp_r;
            stall_req=req_out_v && !req_ready;stable_req=req_out;
            stall_rsp=rsp_out_v && !rsp_ready;stable_rsp=rsp_out;
        end
        #1;
        if(qp!=qc || rp!=rc || !empty) $fatal(1,"pipeline failed to drain");
        $display("PIPE_PASS req=%0d rsp=%0d cycles=22000 two_stage_latency=2",qc,rc);
        pipe_done=1;
    end

    reg dot_valid=0,dot_last=0;
    reg [127:0] a,w;
    wire dv,dl;
    wire signed [19:0] ds;
    integer expected_sum[0:6];
    reg [6:0] expected_v=0,expected_l=0;
    integer dcycle,lane,j,acc,checked=0;
    reg signed [7:0] aa,ww;
    tinyyolo_dot16 dot(.clk(clk),.rst_n(rst_n),.valid(dot_valid),.last(dot_last),
        .a(a),.w(w),.out_valid(dv),.out_last(dl),.sum(ds));
    initial begin
        wait(rst_n);
        for(dcycle=0;dcycle<5010;dcycle=dcycle+1) begin
            @(negedge clk);
            dot_valid=dcycle<5000 && (dcycle<64 || $urandom_range(0,3)!=0);
            dot_last=dot_valid && $urandom_range(0,7)==0;
            for(lane=0;lane<16;lane=lane+1) begin
                a[lane*8+:8]=dcycle==0?8'h80:(dcycle==1?8'h7f:$urandom);
                w[lane*8+:8]=dcycle<2?8'h80:$urandom;
            end
            acc=0;
            for(lane=0;lane<16;lane=lane+1) begin
                aa=a[lane*8+:8];ww=w[lane*8+:8];acc=acc+aa*ww;
            end
            @(posedge clk);
            for(j=6;j>0;j=j-1)expected_sum[j]=expected_sum[j-1];
            expected_sum[0]=acc;
            expected_v={expected_v[5:0],dot_valid};expected_l={expected_l[5:0],dot_last};
            #1;
            if(dv!==expected_v[6] || dl!==expected_l[6]) $fatal(1,"dot valid/last misalignment");
            if(dv) begin
                if($signed(ds)!=expected_sum[6]) $fatal(1,"dot arithmetic expected %d actual %d",expected_sum[6],$signed(ds));
                checked=checked+1;
            end
        end
        $display("DOT_PASS vectors=%0d latency=7 II=1",checked);dot_done=1;
    end

    reg qstart=0;
    reg signed [31:0] qacc;
    reg [63:0] qmul;
    reg [5:0] qshift;
    reg signed [7:0] qzp;
    wire qdone;
    wire signed [7:0] qout;
    reg [7:0] qexpected;
    integer vf,fields,waits,qchecked=0;
    tinyyolo_rne64 rne(.clk(clk),.rst_n(rst_n),.start(qstart),.accumulator(qacc),
        .multiplier(qmul),.shift(qshift),.zero_point(qzp),.done(qdone),.result(qout));
    initial begin
        wait(rst_n);
        vf=$fopen("rne_vectors.txt","r");
        if(!vf) $fatal(1,"missing RNE vectors");
        while(!$feof(vf)) begin
            @(negedge clk);
            fields=$fscanf(vf,"%h %h %h %h %h\n",qacc,qmul,qshift,qzp,qexpected);
            if(fields!=5) $fatal(1,"bad RNE vector");
            qstart=1;
            @(negedge clk);qstart=0;waits=0;
            while(!qdone && waits<20) begin @(negedge clk);waits=waits+1;end
            if(!qdone || qout!==qexpected) $fatal(1,"RNE mismatch a=%h mul=%h shift=%d zp=%d exp=%h got=%h",qacc,qmul,qshift,qzp,qexpected,qout);
            qchecked=qchecked+1;
        end
        $fclose(vf);$display("RNE_PASS vectors=%0d exact_96bit=1",qchecked);rne_done=1;
    end
    initial begin
        wait(pipe_done && dot_done && rne_done);
        $display("REGRESSION_PASS");$finish;
    end
    initial begin #2000000; $fatal(1,"regression timeout");end
endmodule
