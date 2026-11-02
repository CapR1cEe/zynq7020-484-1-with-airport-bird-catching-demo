`timescale 1ns/1ps
// 1x1 FP32 head fused with its INT8 -> FP32 activation LUT. Every table
// element is an exact binary64 product of the original FP32 operands.
// Channel order, binary64 RNE additions and the final FP32 cast are retained.
// Table header: bias64, 256-bit zero mask, 24 reserved bytes; then [ci][256]64.
module tinyyolo_head_exact (
    input wire clk,input wire rst_n,input wire start,
    input wire [31:0] src,table_base,dst,ci,height,width,
    output wire busy,output reg done,output wire [31:0] error_code,
    output reg [31:0] terms,outputs_written,output wire [31:0] zero_skipped,
    output reg req_valid,input wire req_ready,output reg req_write,
    output reg [31:0] req_addr,output reg [63:0] req_wdata,
    output reg [7:0] req_wstrb,output reg [1:0] req_kind,
    output reg [31:0] req_low,req_high,
    input wire rsp_valid,output reg rsp_ready,input wire [63:0] rsp_data,
    input wire rsp_error
);
    // Bound the combinational reset inverter fanout without adding a cycle.
    // Synthesis may replicate its LUT beside the synchronous consumers.
    (* MAX_FANOUT=32 *) wire reset_active=!rst_n;

    localparam [4:0] IDLE=0,CHECK=1,SIZES=2,REGIONS=3,HEADER_REQ=4,
        HEADER_RSP=5,PIXEL=6,INPUT_ADDR=7,INPUT_REQ=8,INPUT_RSP=9,
        SELECT=10,TABLE_ADDR=11,TABLE_REQ=12,TABLE_RSP=13,
        ADD_START=14,ADD_WAIT=15,NEXT_CHANNEL=16,CAST_START=17,
        CAST_WAIT=18,WRITE_REQ=19,WRITE_RSP=20,FINISH=21,FAULT=22,REGIONS0=23,MASK_LOOK=24,REGIONS_WAIT=25,PLANE_SUM=26,CONFIG_MERGE=27;
    (* fsm_encoding="none", MAX_FANOUT=16, EXTRACT_ENABLE="NO" *) reg [27:0] state;
    reg invalid_error;
    (* EXTRACT_ENABLE="NO" *) reg [31:0] event_error_code;
    assign error_code=invalid_error?32'd5:event_error_code;
    reg [3:0] config_bad_parts;
    reg config_bad;
    reg pixel_is_last;
    // CHECK limits each dimension to 26, so plane and pixel are at most 676.
    // Register LUT partial products at START, merge configuration guards in
    // CONFIG_MERGE, then add the products in CHECK/PLANE_SUM. No DSP is used.
    reg [9:0] plane,pixel,last_pixel;
    reg [6:0] plane_part_lo;
    reg [7:0] plane_part_hi;
    reg [7:0] plane_part_hi_lo,plane_part_hi_hi;
    reg [7:0] channel;
    reg [31:0] input_address,table_address,table_data_base;
    reg [31:0] pixel_address,next_input_address;
    reg [16:0] input_step_lo,table_step_lo;
    reg [15:0] input_step_hi,table_step_hi;
    // INPUT_ADDR -> INPUT_REQ -> INPUT_RSP -> MASK_LOOK -> SELECT gives
    // enough time to prepare the channel stride without another FSM cycle.
    // Keep each carry chain at 16 bits and consume the registered join.
    always @(posedge clk) begin
        input_step_lo<={1'b0,input_address[15:0]}+{7'd0,plane};
        input_step_hi<=input_address[31:16];
        next_input_address<={input_step_hi+{15'd0,input_step_lo[16]},input_step_lo[15:0]};
    end
    reg [32:0] source_end,table_end,dest_end;
    reg [2:0] header;
    reg [31:0] header_address;
    reg [255:0] zero_mask;
    reg [7:0] region_bad;
    wire [3:0] region_le;
    tinyyolo_le33 source_before_dest(.clk(clk),.a(source_end),.b({1'b0,dst}),.le(region_le[0]));
    tinyyolo_le33 dest_before_source(.clk(clk),.a(dest_end),.b({1'b0,src}),.le(region_le[1]));
    tinyyolo_le33 table_before_dest(.clk(clk),.a(table_end),.b({1'b0,dst}),.le(region_le[2]));
    tinyyolo_le33 dest_before_table(.clk(clk),.a(dest_end),.b({1'b0,table_base}),.le(region_le[3]));
    reg zero_selected;
    reg [63:0] bias,sum,product;
    // A response captures one 64-bit operand on the original edge. Copy its
    // combinational CE near the operand flops, without another pipe stage.
    (* MAX_FANOUT=16 *) wire table_capture=state[TABLE_RSP] && rsp_valid;
    always @(posedge clk)
        if(reset_active)product<=64'd0;
        else if(table_capture)product<=rsp_data;
    reg [7:0] index;
    reg [31:0] output_address;
    wire add_done,add_error,cast_done,cast_error;
    wire [63:0] add_result;
    wire [31:0] cast_result;
    // These pulses coincide with the existing launch states. Retain local
    // registers so the head's state decoder cannot feed the wide
    // arithmetic operand enables in series with the inner FSM's IDLE test.
    (* DONT_TOUCH="TRUE" *) reg add_launch,cast_launch;
    always @(posedge clk)
        if(reset_active)begin add_launch<=1'b0;cast_launch<=1'b0;end
        else begin
            add_launch<=state[TABLE_RSP] && rsp_valid && !rsp_error;
            cast_launch<=state[NEXT_CHANNEL] && channel==8'd255;
        end
    tinyyolo_fp64_add adder(.clk(clk),.rst_n(rst_n),.start(add_launch),
        .a(sum),.b(product),.done(add_done),.error(add_error),.result(add_result));
    tinyyolo_fp64_to_fp32 convert(.clk(clk),.rst_n(rst_n),.start(cast_launch),
        .value(sum),.done(cast_done),.error(cast_error),.result(cast_result));
    assign busy=!state[IDLE] && !state[FINISH] && !state[FAULT];
    // A legal START precedes SELECT by many clocks. Retire its local clear
    // on the next clock so terminal-state decode never drives 35 reset pins.
    (* DONT_TOUCH="TRUE" *) reg zero_clear;
    always @(posedge clk)
        if(reset_active)zero_clear<=1'b0;
        else zero_clear<=start && !busy;
    tinyyolo_counter32 zero_counter(.clk(clk),.rst_n(rst_n),
        .clear(zero_clear),.enable(state[SELECT] && zero_selected),
        .value(zero_skipped));
    // Entering a response state is known at the request handshake. Register
    // READY there, removing the FSM decode from the shared response
    // slice's wide data enable without adding any request/response latency.
    always @(posedge clk)
        if(reset_active)rsp_ready<=1'b0;
        else if(rsp_ready && rsp_valid)rsp_ready<=1'b0;
        else if(req_ready && (state[HEADER_REQ] || state[INPUT_REQ] ||
                              state[TABLE_REQ] || state[WRITE_REQ]))rsp_ready<=1'b1;
    // Prepare requests in the existing predecessor state. This removes the
    // head FSM -> address/data mux -> shared request mux -> skid register path
    // without inserting a cycle per input/table access. Payload stays stable
    // throughout backpressure; only an actual VALID/READY handshake retires it.
    // Read requests retain the last write payload, which AXI ignores. Only
    // CAST_WAIT updates that payload, keeping header decode off its wide CE.
    always @(posedge clk)begin
        if(reset_active)begin
            req_valid<=0;req_write<=0;req_addr<=0;req_wdata<=0;
            req_wstrb<=0;req_kind<=0;
        end else begin
            if(req_valid && req_ready)req_valid<=0;
            (* parallel_case *) case(1'b1)
                state[REGIONS]:begin
                    req_valid<=!(|region_bad);req_write<=0;req_addr<=table_base;req_kind<=0;
                    req_wstrb<=0;
                end
                // Prepare invalid payload speculatively while waiting. Only
                // its single VALID bit depends on the response handshake.
                state[HEADER_RSP]:if(header!=4)begin
                    req_valid<=rsp_valid;req_write<=0;req_addr<=header_address+32'd8;req_kind<=0;
                    req_wstrb<=0;
                end
                state[INPUT_ADDR]:begin
                    req_valid<=1;req_write<=0;req_addr<={input_address[31:3],3'd0};req_kind<=2;
                    req_wstrb<=0;
                end
                state[TABLE_ADDR]:begin
                    req_valid<=1;req_write<=0;
                    req_addr<=table_address;req_kind<=0;
                    req_wstrb<=0;
                end
                state[CAST_WAIT]:begin
                    req_valid<=cast_done && !cast_error;req_write<=1;req_addr<={output_address[31:3],3'd0};req_kind<=0;
                    req_wdata<=output_address[2]?{cast_result,32'd0}:{32'd0,cast_result};
                    req_wstrb<=output_address[2]?8'hf0:8'h0f;
                    
                end
                default:begin end
            endcase
            if(rsp_valid && rsp_ready && rsp_error)req_valid<=0;
        end
    end
    // Register every next-state bit explicitly. Implicit case holds
    // otherwise produce one shared multi-level CE for all 28 state flops.
    reg [27:0] state_next;
    wire head_start=start && !busy;
    wire response_error=rsp_valid && rsp_ready && rsp_error;
    wire invalid_state=!(|state);
    wire config_error=state[CHECK] && config_bad;
    wire region_error=state[REGIONS] && (|region_bad);
    wire add_fault=state[ADD_WAIT] && add_done && add_error;
    wire cast_fault=state[CAST_WAIT] && cast_done && cast_error;
    wire local_error=config_error || region_error || add_fault || cast_fault;
    wire [31:0] local_error_value=({32{config_error}} & 32'd1) |
        ({32{region_error}} & 32'd4) | ({32{add_fault}} & 32'd8) |
        ({32{cast_fault}} & 32'd9);
    always @* begin
        state_next=28'd0;
        state_next[IDLE]=state[IDLE] && !start;
        state_next[CONFIG_MERGE]=head_start;
        state_next[CHECK]=state[CONFIG_MERGE];
        state_next[PLANE_SUM]=state[CHECK] && !config_bad;
        state_next[SIZES]=state[PLANE_SUM];
        state_next[REGIONS_WAIT]=state[SIZES];
        state_next[REGIONS0]=state[REGIONS_WAIT];
        state_next[REGIONS]=state[REGIONS0];
        state_next[HEADER_REQ]=(state[REGIONS] && !(|region_bad)) ||
            (state[HEADER_REQ] && !req_ready) || (state[HEADER_RSP] && rsp_valid && header!=3'd4);
        state_next[HEADER_RSP]=(state[HEADER_REQ] && req_ready) || (state[HEADER_RSP] && !rsp_valid);
        state_next[PIXEL]=(state[HEADER_RSP] && rsp_valid && header==3'd4) ||
            (state[WRITE_RSP] && rsp_valid && !pixel_is_last);
        state_next[INPUT_ADDR]=state[PIXEL] || (state[NEXT_CHANNEL] && channel!=8'd255);
        state_next[INPUT_REQ]=state[INPUT_ADDR] || (state[INPUT_REQ] && !req_ready);
        state_next[INPUT_RSP]=(state[INPUT_REQ] && req_ready) || (state[INPUT_RSP] && !rsp_valid);
        state_next[MASK_LOOK]=state[INPUT_RSP] && rsp_valid;
        state_next[SELECT]=state[MASK_LOOK];
        state_next[TABLE_ADDR]=state[SELECT] && !zero_selected;
        state_next[TABLE_REQ]=state[TABLE_ADDR] || (state[TABLE_REQ] && !req_ready);
        state_next[TABLE_RSP]=(state[TABLE_REQ] && req_ready) || (state[TABLE_RSP] && !rsp_valid);
        state_next[ADD_START]=state[TABLE_RSP] && rsp_valid;
        state_next[ADD_WAIT]=state[ADD_START] || (state[ADD_WAIT] && !add_done);
        state_next[NEXT_CHANNEL]=(state[SELECT] && zero_selected) ||
            (state[ADD_WAIT] && add_done && !add_error);
        state_next[CAST_START]=state[NEXT_CHANNEL] && channel==8'd255;
        state_next[CAST_WAIT]=state[CAST_START] || (state[CAST_WAIT] && !cast_done);
        state_next[WRITE_REQ]=(state[CAST_WAIT] && cast_done && !cast_error) ||
            (state[WRITE_REQ] && !req_ready);
        state_next[WRITE_RSP]=(state[WRITE_REQ] && req_ready) || (state[WRITE_RSP] && !rsp_valid);
        state_next[FINISH]=(state[FINISH] && !start) ||
            (state[WRITE_RSP] && rsp_valid && pixel_is_last);
        state_next[FAULT]=(state[FAULT] && !start) || local_error || invalid_state;
        if(response_error)state_next=28'b1<<FAULT;
    end
    always @(posedge clk)
        if(reset_active)state<=28'b1<<IDLE;
        else state<=state_next;
    always @(posedge clk)
        if(reset_active)begin done<=1'b0;event_error_code<=32'd0;end
        else begin
            done<=response_error || local_error || invalid_state ||
                (state[WRITE_RSP] && rsp_valid && pixel_is_last);
            if(head_start)event_error_code<=32'd0;
            else if(response_error)event_error_code<=32'd3;
            else if(local_error)event_error_code<=local_error_value;
        end
    // End the wide zero-state reduction at one sticky flop. FAULT and DONE
    // still assert on the original edge, with bus errors taking priority.
    always @(posedge clk)
        if(reset_active || head_start || response_error)invalid_error<=1'b0;
        else if(invalid_state)invalid_error<=1'b1;
    // Read range selection is independent of the request payload case.
    // WRITE ignores this range and must not put CAST_WAIT on a 64-bit CE.
    always @(posedge clk)
        if(reset_active)begin req_low<=32'd0;req_high<=32'd0;end
        else if(state[INPUT_ADDR])begin req_low<=src;req_high<=source_end[31:0];end
        else if(state[REGIONS] || state[TABLE_ADDR])begin
            req_low<=table_base;req_high<=table_end[31:0];
        end
    // Datapath updates are independent of state and status publication.
    always @(posedge clk) begin
        if(reset_active) begin
            terms<=0;outputs_written<=0;
            config_bad_parts<=4'd0;config_bad<=1'b0;pixel_is_last<=1'b0;
            plane<=0;plane_part_lo<=0;plane_part_hi<=0;plane_part_hi_lo<=0;plane_part_hi_hi<=0;
            pixel<=0;last_pixel<=0;channel<=0;
            input_address<=0;table_address<=0;table_data_base<=0;source_end<=0;table_end<=0;dest_end<=0;
            header<=0;header_address<=0;zero_mask<=0;region_bad<=0;zero_selected<=0;bias<=0;sum<=0;index<=0;
            output_address<=0;pixel_address<=0;table_step_lo<=0;table_step_hi<=0;
        end else begin
            (* parallel_case *) case(1'b1)
                state[IDLE],state[FINISH],state[FAULT]:if(start) begin
                    terms<=0;outputs_written<=0;
                    // Preload the first output address before the header
                    // response state. Keeping HEADER_RSP off this CE
                    // removes the high-fanout state[HEADER_RSP] to
                    // output_address timing path; the address is stable
                    // for the entire header and compute sequence.
                    output_address<=dst;
                    config_bad_parts[0]<=|(src[2:0]|table_base[2:0]|dst[2:0]);
                    config_bad_parts[1]<=ci!=256;
                    config_bad_parts[2]<=!height || height>26;
                    config_bad_parts[3]<=!width || width>26;
                    plane_part_lo <= (width[0]?{2'b0,height[4:0]}:7'd0) +
                                     (width[1]?{1'b0,height[4:0],1'b0}:7'd0);
                    plane_part_hi_lo <= (width[2]?{3'b0,height[4:0]}:8'd0) +
                                        (width[3]?{2'b0,height[4:0],1'b0}:8'd0);
                    plane_part_hi_hi <= width[4]?{1'b0,height[4:0],2'b0}:8'd0;
                end
                state[CONFIG_MERGE]:config_bad<=|config_bad_parts;
                state[CHECK]:plane_part_hi<=plane_part_hi_lo+plane_part_hi_hi;
                state[PLANE_SUM]:plane<={3'b0,plane_part_lo}+{plane_part_hi,2'b0};
                state[SIZES]:begin
                    last_pixel<=plane-10'd1;
                    table_data_base<=table_base+32'd64;
                    source_end<={1'b0,src}+{15'd0,plane,8'd0};
                    table_end<={1'b0,table_base}+33'd524352;
                    dest_end<={1'b0,dst}+{1'b0,plane,2'd0};
                end
                state[REGIONS0]:begin
                    region_bad[0]<=src<32'h00100000;
                    region_bad[1]<=table_base<32'h00100000;
                    region_bad[2]<=dst<32'h00100000;
                    region_bad[3]<=source_end>33'h01fff0000;
                    region_bad[4]<=table_end>33'h01fff0000;
                    region_bad[5]<=dest_end>33'h01fff0000;
                    region_bad[6]<=!(region_le[0] || region_le[1]);
                    region_bad[7]<=!(region_le[2] || region_le[3]);
                end
                state[REGIONS]:begin header<=0;header_address<=table_base;end
                state[HEADER_RSP]:if(rsp_valid) begin
                    if(header==0)bias<=rsp_data;
                    else zero_mask[(header-1'b1)*64+:64]<=rsp_data;
                    if(header==4)begin pixel<=0;pixel_address<=src;end
                    else begin header<=header+3'd1;header_address<=header_address+32'd8;end
                end
                state[PIXEL]:begin
                    pixel_is_last<=pixel==last_pixel;sum<=bias;channel<=0;input_address<=pixel_address;
                end
                state[INPUT_RSP]:if(rsp_valid)index<=rsp_data[input_address[2:0]*8+:8]^8'h80;
                state[MASK_LOOK]:begin
                    zero_selected<=zero_mask[index];
                    table_step_lo<={1'b0,table_data_base[15:0]}+{1'b0,channel[4:0],index,3'd0};
                    table_step_hi<=table_data_base[31:16]+{13'd0,channel[7:5]};
                end
                state[SELECT]:table_address<={table_step_hi+{15'd0,table_step_lo[16]},table_step_lo[15:0]};
                state[TABLE_RSP]:begin end
                state[ADD_WAIT]:if(add_done && !add_error)sum<=add_result;
                state[NEXT_CHANNEL]:begin
                    terms<=terms+32'd1;
                    if(channel!=8'd255)begin channel<=channel+8'd1;input_address<=next_input_address;end
                end
                state[WRITE_RSP]:if(rsp_valid)begin
                    outputs_written<=outputs_written+32'd1;
                    if(!pixel_is_last)begin
                        pixel<=pixel+10'd1;pixel_address<=pixel_address+32'd1;
                        output_address<=output_address+32'd4;
                    end
                end
                default:begin end
            endcase
        end
    end
endmodule
