// NTT core for ML-KEM and ML-DSA with P parallel butterflies (P = 1, 2 or 4).
//
// Operations (op): 0 NTT(buf), 1 INTT(buf) incl. the 1/2^L scale, 2 PWM: C = A o B in the NTT domain,
// 3 MUL: C = A * B mod (x^256 + 1) = INTT(NTT(A) o NTT(B)); afterwards A and B hold NTT(A), NTT(B).
// scheme: 0 ML-KEM (q = 3329, 7 layers), 1 ML-DSA (q = 8380417, 8 layers). op, scheme and buf are
// captured in the cycle start is accepted (start && !busy) and stay fixed until done.
//
// The schedule (which butterfly does what in which cycle, bank mapping, timing) is the one modelled
// and proven conflict/hazard free in python/pqc_golden/schedule.py; tb/tb_ntt_core.v compares this
// RTL against it record by record. Summary:
//   - buffers A, B, C, each 2P banks of 128/P words; coefficient i is in bank xorfold_B(i), at
//     address i >> B, where B = log2(2P);
//   - a group is decoded one cycle before it is issued; issued in cycle t it reads RAM/ROM in t
//     (data in t+1), is routed to its lanes and registered (butterfly inputs valid in t+2) and is
//     written back in t + D, D = 2 + 6 = 8; the first group is issued in cycle 2;
//   - passes are issued back to back; done is high for one cycle at (last issue) + D + 1, and
//     cycles = that cycle's number, counting the start cycle as 0.
// Host port (only while !busy): h_we writes h_wdata to h_buf[h_idx]; h_re reads, data on h_rdata
// in the next cycle.
module ntt_core #(
    parameter P = 1,
    parameter DIL_SPECIAL = 0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [1:0]  op,
    input  wire        scheme,
    input  wire [1:0]  buf_sel,
    output reg         busy,
    output reg         done,
    output reg  [31:0] cycles,
    input  wire        h_we,
    input  wire        h_re,
    input  wire [1:0]  h_buf,
    input  wire [7:0]  h_idx,
    input  wire [22:0] h_wdata,
    output wire [22:0] h_rdata,
    // trace taps for tb_ntt_core (unconnected in synthesis tops, removed by the tools)
    output wire                dbg_issue,
    output wire [2*P-1:0]      dbg_kind,
    output wire [9*P-1:0]      dbg_u,
    output wire [8*P-1:0]      dbg_v,
    output wire [3*2*P-1:0]    dbg_we,
    output wire [3*2*P*8-1:0]  dbg_waddr,
    output wire [3*2*P*23-1:0] dbg_wdata
);
    localparam B   = (P == 1) ? 1 : (P == 2) ? 2 : 3;  // log2(2P)
    localparam NB  = 2 * P;                             // banks per buffer
    localparam AW  = 8 - B;                             // address bits per bank
    localparam D   = 8;                                 // issue -> write (RAM read 1, routing register 1, butterfly 6)
    localparam LB  = (P == 1) ? 1 : B - 1;              // lane index width (>= 1)

    localparam K_FWD = 4'd0, K_INV = 4'd1, K_SCALE = 4'd2, K_PWD = 4'd3;  // K1..K5 = 4..8
    localparam OP_CT = 2'd0, OP_GS = 2'd1, OP_MAC = 2'd2;
    localparam BA = 2'd0, BB = 2'd1, BC = 2'd2;
    localparam ZROM = 2'd0, ZBUF = 2'd1, ZNINV = 2'd2;

    // ------------------------------------------------------------------ helpers
    function automatic [B-1:0] bank_of(input [7:0] i);
        integer s;
        reg [B-1:0] r;
        begin
            r = 0;
            for (s = 0; s < 8; s = s + B) r = r ^ ((i >> s) & ((1 << B) - 1));
            bank_of = r;
        end
    endfunction
    function automatic [AW-1:0] addr_of(input [7:0] i);
        addr_of = i >> B;
    endfunction
    // u index of lane `lane`, group c, butterfly bit k (see ntt_lane_positions in schedule.py)
    function automatic [7:0] ntt_u(input [7:0] c, input integer lane, input [3:0] k);
        integer p, j, km;
        reg [7:0] r;
        begin
            km = k % B;
            j = 0;
            r = 0;
            for (p = 0; p < 8; p = p + 1) begin
                if (p == k) r[p] = 1'b0;
                else if (p < B && p != km) r[p] = (lane >> ((p > km) ? p - 1 : p)) & 1;
                else begin
                    r[p] = c[j];
                    j = j + 1;
                end
            end
            ntt_u = r;
        end
    endfunction
    // pass n of an operation: {valid, kind[3:0], buffer[1:0], level[3:0]}
    function automatic [10:0] pass_desc(input [1:0] o, input sch, input [1:0] bf, input [5:0] n);
        integer L, W;
        reg [3:0] lv, kd;
        begin
            L = sch ? 8 : 7;
            W = sch ? 1 : 5;
            pass_desc = 11'd0;
            case (o)
                2'd0: if (n < L) begin lv = n + 1; pass_desc = {1'b1, K_FWD, bf, lv}; end
                2'd1: if (n < L) begin lv = L - n; pass_desc = {1'b1, K_INV, bf, lv}; end
                      else if (n == L) pass_desc = {1'b1, K_SCALE, bf, 4'd0};
                2'd2: if (n < W) begin kd = sch ? K_PWD : 4 + n; pass_desc = {1'b1, kd, BC, 4'd0}; end
                2'd3: if (n < L) begin lv = n + 1; pass_desc = {1'b1, K_FWD, BA, lv}; end
                      else if (n < 2 * L) begin lv = n - L + 1; pass_desc = {1'b1, K_FWD, BB, lv}; end
                      else if (n < 2 * L + W) begin kd = sch ? K_PWD : 4 + n - 2 * L; pass_desc = {1'b1, kd, BC, 4'd0}; end
                      else if (n < 3 * L + W) begin lv = L - (n - 2 * L - W); pass_desc = {1'b1, K_INV, BC, lv}; end
                      else if (n == 3 * L + W) pass_desc = {1'b1, K_SCALE, BC, 4'd0};
            endcase
        end
    endfunction

    // ------------------------------------------------------------------ controller
    reg        active;
    reg [1:0]  r_op, r_buf;
    reg        r_sch;
    reg [5:0]  pass_no;
    reg [7:0]  c;
    reg [3:0]  tail;
    reg [31:0] cyc;

    wire [10:0] desc   = pass_desc(r_op, r_sch, r_buf, pass_no);
    wire [3:0]  kind   = desc[9:6];
    wire [1:0]  pbuf   = desc[5:4];
    wire [3:0]  level  = desc[3:0];
    wire [7:0]  c_last = (kind == K_SCALE || kind == K_PWD) ? (256 / P - 1) : (128 / P - 1);
    wire [10:0] desc_n = pass_desc(r_op, r_sch, r_buf, pass_no + 6'd1);

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            busy <= 1'b0;
            active <= 1'b0;
            tail <= 0;
        end else if (!busy) begin
            if (start) begin
                busy <= 1'b1;
                active <= 1'b1;
                r_op <= op;
                r_sch <= scheme;
                r_buf <= buf_sel;
                pass_no <= 0;
                c <= 0;
                cyc <= 1;
            end
        end else begin
            cyc <= cyc + 1;
            if (active) begin
                if (c == c_last) begin
                    c <= 0;
                    pass_no <= pass_no + 1;
                    if (!desc_n[10]) begin
                        active <= 1'b0;
                        tail <= D + 1;  // decode stage + D
                    end
                end else c <= c + 1;
            end else if (tail != 0) begin
                tail <= tail - 1;
                if (tail == 1) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    cycles <= cyc + 1;
                end
            end
        end
    end

    // ------------------------------------------------------------------ per-lane issue decode
    reg        l_uen[0:P-1];
    reg [1:0]  l_ubuf[0:P-1], l_vbuf[0:P-1], l_zsrc[0:P-1], l_op[0:P-1], l_wbuf[0:P-1];
    reg [7:0]  l_uidx[0:P-1], l_vidx[0:P-1], l_zidx[0:P-1], l_w0[0:P-1], l_w1[0:P-1];
    reg [8:0]  l_rom[0:P-1];
    reg        l_wtwo[0:P-1];

    integer ln;
    reg [7:0] u_i, v_i, ii, e_i, o_i;
    reg [6:0] pr;
    reg [7:0] blk, zi;
    reg [3:0] k;
    always @* begin
        k = 4'd8 - level;
        for (ln = 0; ln < P; ln = ln + 1) begin
            u_i = ntt_u(c, ln, k);
            v_i = u_i | (8'd1 << k);
            ii  = (c << (B - 1)) | ln;
            pr  = (c << (B - 1)) | ln;
            e_i = {pr, 1'b0};
            o_i = {pr, 1'b1};
            blk = u_i >> (k + 1);
            zi  = (kind == K_FWD) ? ((8'd1 << (level - 1)) + blk) : ((9'd1 << level) - 1 - blk);
            // defaults: NTT butterfly on pbuf
            l_uen[ln] = 1'b1; l_ubuf[ln] = pbuf; l_uidx[ln] = u_i;
            l_vbuf[ln] = pbuf; l_vidx[ln] = v_i;
            l_zsrc[ln] = ZROM; l_zidx[ln] = 8'd0; l_rom[ln] = r_sch ? {1'b1, zi} : {1'b0, zi};
            l_op[ln] = (kind == K_INV) ? OP_GS : OP_CT;
            l_wtwo[ln] = 1'b1; l_wbuf[ln] = pbuf; l_w0[ln] = u_i; l_w1[ln] = v_i;
            if (kind >= K_SCALE) begin
                l_op[ln] = OP_MAC; l_wtwo[ln] = 1'b0; l_uen[ln] = 1'b0; l_w1[ln] = 8'd0;
                l_zsrc[ln] = ZBUF; l_wbuf[ln] = BC;
            end
            case (kind)
                K_SCALE: begin
                    l_vbuf[ln] = pbuf; l_vidx[ln] = ii; l_zsrc[ln] = ZNINV; l_wbuf[ln] = pbuf; l_w0[ln] = ii;
                end
                K_PWD: begin
                    l_vbuf[ln] = BA; l_vidx[ln] = ii; l_zidx[ln] = ii; l_w0[ln] = ii;
                end
                4'd4: begin  // K1: C[e] = a1*b1
                    l_vbuf[ln] = BA; l_vidx[ln] = o_i; l_zidx[ln] = o_i; l_w0[ln] = e_i;
                end
                4'd5: begin  // K2: C[e] = C[e]*gamma
                    l_vbuf[ln] = BC; l_vidx[ln] = e_i; l_zsrc[ln] = ZROM; l_rom[ln] = {2'b01, pr}; l_w0[ln] = e_i;
                end
                4'd6: begin  // K3: C[e] = C[e] + a0*b0
                    l_uen[ln] = 1'b1; l_ubuf[ln] = BC; l_uidx[ln] = e_i;
                    l_vbuf[ln] = BA; l_vidx[ln] = e_i; l_zidx[ln] = e_i; l_w0[ln] = e_i;
                end
                4'd7: begin  // K4: C[o] = a1*b0
                    l_vbuf[ln] = BA; l_vidx[ln] = o_i; l_zidx[ln] = e_i; l_w0[ln] = o_i;
                end
                4'd8: begin  // K5: C[o] = C[o] + a0*b1
                    l_uen[ln] = 1'b1; l_ubuf[ln] = BC; l_uidx[ln] = o_i;
                    l_vbuf[ln] = BA; l_vidx[ln] = e_i; l_zidx[ln] = o_i; l_w0[ln] = o_i;
                end
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------------ issue stage (registered decode)
    // The decode above is registered; the registered group is "issued" in the next cycle: its read
    // addresses go to the RAMs and its ROM addresses to the ROMs. Bank selects are kept as one-hot
    // vectors so every RAM port is a flat AND-OR of the lane slots instead of a priority chain.
    localparam NBK = 3 * NB;  // banks in all three buffers
    reg             q_valid, q_sch;
    reg [5:0]       q_pass;  // pass of the issued group (trace taps)
    reg [1:0]       q_op[0:P-1];
    reg [NBK-1:0]   q_uoh[0:P-1], q_voh[0:P-1], q_zoh[0:P-1];  // one-hot bank of each read slot
    reg [AW-1:0]    q_ua[0:P-1], q_va[0:P-1], q_za[0:P-1];
    reg             q_uen[0:P-1];
    reg [1:0]       q_zsrc[0:P-1];
    reg [8:0]       q_rom[0:P-1];
    reg [7:0]       q_uidx[0:P-1], q_vidx[0:P-1];
    reg             q_wtwo[0:P-1];
    reg [1:0]       q_wbuf[0:P-1];
    reg [7:0]       q_w0[0:P-1], q_w1[0:P-1];
    localparam [NBK-1:0] ONE = 1;
    integer lq;
    always @(posedge clk) begin
        q_valid <= active && !rst;
        q_pass <= pass_no;
        q_sch <= r_sch;
        for (lq = 0; lq < P; lq = lq + 1) begin
            q_op[lq]   <= l_op[lq];
            q_uen[lq]  <= l_uen[lq];
            q_uoh[lq]  <= l_uen[lq] ? (ONE << (l_ubuf[lq] * NB + bank_of(l_uidx[lq]))) : {NBK{1'b0}};
            q_voh[lq]  <= ONE << (l_vbuf[lq] * NB + bank_of(l_vidx[lq]));
            q_zoh[lq]  <= (l_zsrc[lq] == ZBUF) ? (ONE << (BB * NB + bank_of(l_zidx[lq]))) : {NBK{1'b0}};
            q_ua[lq]   <= addr_of(l_uidx[lq]);
            q_va[lq]   <= addr_of(l_vidx[lq]);
            q_za[lq]   <= addr_of(l_zidx[lq]);
            q_zsrc[lq] <= l_zsrc[lq];
            q_rom[lq]  <= l_rom[lq];
            q_uidx[lq] <= l_uidx[lq];
            q_vidx[lq] <= l_vidx[lq];
            q_wtwo[lq] <= l_wtwo[lq];
            q_wbuf[lq] <= l_wbuf[lq];
            q_w0[lq]   <= l_w0[lq];
            q_w1[lq]   <= l_w1[lq];
        end
    end

    // ------------------------------------------------------------------ memories
    reg  [AW-1:0] raddr[0:NBK-1];
    reg           we[0:NBK-1];
    reg  [AW-1:0] waddr[0:NBK-1];
    reg  [22:0]   wdata[0:NBK-1];
    wire [22:0]   rdata[0:NBK-1];

    genvar gb;
    generate
        for (gb = 0; gb < NBK; gb = gb + 1) begin : g_bank
            ram_sdp #(.AW(AW)) u_ram (
                .clk(clk), .we(we[gb]), .waddr(waddr[gb]), .wdata(wdata[gb]), .raddr(raddr[gb]), .rdata(rdata[gb])
            );
            assign dbg_we[gb] = we[gb];
            assign dbg_waddr[gb*8 +: 8] = waddr[gb];
            assign dbg_wdata[gb*23 +: 23] = wdata[gb];
        end
    endgenerate

    // read addresses: each bank is read by at most one lane slot per cycle (proven by schedule.py),
    // so OR-ing the masked slot addresses selects the one that targets the bank
    wire [NBK-1:0] h_oh = ONE << (h_buf * NB + bank_of(h_idx));
    integer xr, lr;
    always @* begin
        for (xr = 0; xr < NBK; xr = xr + 1) begin
            raddr[xr] = 0;
            if (q_valid) begin
                for (lr = 0; lr < P; lr = lr + 1)
                    raddr[xr] = raddr[xr] | ({AW{q_uoh[lr][xr]}} & q_ua[lr]) | ({AW{q_voh[lr][xr]}} & q_va[lr])
                                          | ({AW{q_zoh[lr][xr]}} & q_za[lr]);
            end else if (!busy && h_re && h_oh[xr]) raddr[xr] = addr_of(h_idx);
        end
    end

    // host read data: select the bank one cycle later
    reg [5:0] h_rsel;
    always @(posedge clk) h_rsel <= h_buf * NB + bank_of(h_idx);
    assign h_rdata = rdata[h_rsel];

    // ------------------------------------------------------------------ ROMs (one per lane)
    wire [22:0] rom_q[0:P-1];
    genvar gl;
    generate
        for (gl = 0; gl < P; gl = gl + 1) begin : g_rom
            twiddle_rom u_rom (.clk(clk), .addr(q_rom[gl]), .data(rom_q[gl]));
        end
    endgenerate

    // ------------------------------------------------------------------ issue + 1: route RAM/ROM data to the lanes
    reg        s1_valid, s1_sch;
    reg        s1_uen[0:P-1];
    reg [5:0]  s1_usel[0:P-1], s1_vsel[0:P-1], s1_zsel[0:P-1];
    reg [1:0]  s1_zsrc[0:P-1], s1_op[0:P-1];
    function automatic [5:0] oh2i(input [NBK-1:0] oh);  // one-hot -> index
        integer j;
        begin
            oh2i = 0;
            for (j = 0; j < NBK; j = j + 1) oh2i = oh2i | (oh[j] ? j : 0);
        end
    endfunction
    integer ls;
    always @(posedge clk) begin
        s1_valid <= q_valid && !rst;
        s1_sch <= q_sch;
        for (ls = 0; ls < P; ls = ls + 1) begin
            s1_uen[ls]  <= q_uen[ls];
            s1_usel[ls] <= oh2i(q_uoh[ls]);
            s1_vsel[ls] <= oh2i(q_voh[ls]);
            s1_zsel[ls] <= oh2i(q_zoh[ls]);
            s1_zsrc[ls] <= q_zsrc[ls];
            s1_op[ls]   <= q_op[ls];
        end
    end

    wire [22:0] o0[0:P-1], o1[0:P-1];
    generate
        for (gl = 0; gl < P; gl = gl + 1) begin : g_bf
            wire [22:0] bu = s1_uen[gl] ? rdata[s1_usel[gl]] : 23'd0;
            wire [22:0] bv = rdata[s1_vsel[gl]];
            wire [22:0] bz = (s1_zsrc[gl] == ZROM) ? rom_q[gl] :
                             (s1_zsrc[gl] == ZBUF) ? rdata[s1_zsel[gl]] :
                             (s1_sch ? 23'd8347681 : 23'd3303);  // n^-1: 1/256 resp. 1/128 mod q
            // routing register: cuts the path BRAM -> bank multiplexer -> pre-add -> multiplier
            reg        r_valid, r_sch;
            reg [1:0]  r_op;
            reg [22:0] r_u, r_v, r_z;
            always @(posedge clk) begin
                r_valid <= s1_valid && !rst;
                r_sch <= s1_sch;
                r_op <= s1_op[gl];
                r_u <= bu; r_v <= bv; r_z <= bz;
            end
            wire bvalid;
            butterfly #(.DIL_SPECIAL(DIL_SPECIAL)) u_bf (
                .clk(clk), .rst(rst), .in_valid(r_valid), .mode(r_sch), .op(r_op),
                .u(r_u), .v(r_v), .z(r_z), .out_valid(bvalid), .o0(o0[gl]), .o1(o1[gl])
            );
        end
    endgenerate

    // ------------------------------------------------------------------ write-back control, delayed D cycles
    // stage d holds, in cycle t+1+d, what was issued in cycle t. Stage D-2 is turned into one-hot
    // bank selects and registered, so in the write cycle t + D (when the butterfly result appears)
    // the write ports are again a flat AND-OR.
    reg        wd_valid[0:D-2];
    reg        wd_two[0:D-2][0:P-1];
    reg [1:0]  wd_buf[0:D-2][0:P-1];
    reg [7:0]  wd_i0[0:D-2][0:P-1], wd_i1[0:D-2][0:P-1];
    reg            ww_valid;
    reg [NBK-1:0]  ww_oh0[0:P-1], ww_oh1[0:P-1];
    reg [AW-1:0]   ww_a0[0:P-1], ww_a1[0:P-1];
    integer d, lw, lx, xw;
    always @(posedge clk) begin
        wd_valid[0] <= q_valid && !rst;
        for (lw = 0; lw < P; lw = lw + 1) begin
            wd_two[0][lw] <= q_wtwo[lw];
            wd_buf[0][lw] <= q_wbuf[lw];
            wd_i0[0][lw]  <= q_w0[lw];
            wd_i1[0][lw]  <= q_w1[lw];
        end
        for (d = 1; d < D - 1; d = d + 1) begin
            wd_valid[d] <= rst ? 1'b0 : wd_valid[d-1];
            for (lw = 0; lw < P; lw = lw + 1) begin
                wd_two[d][lw] <= wd_two[d-1][lw];
                wd_buf[d][lw] <= wd_buf[d-1][lw];
                wd_i0[d][lw]  <= wd_i0[d-1][lw];
                wd_i1[d][lw]  <= wd_i1[d-1][lw];
            end
        end
        ww_valid <= rst ? 1'b0 : wd_valid[D-2];
        for (lw = 0; lw < P; lw = lw + 1) begin
            ww_oh0[lw] <= ONE << (wd_buf[D-2][lw] * NB + bank_of(wd_i0[D-2][lw]));
            ww_oh1[lw] <= wd_two[D-2][lw] ? (ONE << (wd_buf[D-2][lw] * NB + bank_of(wd_i1[D-2][lw]))) : {NBK{1'b0}};
            ww_a0[lw]  <= addr_of(wd_i0[D-2][lw]);
            ww_a1[lw]  <= addr_of(wd_i1[D-2][lw]);
        end
    end

    always @* begin
        for (xw = 0; xw < NBK; xw = xw + 1) begin
            we[xw] = 1'b0;
            waddr[xw] = 0;
            wdata[xw] = 0;
            if (ww_valid) begin
                for (lx = 0; lx < P; lx = lx + 1) begin
                    we[xw]    = we[xw] | ww_oh0[lx][xw] | ww_oh1[lx][xw];
                    waddr[xw] = waddr[xw] | ({AW{ww_oh0[lx][xw]}} & ww_a0[lx]) | ({AW{ww_oh1[lx][xw]}} & ww_a1[lx]);
                    wdata[xw] = wdata[xw] | ({23{ww_oh0[lx][xw]}} & o0[lx]) | ({23{ww_oh1[lx][xw]}} & o1[lx]);
                end
            end else if (!busy && h_we && h_oh[xw]) begin
                we[xw] = 1'b1;
                waddr[xw] = addr_of(h_idx);
                wdata[xw] = h_wdata;
            end
        end
    end

    // ------------------------------------------------------------------ trace taps (issue stage)
    assign dbg_issue = q_valid;
    generate
        for (gl = 0; gl < P; gl = gl + 1) begin : g_dbg
            assign dbg_kind[gl*2 +: 2] = q_op[gl];
            assign dbg_u[gl*9 +: 9]    = q_uen[gl] ? {1'b0, q_uidx[gl]} : 9'h1FF;
            assign dbg_v[gl*8 +: 8]    = q_vidx[gl];
        end
    endgenerate
endmodule

// Simple dual-port RAM: one synchronous write and one synchronous read per cycle (read data in the
// next cycle). A read and a write of the same address in one cycle never happen (schedule.py checks it).
module ram_sdp #(
    parameter AW = 7
) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [22:0]   wdata,
    input  wire [AW-1:0] raddr,
    output reg  [22:0]   rdata
);
    reg [22:0] mem[0:(1<<AW)-1];
    integer i;
    initial for (i = 0; i < (1 << AW); i = i + 1) mem[i] = 0;
    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule
