// Command controller: the UART protocol of docs/architecture.md, Section "Host protocol".
//
// Request : A5 | CMD | LEN (2 bytes, little-endian) | PAYLOAD (LEN bytes) | CHK
// Response: 5A | STATUS | LEN (2 bytes, LE) | PAYLOAD | CHK
// CHK = XOR of every byte after the sync byte. One command at a time; the response is sent after
// the whole request (including CHK) has arrived and the command has finished.
//
// Commands: 01 PING (LEN 0)  10 LOAD (LEN 770: scheme, buffer, 256 x 3-byte LE coefficients)
//           11 READ (LEN 1: buffer)  20 RUN (LEN 3: scheme, op, buffer)
//           30 HASH (LEN 3 + n: mode, outlen LE16, n message bytes)
// Status : 00 OK, 01 ERR_RANGE, 02 ERR_CMD, 03 ERR_LEN, 04 ERR_CHK, 05 ERR_TIMEOUT, 06 ERR_ARG, 07 ERR_STATE
//
// Every request is consumed completely (LEN payload bytes + CHK) before an error is answered, so
// the next request starts cleanly. An inter-byte gap longer than TIMEOUT cycles inside a request
// aborts it with ERR_TIMEOUT. LOAD is atomic: coefficients go to a staging buffer, and only a
// fully valid request (lengths, scheme, buffer, every coefficient < q, checksum) is copied into
// the core; otherwise the core's A/B/C buffers are untouched.
module cmd_ctrl #(
    parameter P = 1,
    parameter DIL_SPECIAL = 0,
    parameter TIMEOUT = 1_000_000  // 10 ms at 100 MHz (a byte takes 87 us at 115200 baud)
) (
    input  wire        clk,
    input  wire        rst,
    // UART
    input  wire        rx_valid,
    input  wire [7:0]  rx_byte,
    output reg         tx_valid,
    output reg  [7:0]  tx_byte,
    input  wire        tx_ready,
    // NTT core
    output reg         c_start,
    output reg  [1:0]  c_op,
    output reg         c_scheme,
    output reg  [1:0]  c_buf,
    input  wire        c_busy,
    input  wire        c_done,
    input  wire [31:0] c_cycles,
    output reg         h_we,
    output reg         h_re,
    output reg  [1:0]  h_buf,
    output reg  [7:0]  h_idx,
    output reg  [22:0] h_wdata,
    input  wire [22:0] h_rdata,
    // Keccak
    output reg         k_init,
    output reg  [1:0]  k_mode,
    output reg         k_in_valid,
    output reg  [7:0]  k_in_byte,
    output reg         k_finish,
    input  wire        k_in_ready,
    output reg         k_out_req,
    input  wire        k_out_valid,
    input  wire [7:0]  k_out_byte,
    // status
    output reg  [7:0]  last_status
);
    localparam C_PING = 8'h01, C_LOAD = 8'h10, C_READ = 8'h11, C_RUN = 8'h20, C_HASH = 8'h30;
    localparam OK = 8'h00, E_RANGE = 8'h01, E_CMD = 8'h02, E_LEN = 8'h03, E_CHK = 8'h04,
               E_TIMEOUT = 8'h05, E_ARG = 8'h06, E_STATE = 8'h07;

    localparam S_HUNT = 4'd0, S_HDR = 4'd1, S_PAY = 4'd2, S_CHK = 4'd3, S_EXEC = 4'd4,
               S_COMMIT = 4'd5, S_RUN = 4'd6, S_FIN = 4'd7, S_RH = 4'd8, S_RP = 4'd9, S_RC = 4'd10;

    reg [3:0]  st;
    reg [1:0]  hdr_n;
    reg [7:0]  cmd, status, chk;
    reg [15:0] len, k;            // payload length, payload byte counter
    reg [31:0] idle;              // cycles since the last byte inside a request
    // arguments
    reg        a_scheme;
    reg [1:0]  a_buf, a_op, a_mode;
    reg [15:0] a_outlen;
    reg [15:0] coef_lo;           // first two bytes of the coefficient being received
    reg [1:0]  cb;                // byte within the coefficient
    reg [7:0]  ci;                // coefficient index
    // operand tags: {loaded, scheme} per buffer A, B, C
    reg        tag_v[0:2], tag_s[0:2];
    // staging buffer for LOAD
    reg [22:0] stage[0:255];
    reg [22:0] stage_q;
    reg [7:0]  stage_ra;
    always @(posedge clk) stage_q <= stage[stage_ra];

    // pending keccak byte (absorbed as soon as the core is ready; UART bytes are far apart)
    reg        kp;
    reg [7:0]  kb;

    // response sequencing
    reg [1:0]  rh_n;              // header byte number
    reg [15:0] rlen, rk;          // response payload length, byte counter
    reg [7:0]  rchk;
    reg [31:0] r_cycles;
    reg [1:0]  rd_b;              // byte within a coefficient being read
    reg [23:0] rd_w;
    reg        tx_pl;             // the byte on tx_valid is a payload byte (counted into rk)
    reg        rd_wait;           // LOAD commit: staging read in flight
    reg [1:0]  rd_ph;             // READ: 0 request, 1 core RAM read, 2 data on h_rdata

    wire [23:0] coef = {rx_byte, coef_lo};
    wire [23:0] qmax = a_scheme ? 24'd8380417 : 24'd3329;

    function automatic [15:0] expect_len(input [7:0] c);
        case (c)
            C_PING: expect_len = 16'd0;
            C_LOAD: expect_len = 16'd770;
            C_READ: expect_len = 16'd1;
            C_RUN:  expect_len = 16'd3;
            default: expect_len = 16'd0;
        endcase
    endfunction

    task set_err(input [7:0] e);
        if (status == OK) status <= e;  // the first error found wins
    endtask

    integer t;
    always @(posedge clk) begin
        tx_valid <= 1'b0;
        c_start <= 1'b0;
        h_we <= 1'b0;
        h_re <= 1'b0;
        k_init <= 1'b0;
        k_finish <= 1'b0;
        k_out_req <= 1'b0;
        if (k_in_valid && k_in_ready) k_in_valid <= 1'b0;
        if (kp && !k_in_valid) begin
            k_in_valid <= 1'b1;
            k_in_byte <= kb;
            kp <= 1'b0;
        end
        if (rst) begin
            st <= S_HUNT;
            last_status <= 8'h00;
            k_in_valid <= 1'b0;
            kp <= 1'b0;
            for (t = 0; t < 3; t = t + 1) tag_v[t] <= 1'b0;
        end else begin
            // inter-byte timeout inside a request
            if (st == S_HDR || st == S_PAY || st == S_CHK) begin
                if (rx_valid) idle <= 0;
                else if (idle >= TIMEOUT - 1) begin
                    status <= E_TIMEOUT;
                    st <= S_RH;
                    rh_n <= 0;
                    rlen <= 0;
                end else idle <= idle + 1;
            end
            case (st)
                S_HUNT:
                    if (rx_valid && rx_byte == 8'hA5) begin
                        st <= S_HDR;
                        hdr_n <= 0;
                        idle <= 0;
                        chk <= 0;
                        status <= OK;
                    end
                S_HDR:
                    if (rx_valid) begin
                        chk <= chk ^ rx_byte;
                        hdr_n <= hdr_n + 1;
                        case (hdr_n)
                            2'd0: cmd <= rx_byte;
                            2'd1: len[7:0] <= rx_byte;
                            default: begin
                                len[15:8] <= rx_byte;
                                k <= 0; cb <= 0; ci <= 0;
                                if (cmd != C_PING && cmd != C_LOAD && cmd != C_READ && cmd != C_RUN && cmd != C_HASH)
                                    status <= E_CMD;
                                else if (cmd == C_HASH ? ({rx_byte, len[7:0]} < 16'd3)
                                                       : ({rx_byte, len[7:0]} != expect_len(cmd)))
                                    status <= E_LEN;
                                st <= ({rx_byte, len[7:0]} == 16'd0) ? S_CHK : S_PAY;
                            end
                        endcase
                    end
                S_PAY:
                    if (rx_valid) begin
                        chk <= chk ^ rx_byte;
                        k <= k + 1;
                        if (k == len - 1) st <= S_CHK;
                        if (status == OK) begin
                            case (cmd)
                                C_LOAD:
                                    if (k == 0) begin
                                        a_scheme <= rx_byte[0];
                                        if (rx_byte > 1) set_err(E_ARG);
                                    end else if (k == 1) begin
                                        a_buf <= rx_byte[1:0];
                                        if (rx_byte > 2) set_err(E_ARG);
                                    end else begin
                                        if (cb == 2'd0) coef_lo[7:0] <= rx_byte;
                                        if (cb == 2'd1) coef_lo[15:8] <= rx_byte;
                                        if (cb == 2'd2) begin
                                            if (coef >= qmax) set_err(E_RANGE);
                                            stage[ci] <= coef[22:0];
                                            ci <= ci + 1;
                                            cb <= 0;
                                        end else cb <= cb + 1;
                                    end
                                C_READ:
                                    if (k == 0) begin
                                        a_buf <= rx_byte[1:0];
                                        if (rx_byte > 2) set_err(E_ARG);
                                    end
                                C_RUN:
                                    if (k == 0) begin
                                        a_scheme <= rx_byte[0];
                                        if (rx_byte > 1) set_err(E_ARG);
                                    end else if (k == 1) begin
                                        a_op <= rx_byte[1:0];
                                        if (rx_byte > 3) set_err(E_ARG);
                                    end else begin
                                        a_buf <= rx_byte[1:0];
                                        if (rx_byte > 2) set_err(E_ARG);
                                    end
                                C_HASH:
                                    if (k == 0) begin
                                        a_mode <= rx_byte[1:0];
                                        if (rx_byte > 3) set_err(E_ARG);
                                        k_init <= 1'b1;
                                        k_mode <= rx_byte[1:0];
                                    end else if (k == 1) a_outlen[7:0] <= rx_byte;
                                    else if (k == 2) begin
                                        a_outlen[15:8] <= rx_byte;
                                        // SHA3-256 gives 32 bytes, SHA3-512 64, SHAKE 1..65535
                                        if (a_mode == 2'd0 ? ({rx_byte, a_outlen[7:0]} != 16'd32) :
                                            a_mode == 2'd1 ? ({rx_byte, a_outlen[7:0]} != 16'd64) :
                                                             ({rx_byte, a_outlen[7:0]} == 16'd0))
                                            set_err(E_ARG);
                                    end else begin
                                        kp <= 1'b1;
                                        kb <= rx_byte;
                                    end
                                default: ;
                            endcase
                        end
                    end
                S_CHK:
                    if (rx_valid) begin
                        if ((chk ^ rx_byte) != 8'h00) set_err(E_CHK);
                        st <= S_EXEC;
                    end
                S_EXEC: begin
                    // the request is complete; act only if it is entirely valid
                    st <= S_RH;
                    rh_n <= 0;
                    rlen <= 0;
                    if (status == OK) begin
                        case (cmd)
                            C_PING: rlen <= 16'd4;
                            C_LOAD: begin
                                st <= S_COMMIT;
                                ci <= 0;
                                stage_ra <= 0;
                                rd_wait <= 1'b1;
                            end
                            C_READ: begin
                                rlen <= 16'd768;
                            end
                            C_RUN: begin
                                if (a_op[1] ? !(tag_v[0] && tag_v[1] && tag_s[0] == a_scheme && tag_s[1] == a_scheme)
                                            : !(tag_v[a_buf] && tag_s[a_buf] == a_scheme))
                                    status <= E_STATE;
                                else begin
                                    st <= S_RUN;
                                    c_start <= 1'b1;
                                    c_op <= a_op;
                                    c_scheme <= a_scheme;
                                    c_buf <= a_buf;
                                end
                            end
                            C_HASH: st <= S_FIN;
                            default: ;
                        endcase
                    end
                end
                S_COMMIT: begin
                    // staging -> core buffer, one coefficient per cycle (staging read latency 1)
                    stage_ra <= stage_ra + 1;
                    rd_wait <= 1'b0;
                    if (!rd_wait) begin
                        h_we <= 1'b1;
                        h_buf <= a_buf;
                        h_idx <= ci;
                        h_wdata <= stage_q;
                        ci <= ci + 1;
                        if (ci == 8'd255) begin
                            tag_v[a_buf] <= 1'b1;
                            tag_s[a_buf] <= a_scheme;
                            st <= S_RH;
                            rh_n <= 0;
                            rlen <= 0;
                        end
                    end
                end
                S_RUN:
                    if (c_done) begin
                        r_cycles <= c_cycles;
                        if (a_op[1]) begin  // PWM / MUL write C (MUL also leaves NTT(A), NTT(B))
                            tag_v[2] <= 1'b1;
                            tag_s[2] <= a_scheme;
                        end
                        rlen <= 16'd4;
                        st <= S_RH;
                        rh_n <= 0;
                    end
                S_FIN:
                    if (k_in_ready && !kp && !k_in_valid) begin
                        k_finish <= 1'b1;
                        rlen <= a_outlen;
                        st <= S_RH;
                        rh_n <= 0;
                    end
                S_RH:  // response header: 5A, status, len lo, len hi
                    if (tx_ready && !tx_valid) begin
                        tx_valid <= 1'b1;
                        tx_pl <= 1'b0;
                        case (rh_n)
                            2'd0: begin tx_byte <= 8'h5A; rchk <= 0; end
                            2'd1: begin tx_byte <= status; rchk <= status; last_status <= status; end
                            2'd2: begin tx_byte <= rlen[7:0]; rchk <= rchk ^ rlen[7:0]; end
                            default: begin
                                tx_byte <= rlen[15:8];
                                rchk <= rchk ^ rlen[15:8];
                                rk <= 0;
                                rd_b <= 0;
                                rd_ph <= 0;
                                ci <= 0;
                                st <= (rlen == 0) ? S_RC : S_RP;
                            end
                        endcase
                        rh_n <= rh_n + 1;
                    end
                S_RP:  // response payload
                    if (tx_ready && !tx_valid) begin
                        tx_pl <= 1'b1;
                        case (cmd)
                            C_PING: begin
                                tx_valid <= 1'b1;
                                tx_byte <= (rk == 0) ? 8'h50 : (rk == 1) ? 8'h51 : (rk == 2) ? P[7:0] : DIL_SPECIAL[7:0];
                            end
                            C_RUN: begin
                                tx_valid <= 1'b1;
                                tx_byte <= r_cycles[8*rk[1:0] +: 8];
                            end
                            C_READ:
                                // h_re registered in cycle n reaches the core in n+1 (RAM read) and the
                                // data is on h_rdata in n+2
                                if (rd_b == 0 && rd_ph == 2'd0) begin
                                    h_re <= 1'b1;
                                    h_buf <= a_buf;
                                    h_idx <= ci;
                                    rd_ph <= 2'd1;
                                end else if (rd_b == 0 && rd_ph == 2'd1) begin
                                    rd_ph <= 2'd2;
                                end else begin
                                    if (rd_b == 0) rd_w = {1'b0, h_rdata};
                                    tx_valid <= 1'b1;
                                    tx_byte <= rd_w[8*rd_b +: 8];
                                    if (rd_b == 2'd2) begin
                                        rd_b <= 0;
                                        rd_ph <= 2'd0;
                                        ci <= ci + 1;
                                    end else rd_b <= rd_b + 1;
                                end
                            C_HASH:
                                if (k_out_valid && !k_out_req) begin
                                    tx_valid <= 1'b1;
                                    tx_byte <= k_out_byte;
                                    k_out_req <= 1'b1;
                                end
                            default: ;
                        endcase
                    end
                S_RC:
                    if (tx_ready && !tx_valid) begin
                        tx_valid <= 1'b1;
                        tx_pl <= 1'b0;
                        tx_byte <= rchk;
                        st <= S_HUNT;
                    end
                default: st <= S_HUNT;
            endcase
            // count payload bytes as they are handed to the transmitter
            if (tx_valid && tx_pl) begin
                rchk <= rchk ^ tx_byte;
                rk <= rk + 1;
                if (rk == rlen - 1) st <= S_RC;
            end
        end
    end
endmodule
