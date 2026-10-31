// y = (a - b) mod q, for a, b in [0, q). Combinational.
// One subtract, then add q back if it went negative.
module mod_sub (
    input  wire        mode,
    input  wire [23:0] a,
    input  wire [23:0] b,
    output wire [23:0] y
);
`include "pqc_params.vh"

    wire [23:0] q = mode ? Q_DSA : Q_KEM;
    wire [24:0] d = {1'b0, a} - {1'b0, b};  // d[24] set means a < b

    assign y = d[24] ? d[23:0] + q : d[23:0];

endmodule
