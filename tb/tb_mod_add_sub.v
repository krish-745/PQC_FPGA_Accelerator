// mod_add and mod_sub against a % reference: every pair of edge values, then random pairs, both modes.
`timescale 1ns/1ps

module tb_mod_add_sub;
`include "pqc_params.vh"

    localparam N_RAND = 100000;

    reg         mode;
    reg  [23:0] a, b;
    wire [23:0] sum, diff;

    mod_add dut_add (.mode(mode), .a(a), .b(b), .y(sum));
    mod_sub dut_sub (.mode(mode), .a(a), .b(b), .y(diff));

    reg  [63:0] q;
    reg  [23:0] edges [0:3];
    reg  [31:0] r;
    integer seed, i, j, m, checks, errors;

    task check;
        begin
            #1;
            checks = checks + 1;
            if (sum !== (a + b) % q || diff !== (a + q - b) % q) begin
                if (errors < 10)
                    $display("FAIL mode=%0d a=%0d b=%0d: sum %0d diff %0d", mode, a, b, sum, diff);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        seed = 1;
        checks = 0;
        errors = 0;
        for (m = 0; m < 2; m = m + 1) begin
            mode = m;
            q = m ? Q_DSA : Q_KEM;
            edges[0] = 0; edges[1] = 1; edges[2] = q - 2; edges[3] = q - 1;
            for (i = 0; i < 4; i = i + 1)
                for (j = 0; j < 4; j = j + 1) begin
                    a = edges[i];
                    b = edges[j];
                    check;
                end
            for (i = 0; i < N_RAND; i = i + 1) begin
                r = $random(seed); a = r % q;
                r = $random(seed); b = r % q;
                check;
            end
        end
        if (errors == 0) $display("PASS tb_mod_add_sub: %0d checks", checks);
        else             $display("FAIL tb_mod_add_sub: %0d of %0d checks wrong", errors, checks);
        $finish;
    end

endmodule
