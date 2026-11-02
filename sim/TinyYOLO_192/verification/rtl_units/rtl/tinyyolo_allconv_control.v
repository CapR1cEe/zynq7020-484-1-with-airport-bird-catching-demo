`timescale 1ns/1ps
// Configurable NCHW k1/k3 s1 convolution. The PL gathers original DDR inputs,
// shares each gathered vector over up to 32 output channels, and performs
// signed MAC, validated UINT36 RNE, saturation and both DDR writes without CPU packing.
// G227: launch INT32 writeback alongside exact requantization. Preserve DDR
// request ordering, error handling, numerical semantics and counter ABI.
module tinyyolo_allconv_control (
    input wire clk, input wire rst_n,
    input wire [7:0] s_awaddr,input wire s_awvalid,output reg s_awready,
    input wire [31:0] s_wdata,input wire [3:0] s_wstrb,
    input wire s_wvalid,output reg s_wready,
    output wire [1:0] s_bresp,output reg s_bvalid,input wire s_bready,
    input wire [7:0] s_araddr,input wire s_arvalid,output reg s_arready,
    output reg [31:0] s_rdata,output wire [1:0] s_rresp,
    output reg s_rvalid,input wire s_rready,
    output reg req_valid,input wire req_ready,output reg req_write,
    output reg [31:0] req_addr,output reg [63:0] req_wdata,
    output reg [7:0] req_wstrb,input wire rsp_valid,output wire rsp_ready,
    input wire [63:0] rsp_data,input wire rsp_error,
    output wire cache_invalidate, output reg [1:0] req_kind,
    output reg [31:0] req_low, output reg [31:0] req_high,
    input wire [31:0] hp_bursts, hp_beats, hp_input_hits, hp_weight_hits, hp_misses,
    input wire hp_idle,
    input wire [31:0] profile_rdata,
    output wire profile_busy, profile_start, profile_clear, profile_read_enable,
    output wire [63:0] profile_state
);
    // Bound the combinational reset inverter fanout without adding a cycle.
    // Synthesis may replicate its LUT beside the synchronous consumers.
    (* MAX_FANOUT=32 *) wire reset_active=!rst_n;

    localparam [5:0] IDLE=0,CHECK=1,SIZE0=2,SIZE1=3,REGIONS=4,
        RO_CHECK=5,GROUP=6,P_ADDR=7,P_REQ=8,P_RSP=9,P_NEXT=10,
        W_REQ=11,W_RSP=12,PIXEL=13,G_COORD=14,G_ADDR=15,G_LOOK=16,
        G_REQ=17,G_RSP=18,G_STORE=19,OC_INIT=20,D_PRIME=21,D_FEED=22,
        D_WAIT=23,Q_START=24,Q_WAIT=25,A_REQ=26,A_RSP=27,
        Q_REQ=28,Q_RSP=29,NEXT_OC=30,NEXT_PIXEL=31,NEXT_GROUP=32,
        FINISH=33,FAULT=34,RO_PICK=35,RO_SUM=36,RO_COMPARE=37,G_CHECK=59,REGION_COMPARE=38,ACC_CHECK=39,OC_RESULT=60,D_ALIGN=61,OC_BIAS=62,REGION_SETTLE=48,RO_SETTLE=63;
    // Keep the shared FSM decode local to its consumers. Vivado otherwise
    // leaves a very high-fanout state bit on the gather/DSP enable path.
    (* fsm_encoding="none", MAX_FANOUT=16, EXTRACT_ENABLE="NO" *) reg [63:0] state;
    reg [5:0] state_code;
    integer observed_bit;
    always @* begin
        state_code=6'd0;
        for(observed_bit=0;observed_bit<64;observed_bit=observed_bit+1)
            if(state[observed_bit])state_code=state_code | observed_bit[5:0];
    end
    // Keep synchronous reset distribution local to each arithmetic island.
    // The PS reset controller already synchronizes the input to this clock.
    // A START cannot reach arithmetic before the AXI command and validation
    // states, so this one-cycle reset extension cannot discard a real term.
    // Preserve separate registers: merging them recreated an 8608-load net.
    (* DONT_TOUCH="TRUE" *) reg [24:0] arithmetic_reset;
    always @(posedge clk)
        arithmetic_reset<={25{reset_active}};
    reg [5:0] debug_state;
    always @(posedge clk)
        if(reset_active)debug_state<=0;
        else debug_state<=state_code;
    reg [31:0] cfg[0:14];
    // Write-only extensions, stable while busy. 0x44: options, 0x4c: LUT base.
    // bits: 0 omit accumulator DDR, 1 fuse INT8 LUT, 2 exact FP head,
    //       3 compact all-zero activation chunks, 4 local gather cache,
    //       5 coalesce quantized output writes, 6 fuse LUT then stride-2 maxpool. Default zero retains trace ABI.
    reg [6:0] options;
    reg [31:0] lut_base;
    localparam [5:0] LC_SWEEP=40,H_START=41,H_RUN=42,Q_PACK=43,
        Q_EMIT=44,LUT_REQ=45,LUT_RSP=46,G_CHUNK=47,D_DATA=49,Q_LUT=50,Q_PAIR=51,
        END_MERGE=52,LUT_SUM=53,LUT_END=54,LUT_VALIDATE=55,
        LUT_OVERLAP=56,LUT_OVERLAP_CHECK=57,GROUP_CLEAR=58;
    reg [12:0] local_sweep;
    reg sweep_last,plane_is_single;
    reg [4:0] lut_beat;
    reg [31:0] lut_fetch_address;
    reg lut_fetch_carry16;
    // The table pointer is loaded before its first request. Predict the
    // low-word carry when advancing it so neither the request mux nor the
    // pointer feedback contains a full 32-bit carry chain.
    always @(posedge clk)
        if(reset_active)begin lut_fetch_address<=0;lut_fetch_carry16<=0;end
        else if(state[LUT_OVERLAP_CHECK])begin
            lut_fetch_address<=lut_base;
            lut_fetch_carry16<=(&lut_base[15:3]);
        end else if(state[LUT_RSP] && rsp_valid)begin
            lut_fetch_address[15:3]<=lut_fetch_address[15:3]+13'd1;
            lut_fetch_address[31:16]<=lut_fetch_address[31:16]+lut_fetch_carry16;
            lut_fetch_carry16<=lut_fetch_address[15:3]==13'h1ffe;
        end
    reg [31:0] skipped_chunks;
    (* ram_style="distributed" *) reg [63:0] lut_table[0:31];
    (* ram_style="block" *) reg [7:0] pool_row[0:8191];
    reg [7:0] pool_row_q,pool_row_pipe;
    reg [7:0] pool_left[0:31];
    reg [17:0] pool_pixel,pool_row_base;
    reg [31:0] pooled_output_index;
    reg [63:0] q_words[0:31];
    reg [7:0] q_masks[0:31];
    // The channel stays stable from output selection through Q_EMIT. Read
    // its partial word ahead of the byte merge instead of putting LUT RAM,
    // byte masking and the pending-write register on one timing path.
    (* DONT_TOUCH="TRUE" *) reg [63:0] q_word_q;
    (* DONT_TOUCH="TRUE" *) reg [7:0] q_mask_q;
    reg [63:0] q_pending_word;
    reg [7:0] q_pending_mask,q_payload,q_lut,pool_pair_reg;
    reg [9:0] active_count;
    reg active_empty;
    always @(posedge clk)
        if(reset_active)active_empty<=1'b1;
        else active_empty<=active_count==10'd0;
    reg [7:0] feed_penultimate,weight_read_chunk;
    reg issue_is_last;
    (* ram_style="distributed" *) reg [7:0] chunk_map[0:255];
    wire h_done;
    wire [31:0] h_error,h_terms,h_outputs,h_zero;
    wire h_req_valid,h_req_write,h_rsp_ready;
    wire [31:0] h_req_addr,h_req_low,h_req_high;
    wire [63:0] h_req_data;
    wire [7:0] h_req_strb;
    wire [1:0] h_req_kind;

    wire [31:0] src=cfg[0], weights=cfg[1], biases=cfg[2], multipliers=cfg[3], shifts=cfg[4];
    wire [31:0] dst_acc=cfg[5],dst_q=cfg[6],ci=cfg[7],co=cfg[8],height=cfg[9],width=cfg[10];
    wire [31:0] kernel=cfg[11],pad=cfg[12],zx=cfg[13],zy=cfg[14];
    // Configuration is immutable throughout a running layer. Decode this
    // wide comparison before the pixel gather starts, keeping cfg[11] off
    // the border/mux path. CHECK/SIZE/RO validation provides ample settling.
    reg kernel_is_one;
    always @(posedge clk)
        if(reset_active)kernel_is_one<=1'b0;
        else kernel_is_one<=kernel==32'd1;
    tinyyolo_head_exact head(.clk(clk),.rst_n(!arithmetic_reset[24]),.start(state[H_START]),
        .src(src),.table_base(weights),.dst(dst_q),.ci(ci),.height(height),.width(width),
        .busy(),.done(h_done),.error_code(h_error),.terms(h_terms),.outputs_written(h_outputs),.zero_skipped(h_zero),
        .req_valid(h_req_valid),.req_ready(req_ready),.req_write(h_req_write),
        .req_addr(h_req_addr),.req_wdata(h_req_data),.req_wstrb(h_req_strb),.req_kind(h_req_kind),
        .req_low(h_req_low),.req_high(h_req_high),.rsp_valid(rsp_valid),
        .rsp_ready(h_rsp_ready),.rsp_data(rsp_data),.rsp_error(rsp_error));
    wire busy=!state[IDLE] && !state[FINISH] && !state[FAULT];
    wire [31:0] status={29'd0,state[FAULT],state[FINISH],busy};
    reg aw_hold,w_hold;
    // AXI write address is decoded into local selects at the handshake.
    reg [31:0] wdata;
    reg [3:0] wstrb;
    wire commit=aw_hold && w_hold && !s_bvalid;
    reg start_req,clear_req;
    // Decode the address when AW is accepted, independently of W arrival.
    // Fixed one-hot selects remove the dynamic address subtract/index from
    // configuration-register byte enables at the later commit cycle.
    (* MAX_FANOUT=16 *) reg [14:0] config_select;
    reg command_select,options_select,lut_select;
    genvar config_word;
    generate for(config_word=0;config_word<15;config_word=config_word+1)begin: config_address_decode
        always @(posedge clk)
            if(reset_active)config_select[config_word]<=0;
            else if(s_awready && s_awvalid)
                config_select[config_word]<=s_awaddr==(8+4*config_word);
    end endgenerate
    always @(posedge clk)
        if(reset_active)begin command_select<=0;options_select<=0;lut_select<=0;end
        else if(s_awready && s_awvalid)begin
            command_select<=s_awaddr==8'h00;
            options_select<=s_awaddr==8'h44;
            lut_select<=s_awaddr==8'h4c;
        end
    // Decode commands before they drive counters or wide datapath enables.
    // Ignore busy submissions at acceptance, even if the layer finishes on
    // the following clock. AXI-Lite response ordering remains unchanged.
    always @(posedge clk) begin
        if(reset_active)begin start_req<=0;clear_req<=0;end
        else begin
            start_req<=commit && command_select && wstrb[0] && wdata[0] && state[IDLE];
            clear_req<=commit && command_select && wstrb[0] && wdata[1] && !busy;
        end
    end
    (* EXTRACT_ENABLE="NO" *) reg [31:0] event_error_code;
    reg invalid_error;
    wire [31:0] error_code=invalid_error?32'd5:event_error_code;
    reg [31:0] reads,writes,macs;
    reg [16:0] macs_add_lo;
    reg [15:0] macs_add_hi;
    wire [31:0] outputs_written;
    reg accepted_read,accepted_write;
    always @(posedge clk)
        if(reset_active) begin accepted_read<=1'b0;accepted_write<=1'b0;end
        else begin
            accepted_read<=req_valid && req_ready && !req_write;
            accepted_write<=req_valid && req_ready && req_write;
        end
    wire [63:0] cycles;
    tinyyolo_counter64 cycle_count(.clk(clk),.rst_n(rst_n),
        .clear(clear_req || start_req),
        .enable(busy),.value(cycles));
    reg [31:0] plane,taps,src_bytes,q_bytes,acc_bytes,weight_bytes,chunks,pad_offset;
    // Six LUT arithmetic stages free DSPs for the convolution datapath.
    // Inputs remain stable throughout validation; SIZE0/SIZE1 wait for pipes.
    // runtime group arithmetic is ready long before its parameter fetch ends.
    reg [2:0] size_wait;
    wire signed [42:0] dimension_product,source_size_product,output_size_product;
    wire signed [42:0] weight_size_product,group_size_product;
    // Terminal values are computed once after dimension validation. Compare
    // against the current counter, not increment -> 32-bit compare -> CE.
    // Predict the terminal-pixel condition one transition early. Q_EMIT and
    // NEXT_PIXEL then consume a local register instead of a wide equality
    // feeding the state decoder on the 170 MHz path.
    reg [17:0] before_last_pixel;
    reg [17:0] pixel;
    reg pixel_is_last;
    // Pixel and terminal value settle throughout the gather/MAC/output states.
    // Register three local comparisons before NEXT_PIXEL consumes their AND;
    // an 18-bit equality and its carry chain need not sit on that control edge.
    reg [2:0] before_last_pixel_match;
    always @(posedge clk) begin
        before_last_pixel_match[0]<=pixel[5:0]==before_last_pixel[5:0];
        before_last_pixel_match[1]<=pixel[11:6]==before_last_pixel[11:6];
        before_last_pixel_match[2]<=pixel[17:12]==before_last_pixel[17:12];
    end
`ifndef SYNTHESIS
    always @(posedge clk)if(rst_n && state[NEXT_PIXEL] && !pixel_is_last &&
        (&before_last_pixel_match)!==(pixel==before_last_pixel))
        $fatal(1,"PIXEL_TERMINAL_COMPARISON_NOT_SETTLED");
`endif
    reg pixel_is_row_last;
    reg [12:0] last_tap,before_last_tap;
    reg tap_is_last;
    reg [7:0] last_chunk;
    reg [1:0] last_kernel;
    reg last_group;
    reg [10:0] group_base;
    reg [5:0] group_size;
    reg [4:0] last_oc;
    reg [31:0] weight_pointer;
    reg [14:0] weight_left;
    reg [14:0] group_weight_beats;
    reg last_weight;
    // Update alongside group_base. The GROUP cycle then consumes a local
    // count, without a configuration subtraction before last_oc/BRAM enables.
    reg [10:0] remaining_channels;
    reg [31:0] source_high,weight_high,bias_high,multiplier_high,shift_high;
    reg [4:0] p_oc,local_oc,w_oc;
    reg local_oc_is_last;
    always @(posedge clk)
        if(reset_active)local_oc_is_last<=1'b0;
        else local_oc_is_last<=local_oc==last_oc;
    reg [1:0] p_kind;
    reg [31:0] parameter_address;
    reg [31:0] parameter_low,parameter_high;
    reg [16:0] parameter_address_lo;
    reg [15:0] parameter_address_hi;
    reg parameter_address_join;
    // Each P_ADDR visit has a low-word addition followed by a carry join.
    // No VALID request is issued until the full address has been registered.
    always @(posedge clk)
        if(reset_active)parameter_address_join<=1'b0;
        else parameter_address_join<=state[P_ADDR] && !parameter_address_join;
    // Private request staging is overwritten on every P_ADDR visit before
    // P_REQ can assert VALID. It does not need the global synchronous reset;
    // keeping that reset off these 129 bits avoids a long PS-reset route.
    always @(posedge clk)
        if(state[P_ADDR])begin
            if(parameter_address_join)
                parameter_address<={parameter_address_hi+{15'd0,parameter_address_lo[16]},parameter_address_lo[15:0]};
            else case(p_kind)
                0:begin
                    parameter_address_lo<={1'b0,biases[15:0]}+{4'd0,group_base[10:5],p_oc,2'd0};
                    parameter_address_hi<=biases[31:16];
                    parameter_low<=biases;parameter_high<=bias_high;
                end
                1:begin
                    parameter_address_lo<={1'b0,multipliers[15:0]}+{3'd0,group_base[10:5],p_oc,3'd0};
                    parameter_address_hi<=multipliers[31:16];
                    parameter_low<=multipliers;parameter_high<=multiplier_high;
                end
                default:begin
                    parameter_address_lo<={1'b0,shifts[15:0]}+{4'd0,group_base[10:5],p_oc,2'd0};
                    parameter_address_hi<=shifts[31:16];
                    parameter_low<=shifts;parameter_high<=shift_high;
                end
            endcase
        end
    reg next_parameter,parameter_is_shift;
    reg parameter_zero,parameter_wide,shift_low_bad,shift_high_bad;
    // Check both response halves independently before selecting their one-bit
    // flags. Selecting a 32-bit half ahead of its reduction put the parameter
    // address mux and a wide reduction on one response-register path.
    wire parameter_bad=(p_kind==1 && (parameter_zero || parameter_wide)) ||
        (p_kind==2 && (parameter_address[2]?shift_high_bad:shift_low_bad));
    // Parameter kind/channel are stable from P_ADDR through P_RSP. Decode
    // completion before P_NEXT instead of placing it in wide weight-RAM CEs.
    always @(posedge clk)
        if(reset_active)begin
            parameter_zero<=0;parameter_wide<=0;shift_low_bad<=0;shift_high_bad<=0;
            next_parameter<=0;parameter_is_shift<=0;
        end
        else begin
            if(state[P_ADDR])begin
                next_parameter<=p_kind!=2 || p_oc!=last_oc;
                parameter_is_shift<=p_kind==2;
            end
            if(state[P_RSP] && rsp_valid)begin
                parameter_zero<=!(|rsp_data);
                parameter_wide<=|rsp_data[63:36];
                shift_low_bad<=(|rsp_data[31:6]) || rsp_data[5:0]==0 || (&rsp_data[5:0]);
                shift_high_bad<=(|rsp_data[63:38]) || rsp_data[37:32]==0 || (&rsp_data[37:32]);
            end
        end
    reg [7:0] w_chunk,issue_chunk;
    reg [1:0] w_phase;
    reg [127:0] w_low;
    // Stage the completed 192-bit weight word and its address. This keeps the
    // wide weight BRAM enable off the distributed W_RSP state decode path.
    reg [12:0] weight_write_address;
    reg [191:0] weight_write_data;
    (* ram_style="block" *) reg [191:0] activation_mem[0:255];
    wire [191:0] weight_data[0:15];
    reg [191:0] activation_data,activation_q,activation_pipe,activation_dot;
    reg feed_valid,feed_last,dot_feed_valid,dot_feed_last;
    always @(posedge clk)
        if(reset_active)begin
            feed_valid<=0;feed_last<=0;dot_feed_valid<=0;dot_feed_last<=0;
        end else begin
            feed_valid<=state[D_FEED];feed_last<=issue_is_last;
            dot_feed_valid<=feed_valid;dot_feed_last<=feed_last;
        end
    // Sixteen concurrent two-entry reads require explicit flip-flop storage.
    (* ram_style="registers" *) reg signed [31:0] bias_mem[0:31];
    // Each requant lane addresses just four entries. Keep this small table
    // in local LUT RAM instead of adding BRAM tCO to its parameter pipeline.
    (* ram_style="distributed" *) reg [63:0] mul_mem[0:31];
    reg [5:0] shift_mem[0:31];
    // Capture response data and one-hot write commands together. The next
    // P_NEXT edge writes each local RAM with an already registered enable.
    (* DONT_TOUCH="TRUE" *) reg [2:0] parameter_store;
    // Duplicate the short reset-qualified write command near each table's
    // address decoder; it must not drive all table CEs from one LUT.
    (* MAX_FANOUT=8 *) wire [2:0] parameter_write=parameter_store & {3{rst_n}};
    // Keep the write-index registers local to each parameter table.  Sharing
    // one index register made its Q[1] net fan out to every distributed RAM
    // write address (144 loads), creating a long post-route setup path at
    // 240 MHz.  These registers carry the same value and are captured on the
    // same edge, so the write-cycle semantics are unchanged while each net
    // only drives its own table.
    (* DONT_TOUCH="TRUE" *) reg [4:0] parameter_store_bias_index;
    (* DONT_TOUCH="TRUE" *) reg [4:0] parameter_store_mul_index;
    (* DONT_TOUCH="TRUE" *) reg [4:0] parameter_store_shift_index;
    reg [31:0] parameter_store_bias;
    reg [63:0] parameter_store_multiplier;
    reg [5:0] parameter_store_shift;
    always @(posedge clk) begin
        if(reset_active)parameter_store<=3'd0;
        else begin
            parameter_store[0]<=state[P_RSP] && rsp_valid && !rsp_error && p_kind==2'd0;
            parameter_store[1]<=state[P_RSP] && rsp_valid && !rsp_error && p_kind==2'd1;
            parameter_store[2]<=state[P_RSP] && rsp_valid && !rsp_error && p_kind==2'd2;
        end
        parameter_store_bias_index<=p_oc;
        parameter_store_mul_index<=p_oc;
        parameter_store_shift_index<=p_oc;
        parameter_store_bias<=parameter_address[2]?rsp_data[63:32]:rsp_data[31:0];
        parameter_store_multiplier<=rsp_data;
        parameter_store_shift<=parameter_address[2]?rsp_data[37:32]:rsp_data[5:0];
        if(parameter_write[0])bias_mem[parameter_store_bias_index]<=parameter_store_bias;
        if(parameter_write[1])mul_mem[parameter_store_mul_index]<=parameter_store_multiplier;
        if(parameter_write[2])shift_mem[parameter_store_shift_index]<=parameter_store_shift;
    end
    // The speculative read after the final chunk is never consumed. Removing
    // its terminal compare keeps that control off every BRAM read-address pin.
    wire [7:0] read_chunk=(state[D_FEED])?issue_chunk+8'd2:
        (state[D_ALIGN]?8'd1:issue_chunk);
    // Pre-register the sparse-map read address so the FSM state decode is not
    // in series with the distributed RAM lookup and weight-read register.
    reg [7:0] map_read_chunk;
    // These counters are used only after the full-width configuration guards.
    reg [9:0] px;
    reg [8:0] py;
    reg [12:0] tap;
    reg [31:0] pixel_source;
    reg [31:0] channel_origin,row_origin;
    // Prepare the first padded pixel long before the weight fetch completes.
    // Width has passed its guard and pad_offset fits in ten bits. A split
    // subtraction removes the variable 32-bit borrow from PIXEL fanout.
    reg [16:0] source_origin_lo;
    reg [15:0] source_origin_hi;
    reg [31:0] source_origin;
    always @(posedge clk)begin
        source_origin_lo<={1'b0,src[15:0]}-{1'b0,pad_offset[15:0]};
        source_origin_hi<=src[31:16];
        source_origin<={source_origin_hi-{15'd0,source_origin_lo[16]},source_origin_lo[15:0]};
    end
    // Every real k1 gather takes at least G_LOOK plus G_CHECK/G_COORD;
    // k3 row/channel steps are separated by three/nine taps, even in padding.
    // Prepare the next origins in those existing cycles so the address mux
    // and its enable do not follow a configuration-width carry chain.
    reg [31:0] next_channel_origin,next_row_origin;
    always @(posedge clk) begin
        next_channel_origin<=channel_origin+plane;
        next_row_origin<=row_origin+{22'd0,width[9:0]};
    end
    reg [9:0] last_x;
    reg [8:0] last_y;
    reg [2:0] valid_x,valid_y;
    reg [1:0] kx,ky;
    reg [31:0] input_address,output_index,output_channel_offset,group_channel_offset;
    reg [16:0] output_offset_lo;
    reg [15:0] output_offset_hi;
    // The offset is stable throughout each output. Prepare its next plane
    // advance before NEXT_OC, so publication needs only a local carry join.
    always @(posedge clk) begin
        output_offset_lo<={1'b0,output_channel_offset[15:0]}+{1'b0,plane[15:0]};
        output_offset_hi<=output_channel_offset[31:16]+plane[31:16];
    end
    // Update carry flags together with the address. A padding capture can
    // follow PIXEL or a row commit immediately, so sampling the old address
    // one clock later would give the speculative increment stale carries.
    reg [2:0] input_increment_carry;
    // Decode the next tap address during capture. Commit then needs only
    // one local enable, without the five-state gather decoder or a kernel
    // comparison in series with the address mux. No gather cycle is added.
    reg [31:0] gather_address_next;
    always @(posedge clk)
        if(kx==last_kernel)
            gather_address_next<=ky==last_kernel?next_channel_origin:next_row_origin;
        else begin
            gather_address_next[7:0]<=input_address[7:0]+8'd1;
            gather_address_next[15:8]<=input_address[15:8]+input_increment_carry[0];
            gather_address_next[23:16]<=input_address[23:16]+input_increment_carry[1];
            gather_address_next[31:24]<=input_address[31:24]+input_increment_carry[2];
        end
    // Configuration is stable before CHECK. Prepare the constant-nine
    // product and select it in separate stages, entirely in LUT arithmetic.
    reg [13:0] config_taps_k3,config_taps;
    (* use_dsp="no" *) reg [7:0] config_chunks;
    // ceil(taps/24) = floor(((taps+23)>>3)/3). Base-16 long
    // division uses a six-input LUT for each quotient/remainder digit.
    // Short registered stages replace the former 17-level carry path.
    reg [13:0] config_rounded;
    reg [3:0] config_div_mid;
    reg [1:0] config_rem_hi,config_rem_mid;
    reg [7:0] config_div_low;
    reg [3:0] config_div_tail;
    function [5:0] div3_digit;
        input [5:0] value;
        begin
            case(value)
                6'd0: div3_digit=6'd0;
                6'd1: div3_digit=6'd1;
                6'd2: div3_digit=6'd2;
                6'd3: div3_digit=6'd4;
                6'd4: div3_digit=6'd5;
                6'd5: div3_digit=6'd6;
                6'd6: div3_digit=6'd8;
                6'd7: div3_digit=6'd9;
                6'd8: div3_digit=6'd10;
                6'd9: div3_digit=6'd12;
                6'd10: div3_digit=6'd13;
                6'd11: div3_digit=6'd14;
                6'd12: div3_digit=6'd16;
                6'd13: div3_digit=6'd17;
                6'd14: div3_digit=6'd18;
                6'd15: div3_digit=6'd20;
                6'd16: div3_digit=6'd21;
                6'd17: div3_digit=6'd22;
                6'd18: div3_digit=6'd24;
                6'd19: div3_digit=6'd25;
                6'd20: div3_digit=6'd26;
                6'd21: div3_digit=6'd28;
                6'd22: div3_digit=6'd29;
                6'd23: div3_digit=6'd30;
                6'd24: div3_digit=6'd32;
                6'd25: div3_digit=6'd33;
                6'd26: div3_digit=6'd34;
                6'd27: div3_digit=6'd36;
                6'd28: div3_digit=6'd37;
                6'd29: div3_digit=6'd38;
                6'd30: div3_digit=6'd40;
                6'd31: div3_digit=6'd41;
                6'd32: div3_digit=6'd42;
                6'd33: div3_digit=6'd44;
                6'd34: div3_digit=6'd45;
                6'd35: div3_digit=6'd46;
                6'd36: div3_digit=6'd48;
                6'd37: div3_digit=6'd49;
                6'd38: div3_digit=6'd50;
                6'd39: div3_digit=6'd52;
                6'd40: div3_digit=6'd53;
                6'd41: div3_digit=6'd54;
                6'd42: div3_digit=6'd56;
                6'd43: div3_digit=6'd57;
                6'd44: div3_digit=6'd58;
                6'd45: div3_digit=6'd60;
                6'd46: div3_digit=6'd61;
                6'd47: div3_digit=6'd62;
                default: div3_digit=6'd0;
            endcase
        end
    endfunction
    wire [5:0] config_digit_hi=div3_digit({3'd0,config_rounded[13:11]});
    wire [5:0] config_digit_mid=div3_digit({config_rem_hi,config_div_low[7:4]});
    wire [5:0] config_digit_lo=div3_digit({config_rem_mid,config_div_tail});
    always @(posedge clk)begin
        config_rounded<=config_taps+14'd23;
        config_rem_hi<=config_digit_hi[1:0];
        config_div_low<=config_rounded[10:3];
        config_div_mid<=config_digit_mid[5:2];
        config_rem_mid<=config_digit_mid[1:0];
        config_div_tail<=config_div_low[3:0];
        // Valid taps <=4608 imply an eight-bit quotient. The high digit
        // is zero on supported shapes; the shape guard rejects others.
        config_chunks<={config_div_mid,config_digit_lo[5:2]};
    end
    always @(posedge clk) begin
        config_taps_k3<={3'd0,ci[10:0]}+{ci[10:0],3'd0};
        config_taps<=kernel[1:0]==2'd3 ? config_taps_k3:{3'd0,ci[10:0]};
    end
    reg [31:0] accumulator_address,quantized_address;
    reg output_regions_bad,output_limits_bad;
    reg config_unaligned,config_dimensions_bad,sizes_bad;
    reg config_channels_bad,config_spatial_bad,config_kernel_pad_bad,config_zero_points_bad;
    reg [5:0] config_channel_parts,config_spatial_parts;
    reg [2:0] config_pool_parts;
    reg config_pool_bad,config_lut_bad,lut_bounds_bad;
    reg [1:0] config_guard_error;
    // Config writes finish before START is accepted. Capture independent full
    // width guards without putting their reduction trees on multiplier enables.
    always @(posedge clk) begin
        config_unaligned<=|(src[2:0]|weights[2:0]|biases[2:0]|multipliers[2:0]|shifts[2:0]|dst_acc[2:0]|dst_q[2:0]);
        // Keep independent configuration reductions out of one long compare /
        // OR chain. START reaches CHECK several cycles after the final AXI-Lite
        // config write, so this registered reduction stage preserves the guard
        // result while shortening the 180-MHz path.
        // Reject high bits independently: a zero low word is also invalid
        // whenever a high bit is set. Small parallel predicates followed by
        // one reduction avoid a full-width compare plus serial guard muxes.
        config_channel_parts[0]<=ci[10:0]==11'd0;
        config_channel_parts[1]<=|ci[31:11];
        config_channel_parts[2]<=ci[10:0]>11'd1024;
        config_channel_parts[3]<=co[10:0]==11'd0;
        config_channel_parts[4]<=|co[31:11];
        config_channel_parts[5]<=co[10:0]>11'd1024;
        config_channels_bad<=|config_channel_parts;
        config_spatial_parts[0]<=height[8:0]==9'd0;
        config_spatial_parts[1]<=|height[31:9];
        config_spatial_parts[2]<=height[8:0]>9'd416;
        config_spatial_parts[3]<=width[9:0]==10'd0;
        config_spatial_parts[4]<=|width[31:10];
        config_spatial_parts[5]<=width[9:0]>10'd845;
        config_spatial_bad<=|config_spatial_parts;
        config_kernel_pad_bad<=(|kernel[31:2]) || (|pad[31:1]) ||
            !((kernel[1:0]==2'd1 && !pad[0]) || (kernel[1:0]==2'd3 && pad[0]));
        config_zero_points_bad<=(|(zx[31:8] ^ {24{zx[7]}})) || (|(zy[31:8] ^ {24{zy[7]}}));
        config_dimensions_bad<=config_channels_bad || config_spatial_bad ||
            config_kernel_pad_bad || config_zero_points_bad;
        config_pool_parts[0]<=!options[1] || height[0] || width[0];
        config_pool_parts[1]<=|width[31:10];
        config_pool_parts[2]<=width[9:0]>10'd512;
        config_pool_bad<=options[6] && (|config_pool_parts);
        config_lut_bad<=options[1] && (lut_base[2:0]!=3'd0 || lut_base<32'h0010_0000);
        // The table is exactly 256 bytes. In 33-bit arithmetic,
        // base+256 > 0x1fff0000 iff base > 0x1ffeff00 for every UINT32 base.
        // Capture this while configuration is stable instead of placing the
        // end-address comparison on LUT_VALIDATE -> FAULT/error-code paths.
        lut_bounds_bad<=lut_base>32'h1ffe_ff00;
        config_guard_error<=config_pool_bad?2'd2:
            ((config_lut_bad || config_unaligned)?2'd1:(config_dimensions_bad?2'd2:2'd0));
        // SIZE1 consumes this only after SIZE0 has captured the current sizes.
        sizes_bad<=plane>173056 || taps>4608;
        group_weight_beats<={group_size_product[13:0],1'b0}+{1'b0,group_size_product[13:0]};
        if(state[W_REQ])last_weight<=weight_left==15'd1;
    end
    (* ram_style="block" *) reg [63:0] local_data[0:8191];
    (* ram_style="block" *) reg [16:0] local_tags[0:8191];
    reg [63:0] local_data_q;
    (* DONT_TOUCH="TRUE" *) reg [63:0] local_data_pipe;
    reg [16:0] local_tag_q,local_tag_pipe;
    reg [2:0] local_tag_equal_q;
    wire local_hit=&local_tag_equal_q;
    localparam [1:0] TAP_CACHE=2'd0,TAP_DDR=2'd1,TAP_LOCAL=2'd2,TAP_PENDING=2'd3;
    reg [1:0] tap_source;
    reg gather_pending;
    reg cache_valid;
    reg [28:0] cache_tag;
    reg [63:0] cache_data;
    reg [4:0] gather_tag_equal_q;
    wire [4:0] gather_tag_equal;
    // Predict padding when advancing the coordinates. The registered flag
    // keeps two dynamic coordinate muxes off the gather commit/state fanout.
    reg gather_padding;
    reg pixel_left_border,pixel_top_border;
    // Retire cache fill data and its tag together from a local command.
    // G_RSP captures the response; its existing gather-commit clock writes
    // both RAMs before another local lookup can consume the line.
    (* DONT_TOUCH="TRUE" *) reg local_store_valid;
    reg [12:0] local_store_index;
    reg [16:0] local_store_tag;
    reg [63:0] local_store_data;
    always @(posedge clk) begin
        if(reset_active)local_store_valid<=1'b0;
        else local_store_valid<=options[4] && state[G_RSP] && !gather_pending && rsp_valid && !rsp_error;
        local_store_index<=input_address[15:3];
        local_store_tag<={1'b1,input_address[31:16]};
        local_store_data<=rsp_data;
    end
    // One explicit tag write port keeps this array in BRAM. Separate sweep
    // and fill assignments infer independent ports and an expensive LUT RAM.
    wire local_tag_write=rst_n && (state[LC_SWEEP] || local_store_valid);
    wire [12:0] local_tag_write_index=state[LC_SWEEP]?local_sweep:local_store_index;
    wire [16:0] local_tag_write_data=state[LC_SWEEP]?17'd0:local_store_tag;
    always @(posedge clk) begin
        local_data_q<=local_data[input_address[15:3]];
        local_data_pipe<=local_data_q;
        local_tag_q<=local_tags[input_address[15:3]];
        local_tag_pipe<=local_tag_q;
        // G_LOOK reads the tag; G_COORD clocks the BRAM output register;
        // G_ADDR clocks these comparisons; G_STORE consumes their reduction.
        // Comparing after the output register removes raw BRAM tCO from the
        // equality path without adding a gather state or using an old tag.
        local_tag_equal_q[0]<=~|(local_tag_pipe[5:0]^input_address[21:16]);
        local_tag_equal_q[1]<=~|(local_tag_pipe[11:6]^input_address[27:22]);
        local_tag_equal_q[2]<=~|(local_tag_pipe[16:12]^{1'b1,input_address[31:28]});
        if(reset_active) begin
            gather_tag_equal_q<=5'd0;
            tap_source<=TAP_PENDING;
        end else begin
            if(state[G_LOOK]) begin
                // Validity belongs to this address comparison sample. It
                // cannot change between G_LOOK and the matching hit consumer.
                gather_tag_equal_q<=gather_tag_equal & {5{cache_valid}};
                tap_source<=gather_padding?TAP_CACHE:
                    ((cache_valid && (&gather_tag_equal))?TAP_CACHE:TAP_PENDING);
            end
            if(state[G_ADDR])tap_source<=TAP_LOCAL;
            if(state[G_REQ] && req_ready)tap_source<=TAP_DDR;
        end
        if(local_tag_write)
            local_tags[local_tag_write_index]<=local_tag_write_data;
        if(local_store_valid)
            local_data[local_store_index]<=local_store_data;
    end
    // Test the address that was registered by the preceding gather step.
    // Precomputing the next tag hit here chained the channel_origin + plane
    // adder into the tag comparators and the gather-tag register at 170 MHz.
    // G_LOOK already provides a cycle after input_address is registered, so
    // compare that stable address directly against the cached word tag.
    wire [31:0] pixel_gather_address=pixel_source;
    // Split the 29-bit tag compare into small parallel reductions. Vivado's
    // inferred wide equality used a serial CARRY4 chain on the G_LOOK -> FSM
    // path; local chunks keep the comparison in LUT levels and reduce delay.
    assign gather_tag_equal[0]=~|(cache_tag[5:0]   ^ input_address[8:3]);
    assign gather_tag_equal[1]=~|(cache_tag[11:6]  ^ input_address[14:9]);
    assign gather_tag_equal[2]=~|(cache_tag[17:12] ^ input_address[20:15]);
    assign gather_tag_equal[3]=~|(cache_tag[23:18] ^ input_address[26:21]);
    assign gather_tag_equal[4]=~|(cache_tag[28:24] ^ input_address[31:27]);
    wire gather_hit=&gather_tag_equal_q;
    wire gather_capture=!gather_pending && ((state[G_LOOK] && gather_padding) ||
        ((state[G_COORD] || state[G_CHECK]) && gather_hit) ||
        (state[G_RSP] && rsp_valid && !rsp_error) || (state[G_STORE] && local_hit));
    wire gather_commit=gather_pending;
    // Fill only on the actual producer handshake. Keeping these registers
    // outside the gather case removes padding and cache-hit decode from the
    // 64-bit fill enable, while tag, data and valid still retire together.
    wire gather_fill=!gather_pending &&
        ((state[G_RSP] && rsp_valid && !rsp_error) || (state[G_STORE] && local_hit));
    always @(posedge clk)
        if(reset_active)begin cache_valid<=1'b0;cache_tag<=29'd0;cache_data<=64'd0;end
        else begin
            if((state[IDLE] && start_req) || (state[W_RSP] && rsp_valid && last_weight))
                cache_valid<=1'b0;
            else if(gather_fill)cache_valid<=1'b1;
            if(gather_fill)begin
                cache_tag<=input_address[31:3];
                cache_data<=state[G_STORE]?local_data_pipe:rsp_data;
            end
        end
    // Capture the address-step qualification beside the sample. Commit is
    // exactly one clock later, so no gather-state decode or tap comparator
    // needs to drive the 64 origin-register enables at the commit edge.
    (* DONT_TOUCH="TRUE" *) reg gather_channel_step,gather_row_step;
    always @(posedge clk)
        if(reset_active)begin gather_channel_step<=1'b0;gather_row_step<=1'b0;end
        else begin
            gather_channel_step<=gather_capture && !tap_is_last &&
                kx==last_kernel && ky==last_kernel;
            gather_row_step<=gather_capture && !tap_is_last &&
                kx==last_kernel && ky!=last_kernel;
        end
    always @(posedge clk)
        if(reset_active)begin channel_origin<=32'd0;row_origin<=32'd0;end
        else if(state[PIXEL])begin
            channel_origin<=pixel_source;row_origin<=pixel_source;
        end else if(gather_channel_step)begin
            channel_origin<=next_channel_origin;row_origin<=next_channel_origin;
        end else if(gather_row_step)row_origin<=next_row_origin;
    always @(posedge clk) begin
        if(reset_active)gather_padding<=1'b0;
        else if(state[PIXEL])
            gather_padding<=!kernel_is_one && (pixel_left_border || pixel_top_border);
        else if(gather_commit)begin
            if(kx==last_kernel)begin
                if(ky==last_kernel)
                    gather_padding<=!valid_x[0] || !valid_y[0];
                else gather_padding<=!valid_x[0] || !valid_y[ky+2'd1];
            end else gather_padding<=!valid_x[kx+2'd1] || !valid_y[ky];
        end
    end
    // G_LOOK settles the registered address before a cache hit is committed;
    // local RAM also has its G_ADDR cycle. Extract bytes in those existing
    // cycles, keeping the 64-to-8 mux out of the pack write path. DDR data
    // remains selected at its actual response handshake.
    reg [7:0] cache_byte,local_byte;
    always @(posedge clk) begin
        cache_byte<=cache_data[input_address[2:0]*8+:8];
        local_byte<=local_data_pipe[input_address[2:0]*8+:8];
    end
    wire [7:0] gather_value=gather_padding?zx[7:0]:
        (tap_source==TAP_DDR?rsp_data[input_address[2:0]*8+:8]:
        (tap_source==TAP_LOCAL?local_byte:cache_byte));
    reg [7:0] tap_value;
    // Capture every producer once, including a DDR response that can vanish
    // immediately after its handshake. Commit the byte and sparse reduction
    // on the following clock, with the FSM held locally in its gather state.
    always @(posedge clk)
        if(reset_active)begin gather_pending<=1'b0;tap_value<=8'd0;end
        else begin
            gather_pending<=gather_capture;
            if(gather_capture)tap_value<=gather_value;
        end
    reg [7:0] gather_chunk;
    reg [4:0] tap_in_chunk;
    // Independent chunk/byte counters avoid division/modulo in gather.
    always @(posedge clk)
        if(reset_active || state[PIXEL])begin gather_chunk<=0;tap_in_chunk<=0;end
        else if(gather_commit)begin
            if(tap_in_chunk==5'd23)begin tap_in_chunk<=0;gather_chunk<=gather_chunk+8'd1;end
            else tap_in_chunk<=tap_in_chunk+5'd1;
        end
    reg pack_nonzero,chunk_nonzero,chunk_final;
    reg [7:0] chunk_index,chunk_original;
    reg [191:0] pack;
    // G_CHUNK writes the completed pack before clearing it. Byte enables
    // replace the old full-width pack_next and redundant chunk_data muxes.
    always @(posedge clk) begin
        if(reset_active || state[PIXEL] || state[G_CHUNK])begin pack<=0;pack_nonzero<=0;end
        else if(gather_commit)begin
            pack[tap_in_chunk*8+:8]<=tap_value;
            pack_nonzero<=pack_nonzero || tap_value!=0;
        end
    end
    always @(posedge clk) begin
        weight_read_chunk<=options[3]?chunk_map[map_read_chunk]:map_read_chunk;
        activation_q<=activation_mem[read_chunk];
        activation_data<=activation_q;
        activation_pipe<=activation_data;
        activation_dot<=activation_pipe;
        // Assemble a complete chunk before driving RAM write ports and the
        // sparse counter. Running byte OR avoids a variable-byte pack ->
        // 192-bit reduction -> RAM enable path at the end of every chunk.
        if(rst_n && state[G_CHUNK] && (!options[3] || chunk_nonzero)) begin
            activation_mem[chunk_index]<=pack;
            chunk_map[chunk_index]<=chunk_original;
        end
    end
    // Sixteen 24-MAC engines consume the same activation vector concurrently.
    // Bank weights by output-channel low bits; each bank has two channels.
    // Capacity is 32 * 256 * 24 bytes without RAM replication for read ports.
    wire [15:0] dot_valid,dot_last;
    wire signed [20:0] dot_sum[0:15];
    wire signed [31:0] accumulator_lane[0:15];
    wire signed [31:0] bias_lane[0:15];
    reg signed [31:0] result_lane[0:15];
    wire [15:0] accum_valid,accum_last,accum_overflow_now;
    reg [15:0] accumulator_overflow;
    reg accumulated_last;
    reg result_overflow;
    reg output_only;
    reg [3:0] selected_overflow_bank;
    reg selected_overflow;
    genvar overflow_bank;
    generate for(overflow_bank=0;overflow_bank<4;overflow_bank=overflow_bank+1)begin: overflow_read_bank
        always @(posedge clk)
            selected_overflow_bank[overflow_bank]<=accumulator_overflow[overflow_bank*4+local_oc[1:0]];
    end endgenerate
    always @(posedge clk)
        selected_overflow<=selected_overflow_bank[local_oc[3:2]];
    // accumulated_last is itself registered after the DSP output metadata.
    // Consequently the sticky lane flag has already sampled the final sum
    // before this edge. Avoid decoding the live DSP P bus a second time.
    always @(posedge clk)
        if(reset_active || state[OC_INIT])result_overflow<=1'b0;
        else if(state[D_WAIT] && accumulated_last)
            result_overflow<=accumulator_overflow[0];
        // NEXT_OC updates the selector. OC_RESULT and D_PRIME settle the
        // two mux stages before D_DATA publishes the selected sticky flag.
        else if(state[D_DATA] && output_only)
            result_overflow<=selected_overflow;
    reg signed [31:0] result_acc;
    reg signed [31:0] selected_acc_bank[0:3];
    reg signed [31:0] selected_acc;
    genvar acc_bank;
    generate for(acc_bank=0;acc_bank<4;acc_bank=acc_bank+1)begin: accumulator_read_bank
        always @(posedge clk)
            selected_acc_bank[acc_bank]<=result_lane[acc_bank*4+local_oc[1:0]];
    end endgenerate
    always @(posedge clk)
        selected_acc<=selected_acc_bank[local_oc[3:2]];
    tinyyolo_lut_mul #(.AW(9),.BW(10)) dim_mul(.clk(clk),.rst_n(rst_n),
            .a(height[8:0]),.b(width[9:0]),.product(dimension_product));
    tinyyolo_lut_mul #(.AW(18),.BW(11)) src_mul(.clk(clk),.rst_n(rst_n),
            .a(plane[17:0]),.b(ci[10:0]),.product(source_size_product));
    tinyyolo_lut_mul #(.AW(18),.BW(11)) out_mul(.clk(clk),.rst_n(rst_n),
            .a(plane[17:0]),.b(co[10:0]),.product(output_size_product));
    tinyyolo_lut_mul #(.AW(11),.BW(9)) weight_mul(.clk(clk),.rst_n(rst_n),
            .a(co[10:0]),.b(chunks[8:0]),.product(weight_size_product));
    tinyyolo_lut_mul #(.AW(6),.BW(9)) group_mul(.clk(clk),.rst_n(rst_n),
            .a(group_size),.b(chunks[8:0]),.product(group_size_product));
    always @(posedge clk)
        if(reset_active)accumulated_last<=0;
        else accumulated_last<=accum_valid[0] && accum_last[0];


    genvar compute_lane;
    generate for(compute_lane=0;compute_lane<16;compute_lane=compute_lane+1) begin: parallel_lane
        (* ram_style="block" *) reg [191:0] weight_bank[0:511];
        reg [191:0] weight_q,weight_pipe;
        // Isolate BRAM tCO and lane masking from signed weight packing.
        // Keep this physical stage so its mask cannot become a BRAM REGCE.
        (* DONT_TOUCH="TRUE" *) reg [191:0] weight_dot;
        // One local registered address per bank prevents the address/FSM
        // decode from driving the complete 1024-bit parallel memory interface.
        reg [8:0] read_address;
        reg signed [31:0] bias_q;
        (* DONT_TOUCH="TRUE" *) reg bias_result_load;
        always @(posedge clk)
            if(reset_active)bias_result_load<=1'b0;
            else bias_result_load<=state[D_PRIME] && !output_only && options[3] && active_empty;
        // Retain the local mask flip-flop. Absorbing it into the BRAM output
        // enable recreates a last_oc comparator on every bank's REGCE pin.
        (* DONT_TOUCH="TRUE" *) reg weight_enabled;
        (* MAX_FANOUT=16 *) wire weight_disabled=!weight_enabled;
        // Register the channel decode together with the completed weight
        // payload/address. Each BRAM receives a local one-bit write command.
        (* DONT_TOUCH="TRUE" *) reg weight_store;
        always @(posedge clk)
            if(reset_active)weight_store<=1'b0;
            else weight_store<=state[W_RSP] && rsp_valid && !rsp_error && w_phase==2'd2 &&
                w_oc[3:0]==compute_lane;
        always @(posedge clk) begin
            bias_q<=bias_mem[{local_oc[4],4'd0}+compute_lane];
            weight_enabled<=({local_oc[4],4'd0}+compute_lane)<=last_oc;
            read_address<={local_oc[4],weight_read_chunk};
            weight_q<=weight_bank[read_address];
            // A dedicated BRAM output stage allows DO_REG inference and
            // isolates memory tCO from the signed INT8 packing logic.
            weight_pipe<=weight_q;
            weight_dot<=weight_disabled?192'd0:weight_pipe;
            // A reset may retire one private pending write on assertion.
            // No bank is consumed until its next complete weight reload;
            // the local extension also blocks stale writes on release.
            if(!arithmetic_reset[compute_lane] && weight_store)
                weight_bank[{weight_write_address[12],weight_write_address[7:0]}]<=weight_write_data;
        end
        assign weight_data[compute_lane]=weight_dot;
        assign bias_lane[compute_lane]=bias_q;
        if ((compute_lane % 2)==0)begin: paired_dot
            tinyyolo_dot24_pair dot(.clk(clk),.rst_n(!arithmetic_reset[compute_lane]),
                .valid(dot_feed_valid),.last(dot_feed_last),.a(activation_dot),
                .w0(weight_data[compute_lane]),.w1(weight_data[compute_lane+1]),
                .out_valid(dot_valid[compute_lane]),.out_last(dot_last[compute_lane]),
                .sum0(dot_sum[compute_lane]),.sum1(dot_sum[compute_lane+1]));
            assign dot_valid[compute_lane+1]=dot_valid[compute_lane];
            assign dot_last[compute_lane+1]=dot_last[compute_lane];
        end
        tinyyolo_dsp_accum32 #(.TERM_WIDTH(21)) accum(.clk(clk),.rst_n(!arithmetic_reset[compute_lane]),.load(state[OC_INIT]),
            .bias(bias_q),
            .valid(dot_valid[compute_lane] && (state[D_FEED] || state[D_WAIT])),
            .last(dot_last[compute_lane]),.term(dot_sum[compute_lane]),
            .sum(accumulator_lane[compute_lane]),.overflow(accum_overflow_now[compute_lane]),
            .out_valid(accum_valid[compute_lane]),.out_last(accum_last[compute_lane]));
        always @(posedge clk) begin
            // Private result storage is overwritten before each requant.
            // Its validity comes from bias_result_load or the final MAC.
            if(bias_result_load) begin
                // No MAC was issued. The exact result is the registered bias;
                // do not read the DSP before its deeper load pipeline retires.
                result_lane[compute_lane]<=bias_q;
            end else if(accum_valid[compute_lane] && accum_last[compute_lane])
                result_lane[compute_lane]<=accumulator_lane[compute_lane];
        end
        always @(posedge clk) begin
            if(arithmetic_reset[compute_lane] || state[OC_INIT])accumulator_overflow[compute_lane]<=1'b0;
            else if(!bias_result_load && accum_valid[compute_lane])
                accumulator_overflow[compute_lane]<=accumulator_overflow[compute_lane] ||
                    accum_overflow_now[compute_lane];
        end
    end endgenerate
    // Two fully pipelined RNE engines dispatch all sixteen channels in eight
    // clocks. The channel tag accompanies the accumulator and its parameters
    // through both local read stages and the complete arithmetic pipeline.
    wire [1:0] q_done_lane;
    wire [2:0] q_result_tag[0:1];
    wire signed [7:0] q_result_lane[0:1];
    reg signed [7:0] q_result_bank[0:15];
    reg q_dispatch,q_complete;
    reg [2:0] q_pair;
    wire q_done=q_complete;
    wire [7:0] result_q=q_result_bank[local_oc[3:0]];
    reg [7:0] selected_result_q;
    reg [31:0] missing_chunks;
    always @(posedge clk)begin
        selected_result_q<=result_q;
        missing_chunks<=chunks-{22'd0,active_count};
        // MAC-count events are separated by complete output states. Prepare
        // two local word sums in those cycles, then join only their carry.
        macs_add_lo<={1'b0,macs[15:0]}+{1'b0,chunks[15:0]};
        macs_add_hi<=macs[31:16]+chunks[31:16];
    end
    integer qr;
    always @(posedge clk)begin
        if(reset_active)begin
            q_dispatch<=0;q_complete<=0;q_pair<=0;
            for(qr=0;qr<16;qr=qr+1)q_result_bank[qr]<=0;
        end else begin
            q_complete<=0;
            if(state[Q_START] && !output_only)begin
                q_dispatch<=1;q_pair<=0;
            end else if(q_dispatch)begin
                q_pair<=q_pair+3'd1;
                if(q_pair==3'd7)q_dispatch<=0;
            end
            if(q_done_lane[0])q_result_bank[{q_result_tag[0],1'b0}]<=q_result_lane[0];
            if(q_done_lane[1])begin
                q_result_bank[{q_result_tag[1],1'b1}]<=q_result_lane[1];
                if(q_result_tag[1]==3'd7)q_complete<=1;
            end
        end
    end
    reg q_ready;
    genvar q_lane;
    generate for(q_lane=0;q_lane<2;q_lane=q_lane+1)begin: parallel_requant
        localparam Q_LANE_BIT=(q_lane!=0);
        reg [35:0] multiplier_q;
        reg [5:0] shift_q;
        reg signed [31:0] accumulator_q,accumulator_pipe;
        (* DONT_TOUCH="TRUE" *) reg [35:0] multiplier_pipe;
        reg [5:0] shift_pipe;
        reg [2:0] tag_q,tag_pipe;
        reg valid_q,valid_pipe;
        always @(posedge clk)
            if(arithmetic_reset[16+q_lane])begin valid_q<=0;valid_pipe<=0;end
            else begin
                valid_q<=q_dispatch;valid_pipe<=valid_q;
            end
        always @(posedge clk)begin
            multiplier_q<=mul_mem[{local_oc[4],q_pair,Q_LANE_BIT}][35:0];
            shift_q<=shift_mem[{local_oc[4],q_pair,Q_LANE_BIT}];
            accumulator_q<=result_lane[{q_pair,Q_LANE_BIT}];
            tag_q<=q_pair;tag_pipe<=tag_q;
            multiplier_pipe<=multiplier_q;shift_pipe<=shift_q;
            accumulator_pipe<=accumulator_q;
        end
        tinyyolo_requant36_stream #(.TAG_BITS(3)) requant(
            .clk(clk),.rst_n(!arithmetic_reset[16+q_lane]),.in_valid(valid_pipe),
            .accumulator(accumulator_pipe),.multiplier(multiplier_pipe),
            .shift(shift_pipe),.zero_point(zy[7:0]),
            .in_tag(tag_pipe),.out_valid(q_done_lane[q_lane]),
            .result(q_result_lane[q_lane]),.out_tag(q_result_tag[q_lane]));
    end endgenerate
    reg [2:0] ro_index;
    reg hp_idle_observed;
    always @(posedge clk)
        if(reset_active) hp_idle_observed<=1'b0;
        else hp_idle_observed<=hp_idle;
    reg [31:0] ro_address,ro_bytes;
    reg profile_read_pending,read_pending,profile_read_wait;
    reg [2:0] read_bank_index;
    wire [31:0] mmio_word[0:39];
    reg [31:0] read_bank[0:4];
    reg [31:0] bank_read_mux;
    assign mmio_word[0]=skipped_chunks;
    assign mmio_word[1]=status;
    genvar cfg_read_word;
    generate for(cfg_read_word=0;cfg_read_word<15;cfg_read_word=cfg_read_word+1)begin: cfg_read_words
        assign mmio_word[cfg_read_word+2]=cfg[cfg_read_word];
    end endgenerate
    assign mmio_word[17]=error_code;
    assign mmio_word[18]=cycles[31:0];
    assign mmio_word[19]=32'h4732_5502;
    assign mmio_word[20]=cycles[63:32];
    assign mmio_word[21]=reads;
    assign mmio_word[22]=writes;
    assign mmio_word[23]=macs;
    assign mmio_word[24]=outputs_written;
    assign mmio_word[25]={26'd0,debug_state};
    assign mmio_word[26]={21'd0,group_base};
    assign mmio_word[27]={14'd0,pixel};
    assign mmio_word[28]=hp_bursts;
    assign mmio_word[29]=hp_beats;
    assign mmio_word[30]=hp_input_hits;
    assign mmio_word[31]=hp_weight_hits;
    assign mmio_word[32]=hp_misses;
    assign mmio_word[33]={31'd0,hp_idle_observed};
    genvar zero_read_word;
    generate for(zero_read_word=34;zero_read_word<40;zero_read_word=zero_read_word+1)begin: zero_read_words
        assign mmio_word[zero_read_word]=0;
    end endgenerate
    genvar mmio_bank;
    reg [4:0] mmio_read_addr;
    always @(posedge clk)mmio_read_addr<=s_araddr[4:0];
    generate for(mmio_bank=0;mmio_bank<5;mmio_bank=mmio_bank+1)begin: mmio_read_banks
        (* DONT_TOUCH="TRUE" *) reg read_enable;
        always @(posedge clk)
            if(reset_active)read_enable<=1'b0;
            else read_enable<=s_arready && s_arvalid;
        reg [31:0] selected;
        always @* begin
            case(mmio_read_addr[4:2])
                0:selected=mmio_word[mmio_bank*8+0];
                1:selected=mmio_word[mmio_bank*8+1];
                2:selected=mmio_word[mmio_bank*8+2];
                3:selected=mmio_word[mmio_bank*8+3];
                4:selected=mmio_word[mmio_bank*8+4];
                5:selected=mmio_word[mmio_bank*8+5];
                6:selected=mmio_word[mmio_bank*8+6];
                7:selected=mmio_word[mmio_bank*8+7];
                default:selected=0;
            endcase
        end
        always @(posedge clk)
            if(read_enable)
                read_bank[mmio_bank]<=mmio_read_addr[1:0]==0?selected:32'd0;
    end endgenerate
    always @* begin
        case(read_bank_index)
            0:bank_read_mux=read_bank[0];
            1:bank_read_mux=read_bank[1];
            2:bank_read_mux=read_bank[2];
            3:bank_read_mux=read_bank[3];
            4:bank_read_mux=read_bank[4];
            default:bank_read_mux=0;
        endcase
    end
    reg [31:0] selected_ro_address,selected_ro_bytes;
    reg [32:0] ro_end,acc_end,q_end;
    reg [16:0] ro_end_lo,ro_end_hi;
    reg ro_settle_wait;
    reg ro_limits_bad;
    // The second RO_SETTLE clock observes the merged 33-bit endpoint.
    // RO_COMPARE can then combine registered bounds and overlap results.
    always @(posedge clk)
        ro_limits_bad<=selected_ro_address<32'h00100000 ||
            selected_ro_bytes==0 || ro_end>33'h01fff0000;
    // RO_PICK always precedes RO_SUM. These private selectors can sample
    // continuously; only the subsequent guarded states consume them.
    // This removes both the wide reset and RO_PICK clock-enable fanout.
    always @(posedge clk)begin
        selected_ro_address<=ro_address;selected_ro_bytes<=ro_bytes;
    end
    // The split sum is merged on the first RO_SETTLE clock. Hold this state
    // for one more clock so the registered le33 comparators see the new end
    // before RO_COMPARE consumes their outputs. Keep the 64-state ABI.
    always @(posedge clk)
        if(reset_active || !state[RO_SETTLE])ro_settle_wait<=1'b0;
        else ro_settle_wait<=1'b1;
    // The pointer is private until weight requests start. Loading it at
    // RO_PICK removes ro_index/ro_bad from its shared initialization enable.
    always @(posedge clk)
        if(reset_active)weight_pointer<=32'd0;
        else if(state[RO_PICK])weight_pointer<=weights;
        else if(state[W_RSP] && rsp_valid)weight_pointer<=weight_pointer+32'd8;
    reg [16:0] acc_end_lo,acc_end_hi,q_end_lo,q_end_hi;
    reg [16:0] lut_end_lo,lut_end_hi;
    reg [32:0] lut_end;
    reg [4:0] clear_index;
    reg lut_overlap_bad,response_error_pending;
    reg ro_bad;
    wire [9:0] region_le;
    tinyyolo_le33 regcmp0(clk,acc_end,{1'b0,dst_q},region_le[0]);
    tinyyolo_le33 regcmp1(clk,q_end,{1'b0,dst_acc},region_le[1]);
    tinyyolo_le33 regcmp2(clk,ro_end,{1'b0,dst_acc},region_le[2]);
    tinyyolo_le33 regcmp3(clk,acc_end,{1'b0,selected_ro_address},region_le[3]);
    tinyyolo_le33 regcmp4(clk,ro_end,{1'b0,dst_q},region_le[4]);
    tinyyolo_le33 regcmp5(clk,q_end,{1'b0,selected_ro_address},region_le[5]);
    tinyyolo_le33 regcmp6(clk,lut_end,{1'b0,dst_acc},region_le[6]);
    tinyyolo_le33 regcmp7(clk,acc_end,{1'b0,lut_base},region_le[7]);
    tinyyolo_le33 regcmp8(clk,lut_end,{1'b0,dst_q},region_le[8]);
    tinyyolo_le33 regcmp9(clk,q_end,{1'b0,lut_base},region_le[9]);
    // End addresses are published by END_MERGE. This independent predicate
    // settles during REGION_SETTLE, before the overlap reduction consumes it.
    always @(posedge clk)
        output_limits_bad<=dst_acc<32'h00100000 || dst_q<32'h00100000 ||
            acc_end>33'h01fff0000 || q_end>33'h01fff0000;

    always @* begin
        case(ro_index)
            0:begin ro_address=src;ro_bytes=src_bytes;end
            1:begin ro_address=weights;ro_bytes=weight_bytes;end
            2:begin ro_address=biases;ro_bytes=co<<2;end
            3:begin ro_address=multipliers;ro_bytes=co<<3;end
            default:begin ro_address=shifts;ro_bytes=co<<2;end
        endcase

    end
    // Observation only: these wires never feed the convolution datapath/FSM.
    assign profile_busy=busy;
    // Both requests are already qualified against IDLE/!busy when captured
    // above. Re-decoding the live FSM here put its high-fanout state net on
    // the synchronous clear path to all 15 x 64 profile-counter bits.
    assign profile_start=start_req;
    assign profile_clear=clear_req;
    assign profile_read_enable=s_arready && s_arvalid && s_araddr>=8'h88 && s_araddr[1:0]==2'd0;
    assign profile_state=state;
    assign cache_invalidate=start_req && state[IDLE];
    assign s_bresp=2'd0;
    assign s_rresp=2'd0;
    // A gather has only one outstanding request. Its accepted response has
    // left the return slice before the commit clock, so READY can remain
    // high throughout G_RSP. Capture still requires !gather_pending.
    assign rsp_ready=state[P_RSP] || state[W_RSP] || state[G_RSP] || state[A_RSP] || state[Q_RSP] ||
        state[LUT_RSP] || (state[H_RUN] && h_rsp_ready);
    wire [7:0] q_value=options[1]?lut_table[selected_result_q[7:3]^5'h10][selected_result_q[2:0]*8+:8]:selected_result_q;
    reg [7:0] pool_left_q;
    // local_oc is stable for many output-preparation clocks. Keep one local
    // fabric register after the RAM output pipeline before the signed max.
    (* DONT_TOUCH="TRUE" *) reg [7:0] pool_above;
    wire [7:0] pool_pair=$signed(q_lut)>$signed(pool_left_q)?q_lut:pool_left_q;
    wire [7:0] pool_value=$signed(pool_pair_reg)>$signed(pool_above)?pool_pair_reg:pool_above;
    always @(posedge clk) begin
        pool_above<=pool_row_pipe;
        pool_left_q<=pool_left[local_oc];
        pool_row_q<=pool_row[{local_oc,px[8:1]}];
        pool_row_pipe<=pool_row_q;
        // Each even row overwrites this private RAM before the odd row
        // reads it. Use its local reset island for the BRAM write gate.
        if(!arithmetic_reset[18] && state[Q_PACK] && options[6] && px[0] && !py[0])
            pool_row[{local_oc,px[8:1]}]<=pool_pair_reg;
    end
    always @(posedge clk) begin
        q_word_q<=q_words[local_oc];
        q_mask_q<=q_masks[local_oc];
    end
    wire [63:0] q_merge=(q_word_q&~(64'hff<<(quantized_address[2:0]*8))) |
        ({56'd0,q_payload}<<(quantized_address[2:0]*8));
    wire [7:0] q_merge_mask=q_mask_q|(8'd1<<quantized_address[2:0]);
    // Local write command removes FSM priority/flush logic from LUT RAM WE.
    reg q_store;
    reg [4:0] q_store_index;
    reg [63:0] q_store_word;
    reg [7:0] q_store_mask;
    always @(posedge clk) begin
        if(reset_active)begin
            q_store<=0;q_store_index<=0;q_store_word<=0;q_store_mask<=0;
            sweep_last<=0;plane_is_single<=0;
        end else begin
            q_store<=state[GROUP_CLEAR] || state[Q_EMIT];
            q_store_index<=state[GROUP_CLEAR]?clear_index:local_oc;
            q_store_word<=(state[GROUP_CLEAR] || !options[5] || quantized_address[2:0]==3'd7 || pixel_is_last)?64'd0:q_merge;
            q_store_mask<=(state[GROUP_CLEAR] || !options[5] || quantized_address[2:0]==3'd7 || pixel_is_last)?8'd0:q_merge_mask;
            if(state[IDLE])sweep_last<=0;
            else if(state[LC_SWEEP])sweep_last<=local_sweep==13'd8190;
            if(state[SIZE0])plane_is_single<=plane[17:0]==18'd1;
        end
        if(rst_n && q_store)begin
            q_words[q_store_index]<=q_store_word;
            q_masks[q_store_index]<=q_store_mask;
        end
    end
    always @* begin
        req_valid=1'b0;req_write=1'b0;req_addr=32'd0;
        // Read transactions ignore write payload. Keeping this harmless
        // default removes the Q_START state from the wide write-data mux.
        // Decode only the two payload overrides. Putting these in the large
        // parallel FSM case let unrelated read/A_REQ state bits reach every
        // request-slice data pin through inferred one-hot qualification.
        req_wdata=state[H_RUN]?h_req_data:(state[Q_REQ]?q_pending_word:
            (output_index[0]?{result_acc,32'd0}:{32'd0,result_acc}));
        req_wstrb=state[H_RUN]?h_req_strb:(state[Q_REQ]?q_pending_mask:
            (output_index[0]?8'hf0:8'h0f));
        req_kind=2'd0;req_low=32'd0;req_high=32'd0;
        (* parallel_case *) case(1'b1)
            state[H_RUN]:begin
                req_valid=h_req_valid;req_write=h_req_write;req_addr=h_req_addr;
                req_kind=h_req_kind;
                req_low=h_req_low;req_high=h_req_high;
            end
            state[LUT_REQ]:begin
                req_valid=1;req_addr=lut_fetch_address;
                req_low=lut_base;req_high=lut_end[31:0];
            end
            state[P_REQ]:begin
                req_valid=1'b1;req_addr={parameter_address[31:3],3'd0};
                req_low=parameter_low;req_high=parameter_high;
            end
            state[W_REQ]:begin
                req_valid=1'b1;req_addr=weight_pointer;req_kind=2'd1;
                req_low=weights;req_high=weight_high;
            end
            state[G_REQ]:begin
                req_valid=1'b1;req_addr={input_address[31:3],3'd0};req_kind=2'd2;
                req_low=src;req_high=source_high;
            end
            state[Q_START],state[A_REQ]:begin
                req_valid=!options[0];req_write=1'b1;req_addr=accumulator_address&32'hffff_fff8;
            end
            state[Q_REQ]:begin
                req_valid=1'b1;req_write=1'b1;req_addr=quantized_address&32'hffff_fff8;
            end
            default:begin end
        endcase
        if(response_error_pending)req_valid=1'b0;
    end

    reg [63:0] state_next;
    wire gather_state=state[G_LOOK] || state[G_COORD] || state[G_CHECK] || state[G_RSP] || state[G_STORE];
    wire gather_chunk_end=tap_in_chunk==5'd23 || tap_is_last;
    wire pool_omit=options[6] && (!px[0] || !py[0]);
    // The address and options settle well before Q_EMIT. Register this local
    // decision instead of decoding byte lanes on the FSM/counter enables.
    reg quantized_flush;
    always @(posedge clk)
        quantized_flush<=!options[5] || quantized_address[2:0]==3'd7 || pixel_is_last;
    // Predict private counter events at their predecessor states. These
    // single-load flops publish on exactly the original Q_PACK/Q_EMIT edge,
    // without routing the shared FSM bit and pooling decode into carry24.
    (* DONT_TOUCH="TRUE" *) reg count_pool_omit,count_coalesced;
    always @(posedge clk)
        if(reset_active || clear_req || response_error_pending)begin
            count_pool_omit<=1'b0;count_coalesced<=1'b0;
        end else begin
            count_pool_omit<=state[Q_PAIR] && pool_omit;
            count_coalesced<=state[Q_PACK] && !pool_omit && !quantized_flush;
        end
    wire output_count_event=count_pool_omit || count_coalesced || (state[Q_RSP] && rsp_valid);
`ifndef SYNTHESIS
    always @(posedge clk)if(rst_n &&
        {count_pool_omit,count_coalesced}!==
        {state[Q_PACK] && pool_omit,state[Q_EMIT] && !quantized_flush})
        $fatal(1,"OUTPUT_COUNT_EVENT_PIPELINE_MISMATCH");
`endif
    // Use the same extended reset as the head: a DONE on the edge that
    // asserts global reset cannot reload a stale count on reset release.
    tinyyolo_counter32_load output_counter(.clk(clk),.rst_n(!arithmetic_reset[24]),
        // Command pulses were already accepted only in idle/terminal states.
        // Head DONE is a pulse and can only occur after an H_START launch.
        .clear(clear_req || start_req),
        .load(h_done),.load_value(h_outputs),
        .enable(output_count_event),.value(outputs_written));
    // Every bit is assigned to an explicit state, including comparator
    // settling cycles. An all-zero state is invalid and enters FAULT.
    // A six-bit OR fits one LUT6. Eight-bit groups added another logic
    // level on the zero-state-to-FAULT path after placement and routing.
    (* KEEP="TRUE" *) wire [10:0] state_present;
    genvar presence_group;
    generate for(presence_group=0;presence_group<10;presence_group=presence_group+1)begin: state_presence
        assign state_present[presence_group]=|state[presence_group*6+:6];
    end endgenerate
    assign state_present[10]=|state[63:60];
    (* KEEP="TRUE" *) wire state_present_lo=|state_present[5:0];
    (* KEEP="TRUE" *) wire state_present_hi=|state_present[10:6];
    wire invalid_state=!(state_present_lo || state_present_hi);
    // Keep the zero-state detector independent of the status/error encoder.
    // Its output and both local fault groups fit with priority controls in
    // one final LUT6, instead of merging through the head's error-code mux.
    (* KEEP="TRUE" *) wire fault_config=(state[H_RUN] && h_done && h_error!=0) ||
        (state[CHECK] && config_guard_error!=0) ||
        (state[LUT_VALIDATE] && lut_bounds_bad) ||
        (state[SIZE1] && size_wait==0 && sizes_bad);
    (* KEEP="TRUE" *) wire fault_datapath=(state[REGIONS] && output_regions_bad) ||
        (state[RO_CHECK] && ro_bad) ||
        (state[LUT_OVERLAP_CHECK] && lut_overlap_bad) ||
        (state[P_NEXT] && parameter_bad) || (state[ACC_CHECK] && result_overflow);
    // The two presence reductions, local fault, bus fault, sticky state and
    // clear fit one LUT6. Do not preserve an intermediate invalid-state
    // inverter or a separate final clear gate on this path.
    (* KEEP="TRUE" *) wire fault_local=fault_config || fault_datapath;
    wire fault_next;
    // Keep the two presence reductions at the final fault LUT inputs. When
    // inferred, sharing INVALID_STATE with the error encoder inserted a
    // fourth LUT level on this same-edge fault publication path.
    (* DONT_TOUCH="TRUE" *) LUT6 #(.INIT(64'h5555555555554445)) fault_state_lut (
        .I0(clear_req),.I1(state[FAULT]),.I2(state_present_lo),
        .I3(state_present_hi),.I4(fault_local),.I5(response_error_pending),
        .O(fault_next));
    always @* begin
        state_next=64'd0;
        state_next[IDLE]=state[IDLE] && !start_req;
        state_next[LC_SWEEP]=(state[IDLE] && start_req && !options[2] && options[4]) ||
                             (state[LC_SWEEP] && !sweep_last);
        state_next[H_START]=state[IDLE] && start_req && options[2];
        state_next[H_RUN]=state[H_START] || (state[H_RUN] && !h_done);
        state_next[CHECK]=(state[IDLE] && start_req && !options[2] && !options[4]) ||
                          (state[LC_SWEEP] && sweep_last);
        state_next[LUT_SUM]=state[CHECK] && config_guard_error==0 && options[1];
        state_next[LUT_END]=state[LUT_SUM];
        state_next[LUT_VALIDATE]=state[LUT_END];
        state_next[SIZE0]=(state[CHECK] && config_guard_error==0 && !options[1]) ||
                          (state[LUT_VALIDATE] && !lut_bounds_bad) ||
                          (state[SIZE0] && size_wait!=0);
        state_next[SIZE1]=(state[SIZE0] && size_wait==0) || (state[SIZE1] && size_wait!=0);
        state_next[END_MERGE]=state[SIZE1] && size_wait==0 && !sizes_bad;
        state_next[REGION_SETTLE]=state[END_MERGE];
        state_next[REGION_COMPARE]=state[REGION_SETTLE];
        state_next[REGIONS]=state[REGION_COMPARE];
        state_next[RO_PICK]=(state[REGIONS] && !output_regions_bad) ||
                            (state[RO_CHECK] && !ro_bad && ro_index!=3'd4);
        state_next[RO_SUM]=state[RO_PICK];
        state_next[RO_SETTLE]=state[RO_SUM] || (state[RO_SETTLE] && !ro_settle_wait);
        state_next[RO_COMPARE]=state[RO_SETTLE] && ro_settle_wait;
        state_next[RO_CHECK]=state[RO_COMPARE];
        state_next[LUT_OVERLAP]=state[RO_CHECK] && !ro_bad && ro_index==3'd4 && options[1];
        state_next[LUT_OVERLAP_CHECK]=state[LUT_OVERLAP];
        state_next[LUT_REQ]=(state[LUT_OVERLAP_CHECK] && !lut_overlap_bad) ||
                            (state[LUT_REQ] && !req_ready) ||
                            (state[LUT_RSP] && rsp_valid && lut_beat!=5'd31);
        state_next[LUT_RSP]=(state[LUT_REQ] && req_ready) || (state[LUT_RSP] && !rsp_valid);
        state_next[GROUP]=(state[RO_CHECK] && !ro_bad && ro_index==3'd4 && !options[1]) ||
                          (state[LUT_RSP] && rsp_valid && lut_beat==5'd31) ||
                          (state[NEXT_GROUP] && !last_group);
        state_next[GROUP_CLEAR]=state[GROUP] || (state[GROUP_CLEAR] && clear_index!=5'd31);
        state_next[P_ADDR]=(state[GROUP_CLEAR] && clear_index==5'd31) ||
                           (state[P_NEXT] && !parameter_bad && next_parameter) ||
                           (state[P_ADDR] && !parameter_address_join);
        state_next[P_REQ]=(state[P_ADDR] && parameter_address_join) || (state[P_REQ] && !req_ready);
        state_next[P_RSP]=(state[P_REQ] && req_ready) || (state[P_RSP] && !rsp_valid);
        state_next[P_NEXT]=state[P_RSP] && rsp_valid;
        state_next[W_REQ]=(state[P_NEXT] && !parameter_bad && !next_parameter) ||
                          (state[W_REQ] && !req_ready) || (state[W_RSP] && rsp_valid && !last_weight);
        state_next[W_RSP]=(state[W_REQ] && req_ready) || (state[W_RSP] && !rsp_valid);
        state_next[PIXEL]=(state[W_RSP] && rsp_valid && last_weight) || (state[NEXT_PIXEL] && !pixel_is_last);
        state_next[G_LOOK]=state[PIXEL] || (state[G_LOOK] && gather_capture) ||
                           (gather_state && gather_commit && !gather_chunk_end) ||
                           (state[G_CHUNK] && !chunk_final);
        state_next[G_COORD]=(state[G_LOOK] && !gather_capture && !gather_commit && options[4]) ||
                            (state[G_COORD] && gather_capture);
        state_next[G_CHECK]=(state[G_LOOK] && !gather_capture && !gather_commit && !options[4]) ||
                            (state[G_CHECK] && gather_capture);
        state_next[G_ADDR]=state[G_COORD] && !gather_capture && !gather_commit;
        state_next[G_STORE]=state[G_ADDR] || (state[G_STORE] && gather_capture);
        // A one-hot G_CHECK can only capture a cache hit; G_STORE can only
        // capture a local hit. Avoid routing every gather-state decoder
        // through the shared capture reduction to the DDR request state.
        state_next[G_REQ]=(!gather_commit && ((state[G_CHECK] && !gather_hit) ||
                           (state[G_STORE] && !local_hit))) ||
                          (state[G_REQ] && !req_ready);
        state_next[G_RSP]=(state[G_REQ] && req_ready) || (state[G_RSP] && !gather_commit);
        state_next[G_CHUNK]=gather_state && gather_commit && gather_chunk_end;
        state_next[OC_BIAS]=(state[G_CHUNK] && chunk_final) ||
                            (state[NEXT_OC] && !local_oc_is_last && local_oc[3:0]==4'd15);
        state_next[OC_INIT]=state[OC_BIAS];
        state_next[OC_RESULT]=state[NEXT_OC] && !local_oc_is_last && local_oc[3:0]!=4'd15;
        state_next[D_PRIME]=state[OC_INIT] || state[OC_RESULT];
        state_next[D_DATA]=state[D_PRIME];
        state_next[D_ALIGN]=state[D_DATA] && !output_only && !(options[3] && active_empty);
        state_next[D_FEED]=state[D_ALIGN] || (state[D_FEED] && !issue_is_last);
        state_next[D_WAIT]=(state[D_FEED] && issue_is_last) || (state[D_WAIT] && !accumulated_last);
        state_next[ACC_CHECK]=(state[D_DATA] && (output_only || (options[3] && active_empty))) ||
                              (state[D_WAIT] && accumulated_last);
        state_next[Q_START]=state[ACC_CHECK] && !result_overflow;
        state_next[Q_WAIT]=(state[Q_START] && options[0]) ||
                           (state[Q_WAIT] && !(q_ready || q_done)) ||
                           (state[A_RSP] && rsp_valid && !(q_ready || q_done));
        state_next[A_REQ]=(state[Q_START] && !options[0] && !req_ready) || (state[A_REQ] && !req_ready);
        state_next[A_RSP]=((state[Q_START] && !options[0]) || state[A_REQ]) && req_ready ||
                          (state[A_RSP] && !rsp_valid);
        state_next[Q_LUT]=((state[Q_WAIT] || (state[A_RSP] && rsp_valid)) && (q_ready || q_done));
        state_next[Q_PAIR]=state[Q_LUT];
        state_next[Q_PACK]=state[Q_PAIR];
        state_next[Q_EMIT]=state[Q_PACK] && !pool_omit;
        state_next[Q_REQ]=(state[Q_EMIT] && quantized_flush) || (state[Q_REQ] && !req_ready);
        state_next[Q_RSP]=(state[Q_REQ] && req_ready) || (state[Q_RSP] && !rsp_valid);
        state_next[NEXT_OC]=(state[Q_PACK] && pool_omit) || (state[Q_EMIT] && !quantized_flush) ||
                            (state[Q_RSP] && rsp_valid);
        state_next[NEXT_PIXEL]=state[NEXT_OC] && local_oc_is_last;
        state_next[NEXT_GROUP]=state[NEXT_PIXEL] && pixel_is_last;
        state_next[FINISH]=state[FINISH] || (state[H_RUN] && h_done && h_error==0) ||
                           (state[NEXT_GROUP] && last_group);
        // Preserve existing error/clear priority and bus-drain semantics.
        if(response_error_pending)state_next=64'd1<<FAULT;
        if(clear_req)state_next=64'd1<<IDLE;
        state_next[FAULT]=fault_next;
    end
    always @(posedge clk)
        if(reset_active)state<=64'd1<<IDLE;
        else state<=state_next;

    // A single local clear equation preserves the original reset/command
    // priority and lets synthesis copy it beside each counter segment.
    (* MAX_FANOUT=8 *) wire macs_clear=reset_active || clear_req ||
        (state[IDLE] && start_req);
    always @(posedge clk)
        if(macs_clear)macs<=32'd0;
        else if(state[H_RUN] && h_done)macs<=h_terms;
        else if(state[OC_INIT] || state[OC_RESULT])
            macs<={macs_add_hi+{15'd0,macs_add_lo[16]},macs_add_lo[15:0]};

    // Status has its own parallel event encoder. The datapath case must
    // not place unrelated state bits and its default reduction in series
    // with every error-code data input. Bus errors retain highest priority.
    wire error_config=state[CHECK] && config_guard_error!=0;
    wire error_lut=state[LUT_VALIDATE] && lut_bounds_bad;
    // SIZE0 loads seven settling clocks into SIZE1. Capture the terminal
    // size-fault event at wait==1, then consume it at the original wait==0
    // edge. This keeps the wide SIZE1 decode off the error feedback mux.
    reg error_size;
    always @(posedge clk)
        if(reset_active)error_size<=1'b0;
        else error_size<=state[SIZE1] && size_wait==3'd1 && sizes_bad;
`ifndef SYNTHESIS
    always @(posedge clk)if(rst_n &&
        error_size!==(state[SIZE1] && size_wait==0 && sizes_bad))
        $fatal(1,"SIZE_FAULT_EVENT_PIPELINE_MISMATCH");
`endif
    wire error_region=(state[REGIONS] && output_regions_bad) ||
        (state[RO_CHECK] && ro_bad) || (state[LUT_OVERLAP_CHECK] && lut_overlap_bad);
    wire error_parameter=state[P_NEXT] && parameter_bad;
    wire error_accumulator=state[ACC_CHECK] && result_overflow;
    wire local_error=error_config || error_lut || error_size || error_region ||
        error_parameter || error_accumulator;
    wire [31:0] local_error_value=
        ({32{error_config}} & {30'd0,config_guard_error}) |
        ({32{error_lut}} & 32'd1) | ({32{error_size}} & 32'd2) |
        ({32{error_region}} & 32'd4) | ({32{error_parameter}} & 32'd6) |
        ({32{error_accumulator}} & 32'd7);
    // Preserve immediate zero-state detection in the FSM while terminating
    // its 64-bit reduction at a dedicated sticky register. The MMIO encoder
    // observes both registers after the same edge; error precedence is kept.
    always @(posedge clk)
        if(reset_active || clear_req || (state[IDLE] && start_req) || response_error_pending)
            invalid_error<=1'b0;
        else if(invalid_state)invalid_error<=1'b1;
    always @(posedge clk)
        if(reset_active || clear_req || (state[IDLE] && start_req))event_error_code<=32'd0;
        else if(response_error_pending)event_error_code<=32'd3;
        // Head completion and local faults are mutually exclusive in the
        // one-hot FSM (including the zero-state fault). Encode in parallel.
        else if(local_error || (state[H_RUN] && h_done))
            event_error_code<=local_error_value | ({32{state[H_RUN] && h_done}} & h_error);
    always @(posedge clk)
        if(reset_active)begin input_address<=32'd0;input_increment_carry<=3'd0;end
        else if(state[PIXEL])begin
            input_address<=pixel_gather_address;
            input_increment_carry<={&pixel_gather_address[23:0],&pixel_gather_address[15:0],&pixel_gather_address[7:0]};
        end else if(gather_commit && !tap_is_last)begin
            input_address<=gather_address_next;
            input_increment_carry<={&gather_address_next[23:0],&gather_address_next[15:0],&gather_address_next[7:0]};
        end

    integer i,j;
    (* DONT_TOUCH="TRUE" *) reg options_write,lut_write;
    reg [31:0] extension_write_data;
    // Qualify busy/byte strobes at the original commit edge and capture the
    // matching payload. Publish extensions one clock later, before another
    // AXI-Lite transaction can commit or START can reach configuration checks.
    always @(posedge clk) begin
        if(reset_active)begin options_write<=0;lut_write<=0;end
        else begin
            options_write<=commit && !busy && options_select && wstrb==4'hf;
            lut_write<=commit && !busy && lut_select && wstrb==4'hf;
        end
        if(commit)extension_write_data<=wdata;
    end
    // Command strobes were qualified while idle before being registered.
    // Keep the observation counters independent of the main FSM case mux.
    always @(posedge clk)
        if(reset_active || start_req || clear_req)begin reads<=0;writes<=0;end
        else begin
            if(accepted_write)writes<=writes+32'd1;
            if(accepted_read)reads<=reads+32'd1;
        end
    always @(posedge clk) begin
        if(reset_active) begin
            aw_hold<=1'b0;w_hold<=1'b0;s_awready<=1'b0;s_wready<=1'b0;
            s_bvalid<=1'b0;s_arready<=1'b0;s_rvalid<=1'b0;s_rdata<=32'd0;
            profile_read_pending<=1'b0;read_pending<=0;read_bank_index<=0;profile_read_wait<=0;
            wdata<=32'd0;wstrb<=4'd0;
            for(i=0;i<15;i=i+1)cfg[i]<=32'd0;
            options<=0;lut_base<=0;
        end else begin
            if(options_write)options<=extension_write_data[6:0];
            if(lut_write)lut_base<=extension_write_data;
            s_awready<=!aw_hold && !s_bvalid;
            s_wready<=!w_hold && !s_bvalid;
            if(s_awready && s_awvalid)begin aw_hold<=1'b1;s_awready<=1'b0;end
            if(s_wready && s_wvalid)begin wdata<=s_wdata;wstrb<=s_wstrb;w_hold<=1'b1;s_wready<=1'b0;end
            if(commit)begin
                aw_hold<=1'b0;w_hold<=1'b0;s_bvalid<=1'b1;
                for(i=0;i<15;i=i+1)
                    for(j=0;j<4;j=j+1)
                        if(!busy && config_select[i] && wstrb[j])cfg[i][j*8+:8]<=wdata[j*8+:8];
            end
            if(s_bvalid && s_bready)s_bvalid<=1'b0;
            if(read_pending)begin
                // Both command paths register local bank enables. Wait one
                // cycle for the accepted-address snapshot before publishing.
                if(!profile_read_wait)profile_read_wait<=1'b1;
                else begin
                    s_rdata<=profile_read_pending?profile_rdata:bank_read_mux;
                    s_rvalid<=1'b1;read_pending<=1'b0;s_arready<=1'b0;
                end
            end else if(!s_rvalid)begin
                s_arready<=1'b1;
                if(s_arready && s_arvalid)begin
                    s_arready<=1'b0;
                    read_pending<=1'b1;read_bank_index<=s_araddr[7:5];
                    profile_read_pending<=s_araddr>=8'h88 && s_araddr[1:0]==2'd0;
                    profile_read_wait<=1'b0;
                end
            end else if(s_rready)s_rvalid<=1'b0;
        end
    end
    always @(posedge clk) begin
        if(reset_active)begin
            weight_write_address<=13'd0;
            weight_write_data<=192'd0;
        end else begin
            if(state[W_RSP] && rsp_valid && !rsp_error && w_phase==2'd2)begin
                weight_write_address<={w_oc,w_chunk};
                weight_write_data<={rsp_data,w_low};
            end
        end
        if(reset_active)begin
             begin end
            response_error_pending<=1'b0;
            local_sweep<=0;lut_beat<=0;skipped_chunks<=0;active_count<=0;pool_pixel<=0;pool_row_base<=0;pooled_output_index<=0;
            feed_penultimate<=0;issue_is_last<=0;
            q_pending_word<=0;q_pending_mask<=0;q_payload<=0;q_lut<=0;pool_pair_reg<=0;
            size_wait<=0;plane<=32'd0;taps<=32'd0;src_bytes<=32'd0;q_bytes<=32'd0;acc_bytes<=32'd0;
            weight_bytes<=32'd0;chunks<=32'd0;pad_offset<=32'd0;
            before_last_pixel<=18'd0;pixel_is_last<=1'b0;pixel_is_row_last<=1'b0;
            last_tap<=13'd0;before_last_tap<=13'd0;tap_is_last<=1'b0;last_chunk<=8'd0;
            last_kernel<=2'd0;last_group<=1'b0;
            group_base<=11'd0;remaining_channels<=11'd0;group_size<=6'd0;last_oc<=5'd0;weight_left<=15'd0;
            source_high<=32'd0;weight_high<=32'd0;bias_high<=32'd0;
            multiplier_high<=32'd0;shift_high<=32'd0;
            p_oc<=5'd0;p_kind<=2'd0;
            local_oc<=5'd0;w_oc<=5'd0;w_chunk<=8'd0;issue_chunk<=8'd0;map_read_chunk<=8'd0;w_phase<=2'd0;w_low<=128'd0;
            px<=10'd0;py<=9'd0;pixel_left_border<=1'b1;pixel_top_border<=1'b1;
            pixel<=18'd0;tap<=13'd0;
            pixel_source<=32'd0;
            last_x<=10'd0;last_y<=9'd0;valid_x<=3'd0;valid_y<=3'd0;
            kx<=2'd0;ky<=2'd0;output_index<=32'd0;
            output_channel_offset<=32'd0;group_channel_offset<=32'd0;accumulator_address<=32'd0;
            quantized_address<=32'd0;output_regions_bad<=1'b0;
            chunk_nonzero<=0;chunk_final<=0;chunk_index<=0;chunk_original<=0;
            output_only<=1'b0;
            result_acc<=32'sd0;q_ready<=1'b0;ro_index<=3'd0;
            ro_end<=33'd0;ro_end_lo<=17'd0;ro_end_hi<=17'd0;
            acc_end<=33'd0;q_end<=33'd0;ro_bad<=1'b0;
            acc_end_lo<=0;acc_end_hi<=0;q_end_lo<=0;q_end_hi<=0;
            lut_end_lo<=0;lut_end_hi<=0;lut_end<=0;clear_index<=0;
            lut_overlap_bad<=1'b0;
        end else begin
            response_error_pending<=rsp_valid && rsp_ready && rsp_error;
            if(q_done)q_ready<=1'b1;
            (* parallel_case *) case(1'b1)
                state[IDLE]:if(start_req)begin
                    skipped_chunks<=0;local_sweep<=0;group_channel_offset<=0;
                     begin end 
                end
                state[LC_SWEEP]:begin
                    local_sweep<=local_sweep+13'd1;
                    if(sweep_last) begin end 
                end
                state[H_START]: begin end 
                state[H_RUN]:if(h_done)begin
                    skipped_chunks<=h_zero;
                     begin end 
                end
                state[CHECK]:begin
                    if(config_guard_error!=2'd0)begin  begin end end
                    else begin
                        plane<=dimension_product[31:0];size_wait<=3'd7;
                        taps<={18'd0,config_taps};
                        last_x<=width[9:0]-10'd1;last_y<=height[8:0]-9'd1;
                        last_kernel<=kernel[1:0]-2'd1;
                        pad_offset<=pad[0]?{22'd0,(width[9:0]+10'd1)}:32'd0;
                         begin end 
                    end
                end
                state[LUT_SUM]:begin
                    lut_end_lo<={1'b0,lut_base[15:0]}+17'd256;
                    lut_end_hi<={1'b0,lut_base[31:16]}; begin end 
                end
                state[LUT_END]:begin
                    lut_end<={lut_end_hi+lut_end_lo[16],lut_end_lo[15:0]}; begin end 
                end
                state[LUT_VALIDATE]:begin
                    if(lut_bounds_bad)begin  begin end end
                    else  begin end 
                end
                state[SIZE0]:if(size_wait!=0)size_wait<=size_wait-3'd1;else begin
                    size_wait<=3'd7;
                    chunks<={24'd0,config_chunks};
                    last_chunk<=config_chunks-8'd1;
                    last_tap<=taps[12:0]-13'd1;
                    before_last_tap<=taps[12:0]-13'd2;
                    before_last_pixel <= (plane[17:0] > 18'd1) ? (plane[17:0]-18'd2) : 18'd0;
                    src_bytes<=source_size_product[31:0];
                    q_bytes<=output_size_product[31:0];
                    acc_bytes<={output_size_product[29:0],2'd0}; begin end 
                end
                state[SIZE1]:if(size_wait!=0)size_wait<=size_wait-3'd1;else begin
                    if(sizes_bad)begin  begin end end
                    else begin
                        weight_bytes<={weight_size_product[27:0],4'd0}+{1'b0,weight_size_product[27:0],3'd0};
                        acc_end_lo<={1'b0,dst_acc[15:0]}+{1'b0,acc_bytes[15:0]};
                        acc_end_hi<={1'b0,dst_acc[31:16]}+{1'b0,acc_bytes[31:16]};
                        q_end_lo<={1'b0,dst_q[15:0]}+{1'b0,q_bytes[15:0]};
                        q_end_hi<={1'b0,dst_q[31:16]}+{1'b0,q_bytes[31:16]};
                         begin end 
                    end
                end
                state[END_MERGE]:begin
                    acc_end<={acc_end_hi+acc_end_lo[16],acc_end_lo[15:0]};
                    q_end<={q_end_hi+q_end_lo[16],q_end_lo[15:0]}; begin end 
                end
                state[REGION_SETTLE]:begin end
                state[REGION_COMPARE]:begin
                    output_regions_bad<=output_limits_bad || !(region_le[0] || region_le[1]);
                     begin end 
                end
                state[REGIONS]:begin
                    if(output_regions_bad)begin  begin end end
                    else begin ro_index<=3'd0; begin end end
                end
                // Break source selection -> end-address carry -> overlap
                // compare -> FSM enables into independent registered stages.
                state[RO_PICK]:begin end
                state[RO_SUM]:begin
                    ro_end_lo<={1'b0,selected_ro_address[15:0]}+{1'b0,selected_ro_bytes[15:0]};
                    ro_end_hi<={1'b0,selected_ro_address[31:16]}+{1'b0,selected_ro_bytes[31:16]};
                end
                state[RO_SETTLE]:ro_end<={ro_end_hi+{16'd0,ro_end_lo[16]},ro_end_lo[15:0]};
                state[RO_COMPARE]:begin
                    ro_bad<=ro_limits_bad ||
                        !(region_le[2] || region_le[3]) ||
                        !(region_le[4] || region_le[5]);
                     begin end 
                end
                state[RO_CHECK]:begin
                    case(ro_index)
                        0:source_high<=(ro_end[31:0]+32'd7)&32'hffff_fff8;
                        1:weight_high<=ro_end[31:0];
                        2:bias_high<=(ro_end[31:0]+32'd7)&32'hffff_fff8;
                        3:multiplier_high<=ro_end[31:0];
                        default:shift_high<=(ro_end[31:0]+32'd7)&32'hffff_fff8;
                    endcase
                    if(ro_bad)begin  begin end end
                    else if(ro_index==3'd4)begin
                        group_base<=0;remaining_channels<=co[10:0];lut_beat<=0;
                         begin end 
                    end
                    else begin ro_index<=ro_index+3'd1; begin end end
                end
                state[LUT_OVERLAP]:begin
                    lut_overlap_bad<=!(region_le[6] || region_le[7]) ||
                        !(region_le[8] || region_le[9]);
                     begin end 
                end
                state[LUT_OVERLAP_CHECK]:begin
                    if(lut_overlap_bad)begin  begin end end
                    else  begin end 
                end
                state[LUT_REQ]:if(req_ready) begin end 
                state[LUT_RSP]:if(rsp_valid)begin
                    lut_table[lut_beat]<=rsp_data;
                    if(lut_beat==5'd31) begin end 
                    else begin lut_beat<=lut_beat+5'd1; begin end end
                end
                state[GROUP]:begin
                    group_size<=(remaining_channels>=11'd32)?6'd32:remaining_channels[5:0];
                    last_oc<=(remaining_channels>=11'd32)?5'd31:remaining_channels[4:0]-5'd1;
                    last_group<=remaining_channels<=11'd32;
                    p_oc<=5'd0;p_kind<=2'd0;clear_index<=0; begin end 
                end
                state[GROUP_CLEAR]:begin
                    pool_left[clear_index]<=8'd0;
                    if(clear_index==5'd31) begin end 
                    else clear_index<=clear_index+5'd1;
                end
                state[P_ADDR]:begin
                     begin end 
                end
                state[P_REQ]:if(req_ready) begin end 
                state[P_RSP]:if(rsp_valid)begin
                     begin end 
                end
                state[P_NEXT]:begin
                    // These private initial values are harmless on a fault;
                    // do not put parameter validation on their wide enables.
                    if(!next_parameter)begin
                        w_oc<=0;w_chunk<=0;w_phase<=0;
                        weight_left<=group_weight_beats;
                    end
                    if(parameter_bad)begin  begin end end
                    else if(!parameter_is_shift)begin p_kind<=p_kind+2'd1; begin end end
                    else if(next_parameter)begin p_oc<=p_oc+5'd1;p_kind<=0; begin end end
                    else begin end
                end
                state[W_REQ]:if(req_ready) begin end 
                state[W_RSP]:if(rsp_valid)begin
                    weight_left<=weight_left-15'd1;
                    w_phase <= (w_phase == 2'd2) ? 2'd0 : w_phase + 2'd1;
                    if(w_phase==2'd0)w_low[63:0]<=rsp_data;
                    else if(w_phase==2'd1)w_low[127:64]<=rsp_data;
                    else if(w_chunk==last_chunk)begin w_chunk<=0;w_oc<=w_oc+5'd1;end
                    else w_chunk<=w_chunk+8'd1;
                    if(last_weight)begin
                        pool_pixel<=0;pool_row_base<=0;px<=0;py<=0;pixel<=0;
                        pixel_left_border<=1'b1;pixel_top_border<=1'b1;
                        pixel_is_last<=plane_is_single;
                        pixel_source<=source_origin; begin end 
                    end
                    else  begin end 
                end
                state[PIXEL]:begin
                    tap<=0;tap_is_last<=last_tap==0;kx<=0;ky<=0;local_oc<=0;active_count<=0;
                    pixel_is_row_last<=px==last_x;
                    output_channel_offset<=group_channel_offset;
                    
                    valid_x<=kernel_is_one?3'b111:{px!=last_x[9:0],1'b1,px!=10'd0};
                    valid_y<=kernel_is_one?3'b111:{py!=last_y[8:0],1'b1,py!=9'd0};
                     begin end 
                end
                // Localize cache-hit control to gather state. It must not gate
                // unrelated setup multipliers, output addressing or counters.
                state[G_LOOK],state[G_COORD],state[G_CHECK],state[G_RSP],state[G_STORE]:begin
                    if(gather_commit)begin
                        chunk_nonzero<=pack_nonzero || tap_value!=0;
                        chunk_final<=tap_is_last;
                        chunk_original<=gather_chunk;
                        chunk_index<=options[3]?active_count[7:0]:gather_chunk;
                        if(tap_is_last) begin end 
                        else begin
                            tap<=tap+13'd1;
                            tap_is_last<=tap==before_last_tap;
                            if(kx==last_kernel)begin
                                kx<=2'd0;
                                if(ky==last_kernel)begin
                                    ky<=2'd0;
                                    
                                end else begin
                                    ky<=ky+2'd1;
                                    
                                end
                            end else begin
                                kx<=kx+2'd1;
                                
                                
                                
                                
                            end
                             begin end 
                        end
                        if(tap_in_chunk==5'd23 || tap_is_last) begin end 
                    end else if(state[G_LOOK]) begin end 
                    else if(state[G_COORD]) begin end 
                    else if(state[G_CHECK]) begin end 
                    else if(state[G_STORE]) begin end 
                end
                state[G_CHUNK]:begin
                    if(chunk_nonzero)active_count<=active_count+10'd1;
                     begin end 
                end
                state[G_ADDR]: begin end 
                state[G_REQ]:if(req_ready) begin end 
                state[OC_BIAS]: begin end 
                state[OC_INIT]:begin
                    output_only<=1'b0;issue_chunk<=0;map_read_chunk<=8'd0;
                    feed_penultimate<=options[3]?active_count[7:0]-8'd2:last_chunk-8'd1;
                    issue_is_last<=options[3]?(active_count==10'd1):(last_chunk==0);
                    if(options[3])skipped_chunks<=skipped_chunks+missing_chunks;
                     begin end 
                end
                state[OC_RESULT]:begin
                    output_only<=1'b1;
                    if(options[3])skipped_chunks<=skipped_chunks+missing_chunks;
                     begin end 
                end
                state[D_PRIME]:begin
                    map_read_chunk<=9'd1;
                    output_index<=output_channel_offset+{14'd0,pixel};
                    pooled_output_index<=(output_channel_offset>>2)+{14'd0,pool_pixel}; begin end 
                end
                state[D_DATA]:begin
                    map_read_chunk<=9'd2;
                    accumulator_address<=dst_acc+(output_index<<2);
                    quantized_address<=dst_q+(options[6]?pooled_output_index:output_index);
                    if(output_only)result_acc<=selected_acc;
                    else if(options[3] && active_empty)begin
                        result_acc<=bias_lane[0];q_ready<=0; begin end 
                    end else  begin end 
                end
                state[D_ALIGN]:begin map_read_chunk<=9'd3; begin end end
                state[D_FEED]:begin
                    map_read_chunk<=issue_chunk+8'd4;
                    issue_is_last<=issue_chunk==feed_penultimate;
                    if(issue_is_last) begin end 
                    else issue_chunk<=issue_chunk+8'd1;
                end
                state[D_WAIT]:if(accumulated_last)begin
                    result_acc<=accumulator_lane[0];q_ready<=1'b0; begin end 
                end
                state[ACC_CHECK]:begin
                    // The sticky flag now includes the final sum. Keep the
                    // 33-bit carry chain off the FSM and all write enables.
                    if(result_overflow)begin  begin end end
                    else  begin end 
                end
                // Requant is pulsed once even when write acceptance stalls.
                state[Q_START]:if(options[0]) begin end else if(req_ready) begin end else  begin end 
                state[Q_WAIT]:if(q_ready || q_done) begin end 
                state[A_REQ]:if(req_ready) begin end 
                state[A_RSP]:if(rsp_valid) begin end 
                state[Q_LUT]:begin q_lut<=q_value; begin end end
                state[Q_PAIR]:begin pool_pair_reg<=pool_pair; begin end end
                state[Q_PACK]:begin
                    q_payload<=options[6]?pool_value:q_lut;
                    if(options[6] && !px[0])begin
                        pool_left[local_oc]<=q_lut;
                         begin end
                    end else if(options[6] && !py[0])begin
                         begin end
                    end else  begin end 
                end
                state[Q_EMIT]:begin
                    q_pending_word<=options[5]?q_merge:({56'd0,q_payload}<<(quantized_address[2:0]*8));
                    q_pending_mask<=options[5]?q_merge_mask:(8'd1<<quantized_address[2:0]);
                    if(!options[5] || quantized_address[2:0]==3'd7 || pixel_is_last)begin
                         begin end 
                    end else begin
                         begin end
                    end
                end
                state[Q_REQ]:if(req_ready) begin end 
                state[Q_RSP]:if(rsp_valid)begin end
                state[NEXT_OC]:begin
                    if(!local_oc_is_last)begin
                        local_oc<=local_oc+5'd1;
                        output_channel_offset<={output_offset_hi+{15'd0,output_offset_lo[16]},output_offset_lo[15:0]};
                         begin end 
                    end
                    else  begin end 
                end
                state[NEXT_PIXEL]:begin
                    if(pixel_is_last) begin end 
                    else begin
                        pixel<=pixel+18'd1;
                        pixel_is_last<=&before_last_pixel_match;
                        pixel_source<=pixel_source+32'd1;
                        if(pixel_is_row_last)begin
                            px<=0;py<=py+9'd1;
                            pixel_left_border<=1'b1;pixel_top_border<=1'b0;
                            if(py[0])begin
                                pool_row_base<=pool_row_base+{9'd0,width[9:1]};
                                pool_pixel<=pool_row_base+{9'd0,width[9:1]};
                            end else pool_pixel<=pool_row_base;
                        end
                        else begin
                            px<=px+10'd1;pixel_left_border<=1'b0;
                            if(px[0])pool_pixel<=pool_pixel+18'd1;
                        end
                         begin end 
                    end
                end
                state[NEXT_GROUP]:begin
                    if(last_group) begin end 
                    else begin
                        group_base<=group_base+11'd32;
                        remaining_channels<=remaining_channels-11'd32;
                        // Every non-final channel group contains exactly 32 channels.
                        group_channel_offset<=group_channel_offset+(plane<<5);
                         begin end 
                    end
                end
                state[FINISH]:begin end
                state[FAULT]:begin end
                default:begin  begin end end
            endcase
            if(response_error_pending)begin
                 begin end 
            end
            // Error wins the state transition, without placing a response
            // decoder in every unrelated datapath register's enable cone.
            // Clear affects only terminal/idle control and counters. Keeping
            // it outside the datapath case avoids a decoded MMIO command on
            // every wide array CE/reset (q_words, activations and weights).
            if(clear_req)begin
                 begin end
            end
        end
    end
endmodule

