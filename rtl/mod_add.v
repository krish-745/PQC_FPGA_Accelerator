// y = (a + b) mod q, for a, b in [0, q). Combinational.
// One add, then subtract q and keep the difference if it did not go negative.
module mod_add (
    input  wire        mode,
    input  wire [23:0] a,
    input  wire [23:0] b,
    output wire [23:0] y
);
`include "pqc_params.vh"

    wire [23:0] q = mode ? Q_DSA : Q_KEM;
    wire [24:0] s = a + b;
    wire [25:0] d = {1'b0, s} - {2'b0, q};  // d[25] set means s < q

    assign y = d[25] ? s[23:0] : d[23:0];

endmodule
