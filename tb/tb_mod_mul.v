// Self-checking test of rtl/mod_mul.v against a*b mod q computed here in 64-bit arithmetic.
// Default run: edge operands x edge operands, then 200k random pairs with random bubbles, for both
// schemes, plus a reset in the middle of traffic. +EXHAUSTIVE: all 3329^2 ML-KEM pairs back to back.
// Prints "TEST PASSED" or "TEST FAILED" (the flow script turns that into the exit status).
`timescale 1ns / 1ps
module tb_mod_mul;
    parameter DIL_SPECIAL = 0;
    localparam LAT = 4;

    reg clk = 0, rst = 1, in_valid = 0, mode = 0;
    reg [22:0] a = 0, b = 0;
    wire out_valid;
    wire [22:0] p;
    always #5 clk = ~clk;

    mod_mul #(.DIL_SPECIAL(DIL_SPECIAL)) dut (
        .clk(clk), .rst(rst), .in_valid(in_valid), .mode(mode), .a(a), .b(b), .out_valid(out_valid), .p(p)
    );

    // scoreboard: expected results in issue order
    reg [22:0] exp_q[0:1023];
    reg [22:0] exp_a[0:1023], exp_b[0:1023];
    reg        exp_m[0:1023];
    integer wr = 0, rd = 0, errors = 0, checked = 0;

    function [22:0] qof(input m);
        qof = m ? 23'd8380417 : 23'd3329;
    endfunction
    function [22:0] ref_mul(input [22:0] x, input [22:0] y, input m);
        reg [63:0] t;
        begin
            t = x * y;
            t = t % qof(m);
            ref_mul = t[22:0];
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            rd <= wr;  // anything in flight is discarded by the reset
        end else if (out_valid) begin
            if (rd == wr) begin
                $display("ERROR: out_valid with nothing outstanding (p=%0d)", p);
                errors = errors + 1;
            end else begin
                if (p !== exp_q[rd % 1024]) begin
                    if (errors < 10)
                        $display("ERROR: mode=%0d a=%0d b=%0d expected %0d got %0d", exp_m[rd % 1024],
                                 exp_a[rd % 1024], exp_b[rd % 1024], exp_q[rd % 1024], p);
                    errors = errors + 1;
                end
                checked = checked + 1;
                rd <= rd + 1;
            end
        end
    end

    task issue(input m, input [22:0] x, input [22:0] y);
        begin
            in_valid <= 1; mode <= m; a <= x; b <= y;
            exp_q[wr % 1024] = ref_mul(x, y, m); exp_a[wr % 1024] = x; exp_b[wr % 1024] = y; exp_m[wr % 1024] = m;
            wr = wr + 1;
            @(posedge clk);
            in_valid <= 0;
        end
    endtask
    task bubble(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) @(posedge clk);
        end
    endtask

    integer i, j, m, seed, ne;
    reg [22:0] edges[0:15];
    reg [22:0] x, y, q;
    initial begin
        seed = 12345;
        repeat (3) @(posedge clk);
        rst <= 0;
        @(posedge clk);
        if (!$test$plusargs("EXHAUSTIVE")) begin
            for (m = 0; m < 2; m = m + 1) begin
                q = qof(m);
                edges[0] = 0; edges[1] = 1; edges[2] = 2; edges[3] = q - 1; edges[4] = q - 2;
                edges[5] = q >> 1; edges[6] = (q >> 1) + 1; edges[7] = 4095 % q; edges[8] = 4096 % q;
                edges[9] = 255; edges[10] = 256; edges[11] = 8191 % q; edges[12] = 8192 % q;
                edges[13] = q - 3; edges[14] = 3; edges[15] = (q >> 2);
                for (i = 0; i < 16; i = i + 1)
                    for (j = 0; j < 16; j = j + 1)
                        issue(m, edges[i], edges[j]);  // back to back
                for (i = 0; i < 100000; i = i + 1) begin
                    x = $unsigned($random(seed)) % q;
                    y = $unsigned($random(seed)) % q;
                    issue(m, x, y);
                    if (($random(seed) & 7) == 0) bubble($unsigned($random(seed)) % 3);
                end
            end
            // reset with traffic in flight: nothing may come out afterwards from before the reset
            issue(1, 23'd5, 23'd7);
            issue(1, 23'd9, 23'd11);
            rst <= 1;
            @(posedge clk);
            rst <= 0;
            bubble(LAT + 2);
            if (rd != wr) begin
                $display("ERROR: results lost or pending after reset (rd=%0d wr=%0d)", rd, wr);
                errors = errors + 1;
            end
            issue(0, 23'd3328, 23'd3328);
        end else begin
            for (i = 0; i < 3329; i = i + 1)
                for (j = 0; j < 3329; j = j + 1)
                    issue(0, i, j);
        end
        bubble(LAT + 3);
        if (rd != wr) begin
            $display("ERROR: %0d results missing", wr - rd);
            errors = errors + 1;
        end
        $display("checked %0d products (DIL_SPECIAL=%0d)", checked, DIL_SPECIAL);
        if (errors == 0 && checked > 0) $display("TEST PASSED");
        else $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end
endmodule
