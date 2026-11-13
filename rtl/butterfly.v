// One butterfly unit, forward (Cooley-Tukey) and inverse (Gentleman-Sande):
//   op = 0 (CT, forward NTT):  o0 = u + z*v,  o1 = u - z*v
//   op = 1 (GS, inverse NTT):  o0 = u + v,    o1 = z*(v - u)
//   op = 2 (MAC):              o0 = u + z*v   (o1 unused; pointwise multiply and scaling)
// All values mod q (mode 0 = ML-KEM, 1 = ML-DSA), inputs and outputs canonical in [0, q).
//
// Latency BF_LAT = 6 (pre-add stage, 4-stage multiplier, post-add stage), initiation interval 1,
// no backpressure. Bit-exact model: butterfly() in python/pqc_golden/modmul.py.
module butterfly #(
    parameter DIL_SPECIAL = 0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        in_valid,
    input  wire        mode,
    input  wire [1:0]  op,
    input  wire [22:0] u,
    input  wire [22:0] v,
    input  wire [22:0] z,
    output reg         out_valid,
    output reg  [22:0] o0,
    output reg  [22:0] o1
);
    localparam MUL_LAT = 4;

    function automatic [22:0] qof(input m);
        qof = m ? 23'd8380417 : 23'd3329;
    endfunction
    function automatic [22:0] add_q(input [22:0] x, input [22:0] y, input m);
        reg [23:0] t;
        begin
            t = x + y;
            add_q = (t >= {1'b0, qof(m)}) ? (t - qof(m)) : t[22:0];
        end
    endfunction
    function automatic [22:0] sub_q(input [22:0] x, input [22:0] y, input m);
        reg [23:0] t;
        begin
            t = {1'b0, x} - {1'b0, y};  // negative shows as bit 23 set
            sub_q = t[23] ? (t[22:0] + qof(m)) : t[22:0];
        end
    endfunction

    // ---- pre-add stage ----
    reg        pv, pm;
    reg [1:0]  pop;
    reg [22:0] pu, ps, pz, pmb;
    always @(posedge clk) begin
        pv  <= rst ? 1'b0 : in_valid;
        pm  <= mode;
        pop <= op;
        pu  <= u;
        ps  <= add_q(u, v, mode);
        pz  <= z;
        pmb <= (op == 2'd1) ? sub_q(v, u, mode) : v;
    end

    // ---- multiplier ----
    wire        mv;
    wire [22:0] t;
    mod_mul #(.DIL_SPECIAL(DIL_SPECIAL)) u_mul (
        .clk(clk), .rst(rst), .in_valid(pv), .mode(pm), .a(pz), .b(pmb), .out_valid(mv), .p(t)
    );

    // u, u+v, op and mode travel alongside the product
    reg [22:0] du[0:MUL_LAT-1], ds[0:MUL_LAT-1];
    reg [1:0]  dop[0:MUL_LAT-1];
    reg        dm[0:MUL_LAT-1];
    integer i;
    always @(posedge clk) begin
        du[0] <= pu; ds[0] <= ps; dop[0] <= pop; dm[0] <= pm;
        for (i = 1; i < MUL_LAT; i = i + 1) begin
            du[i] <= du[i-1]; ds[i] <= ds[i-1]; dop[i] <= dop[i-1]; dm[i] <= dm[i-1];
        end
    end
    wire [22:0] uu = du[MUL_LAT-1], ss = ds[MUL_LAT-1];
    wire [1:0]  oo = dop[MUL_LAT-1];
    wire        mm = dm[MUL_LAT-1];

    // ---- post-add stage ----
    always @(posedge clk) begin
        out_valid <= rst ? 1'b0 : mv;
        if (oo == 2'd1) begin
            o0 <= ss;
            o1 <= t;
        end else begin
            o0 <= add_q(uu, t, mm);
            o1 <= sub_q(uu, t, mm);
        end
    end
endmodule
