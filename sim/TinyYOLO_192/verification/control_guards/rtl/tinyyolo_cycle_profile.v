`timescale 1ns/1ps
// G223 observation-only counters. Eight exclusive phase bins count exactly
// the same pre-edge busy interval as the existing 64-bit controller cycles.
// Seven additional bus events overlap the phase bins and each other; they
// MUST NOT be added to the phase sum. No bus signal is driven by this module.
// Counters wrap modulo 2^64; reset/start/accepted idle clear zero every bin.
// Read only when terminal and HP idle for an untorn low/high 64-bit snapshot.
module tinyyolo_cycle_profile (
    input wire clk, input wire rst_n,
    input wire active, input wire start, input wire clear,
    input wire [63:0] state,
    input wire req_valid, input wire req_ready,
    input wire arvalid, input wire arready,
    input wire rvalid, input wire rready,
    input wire awvalid, input wire awready,
    input wire wvalid, input wire wready,
    input wire bvalid, input wire bready,
    input wire read_enable,
    input wire [4:0] read_addr, output reg [31:0] read_data
);
    wire [63:0] counter[0:14];
    wire [7:0] phase;
    // Keep the all-zero-state fallback balanced and separate from the phase
    // membership mux; it otherwise shares a deep, high-fanout state tree.
    (* KEEP="TRUE" *) wire [7:0] state_any_group;
    genvar state_group;
    generate for(state_group=0;state_group<8;state_group=state_group+1)begin: state_presence
        assign state_any_group[state_group]=|state[state_group*8+:8];
    end endgenerate
    // Consume the controller's one-hot state directly. Encoding 64 states
    // into six bits and decoding them again put both trees on one cycle.
    // The masks retain the established phase-counter ABI.
    assign phase[0]=|{state[1],state[2],state[3],state[4],state[5],state[35],state[36],state[37],
        state[38],state[40],state[41],state[42],state[48],state[63],state[52],state[53],
        state[54],state[55],state[56],state[57],state[58]};
    assign phase[1]=|{state[7],state[8],state[9],state[10],state[45],state[46]};
    assign phase[2]=state[11] || state[12];
    assign phase[3]=|{state[14],state[15],state[16],state[17],state[18],state[19],state[47]};
    assign phase[4]=|{state[20],state[21],state[22],state[23],state[39],state[49],state[60],state[61]};
    assign phase[5]=|{state[24],state[25],state[43],state[44],state[50],state[51]};
    assign phase[6]=|{state[26],state[27],state[28],state[29]};
    assign phase[7]=|{state[0],state[6],state[13],state[30],state[31],state[32],state[33],
        state[34],state[59],state[62]} || !(|state_any_group);
    wire [6:0] bus_event={bready && bvalid,bready && !bvalid,
        (awvalid && !awready) || (wvalid && !wready),
        rready && rvalid,rready && !rvalid,arvalid && !arready,req_valid && !req_ready};
    // Delay the observation stream as a unit before driving 960 counter
    // enables. The final sample drains one cycle after the controller ends,
    // before any accepted MMIO profile read can complete. Counts and phase
    // membership remain exact; the compute/bus datapaths are unaffected.
    reg active_q,start_q,clear_q;
    reg [7:0] phase_q;
    reg [7:0] state_any_q;
    reg [6:0] bus_event_q;
    always @(posedge clk)
        if(!rst_n)begin
            active_q<=0;start_q<=0;clear_q<=0;phase_q<=0;state_any_q<=0;bus_event_q<=0;
        end else begin
            active_q<=active;start_q<=start;clear_q<=clear;
            phase_q[6:0]<=phase[6:0];
            // Capture the small explicit phase and each presence group in
            // parallel. The zero-state fallback is reduced after this edge,
            // so no 64-state reduction is chained into a phase register.
            phase_q[7]<=|{state[0],state[6],state[13],state[30],state[31],state[32],
                state[33],state[34],state[59],state[62]};
            state_any_q<=state_any_group;
            bus_event_q<=bus_event;
        end
    genvar n;
    generate for(n=0;n<15;n=n+1) begin: phase_counter
        wire count_enable;
        // Reset arrives with the already registered observation stream.
        // Preserve a local driver for each 64-bit counter island.
        (* DONT_TOUCH="TRUE" *) reg counter_reset;
        always @(posedge clk)counter_reset<=!rst_n;
        if(n==7) assign count_enable=active_q && (phase_q[7] || !(|state_any_q));
        else if(n<8) assign count_enable=active_q && phase_q[n];
        else assign count_enable=active_q && bus_event_q[n-8];
        tinyyolo_counter64 count(.clk(clk),.rst_n(!counter_reset),.clear(start_q || clear_q),
            .enable(count_enable),.value(counter[n]));
    end endgenerate
    // Split the 30-word counter read mux across two register stages. The
    // first stage selects one of eight words in each 4-counter bank; the
    // controller selects one of the four registered banks on the next cycle.
    // Only accepted profile reads update the snapshot, so AXI address changes
    // after AR handshaking cannot alter the returned word.
    wire [31:0] profile_word[0:31];
    genvar word_id;
    generate for(word_id=0;word_id<15;word_id=word_id+1) begin: profile_words
        assign profile_word[word_id*2]=counter[word_id][31:0];
        assign profile_word[word_id*2+1]=counter[word_id][63:32];
    end endgenerate
    assign profile_word[30]=32'd0;
    assign profile_word[31]=32'd0;

    // Only the low five word-address bits enter the four-bank mux.
    reg [4:0] read_word_q;
    // Parent supplies byte-address bits [6:2]; the MMIO ABI is unchanged.
    always @(posedge clk) read_word_q<=read_addr;
    wire [4:0] word_index=read_word_q-5'd2;
    wire [2:0] word_in_bank=word_index[2:0];
    wire [1:0] bank_index=word_index[4:3];
    reg [1:0] bank_index_q;
    reg [31:0] bank_data[0:3];
    genvar bank_id;
    generate for(bank_id=0;bank_id<4;bank_id=bank_id+1) begin: profile_read_bank
        (* DONT_TOUCH="TRUE" *) reg read_enable_q;
        always @(posedge clk)
            if(!rst_n)read_enable_q<=1'b0;
            else read_enable_q<=read_enable;
        reg [31:0] selected_word;
        always @* begin
            case(word_in_bank)
                3'd0:selected_word=profile_word[bank_id*8+0];
                3'd1:selected_word=profile_word[bank_id*8+1];
                3'd2:selected_word=profile_word[bank_id*8+2];
                3'd3:selected_word=profile_word[bank_id*8+3];
                3'd4:selected_word=profile_word[bank_id*8+4];
                3'd5:selected_word=profile_word[bank_id*8+5];
                3'd6:selected_word=profile_word[bank_id*8+6];
                3'd7:selected_word=profile_word[bank_id*8+7];
                default:selected_word=32'd0;
            endcase
        end
        always @(posedge clk)
            if(read_enable_q) bank_data[bank_id]<=selected_word;
    end endgenerate

    always @(posedge clk)
        if(profile_read_bank[0].read_enable_q) bank_index_q<=bank_index;

    always @* begin
        case(bank_index_q)
            2'd0:read_data=bank_data[0];
            2'd1:read_data=bank_data[1];
            2'd2:read_data=bank_data[2];
            2'd3:read_data=bank_data[3];
            default:read_data=32'd0;
        endcase
    end
endmodule

// Four 16-bit incrementers keep each data path local. Registered predictive
// carries describe whether the current lower words are all ones; they are
// computed one cycle ahead from the pre-increment value. The visible modulo-
// 2^64 count and read ABI therefore retain exactly the original cycle semantics.
module tinyyolo_counter64 (
    input wire clk,rst_n,clear,enable,
    output reg [63:0] value
);
    reg carry16,carry32,carry48;
    always @(posedge clk) begin
        if(!rst_n || clear) begin
            value<=64'd0;
            carry16<=1'b0;
            carry32<=1'b0;
            carry48<=1'b0;
        end else if(enable) begin
            value[15:0]<=value[15:0]+16'd1;
            value[31:16]<=value[31:16]+carry16;
            value[47:32]<=value[47:32]+carry32;
            value[63:48]<=value[63:48]+carry48;
        end
        // The next low word is all ones iff bits 15:1 are all ones and
        // bit zero differs from enable. This is also true during a stall,
        // so enable only enters one small XOR instead of a wide carry mux.
        // Recompute each cycle to retain force/deposit self-correction.
        if(rst_n && !clear)begin
            carry16<=(&value[15:1]) && (value[0] ^ enable);
            carry32<=(&value[31:1]) && (value[0] ^ enable);
            carry48<=(&value[47:1]) && (value[0] ^ enable);
        end
    end
endmodule
