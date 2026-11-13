// Modular multiplier: p = a*b mod q, canonical (0 <= p < q) for 0 <= a, b < q.
// mode = 0: ML-KEM (q = 3329), mode = 1: ML-DSA (q = 8380417).
//
// Fixed latency MUL_LAT = 4, initiation interval 1, no backpressure: a valid input in cycle t
// gives out_valid with the product in cycle t + 4. Widths and bounds: docs/arithmetic.md,
// bit-exact model: python/pqc_golden/modmul.py.
//
// DIL_SPECIAL = 0: Barrett reduction for both schemes (one shared, ML-DSA-width datapath).
// DIL_SPECIAL = 1: ML-DSA uses the exact special-form reduction (2^23 = 2^13 - 1 mod q);
//                  ML-KEM keeps Barrett, on a narrow ML-KEM-only datapath.
module mod_mul #(
    parameter DIL_SPECIAL = 0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        in_valid,
    input  wire        mode,
    input  wire [22:0] a,
    input  wire [22:0] b,
    output reg         out_valid,
    output reg  [22:0] p
);
    localparam [22:0] QK = 23'd3329;
    localparam [22:0] QD = 23'd8380417;

    // ---- stage 1: the 23 x 23 product (c < q^2 < 2^46) ----
    reg        v1, m1;
    reg [45:0] c1;
    always @(posedge clk) begin
        v1 <= rst ? 1'b0 : in_valid;
        m1 <= mode;
        c1 <= a * b;
    end

    reg        v2, m2, v3, m3;

    generate
        if (DIL_SPECIAL == 0) begin : g_barrett
            // ---- stage 2: q1 = c >> (k-1); q2 = q1 * mu ----
            wire [23:0] q1 = m1 ? c1[45:22] : {11'd0, c1[23:11]};
            wire [23:0] mu = m1 ? 24'd8396807 : 24'd5039;
            reg  [47:0] q2;
            reg  [24:0] c2;  // c mod 2^25 is all the subtraction needs (r < 3q < 2^25)
            always @(posedge clk) begin
                v2 <= rst ? 1'b0 : v1;
                m2 <= m1;
                q2 <= q1 * mu;
                c2 <= c1[24:0];
            end
            // ---- stage 3: q3 = q2 >> (k+1); r = c - q3*q in [0, 3q) ----
            wire [23:0] q3   = m2 ? q2[47:24] : {11'd0, q2[25:13]};
            // q3*q by shifts and adds, low 25 bits: 8380417 = 2^23 - 2^13 + 1, 3329 = 2^11 + 2^10 + 2^8 + 1
            wire [24:0] q3qd = ({q3, 23'd0} - {q3, 13'd0} + q3);
            wire [24:0] q3qk = ({q3, 11'd0} + {q3, 10'd0} + {q3, 8'd0} + q3);
            reg  [24:0] r3;
            always @(posedge clk) begin
                v3 <= rst ? 1'b0 : v2;
                m3 <= m2;
                r3 <= c2 - (m2 ? q3qd : q3qk);
            end
            // ---- stage 4: at most two subtractions of q ----
            wire [24:0] q1x = m3 ? {2'd0, QD} : {2'd0, QK};
            wire [24:0] q2x = {q1x[23:0], 1'b0};
            always @(posedge clk) begin
                out_valid <= rst ? 1'b0 : v3;
                p <= (r3 >= q2x) ? (r3 - q2x) : (r3 >= q1x) ? (r3 - q1x) : r3;
            end
        end else begin : g_special
            // ML-KEM Barrett, narrow: c < 2^24, q1 13 bits, mu = 5039 (13 bits), r < 3q < 2^14.
            // ML-DSA special form: three folds of hi*2^23 -> hi*(2^13 - 1), then one subtraction.
            reg  [25:0] kq2;
            reg  [23:0] kc2;
            reg  [36:0] r1;  // after fold 1: < 2^23 + 2^36
            wire [22:0] h1 = c1[45:23];
            always @(posedge clk) begin
                v2  <= rst ? 1'b0 : v1;
                m2  <= m1;
                kq2 <= c1[23:11] * 13'd5039;
                kc2 <= c1[23:0];
                r1  <= {14'd0, c1[22:0]} + {1'b0, h1, 13'd0} - {14'd0, h1};
            end
            wire [12:0] kq3  = kq2[25:13];
            wire [13:0] kq3q = ({kq3, 11'd0} + {kq3, 10'd0} + {kq3, 8'd0} + kq3);  // low 14 bits
            wire [13:0] h2   = r1[36:23];
            wire [27:0] r2   = {5'd0, r1[22:0]} + {1'b0, h2, 13'd0} - {14'd0, h2};  // < 2^23 + 2^27
            wire [4:0]  h3   = r2[27:23];
            wire [23:0] r3w  = {1'b0, r2[22:0]} + {6'd0, h3, 13'd0} - {19'd0, h3};  // < 2^23 + 2^18 < 2q
            reg  [13:0] kr3;
            reg  [23:0] dr3;
            always @(posedge clk) begin
                v3  <= rst ? 1'b0 : v2;
                m3  <= m2;
                kr3 <= kc2[13:0] - kq3q;
                dr3 <= r3w;
            end
            always @(posedge clk) begin
                out_valid <= rst ? 1'b0 : v3;
                if (m3)
                    p <= (dr3 >= {1'b0, QD}) ? (dr3 - {1'b0, QD}) : dr3[22:0];
                else
                    p <= {9'd0, (kr3 >= 14'd6658) ? (kr3 - 14'd6658) : (kr3 >= 14'd3329) ? (kr3 - 14'd3329) : kr3};
            end
        end
    endgenerate
endmodule
