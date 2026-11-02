`timescale 1ns/1ps
// Simulation-only model of the two DSP48E1 configurations in this project.
// It is qualified cycle-for-cycle against AMD UNISIM before integration use.
// Unsupported parameters or dynamic controls stop simulation immediately.
module ty_dsp48e1_fast #(
    parameter A_INPUT="DIRECT", B_INPUT="DIRECT", USE_DPORT="FALSE",
    parameter USE_MULT="MULTIPLY", USE_SIMD="ONE48",
    parameter AREG=0, ACASCREG=0, BREG=0, BCASCREG=0, ADREG=0,
    parameter CREG=0, DREG=0, MREG=1, PREG=1, ALUMODEREG=0,
    parameter CARRYINREG=0, CARRYINSELREG=0, INMODEREG=0, OPMODEREG=0
) (
    input wire CLK,
    input wire [29:0] A, ACIN,
    input wire [17:0] B, BCIN,
    input wire [47:0] C, PCIN,
    input wire [24:0] D,
    input wire [3:0] ALUMODE,
    input wire [4:0] INMODE,
    input wire [6:0] OPMODE,
    input wire [2:0] CARRYINSEL,
    input wire CARRYIN, CARRYCASCIN, MULTSIGNIN,
    input wire CEA1, CEA2, CEB1, CEB2, CEAD, CEC, CED, CEM, CEP,
    input wire CEALUMODE, CECARRYIN, CECTRL, CEINMODE,
    input wire RSTA, RSTB, RSTC, RSTD, RSTM, RSTP, RSTALUMODE,
    input wire RSTALLCARRYIN, RSTCTRL, RSTINMODE,
    output wire [47:0] P, PCOUT,
    output wire [29:0] ACOUT,
    output wire [17:0] BCOUT,
    output wire [3:0] CARRYOUT,
    output wire CARRYCASCOUT, MULTSIGNOUT, OVERFLOW, UNDERFLOW,
    output wire PATTERNDETECT, PATTERNBDETECT
);
    localparam MULT=USE_MULT=="MULTIPLY";
    reg signed [24:0] aq;
    reg signed [17:0] bq;
    reg signed [42:0] mq;
    reg [47:0] cq, pq;
    reg [6:0] oq;
    wire signed [24:0] av=AREG?aq:$signed(A[24:0]);
    wire signed [17:0] bv=BREG?bq:$signed(B);
    wire [47:0] cv=CREG?cq:C;
    wire [6:0] ov=OPMODEREG?oq:OPMODE;
    assign P=pq;
    assign PCOUT=pq;
    // These outputs are unused in both supported production configurations.
    assign ACOUT=30'bx;
    assign BCOUT=18'bx;
    assign CARRYOUT=4'bx;
    assign {CARRYCASCOUT,MULTSIGNOUT,OVERFLOW,UNDERFLOW,PATTERNDETECT,PATTERNBDETECT}=6'bx;
    initial begin
        if(A_INPUT!="DIRECT" || B_INPUT!="DIRECT" || USE_DPORT!="FALSE" || USE_SIMD!="ONE48" ||
           !(USE_MULT=="MULTIPLY" || USE_MULT=="NONE") || !(AREG==0 || AREG==1) || BREG!=AREG ||
           ACASCREG!=AREG || BCASCREG!=BREG || ADREG!=0 || DREG!=0 || PREG!=1 ||
           ALUMODEREG!=0 || CARRYINREG!=0 || CARRYINSELREG!=0 || INMODEREG!=0 ||
           (MULT && (MREG!=1 || CREG!=0 || OPMODEREG!=0)) ||
           (!MULT && (MREG!=0 || AREG!=0 || CREG!=OPMODEREG || !(CREG==0 || CREG==1))))
            $fatal(1,"FAST_DSP_UNSUPPORTED_PARAMETERS");
    end
    always @(posedge CLK) begin
        if(RSTA)aq<=0; else if(CEA2)aq<=A[24:0];
        if(RSTB)bq<=0; else if(CEB2)bq<=B;
        if(RSTM)mq<=0; else if(CEM)mq<=av*bv;
        if(RSTC)cq<=0; else if(CEC)cq<=C;
        if(RSTCTRL)oq<=0; else if(CECTRL)oq<=OPMODE;
        if(RSTP)pq<=0;
        else if(CEP) begin
            case(ov)
                7'b0000101:begin
                    if(!MULT)$fatal(1,"FAST_DSP_MULTIPLY_DISABLED");
                    pq<={{5{mq[42]}},mq};
                end
                7'b0001100:pq<=cv;
                7'b0101100:pq<=pq+cv;
                7'd0:if(OPMODEREG && RSTCTRL)pq<=0;
                      else $fatal(1,"FAST_DSP_UNEXPECTED_ZERO_OPMODE");
                default:$fatal(1,"FAST_DSP_UNSUPPORTED_OPMODE %b",ov);
            endcase
        end
        if({ALUMODE,INMODE,CARRYINSEL,CARRYIN,CARRYCASCIN,MULTSIGNIN}!==15'd0)
            $fatal(1,"FAST_DSP_UNSUPPORTED_CONTROL");
    end
endmodule
