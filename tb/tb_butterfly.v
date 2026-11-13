// Self-checking test of rtl/butterfly.v: CT, GS and MAC for both schemes against arithmetic done here
// in 64-bit integers, with edge operands, 60k random operations with bubbles, and a reset mid-stream.
`timescale 1ns / 1ps
module tb_butterfly;
    parameter DIL_SPECIAL = 0;
    localparam LAT = 6;

    reg clk = 0, rst = 1, in_valid = 0, mode = 0;
    reg [1:0] op = 0;
    reg [22:0] u = 0, v = 0, z = 0;
    wire out_valid;
    wire [22:0] o0, o1;
    always #5 clk = ~clk;

    butterfly #(.DIL_SPECIAL(DIL_SPECIAL)) dut (
        .clk(clk), .rst(rst), .in_valid(in_valid), .mode(mode), .op(op), .u(u), .v(v), .z(z),
        .out_valid(out_valid), .o0(o0), .o1(o1)
    );

    reg [22:0] e0[0:1023], e1[0:1023];
    reg [1:0]  eop[0:1023];
    integer wr = 0, rd = 0, errors = 0, checked = 0;

    function [22:0] qof(input m);
        qof = m ? 23'd8380417 : 23'd3329;
    endfunction

    always @(posedge clk) begin
        if (rst) rd <= wr;
        else if (out_valid) begin
            if (rd == wr) begin
                $display("ERROR: unexpected out_valid");
                errors = errors + 1;
            end else begin
                if (o0 !== e0[rd % 1024] || (eop[rd % 1024] != 2 && o1 !== e1[rd % 1024])) begin
                    if (errors < 10)
                        $display("ERROR: op %0d: expected (%0d, %0d) got (%0d, %0d)", eop[rd % 1024],
                                 e0[rd % 1024], e1[rd % 1024], o0, o1);
                    errors = errors + 1;
                end
                checked = checked + 1;
                rd <= rd + 1;
            end
        end
    end

    task issue(input m, input [1:0] o, input [22:0] uu, input [22:0] vv, input [22:0] zz);
        reg [63:0] q, t, r0, r1;
        begin
            q = qof(m);
            if (o == 1) begin
                r0 = (uu + vv) % q;
                r1 = (zz * ((vv + q - uu) % q)) % q;
            end else begin
                t = (zz * vv) % q;
                r0 = (uu + t) % q;
                r1 = (uu + q - t) % q;
            end
            e0[wr % 1024] = r0[22:0]; e1[wr % 1024] = r1[22:0]; eop[wr % 1024] = o;
            wr = wr + 1;
            in_valid <= 1; mode <= m; op <= o; u <= uu; v <= vv; z <= zz;
            @(posedge clk);
            in_valid <= 0;
        end
    endtask

    integer i, j, k, m, o, seed;
    reg [22:0] q, ed[0:5];
    initial begin
        seed = 777;
        repeat (3) @(posedge clk);
        rst <= 0;
        for (m = 0; m < 2; m = m + 1) begin
            q = qof(m);
            ed[0] = 0; ed[1] = 1; ed[2] = q - 1; ed[3] = q - 2; ed[4] = q >> 1; ed[5] = 2;
            for (o = 0; o < 3; o = o + 1)
                for (i = 0; i < 6; i = i + 1)
                    for (j = 0; j < 6; j = j + 1)
                        for (k = 0; k < 6; k = k + 1)
                            issue(m, o, ed[i], ed[j], ed[k]);
            for (i = 0; i < 30000; i = i + 1) begin
                issue(m, $unsigned($random(seed)) % 3, $unsigned($random(seed)) % q,
                      $unsigned($random(seed)) % q, $unsigned($random(seed)) % q);
                if (($random(seed) & 7) == 0) repeat ($unsigned($random(seed)) % 4) @(posedge clk);
            end
        end
        issue(1, 0, 23'd1, 23'd2, 23'd3);
        rst <= 1;
        @(posedge clk);
        rst <= 0;
        repeat (LAT + 3) @(posedge clk);
        issue(0, 1, 23'd3328, 23'd0, 23'd17);
        repeat (LAT + 3) @(posedge clk);
        if (rd != wr) begin
            $display("ERROR: %0d results missing", wr - rd);
            errors = errors + 1;
        end
        $display("checked %0d butterflies (DIL_SPECIAL=%0d)", checked, DIL_SPECIAL);
        if (errors == 0 && checked > 0) $display("TEST PASSED");
        else $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end
endmodule
