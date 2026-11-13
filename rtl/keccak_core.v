// Byte-streaming SHA-3 / SHAKE (FIPS 202): SHA3-256, SHA3-512, SHAKE128, SHAKE256.
//
//   init  (pulse)          start a new hash in mode: 0 SHA3-256, 1 SHA3-512, 2 SHAKE128, 3 SHAKE256
//   in_valid/in_byte       absorb one message byte; accepted when in_ready
//   finish (pulse)         the message is complete (also for the empty message); accepted when in_ready
//   out_req                take one output byte: out_byte is valid while out_valid; out_req && out_valid
//                          consumes it. SHAKE can be squeezed for any length; SHA3 output beyond
//                          the digest length is not prevented here (the command layer stops at 32/64).
// One permutation round per clock cycle: 24 cycles per Keccak-f[1600], during which in_ready and
// out_valid are low.
module keccak_core (
    input  wire       clk,
    input  wire       rst,
    input  wire       init,
    input  wire [1:0] mode,
    input  wire       in_valid,
    input  wire [7:0] in_byte,
    input  wire       finish,
    output wire       in_ready,
    input  wire       out_req,
    output wire       out_valid,
    output wire [7:0] out_byte
);
    localparam S_ABSORB = 2'd0, S_PERM = 2'd1, S_SQUEEZE = 2'd2;
    reg [1599:0] st;
    reg [1:0]    state, r_mode;
    reg [7:0]    pos;
    reg [4:0]    rnd;
    reg          squeezing;  // the permutation was started by finish or by squeezing

    wire [7:0] rate = (r_mode == 2'd0) ? 8'd136 : (r_mode == 2'd1) ? 8'd72 : (r_mode == 2'd2) ? 8'd168 : 8'd136;
    wire [7:0] dsuf = r_mode[1] ? 8'h1F : 8'h06;  // SHAKE: 1111 + pad start; SHA3: 01 + pad start

    wire [1599:0] st_next;
    keccak_f1600 u_round (.s_in(st), .round(rnd), .s_out(st_next));

    assign in_ready  = (state == S_ABSORB);
    assign out_valid = (state == S_SQUEEZE);
    assign out_byte  = st[8*pos +: 8];

    always @(posedge clk) begin
        if (rst || init) begin
            st <= 1600'd0;
            state <= S_ABSORB;
            pos <= 0;
            rnd <= 0;
            squeezing <= 1'b0;
            r_mode <= mode;
        end else begin
            case (state)
                S_ABSORB:
                    if (finish) begin
                        // pad10*1 with the domain bits: suffix at pos, 0x80 into the last rate byte
                        st[8*pos +: 8] <= st[8*pos +: 8] ^ dsuf ^ ((pos == rate - 1) ? 8'h80 : 8'h00);
                        if (pos != rate - 1) st[8*(rate-1) +: 8] <= st[8*(rate-1) +: 8] ^ 8'h80;
                        state <= S_PERM;
                        rnd <= 0;
                        squeezing <= 1'b1;
                    end else if (in_valid) begin
                        st[8*pos +: 8] <= st[8*pos +: 8] ^ in_byte;
                        if (pos == rate - 1) begin
                            pos <= 0;
                            state <= S_PERM;
                            rnd <= 0;
                        end else pos <= pos + 1;
                    end
                S_PERM: begin
                    st <= st_next;
                    rnd <= rnd + 1;
                    if (rnd == 5'd23) begin
                        pos <= 0;
                        state <= squeezing ? S_SQUEEZE : S_ABSORB;
                    end
                end
                S_SQUEEZE:
                    if (out_req) begin
                        if (pos == rate - 1) begin
                            state <= S_PERM;
                            rnd <= 0;
                        end else pos <= pos + 1;
                    end
                default: state <= S_ABSORB;
            endcase
        end
    end
endmodule
