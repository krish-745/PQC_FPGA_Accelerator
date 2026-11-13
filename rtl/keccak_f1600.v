// One round of Keccak-f[1600] (FIPS 202, Section 3.3): theta, rho, pi, chi, iota. Combinational.
// Lane (x, y) is s[64*(x + 5*y) +: 64]; byte j of the state is s[8*j +: 8] (lanes little-endian).
// Written with generate loops so every index and rotation amount is a constant.
module keccak_f1600 (
    input  wire [1599:0] s_in,
    input  wire [4:0]    round,
    output wire [1599:0] s_out
);
    // rotation offsets r[x][y], indexed by x + 5y (FIPS 202 Table 2)
    localparam [25*6-1:0] RHO = {
        6'd14, 6'd56, 6'd61, 6'd2,  6'd18,   // y = 4: x = 4..0
        6'd8,  6'd21, 6'd15, 6'd45, 6'd41,   // y = 3
        6'd39, 6'd25, 6'd43, 6'd10, 6'd3,    // y = 2
        6'd20, 6'd55, 6'd6,  6'd44, 6'd36,   // y = 1
        6'd27, 6'd28, 6'd62, 6'd1,  6'd0     // y = 0
    };
    reg [63:0] rc;
    always @* begin
        case (round)
            5'd0:  rc = 64'h0000000000000001; 5'd1:  rc = 64'h0000000000008082;
            5'd2:  rc = 64'h800000000000808A; 5'd3:  rc = 64'h8000000080008000;
            5'd4:  rc = 64'h000000000000808B; 5'd5:  rc = 64'h0000000080000001;
            5'd6:  rc = 64'h8000000080008081; 5'd7:  rc = 64'h8000000000008009;
            5'd8:  rc = 64'h000000000000008A; 5'd9:  rc = 64'h0000000000000088;
            5'd10: rc = 64'h0000000080008009; 5'd11: rc = 64'h000000008000000A;
            5'd12: rc = 64'h000000008000808B; 5'd13: rc = 64'h800000000000008B;
            5'd14: rc = 64'h8000000000008089; 5'd15: rc = 64'h8000000000008003;
            5'd16: rc = 64'h8000000000008002; 5'd17: rc = 64'h8000000000000080;
            5'd18: rc = 64'h000000000000800A; 5'd19: rc = 64'h800000008000000A;
            5'd20: rc = 64'h8000000080008081; 5'd21: rc = 64'h8000000000008080;
            5'd22: rc = 64'h0000000080000001; 5'd23: rc = 64'h8000000080008008;
            default: rc = 64'h0;
        endcase
    end

    wire [63:0] c[0:4], d[0:4], t[0:24], b[0:24], o[0:24];
    genvar x, y;
    generate
        for (x = 0; x < 5; x = x + 1) begin : g_c
            assign c[x] = s_in[64*x +: 64] ^ s_in[64*(x+5) +: 64] ^ s_in[64*(x+10) +: 64]
                        ^ s_in[64*(x+15) +: 64] ^ s_in[64*(x+20) +: 64];
        end
        for (x = 0; x < 5; x = x + 1) begin : g_d
            assign d[x] = c[(x+4)%5] ^ {c[(x+1)%5][62:0], c[(x+1)%5][63]};
        end
        for (y = 0; y < 5; y = y + 1) begin : g_y
            for (x = 0; x < 5; x = x + 1) begin : g_x
                localparam integer R = RHO[6*(x+5*y) +: 6];
                assign t[x+5*y] = s_in[64*(x+5*y) +: 64] ^ d[x];                         // theta
                if (R == 0) begin : g_r0
                    assign b[y + 5*((2*x + 3*y) % 5)] = t[x+5*y];                         // rho, pi
                end else begin : g_r
                    assign b[y + 5*((2*x + 3*y) % 5)] = {t[x+5*y][63-R:0], t[x+5*y][63:64-R]};
                end
            end
        end
        for (y = 0; y < 5; y = y + 1) begin : g_chi_y
            for (x = 0; x < 5; x = x + 1) begin : g_chi_x
                assign o[x+5*y] = b[x+5*y] ^ (~b[(x+1)%5 + 5*y] & b[(x+2)%5 + 5*y]);       // chi
                if (x + 5*y == 0) begin : g_iota
                    assign s_out[63:0] = o[0] ^ rc;                                         // iota
                end else begin : g_pass
                    assign s_out[64*(x+5*y) +: 64] = o[x+5*y];
                end
            end
        end
    endgenerate
endmodule
