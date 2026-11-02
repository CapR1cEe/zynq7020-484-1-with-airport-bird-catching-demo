`timescale 1ns/1ps
module tb_counter64;
    reg clk=0, rst_n=0, clear=0, enable=0;
    wire [63:0] value;
    reg [63:0] expected=0;
    wire [31:0] value32;
    reg [31:0] expected32=0;
    integer checks=0, i;
    reg [31:0] random_state=32'h7a31_590b;
    always #5 clk=~clk;
    tinyyolo_counter64 dut(.clk(clk),.rst_n(rst_n),.clear(clear),.enable(enable),.value(value));
    tinyyolo_counter32 dut32(.clk(clk),.rst_n(rst_n),.clear(clear),.enable(enable),.value(value32));
    reg load32=0;
    reg [31:0] load_value32=0,expected_load32=0;
    wire [31:0] loaded_value32;
    integer load_checks=0;
    tinyyolo_counter32_load loaded_dut(.clk(clk),.rst_n(rst_n),.clear(clear),
        .load(load32),.enable(enable),.load_value(load_value32),.value(loaded_value32));
    // Independent modulo arithmetic checks loads, adjacent enables, stalls,
    // clear priority and reset priority against the published 32-bit value.
    always @(posedge clk)begin
        if(!rst_n || clear)expected_load32=0;
        else if(load32)expected_load32=load_value32;
        else if(enable)expected_load32=expected_load32+32'd1;
        #1;
        if(loaded_value32!==expected_load32)
            $fatal(1,"loaded counter mismatch expected=%h got=%h",expected_load32,loaded_value32);
        load_checks=load_checks+1;
    end
    reg profile_active=0,profile_start=0,profile_clear=0,profile_read_enable=0;
    reg [5:0] profile_state=0;
    reg profile_state_override=0;
    reg [63:0] profile_state_bits=0;
    reg profile_req_valid=0,profile_req_ready=0,profile_arvalid=0,profile_arready=0;
    reg profile_rvalid=0,profile_rready=0,profile_awvalid=0,profile_awready=0;
    reg profile_wvalid=0,profile_wready=0,profile_bvalid=0,profile_bready=0;
    reg [7:0] profile_read_addr=0;
    wire [31:0] profile_read_data;
    integer profile_expected[0:14],profile_index,phase_state,expected_phase;
    reg [63:0] profile_reference[0:14];
    reg sample_rst=0,sample_active=0,sample_start=0,sample_clear=0;
    reg [7:0] sample_phase=0,next_phase;
    reg [6:0] sample_bus=0;
    reg [63:0] observed_state;
    integer sample_index,member_index;
    tinyyolo_cycle_profile profile_dut(
        .clk(clk),.rst_n(rst_n),.active(profile_active),.start(profile_start),.clear(profile_clear),
        .state(profile_state_override?profile_state_bits:(64'd1<<profile_state)),
        .req_valid(profile_req_valid),.req_ready(profile_req_ready),
        .arvalid(profile_arvalid),.arready(profile_arready),.rvalid(profile_rvalid),.rready(profile_rready),
        .awvalid(profile_awvalid),.awready(profile_awready),.wvalid(profile_wvalid),.wready(profile_wready),
        .bvalid(profile_bvalid),.bready(profile_bready),.read_enable(profile_read_enable),
        .read_addr(profile_read_addr[6:2]),.read_data(profile_read_data));
    task tick(input bit reset_input, input bit clear_input, input bit enable_input);
        begin
            @(negedge clk);
            rst_n=reset_input; clear=clear_input; enable=enable_input;
            if(!reset_input || clear_input) expected=64'd0;
            else if(enable_input) expected=expected+64'd1;
            if(!reset_input || clear_input) expected32=32'd0;
            else if(enable_input) expected32=expected32+32'd1;
            @(posedge clk); #1;
            if(value!==expected) $fatal(1,"counter mismatch check=%0d expected=%h got=%h",checks,expected,value);
            if(value32!==expected32) $fatal(1,"counter32 mismatch check=%0d expected=%h got=%h",checks,expected32,value32);
            checks=checks+1;
        end
    endtask
    task load_boundary(input reg [31:0] seed);
        begin
            load32=1;load_value32=seed;tick(1,0,1);
            load32=0;tick(1,0,1);tick(1,0,0);tick(1,0,1);tick(1,0,1);
        end
    endtask
    task boundary32(input reg [31:0] seed);
        begin
            @(negedge clk);dut32.value=seed;expected32=seed;enable=0;clear=0;rst_n=1;
            tick(1,0,0);tick(1,0,1);tick(1,0,0);tick(1,0,1);tick(1,0,1);
        end
    endtask
    task boundary(input reg [63:0] seed);
        begin
            @(negedge clk); dut.value=seed; expected=seed; enable=0; clear=0; rst_n=1;
            tick(1,0,0); tick(1,0,1); tick(1,0,0); tick(1,0,1); tick(1,0,1);
        end
    endtask
    task automatic check_profile_word(input [7:0] address,input [31:0] expected_word);
        reg [31:0] held_word;
        begin
            @(negedge clk);profile_read_addr=address;profile_read_enable=1'b1;
            @(posedge clk);#1;
            // The local read-command stage accepts this address first. Change
            // the live address immediately, then check the published snapshot
            // on the following edge; address retention is still required.
            @(negedge clk);profile_read_enable=1'b0;profile_read_addr=~address;
            @(posedge clk);#1;
            if(profile_read_data!==expected_word)
                $fatal(1,"profile read mismatch address=%h expected=%h got=%h",address,expected_word,profile_read_data);
            held_word=profile_read_data;
            @(negedge clk);profile_read_addr=address^8'h5a;
            @(posedge clk);#1;
            if(profile_read_data!==held_word)
                $fatal(1,"profile response changed after accepted address address=%h",address);
        end
    endtask
    initial begin
        tick(0,0,0); tick(1,0,0);
        // Check all controller states against the original numeric-state ABI.
        // This covers the new direct one-hot observation path independently
        // of the counter/read-mux tests below.
        for(phase_state=0;phase_state<64;phase_state=phase_state+1)begin
            profile_state=phase_state;
            case(phase_state)
                1,2,3,4,5,35,36,37,38,40,41,42,48,63,52,53,54,55,56,57,58:expected_phase=0;
                7,8,9,10,45,46:expected_phase=1;
                11,12:expected_phase=2;
                14,15,16,17,18,19,47:expected_phase=3;
                20,21,22,23,39,49,60,61:expected_phase=4;
                24,25,43,44,50,51:expected_phase=5;
                26,27,28,29:expected_phase=6;
                default:expected_phase=7;
            endcase
            #1;
            if(profile_dut.phase!==(8'd1<<expected_phase))
                $fatal(1,"profile phase ABI changed state=%0d expected=%0d got=%h",phase_state,expected_phase,profile_dut.phase);
        end
        profile_state=0;
        // Exercise natural low-word carry, then deposit near larger boundaries
        // to test all carry words without waiting 2^48 simulation cycles.
        for(i=0;i<65540;i=i+1) tick(1,0,1);
        boundary(64'h0000_0000_ffff_fffe);
        boundary(64'h0000_ffff_ffff_fffe);
        boundary(64'hffff_ffff_ffff_fffe);
        boundary32(32'h0000_00fe);
        boundary32(32'h0000_fffe);
        boundary32(32'h00ff_fffe);
        boundary32(32'hffff_fffe);
        load_boundary(32'h0000_00fe);load_boundary(32'h0000_00ff);
        load_boundary(32'h0000_fffe);load_boundary(32'h0000_ffff);
        load_boundary(32'h00ff_fffe);load_boundary(32'h00ff_ffff);
        load_boundary(32'hffff_fffe);load_boundary(32'hffff_ffff);
        for(i=0;i<20000;i=i+1) begin
            random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
            load32=random_state[12:8]==0;load_value32=random_state;
            tick(1,random_state[9:0]==0,random_state[14]);
        end
        load32=1;load_value32=32'hffff_ffff;tick(1,1,1);tick(0,0,1);
        load32=0;
        tick(1,1,1); tick(1,0,1); tick(0,0,1); tick(1,0,0);
        // Give every profile counter a distinct value, then read all 30 words
        // through the new banked two-stage selector, including its final bank.
        profile_active=1'b1;profile_state=6'd1;
        for(profile_index=0;profile_index<8;profile_index=profile_index+1)begin
            case(profile_index)
                0:profile_state=6'd1;1:profile_state=6'd7;2:profile_state=6'd11;3:profile_state=6'd14;
                4:profile_state=6'd20;5:profile_state=6'd24;6:profile_state=6'd26;default:profile_state=6'd0;
            endcase
            if(profile_index==0)@(negedge clk);
            repeat(profile_index+1)@(negedge clk);
            profile_expected[profile_index]=profile_index+1;
        end
        profile_active=0;profile_state=6'd0;
        for(profile_index=0;profile_index<7;profile_index=profile_index+1)begin
            if(profile_index==0)begin
                profile_expected[7]=8;
                @(negedge clk);profile_active=1;
            end
            case(profile_index)
                0:begin profile_req_valid=1;profile_req_ready=0;end
                1:begin profile_arvalid=1;profile_arready=0;end
                2:begin profile_rready=1;profile_rvalid=0;end
                3:begin profile_rready=1;profile_rvalid=1;end
                4:begin profile_awvalid=1;profile_awready=0;end
                5:begin profile_bready=1;profile_bvalid=0;end
                6:begin profile_bready=1;profile_bvalid=1;end
            endcase
            repeat(profile_index+1)@(negedge clk);
            profile_req_valid=0;profile_arvalid=0;profile_rready=0;profile_rvalid=0;
            profile_awvalid=0;profile_bready=0;profile_bvalid=0;
            profile_req_ready=0;profile_arready=0;profile_awready=0;
            profile_expected[7]=profile_expected[7]+profile_index+1;
            profile_expected[profile_index+8]=profile_index+1;
        end
        profile_active=0;
        for(profile_index=0;profile_index<15;profile_index=profile_index+1)begin
            check_profile_word(8'h88+profile_index*8,profile_expected[profile_index]);
            check_profile_word(8'h8c+profile_index*8,32'd0);
        end
        // Check the sampled observation contract, including zero/multihot
        // states and reset/clear/start adjacent to active samples. An
        // independent state-membership model updates one cycle behind the
        // input stream; readback latency must not hide a shifted sample.
        @(negedge clk);rst_n=0;profile_active=0;profile_state_override=1;
        repeat(3)@(negedge clk);
        for(member_index=0;member_index<15;member_index=member_index+1)
            profile_reference[member_index]=0;
        for(sample_index=0;sample_index<1024;sample_index=sample_index+1)begin
            random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
            profile_state_bits[31:0]=random_state;
            random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
            profile_state_bits[63:32]=random_state;
            if(sample_index%64==0)profile_state_bits=0;
            else if(sample_index%64>9)profile_state_bits=64'd1<<sample_index%64;
            rst_n=sample_index%97!=0;
            profile_active=random_state[0];
            profile_start=sample_index%67==0;profile_clear=sample_index%37==0;
            {profile_req_valid,profile_req_ready,profile_arvalid,profile_arready,
                profile_rvalid,profile_rready,profile_awvalid,profile_awready,
                profile_wvalid,profile_wready,profile_bvalid,profile_bready}=random_state[12:1];
            @(posedge clk);#1;
            for(member_index=0;member_index<15;member_index=member_index+1)begin
                if(!sample_rst || sample_start || sample_clear)profile_reference[member_index]=0;
                else if(sample_active && (member_index<8?sample_phase[member_index]:sample_bus[member_index-8]))
                    profile_reference[member_index]=profile_reference[member_index]+64'd1;
                if(profile_dut.counter[member_index]!==profile_reference[member_index])
                    $fatal(1,"profile sample mismatch sample=%0d counter=%0d expected=%h got=%h",
                        sample_index,member_index,profile_reference[member_index],profile_dut.counter[member_index]);
            end
            observed_state=profile_state_bits;next_phase=0;
            for(member_index=0;member_index<64;member_index=member_index+1)
                if(observed_state[member_index])begin
                    case(member_index)
                        1,2,3,4,5,35,36,37,38,40,41,42,48,63,52,53,54,55,56,57,58:expected_phase=0;
                        7,8,9,10,45,46:expected_phase=1;
                        11,12:expected_phase=2;
                        14,15,16,17,18,19,47:expected_phase=3;
                        20,21,22,23,39,49,60,61:expected_phase=4;
                        24,25,43,44,50,51:expected_phase=5;
                        26,27,28,29:expected_phase=6;
                        default:expected_phase=7;
                    endcase
                    next_phase[expected_phase]=1'b1;
                end
            if(observed_state==0)next_phase=8'h80;
            sample_rst=rst_n;sample_active=rst_n && profile_active;
            sample_start=rst_n && profile_start;sample_clear=rst_n && profile_clear;
            sample_phase=next_phase;
            sample_bus={profile_bready && profile_bvalid,profile_bready && !profile_bvalid,
                (profile_awvalid && !profile_awready) || (profile_wvalid && !profile_wready),
                profile_rready && profile_rvalid,profile_rready && !profile_rvalid,
                profile_arvalid && !profile_arready,profile_req_valid && !profile_req_ready};
            @(negedge clk);
        end
        $display("PROFILE_SAMPLE_PASS samples=1024 counters=15 zero_state=1 multihot=1 delayed_reset=1");
        $display("COUNTER64_PASS checks=%0d carries=16,32,48,64 clear_priority=1 enable_stalls=1",checks);
        $display("COUNTER32_PASS checks=%0d carries=8,16,24,32 clear_priority=1 enable_stalls=1",checks);
        $finish;
    end
endmodule
