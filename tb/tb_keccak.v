// tb_keccak: every case of build/vectors/keccak_cases.txt (+CASES=<file>) through rtl/keccak_core.v.
// Messages are fed with random gaps, output bytes are requested with random gaps (backpressure),
// and every output byte is compared with hashlib's result. A reset in the middle of a hash is
// followed by a clean hash.
`timescale 1ns / 1ps
module tb_keccak;
    reg clk = 0, rst = 1, init = 0, in_valid = 0, finish = 0, out_req = 0;
    reg [1:0] mode = 0;
    reg [7:0] in_byte = 0;
    wire in_ready, out_valid;
    wire [7:0] out_byte;
    always #5 clk = ~clk;
    keccak_core dut (.clk(clk), .rst(rst), .init(init), .mode(mode), .in_valid(in_valid), .in_byte(in_byte),
                     .finish(finish), .in_ready(in_ready), .out_req(out_req), .out_valid(out_valid), .out_byte(out_byte));

    reg [8*256-1:0] cases_file;
    integer fc, r, ncases, n, mlen, olen, i, v, errors = 0, seed = 5, bytes_checked = 0;
    reg [7:0] msg[0:1023], expv[0:1023];

    task absorb(input [7:0] bb);
        begin
            in_valid <= 1; in_byte <= bb;
            #1;
            while (!in_ready) begin @(posedge clk); #1; end  // taken at the edge where in_ready is high
            @(posedge clk); #1;
            in_valid <= 0;
            if (($random(seed) & 3) == 0) repeat ($unsigned($random(seed)) % 5) @(posedge clk);
        end
    endtask
    task do_finish;
        begin
            #1;
            while (!in_ready) begin @(posedge clk); #1; end
            finish <= 1;
            @(posedge clk); #1;
            finish <= 0;
        end
    endtask

    initial begin
        if (!$value$plusargs("CASES=%s", cases_file)) cases_file = "../../vectors/keccak_cases.txt";
        fc = $fopen(cases_file, "r");
        if (fc == 0) begin
            $display("ERROR: cannot open %0s", cases_file);
            $finish;
        end
        r = $fscanf(fc, "%d", ncases);
        repeat (3) @(posedge clk);
        rst <= 0;
        // reset in the middle of a hash, then make sure the next hash is clean
        init <= 1; mode <= 0; @(posedge clk); init <= 0;
        absorb(8'h11); absorb(8'h22);
        rst <= 1; @(posedge clk); rst <= 0;
        for (n = 0; n < ncases; n = n + 1) begin
            r = $fscanf(fc, "%d %d %d", v, mlen, olen);
            for (i = 0; i < mlen; i = i + 1) begin r = $fscanf(fc, "%d", msg[i]); end
            for (i = 0; i < olen; i = i + 1) begin r = $fscanf(fc, "%d", expv[i]); end
            init <= 1; mode <= v; @(posedge clk); init <= 0;
            for (i = 0; i < mlen; i = i + 1) absorb(msg[i]);
            do_finish;
            for (i = 0; i < olen; i = i + 1) begin
                #1;
                while (!out_valid) begin @(posedge clk); #1; end
                if (out_byte !== expv[i]) begin
                    if (errors < 10)
                        $display("ERROR: case %0d (mode %0d, %0d-byte message): output byte %0d expected %02x got %02x",
                                 n, v, mlen, i, expv[i], out_byte);
                    errors = errors + 1;
                end
                bytes_checked = bytes_checked + 1;
                out_req <= 1; @(posedge clk); #1; out_req <= 0;
                if (($random(seed) & 3) == 0) repeat ($unsigned($random(seed)) % 4) @(posedge clk);
            end
        end
        $display("%0d cases, %0d output bytes checked", ncases, bytes_checked);
        if (errors == 0 && bytes_checked > 0) $display("TEST PASSED");
        else $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end
endmodule
