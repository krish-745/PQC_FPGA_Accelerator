// Constants shared by every module. Include inside a module body.
// mode = 0 selects ML-KEM, mode = 1 selects ML-DSA. Values match python/pqc_golden.

localparam MODE_KEM = 1'b0;
localparam MODE_DSA = 1'b1;

localparam [23:0] Q_KEM = 24'd3329;
localparam [23:0] Q_DSA = 24'd8380417;

// Barrett: mu = floor(2^(2k) / q), k = bit width of q (12 and 23)
localparam [23:0] MU_KEM = 24'd5039;
localparam [23:0] MU_DSA = 24'd8396807;
