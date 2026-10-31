// Unified NTT butterfly. Pipelined, latency 6 in both directions, one new pair every cycle.
//   inv = 0, Cooley-Tukey (forward NTT):     u = a + w*b,  v = a - w*b
//   inv = 1, Gentleman-Sande (inverse NTT):  u = a + b,    v = w*(b - a)
// All mod q. Both directions share one mod_mul:
//   stage 1         GS computes a + b and b - a; CT passes a and b through
//   stages 2 to 5   mod_mul: w times b (CT) or w times (b - a) (GS)
//   stage 6         CT computes a + t and a - t; GS passes a + b and the product through
module butterfly (
    input  wire        clk,
    input  wire        in_valid,
    input  wire        mode,
    input  wire        inv,
    input  wire [23:0] a,
    input  wire [23:0] b,
    input  wire [23:0] w,
    output reg         out_valid,
    output reg  [23:0] u,
    output reg  [23:0] v
);

    // stage 1
    wire [23:0] sum_ab, diff_ba;
    mod_add pre_add (.mode(mode), .a(a), .b(b), .y(sum_ab));
    mod_sub pre_sub (.mode(mode), .a(b), .b(a), .y(diff_ba));

    reg  [23:0] keep1, mul_b1, w1;  // keep: a (CT) or a + b (GS), carried around the multiplier
    reg         v1, m1, i1;
    always @(posedge clk) begin
        keep1  <= inv ? sum_ab : a;
        mul_b1 <= inv ? diff_ba : b;
        w1     <= w;
        v1     <= in_valid;
        m1     <= mode;
        i1     <= inv;
    end

    // stages 2 to 5
    wire [23:0] prod;
    wire        prod_valid;
    mod_mul mul (
        .clk(clk), .in_valid(v1), .mode(m1), .a(w1), .b(mul_b1),
        .out_valid(prod_valid), .y(prod)
    );

    // delay keep, mode and inv by the multiplier latency
    reg [23:0] keep_d [0:3];
    reg [3:0]  mode_d, inv_d;
    always @(posedge clk) begin
        keep_d[0] <= keep1;
        keep_d[1] <= keep_d[0];
        keep_d[2] <= keep_d[1];
        keep_d[3] <= keep_d[2];
        mode_d    <= {mode_d[2:0], m1};
        inv_d     <= {inv_d[2:0], i1};
    end

    // stage 6
    wire [23:0] post_sum, post_diff;
    mod_add post_add (.mode(mode_d[3]), .a(keep_d[3]), .b(prod), .y(post_sum));
    mod_sub post_sub (.mode(mode_d[3]), .a(keep_d[3]), .b(prod), .y(post_diff));

    always @(posedge clk) begin
        u         <= inv_d[3] ? keep_d[3] : post_sum;
        v         <= inv_d[3] ? prod : post_diff;
        out_valid <= prod_valid;
    end

endmodule
