`timescale 1ns/1ps
// Native AXI3, one accepted transaction at a time. Reads use bounded 64-byte
// line fills (1..8 beats), never crossing a caller region or 4-KiB boundary.
// kind 0: uncached parameter; 1: weight prefetch; 2: 128-KiB input cache.
// Caller supplies 8-byte-aligned [low, high), rounded only to a final beat.
// A line is published only after the entire burst, including RLAST, is valid.
// Invalidate during an accepted transaction is deferred; it never drops AXI.
module tinyyolo_hp0_burst_cache (
    input wire clk, input wire rst_n, input wire invalidate,
    input wire req_valid, output wire req_ready, input wire req_write,
    input wire [31:0] req_addr, input wire [63:0] req_wdata,
    input wire [7:0] req_wstrb, input wire [1:0] req_kind,
    input wire [31:0] req_low, input wire [31:0] req_high,
    output wire rsp_valid, input wire rsp_ready,
    output reg [63:0] rsp_data, output reg rsp_error,
    output wire idle, output wire [31:0] read_bursts, read_beats,
    output wire [31:0] input_hits, weight_hits, read_misses,
    output wire [31:0] araddr, output wire [3:0] arlen,
    output wire arvalid, input wire arready,
    input wire [63:0] rdata, input wire [5:0] rid,
    input wire [1:0] rresp, input wire rlast, input wire rvalid,
    output wire rready,
    output wire [31:0] awaddr, output wire awvalid, input wire awready,
    output wire [63:0] wdata, output wire [7:0] wstrb,
    output wire wvalid, input wire wready,
    input wire [5:0] bid, input wire [1:0] bresp,
    input wire bvalid, output wire bready
);
    // Bound the combinational reset inverter fanout without adding a cycle.
    // Synthesis may replicate its LUT beside the synchronous consumers.
    (* MAX_FANOUT=32 *) wire reset_active=!rst_n;

    localparam [3:0] SWEEP=4'd0, IDLE=4'd1, PRIME=4'd2, CHECK=4'd3,
        PLAN0=4'd4, PLAN1=4'd5, AR=4'd6, READ=4'd7, COMMIT=4'd8,
        RESP=4'd9, WRITE=4'd10, BRESP=4'd11, DRAIN=4'd12, DECIDE=4'd13, LOOKUP=4'd14;
    reg [3:0] state;
    reg [10:0] sweep_index;
    reg sweep_last;
    always @(posedge clk)
        if(reset_active || invalidate || state!=SWEEP)sweep_last<=1'b0;
        else sweep_last<=sweep_index==11'd2046;
    reg invalidate_pending;
    reg [31:0] address, low_address, high_address;
    reg is_write;
    reg [1:0] kind;
    reg [63:0] write_data;
    reg [7:0] write_strobes;
    reg ar_sent, aw_sent, w_sent;
    reg [31:0] fill_start, fill_end, burst_address, receive_address;
    reg [3:0] burst_len, beat;
    reg [7:0] response_select;
    reg [7:0] fill_mask;
    reg read_error;
    // Rebalance BRAM from input cache to 32-output-channel weight reuse.
    // Eight independent banks retain 128 KiB total, with registered local
    // address/write paths; AXI ordering and bounded line fills are unchanged.
    wire [63:0] input_data_bank[0:7];
    // Per-beat valid mask is essential for shortened first/last cache lines.
    (* ram_style="block" *) reg [22:0] input_tags[0:2047];

    reg [22:0] input_tag_q;
    // Extra unreset RAM output registers allow DO_REG absorption. CHECK
    // registers hit/validation decisions before they fan out to data/FSM CEs.
    wire [63:0] input_data_pipe=input_data_bank[address[16:14]];
    (* dont_touch="true" *) reg [22:0] input_tag_pipe;
    reg input_hit_reg, input_match_reg, weight_hit_reg, weight_match_reg,bad_request_reg;
    reg input_response_hit,weight_response_hit;
    reg [63:0] weight_line[0:7];
    reg [25:0] weight_tag;
    reg [7:0] weight_mask;
    // Separate short LUT comparisons so synthesis cannot serialize the tag
    // equality into a carry chain ahead of the per-beat valid-mask mux.
    (* KEEP="TRUE" *) wire [2:0] input_tag_equal;
    assign input_tag_equal[0]=~|(input_tag_pipe[4:0]^address[21:17]);
    assign input_tag_equal[1]=~|(input_tag_pipe[9:5]^address[26:22]);
    assign input_tag_equal[2]=~|(input_tag_pipe[14:10]^address[31:27]);
    wire input_match=&input_tag_equal;
    wire input_hit=input_match && input_tag_pipe[15+address[5:3]];
    wire weight_hit=weight_tag==address[31:6] && weight_mask[address[5:3]];
    // Register the native PS7 return channels before checking AXI metadata.
    // READY is registered too; skid storage absorbs a full-rate return burst.
    wire [63:0] rx_data;
    wire [5:0] rx_id, rx_bid;
    wire [1:0] rx_resp, rx_bresp;
    wire rx_last, rx_valid, rx_bvalid, rx_empty, b_empty;
    // Register the next state's return readiness beside the FSM. AR and
    // WRITE already use registered completion flags, so this preserves the
    // first/last accepted beat while removing state decode from slice data.
    reg rx_ready,rx_bready;
    always @(posedge clk)
        if(reset_active)begin rx_ready<=1'b0;rx_bready<=1'b0;end
        else begin
            rx_ready<=(state==AR && ar_sent) ||
                ((state==READ || state==DRAIN) && !(rx_valid && rx_last));
            rx_bready<=(state==WRITE && aw_sent && w_sent) ||
                (state==BRESP && !rx_bvalid);
        end
`ifndef SYNTHESIS
    always @(posedge clk)if(rst_n)begin
        if(rx_ready!==(state==READ || state==DRAIN))
            $fatal(1,"HP0_REGISTERED_READ_READY_STATE_MISMATCH");
        if(rx_bready!==(state==BRESP))
            $fatal(1,"HP0_REGISTERED_B_READY_STATE_MISMATCH");
    end
`endif
    tinyyolo_rv_slice #(.WIDTH(73)) u_axi_r_slice (
        .clk(clk),.rst_n(rst_n),.s_valid(rvalid),.s_ready(rready),
        .s_data({rid,rresp,rlast,rdata}),.m_valid(rx_valid),.m_ready(rx_ready),
        .m_data({rx_id,rx_resp,rx_last,rx_data}),.empty(rx_empty));
    tinyyolo_rv_slice #(.WIDTH(8)) u_axi_b_slice (
        .clk(clk),.rst_n(rst_n),.s_valid(bvalid),.s_ready(bready),
        .s_data({bid,bresp}),.m_valid(rx_bvalid),.m_ready(rx_bready),
        .m_data({rx_bid,rx_bresp}),.empty(b_empty));
    wire bad_beat=rx_resp!=2'd0 || rx_id!=6'd0 || rx_last!=(beat==burst_len);
    // Each full-width comparison terminates at a local register. All range
    // ends are beat aligned; address >= high is exactly the invalid final
    // beat test after alignment validation, without a 33-bit increment chain.
    reg request_alignment_bad,request_kind_bad,request_region_bad;
    reg request_empty_bad,request_below_bad,request_above_bad;
    reg [31:0] line_start,line_end;
    wire bad_request=request_alignment_bad || (!is_write &&
        (request_kind_bad || request_region_bad || request_empty_bad ||
         request_below_bad || request_above_bad));
    always @(posedge clk)begin
        request_alignment_bad<=address[2:0]!=0;
        request_kind_bad<=kind==2'd3 || (|low_address[2:0]) || (|high_address[2:0]);
        request_region_bad<=low_address<32'h0010_0000 || high_address>32'h1fff_0000;
        request_empty_bad<=low_address>=high_address;
        request_below_bad<=address<low_address;
        request_above_bad<=address>=high_address;
        // LOOKUP/PRIME/CHECK/DECIDE keep the request stable before PLAN0.
        // Register this comparison and selection ahead of the planning FSM
        // mux, preserving both bounded fills and the external cycle latency.
        line_start<=low_address>{address[31:6],6'd0}?low_address:{address[31:6],6'd0};
        line_end<={address[31:6]+26'd1,6'd0};
    end
    // Request address is registered before the BRAM lookup, removing an FSM
    // mux from every RAM address pin. LOOKUP/PRIME fill two unconditionally
    // clocked read stages; CHECK and DECIDE register and consume the hit.
    // Preserve the fabric pipe so hit logic cannot become a BRAM REGCE net.
    wire [10:0] tag_read_index=address[16:6];
    // Capture validated fill metadata and payload before bank selection.
    // The final beat retires alongside its tag in RESP, before any subsequent
    // request can enter LOOKUP. Continuous bursts still accept one beat/clock.
    reg input_fill_valid_q;
    reg [2:0] input_fill_bank_q;
    reg [10:0] input_fill_index_q;
    reg [63:0] input_fill_data_q;
    always @(posedge clk) begin
        if(reset_active)input_fill_valid_q<=1'b0;
        else input_fill_valid_q<=state==READ && rx_valid && !read_error && !bad_beat && kind==2'd2;
        input_fill_bank_q<=receive_address[16:14];
        input_fill_index_q<=receive_address[13:3];
        input_fill_data_q<=rx_data;
    end
    genvar bank;
    generate for(bank=0;bank<8;bank=bank+1) begin: input_bank
        (* ram_style="block" *) reg [63:0] data[0:2047];
        (* dont_touch="true" *) reg [10:0] read_index,write_index;
        (* dont_touch="true" *) reg write_enable;
        (* dont_touch="true" *) reg [63:0] write_value;
        reg [63:0] data_q,data_output_reg;
        (* dont_touch="true" *) reg [63:0] data_pipe;
        always @(posedge clk) begin
            // Speculate the accepted request address one cycle before the
            // registered address. This pays for the physical BRAM DO_REG
            // without adding a cache-hit/request cycle.
            read_index<=state==IDLE?req_addr[13:3]:address[13:3];
            write_index<=input_fill_index_q;
            write_value<=input_fill_data_q;
            write_enable<=rst_n && input_fill_valid_q && input_fill_bank_q==bank;
            data_q<=data[read_index];
            data_output_reg<=data_q;
            data_pipe<=data_output_reg;
            if(write_enable)data[write_index]<=write_value;
        end
        assign input_data_bank[bank]=data_pipe;
    end endgenerate
    wire clear_counters=(state==IDLE && (invalidate || invalidate_pending)) ||
        (state==RESP && rsp_ready && (invalidate || invalidate_pending));
    assign idle=state==IDLE && !invalidate && !invalidate_pending && rx_empty && b_empty;
    assign req_ready=idle;
    assign rsp_valid=state==RESP;
    assign araddr=burst_address;
    assign arlen=burst_len;
    assign arvalid=state==AR && !ar_sent;
    assign awaddr=address;
    assign awvalid=state==WRITE && !aw_sent;
    assign wdata=write_data;
    assign wstrb=write_strobes;
    assign wvalid=state==WRITE && !w_sent;

    // Separate return metadata checking from the wide BRAM write-enable fanout.
    // The final beat is written on COMMIT, before its tag can be consumed.
    reg fill_weight_valid;
    reg [2:0] fill_write_index;
    reg [63:0] fill_write_data;
    always @(posedge clk) begin
        if(reset_active) begin
            fill_weight_valid<=1'b0;
        end else begin
            fill_weight_valid<=state==READ && rx_valid && !read_error && !bad_beat && kind==2'd1;
        end
        fill_write_index<=receive_address[5:3];
        fill_write_data<=rx_data;
    end

    // A single explicit write port prevents multiple procedural RAM ports
    // when sweep, write invalidation and completed-fill publication select
    // different addresses. This maps the 2048x23 tag array into block RAM.
    wire tag_write_enable=rst_n && (state==SWEEP ||
        (state==DECIDE && is_write && !bad_request_reg && input_match_reg) ||
        (state==PLAN0 && kind==2'd2) ||
        (state==COMMIT && !read_error && kind==2'd2));
    wire [10:0] tag_write_index=state==SWEEP?sweep_index:address[16:6];
    wire [22:0] tag_write_data=state==COMMIT?{fill_mask,address[31:17]}:23'd0;

    // True synchronous RAM ports. No memory-array reset or asynchronous mux.
    reg tag_write_pending;
    reg [10:0] tag_write_index_q;
    reg [22:0] tag_write_data_q;
    always @(posedge clk)begin
        if(reset_active)begin tag_write_pending<=0;tag_write_index_q<=0;tag_write_data_q<=0;end
        else begin
            tag_write_pending<=tag_write_enable;
            tag_write_index_q<=tag_write_index;
            tag_write_data_q<=tag_write_data;
        end
    end
    always @(posedge clk) begin
        input_tag_q<=input_tags[tag_read_index];
        input_tag_pipe<=input_tag_q;
        // Only reset the registered write tokens, not the private RAM ports.
        // A pending write may retire on the reset edge. SWEEP clears every
        // tag before IDLE; weight_mask is reset and published only after a
        // complete new fill, so that private write can never become a hit.
        if(tag_write_pending)
            input_tags[tag_write_index_q]<=tag_write_data_q;
        if(fill_weight_valid)
            weight_line[fill_write_index[2:0]]<=fill_write_data;
    end

    // Delay the complete observation sample together. Local clear registers
    // keep the IDLE/RESP invalidate decode off 160 counter reset pins. Events
    // drain before a completed transaction can be observed through MMIO.
    (* DONT_TOUCH="TRUE" *) reg [4:0] stats_clear_q;
    reg [4:0] stats_event_q;
    always @(posedge clk)
        if(reset_active)begin stats_clear_q<=5'b11111;stats_event_q<=5'd0;end
        else begin
            stats_clear_q<={5{clear_counters}};
            stats_event_q[0]<=arvalid && arready;
            stats_event_q[1]<=rvalid && rready;
            stats_event_q[2]<=state==DECIDE && !is_write && !bad_request_reg &&
                kind==2'd2 && input_hit_reg;
            stats_event_q[3]<=state==DECIDE && !is_write && !bad_request_reg &&
                !(kind==2'd2 && input_hit_reg) && kind==2'd1 && weight_hit_reg;
            stats_event_q[4]<=state==DECIDE && !is_write && !bad_request_reg &&
                !(kind==2'd2 && input_hit_reg) && !(kind==2'd1 && weight_hit_reg);
        end
    tinyyolo_counter32 count_bursts(.clk(clk),.rst_n(rst_n),
        .clear(stats_clear_q[0]),.enable(stats_event_q[0]),.value(read_bursts));
    tinyyolo_counter32 count_beats(.clk(clk),.rst_n(rst_n),
        .clear(stats_clear_q[1]),.enable(stats_event_q[1]),.value(read_beats));
    tinyyolo_counter32 count_input_hits(.clk(clk),.rst_n(rst_n),
        .clear(stats_clear_q[2]),.enable(stats_event_q[2]),.value(input_hits));
    tinyyolo_counter32 count_weight_hits(.clk(clk),.rst_n(rst_n),
        .clear(stats_clear_q[3]),.enable(stats_event_q[3]),.value(weight_hits));
    tinyyolo_counter32 count_misses(.clk(clk),.rst_n(rst_n),
        .clear(stats_clear_q[4]),.enable(stats_event_q[4]),.value(read_misses));

    // Separate response publication from the main FSM priority tree. The
    // last selected read beat retires in COMMIT, before RESP becomes valid.
    // Cache hits retain their existing DECIDE-cycle response publication.
    reg [63:0] read_response_data;
    (* DONT_TOUCH="TRUE" *) reg read_response_load,response_clear;
    always @(posedge clk) begin
        read_response_data<=rx_data;
        if(reset_active)begin
            read_response_load<=0;response_clear<=0;
            input_response_hit<=0;weight_response_hit<=0;
        end else begin
            read_response_load<=state==READ && rx_valid && response_select[0];
            response_clear<=state==IDLE && req_valid;
            input_response_hit<=state==CHECK && !is_write && !bad_request_reg && kind==2'd2 && input_hit;
            weight_response_hit<=state==CHECK && !is_write && !bad_request_reg && kind==2'd1 && weight_hit;
        end
        if(reset_active)rsp_data<=64'd0;
        else if(response_clear)rsp_data<=64'd0;
        else if(input_response_hit)rsp_data<=input_data_pipe;
        else if(weight_response_hit)rsp_data<=weight_line[address[5:3]];
        else if(read_response_load)rsp_data<=read_response_data;
    end

    integer lane;
    always @(posedge clk) begin
        if(reset_active) begin
            state<=SWEEP;sweep_index<=11'd0;invalidate_pending<=1'b0;
            // Request payload is private while the FSM sweeps. IDLE loads
            // every field before LOOKUP/PRIME/CHECK can use it. Reset only
            // the control flags, keeping reset out of the wide payload.
            is_write<=1'b0;kind<=2'd0;
            ar_sent<=1'b0;aw_sent<=1'b0;w_sent<=1'b0;fill_start<=32'd0;fill_end<=32'd0;
            burst_address<=32'd0;receive_address<=32'd0;burst_len<=4'd0;beat<=4'd0;response_select<=8'd0;
            fill_mask<=8'd0;read_error<=1'b0;rsp_error<=1'b0;
            weight_tag<=26'd0;weight_mask<=8'd0;
            input_hit_reg<=1'b0;input_match_reg<=1'b0;
            weight_hit_reg<=1'b0;bad_request_reg<=1'b0;
        end else begin
            if(invalidate)invalidate_pending<=1'b1;
            case(state)
                SWEEP:begin
                    weight_mask<=8'd0;invalidate_pending<=1'b0;
                    if(invalidate)sweep_index<=11'd0;
                    else if(sweep_last)state<=IDLE;
                    else sweep_index<=sweep_index+11'd1;
                end
                IDLE:begin
                    if(invalidate || invalidate_pending)begin
                        sweep_index<=11'd0;weight_mask<=8'd0;state<=SWEEP;
                    end else if(req_valid)begin
                        address<=req_addr;low_address<=req_low;high_address<=req_high;
                        kind<=req_kind;is_write<=req_write;
                        write_data<=req_wdata;write_strobes<=req_wstrb;
                        rsp_error<=1'b0;read_error<=1'b0;
                        aw_sent<=1'b0;w_sent<=1'b0;state<=LOOKUP;
                    end
                end
                LOOKUP:state<=PRIME;
                PRIME:begin
                    // Second registered BRAM read stage.
                    bad_request_reg<=bad_request;
                    state<=CHECK;
                end
                CHECK:begin
                    input_hit_reg<=input_hit;
                    input_match_reg<=input_match;
                    weight_hit_reg<=weight_hit;
                    weight_match_reg<=weight_tag==address[31:6];
                    state<=DECIDE;
                end
                DECIDE:begin
                    rsp_error<=bad_request_reg;
                    if(bad_request_reg)state<=RESP;
                    else if(is_write)begin
                        if(weight_match_reg)weight_mask<=8'd0;
                        state<=WRITE;
                    end else if(input_response_hit)begin
                        state<=RESP;
                    end else if(weight_response_hit)begin
                        state<=RESP;
                    end else state<=PLAN0;
                end
                PLAN0:begin
                    if(kind==2'd0)begin fill_start<=address;fill_end<=address+32'd8;end
                    else begin
                        fill_start<=line_start;
                        fill_end<=high_address<line_end?high_address:line_end;
                    end
                    if(kind==2'd1)weight_mask<=8'd0;
                    state<=PLAN1;
                end
                PLAN1:begin
                    burst_address<=fill_start;receive_address<=fill_start;
                    // Both ends are validated beat-aligned. ARLEN only
                    // consumes four bits, so subtract beat slots modulo 16
                    // directly instead of propagating a byte-address borrow.
                    burst_len<=fill_end[6:3]+(~fill_start[6:3]);beat<=4'd0;
                    // Fills stay in one 64-byte line. Select the requested
                    // beat without a 32-bit address comparator on 64 data CEs.
                    response_select<=8'b0000_0001<<(address[5:3]-fill_start[5:3]);
                    // A validated fill stays within the requested 64-byte
                    // line. Compare beat slots only; an aligned zero end
                    // offset is the exclusive end of that line (slot eight).
                    // This removes address[31:6] from eight full-width masks.
                    for(lane=0;lane<8;lane=lane+1)
                        fill_mask[lane]<=(lane>=fill_start[5:3]) &&
                            (fill_end[5:0]==6'd0 || lane<fill_end[5:3]);
                    ar_sent<=1'b0;state<=AR;
                end
                AR:begin
                    // Terminate native PS ARREADY at one local flag. The R
                    // slice holds an early response until READ consumes it.
                    if(arvalid && arready)ar_sent<=1'b1;
                    if(ar_sent)state<=READ;
                end
                READ:if(rx_valid)begin
                    read_error<=read_error || bad_beat;
                    response_select<={1'b0,response_select[7:1]};
                    receive_address<=receive_address+32'd8;beat<=beat+4'd1;
                    if(rx_last)state<=COMMIT;
                    else if(beat==burst_len)state<=DRAIN;
                end
                // Missing/late RLAST poisons the transaction. Never report
                // success, accept a new request, or release before real RLAST.
                DRAIN:if(rx_valid && rx_last)state<=COMMIT;
                COMMIT:begin
                    rsp_error<=read_error;
                    if(!read_error && kind==2'd1)begin
                        weight_tag<=address[31:6];weight_mask<=fill_mask;
                    end
                    state<=RESP;
                end
                WRITE:begin
                    if(awvalid && awready)aw_sent<=1'b1;
                    if(wvalid && wready)w_sent<=1'b1;
                    // Native PS READY terminates only at its channel flag.
                    // The response slice can hold an early B response while
                    // this registered completion advances one clock later.
                    if(aw_sent && w_sent)state<=BRESP;
                end
                BRESP:if(rx_bvalid)begin rsp_error<=rx_bresp!=2'd0 || rx_bid!=6'd0;state<=RESP;end
                RESP:if(rsp_ready)begin
                    if(invalidate || invalidate_pending)begin sweep_index<=11'd0;weight_mask<=8'd0;state<=SWEEP;end
                    else state<=IDLE;
                end
                default:begin rsp_error<=1'b1;state<=RESP;end
            endcase
        end
    end
endmodule
