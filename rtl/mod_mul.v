// y = (a * b) mod q, for a, b in [0, q). Pipelined, latency 4, one new input every cycle.
// mode travels with the data, so it can change from one cycle to the next.
//
// Barrett reduction, bit for bit the same as python/pqc_golden/reduce.py:
//   stage 1  x    = a * b
//   stage 2  t    = (x >> (k - 1)) * mu
//   stage 3  qq   = (t >> (k + 1)) * q        only the low 25 bits are kept
//   stage 4  r    = x - qq, then subtract q up to twice
// r is always below 3q < 2^25, so 25 bits are enough for both moduli.
module mod_mul (
    input  wire        clk,
    input  wire        in_valid,
    input  wire        mode,
    input  wire [23:0] a,
    input  wire [23:0] b,
    output reg         out_valid,
    output reg  [23:0] y
);
`include "pqc_params.vh"

    // stage 1: product
    reg  [47:0] x1;
    reg         v1, m1;
    always @(posedge clk) begin
        x1 <= a * b;
        v1 <= in_valid;
        m1 <= mode;
    end

    // stage 2: x >> (k - 1) times mu
    wire [23:0] xs = m1 ? x1[45:22] : {11'b0, x1[23:11]};
    wire [23:0] mu = m1 ? MU_DSA : MU_KEM;
    reg  [47:0] t2;
    reg  [24:0] x2;
    reg         v2, m2;
    always @(posedge clk) begin
        t2 <= xs * mu;
        x2 <= x1[24:0];
        v2 <= v1;
        m2 <= m1;
    end

    // stage 3: qhat = t >> (k + 1), times q
    wire [23:0] qhat = m2 ? t2[47:24] : {11'b0, t2[25:13]};
    wire [23:0] q2   = m2 ? Q_DSA : Q_KEM;
    reg  [24:0] qq3;
    reg  [24:0] x3;
    reg         v3, m3;
    always @(posedge clk) begin
        qq3 <= qhat * q2;  // truncated to 25 bits
        x3  <= x2;
        v3  <= v2;
        m3  <= m2;
    end

    // stage 4: remainder and two conditional subtractions
    wire [23:0] q3 = m3 ? Q_DSA : Q_KEM;
    wire [24:0] r  = x3 - qq3;
    wire [25:0] r1 = {1'b0, r} - {2'b0, q3};
    wire [24:0] s1 = r1[25] ? r : r1[24:0];
    wire [25:0] r2 = {1'b0, s1} - {2'b0, q3};
    wire [24:0] s2 = r2[25] ? s1 : r2[24:0];
    always @(posedge clk) begin
        y         <= s2[23:0];
        out_valid <= v3;
    end

endmodule
