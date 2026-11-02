`timescale 1ns/1ps
// Signed 25x18 multiply, 2+INPUT_REG clocks latency, initiation interval one.
// Physical DSP48E1 MREG/PREG are explicit; no inference assumption is needed.
module fast_tinyyolo_dsp_mul #(
    parameter INPUT_REG=0
) (
    input wire clk, input wire rst_n,
    input wire signed [24:0] a, input wire signed [17:0] b,
    output wire signed [42:0] product
);
    wire [47:0] p;
    assign product=p[42:0];
    (* DONT_TOUCH="TRUE" *) ty_dsp48e1_fast #(
        .A_INPUT("DIRECT"),.B_INPUT("DIRECT"),.USE_DPORT("FALSE"),
        .USE_MULT("MULTIPLY"),.USE_SIMD("ONE48"),
        .AREG(INPUT_REG),.ACASCREG(INPUT_REG),.BREG(INPUT_REG),.BCASCREG(INPUT_REG),.ADREG(0),
        .CREG(0),.DREG(0),.MREG(1),.PREG(1),.ALUMODEREG(0),
        .CARRYINREG(0),.CARRYINSELREG(0),.INMODEREG(0),.OPMODEREG(0)
    ) dsp (
        .CLK(clk),.A({{5{a[24]}},a}),.B(b),.C(48'd0),.D(25'd0),
        .ACIN(30'd0),.BCIN(18'd0),.PCIN(48'd0),
        .ALUMODE(4'b0000),.INMODE(5'b00000),.OPMODE(7'b0000101),
        .CARRYINSEL(3'b000),.CARRYIN(1'b0),.CARRYCASCIN(1'b0),.MULTSIGNIN(1'b0),
        .CEA1(1'b1),.CEA2(1'b1),.CEB1(1'b1),.CEB2(1'b1),.CEAD(1'b1),
        .CEC(1'b1),.CED(1'b1),.CEM(1'b1),.CEP(1'b1),.CEALUMODE(1'b1),
        .CECARRYIN(1'b1),.CECTRL(1'b1),.CEINMODE(1'b1),
        .RSTA(!rst_n),.RSTB(!rst_n),.RSTC(!rst_n),.RSTD(!rst_n),
        .RSTM(!rst_n),.RSTP(!rst_n),.RSTALUMODE(!rst_n),
        .RSTALLCARRYIN(!rst_n),.RSTCTRL(!rst_n),.RSTINMODE(!rst_n),
        .P(p),.ACOUT(),.BCOUT(),.PCOUT(),.CARRYOUT(),.CARRYCASCOUT(),
        .MULTSIGNOUT(),.OVERFLOW(),.UNDERFLOW(),.PATTERNDETECT(),.PATTERNBDETECT()
    );
endmodule
