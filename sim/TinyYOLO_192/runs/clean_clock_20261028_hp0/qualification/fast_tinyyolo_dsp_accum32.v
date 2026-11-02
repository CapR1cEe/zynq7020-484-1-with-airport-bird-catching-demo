`timescale 1ns/1ps
// Pipelined DSP feedback accumulator, initiation interval one. The physical
// 48-bit sum retains the carry above INT32 so every intermediate overflow is
// observable. Low 32 bits keep the original modulo arithmetic on fault paths.
module fast_tinyyolo_dsp_accum32 #(parameter TERM_WIDTH=20) (
    input wire clk, input wire rst_n, input wire load,
    input wire signed [31:0] bias,
    input wire valid, input wire last,
    input wire signed [TERM_WIDTH-1:0] term,
    output wire signed [31:0] sum,
    output wire overflow,
    output reg out_valid, output reg out_last
);
    wire [47:0] p;
    // Separate the bias/term selection and fabric routing from DSP C setup.
    // Align command metadata with this stage; initiation interval stays one.
    (* DONT_TOUCH="TRUE" *) reg [47:0] operand_q;
    reg load_q,valid_q,last_q;
    always @(posedge clk)begin
        operand_q<=load?{{16{bias[31]}},bias}:{{(48-TERM_WIDTH){term[TERM_WIDTH-1]}},term};
        if(!rst_n)begin load_q<=0;valid_q<=0;last_q<=0;end
        else begin load_q<=load;valid_q<=valid;last_q<=last;end
    end
    reg command_valid,command_load,command_last;
    always @(posedge clk)
        if(!rst_n) begin command_valid<=0;command_load<=0;command_last<=0;end
        else begin command_valid<=valid_q || load_q;command_load<=load_q;command_last<=last_q;end
    // Retire the DSP P bus through a local register. Four independent sign
    // checks keep the DSP clock-to-out, overflow reduction and sticky flag
    // off one path. Data and both metadata bits gain exactly one clock;
    // feedback remains inside the DSP and still accepts a term each clock.
    reg signed [31:0] sum_q;
    reg [3:0] overflow_parts;
    reg dsp_valid,dsp_last;
    genvar overflow_group;
    generate for(overflow_group=0;overflow_group<4;overflow_group=overflow_group+1)begin: overflow_check
        always @(posedge clk)
            overflow_parts[overflow_group]<=
                |(p[32+overflow_group*4+:4] ^ {4{p[31]}});
    end endgenerate
    always @(posedge clk)sum_q<=p[31:0];
    assign sum=sum_q;
    assign overflow=|overflow_parts;
    always @(posedge clk)
        if(!rst_n) begin
            dsp_valid<=1'b0;dsp_last<=1'b0;out_valid<=1'b0;out_last<=1'b0;
        end else begin
            dsp_valid<=command_valid && !command_load;dsp_last<=command_last;
            out_valid<=dsp_valid;out_last<=dsp_last;
        end
    (* DONT_TOUCH="TRUE" *) ty_dsp48e1_fast #(
        .A_INPUT("DIRECT"),.B_INPUT("DIRECT"),.USE_DPORT("FALSE"),
        .USE_MULT("NONE"),.USE_SIMD("ONE48"),
        .AREG(0),.ACASCREG(0),.BREG(0),.BCASCREG(0),.ADREG(0),
        .CREG(1),.DREG(0),.MREG(0),.PREG(1),.ALUMODEREG(0),
        .CARRYINREG(0),.CARRYINSELREG(0),.INMODEREG(0),.OPMODEREG(1)
    ) dsp (
        .CLK(clk),.A(30'd0),.B(18'd0),.C(operand_q),.D(25'd0),
        .ACIN(30'd0),.BCIN(18'd0),.PCIN(48'd0),
        .ALUMODE(4'b0000),.INMODE(5'b00000),
        .OPMODE(load_q?7'b0001100:7'b0101100),
        .CARRYINSEL(3'b000),.CARRYIN(1'b0),.CARRYCASCIN(1'b0),.MULTSIGNIN(1'b0),
        .CEA1(1'b1),.CEA2(1'b1),.CEB1(1'b1),.CEB2(1'b1),.CEAD(1'b1),
        .CEC(1'b1),.CED(1'b1),.CEM(1'b0),.CEP(command_valid),.CEALUMODE(1'b1),
        .CECARRYIN(1'b1),.CECTRL(1'b1),.CEINMODE(1'b1),
        .RSTA(!rst_n),.RSTB(!rst_n),.RSTC(!rst_n),.RSTD(!rst_n),
        .RSTM(!rst_n),.RSTP(!rst_n),.RSTALUMODE(!rst_n),
        .RSTALLCARRYIN(!rst_n),.RSTCTRL(!rst_n),.RSTINMODE(!rst_n),
        .P(p),.ACOUT(),.BCOUT(),.PCOUT(),.CARRYOUT(),.CARRYCASCOUT(),
        .MULTSIGNOUT(),.OVERFLOW(),.UNDERFLOW(),.PATTERNDETECT(),.PATTERNBDETECT()
    );
endmodule
