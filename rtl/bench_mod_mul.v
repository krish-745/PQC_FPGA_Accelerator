// Out-of-context measurement wrapper for mod_mul: registers every port so that all timed paths
// are register to register. Resource numbers are read for the u_mul instance only
// (route_util_hier.rpt), so the wrapper registers are not counted.
// FIXED_MODE = 2: the mode port is used (both schemes); 0 or 1: mode is tied to that scheme, so
// synthesis removes the other scheme's logic (used to compare the ML-DSA reductions on their own).
module bench_mod_mul #(
    parameter DIL_SPECIAL = 0,
    parameter FIXED_MODE = 2
) (
    input  wire        clk,
    input  wire        in_valid,
    input  wire        mode,
    input  wire [22:0] a,
    input  wire [22:0] b,
    output reg         out_valid,
    output reg  [22:0] p
);
    reg        rv, rm;
    reg [22:0] ra, rb;
    wire       ov;
    wire [22:0] op;
    always @(posedge clk) begin
        rv <= in_valid; rm <= (FIXED_MODE == 2) ? mode : (FIXED_MODE == 1); ra <= a; rb <= b;
        out_valid <= ov; p <= op;
    end
    mod_mul #(.DIL_SPECIAL(DIL_SPECIAL)) u_mul (
        .clk(clk), .rst(1'b0), .in_valid(rv), .mode(rm), .a(ra), .b(rb), .out_valid(ov), .p(op)
    );
endmodule
