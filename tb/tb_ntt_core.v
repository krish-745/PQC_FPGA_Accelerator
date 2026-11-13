// tb_ntt_core: runs every case of build/vectors/ntt_cases.txt through rtl/ntt_core.v and
//   1. writes the cycle trace (issues, writebacks, pass ends, total) to rtl_trace.txt in the same
//      format as python/pqc_golden/schedule.py; scripts/flow.py diffs it against the expected trace;
//   2. reads all three buffers back through the host port and compares them with the golden memory
//      (+MEM=<file>), printing the first mismatches;
//   3. checks the core's cycle count against a cycle counter kept here.
// While the core is busy, start, op, scheme, buf_sel and the host port are driven with random values
// every cycle: the trace and the result must not change (inputs are captured when start is accepted,
// the host port is ignored while busy). The last case is first started and reset in the middle of
// its MUL (busy must drop, no done, no writes), then reloaded and run normally with a full trace check.
// Generics P, DIL_SPECIAL select the configuration. Plusargs: +CASES=<file> +MEM=<file>.
`timescale 1ns / 1ps
module tb_ntt_core;
    parameter P = 1;
    parameter DIL_SPECIAL = 0;
    localparam NB = 2 * P;
    localparam D = 8;  // issue -> write, as in rtl/ntt_core.v and schedule.py

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg        start = 0, scheme = 0, h_we = 0, h_re = 0;
    reg [1:0]  op = 0, bsel = 0, h_buf = 0;
    reg [7:0]  h_idx = 0;
    reg [22:0] h_wdata = 0;
    wire       busy, done;
    wire [31:0] cycles;
    wire [22:0] h_rdata;
    wire                dbg_issue;
    wire [2*P-1:0]      dbg_kind;
    wire [9*P-1:0]      dbg_u;
    wire [8*P-1:0]      dbg_v;
    wire [3*NB-1:0]     dbg_we;
    wire [3*NB*8-1:0]   dbg_waddr;
    wire [3*NB*23-1:0]  dbg_wdata;

    ntt_core #(.P(P), .DIL_SPECIAL(DIL_SPECIAL)) dut (
        .clk(clk), .rst(rst), .start(start), .op(op), .scheme(scheme), .buf_sel(bsel),
        .busy(busy), .done(done), .cycles(cycles),
        .h_we(h_we), .h_re(h_re), .h_buf(h_buf), .h_idx(h_idx), .h_wdata(h_wdata), .h_rdata(h_rdata),
        .dbg_issue(dbg_issue), .dbg_kind(dbg_kind), .dbg_u(dbg_u), .dbg_v(dbg_v),
        .dbg_we(dbg_we), .dbg_waddr(dbg_waddr), .dbg_wdata(dbg_wdata)
    );

    integer ft, fc, fm, n, ncases, errors = 0, cur = 0, logging = 0, i, b, val, r;
    integer lastiss[0:63];
    integer init_scheme, init_op, init_buf;
    integer maxpass;
    reg [8*256-1:0] cases_file, mem_file;
    reg [22:0] init_mem[0:767];
    reg [22:0] exp_mem[0:767];
    reg [8:0]  uu;

    // ---- scramble the core's inputs while it is busy ----
    integer sseed = 99;
    reg was_busy = 0;
    always @(negedge clk) begin
        if (busy) begin
            start <= $random(sseed); op <= $random(sseed); scheme <= $random(sseed); bsel <= $random(sseed);
            h_we <= $random(sseed); h_re <= $random(sseed); h_buf <= $random(sseed);
            h_idx <= $random(sseed); h_wdata <= $random(sseed);
        end else if (was_busy) begin
            start <= 0; h_we <= 0; h_re <= 0;
        end
        was_busy <= busy;
    end

    // ---- cycle-accurate monitor ----
    integer ln, bk;
    always @(posedge clk) begin
        if (start && !busy) cur = 0;
        else cur = cur + 1;
        if (logging) begin
            if (dbg_issue) begin
                for (ln = 0; ln < P; ln = ln + 1) begin
                    uu = dbg_u[ln*9 +: 9];
                    if (uu == 9'h1FF) $fdisplay(ft, "%0d I %0d %0d %0d -1 %0d", n, cur, ln, dbg_kind[ln*2 +: 2], dbg_v[ln*8 +: 8]);
                    else $fdisplay(ft, "%0d I %0d %0d %0d %0d %0d", n, cur, ln, dbg_kind[ln*2 +: 2], uu, dbg_v[ln*8 +: 8]);
                end
                lastiss[dut.q_pass] = cur;
                if (dut.q_pass > maxpass) maxpass = dut.q_pass;
            end
            for (bk = 0; bk < 3 * NB; bk = bk + 1)
                if (dbg_we[bk] && busy)
                    $fdisplay(ft, "%0d W %0d %s %0d %0d %0d", n, cur, (bk / NB == 0) ? "A" : (bk / NB == 1) ? "B" : "C",
                              bk % NB, dbg_waddr[bk*8 +: 8], dbg_wdata[bk*23 +: 23]);
            if (done) begin
                for (i = 0; i <= maxpass; i = i + 1) $fdisplay(ft, "%0d S %0d %0d", n, i, lastiss[i] + D);
                $fdisplay(ft, "%0d T %0d", n, cycles);
                if (cycles != cur) begin
                    $display("ERROR: case %0d: core reports %0d cycles, testbench counted %0d", n, cycles, cur);
                    errors = errors + 1;
                end
            end
        end
    end

    initial begin
        if (!$value$plusargs("CASES=%s", cases_file)) cases_file = "../../vectors/ntt_cases.txt";
        if (!$value$plusargs("MEM=%s", mem_file)) begin
            $display("ERROR: +MEM=<expected memory file> missing");
            $finish;
        end
        fc = $fopen(cases_file, "r");
        fm = $fopen(mem_file, "r");
        ft = $fopen("rtl_trace.txt", "w");
        if (fc == 0 || fm == 0) begin
            $display("ERROR: cannot open %0s or %0s", cases_file, mem_file);
            $finish;
        end
        r = $fscanf(fc, "%d", ncases);
        repeat (3) @(posedge clk);
        rst <= 0;
        @(posedge clk);
        for (n = 0; n < ncases; n = n + 1) begin
            r = $fscanf(fc, "%d %d %d", val, i, b);
            scheme <= val; op <= i; bsel <= b;
            init_scheme = val; init_op = i; init_buf = b;
            for (i = 0; i < 768; i = i + 1) begin
                r = $fscanf(fc, "%d", val);
                init_mem[i] = val;
            end
            for (i = 0; i < 768; i = i + 1) begin
                r = $fscanf(fm, "%d", val);
                exp_mem[i] = val;
            end
            if (n == ncases - 1) begin
                // abort run: start, reset in the middle of the operation, check it stops cleanly
                for (i = 0; i < 768; i = i + 1) begin
                    h_we <= 1; h_buf <= i / 256; h_idx <= i % 256; h_wdata <= init_mem[i];
                    @(posedge clk);
                end
                h_we <= 0;
                scheme <= init_scheme; op <= 3; bsel <= 0;
                @(posedge clk);
                start <= 1;
                @(posedge clk);
                start <= 0;
                repeat (300) @(posedge clk);
                rst <= 1;
                repeat (2) @(posedge clk);
                rst <= 0;
                #1;
                if (busy) begin
                    $display("ERROR: busy still high after a reset in the middle of MUL");
                    errors = errors + 1;
                end
                for (i = 0; i < 40; i = i + 1) begin
                    @(posedge clk); #1;
                    if (done || dbg_we != 0) begin
                        $display("ERROR: done or a RAM write %0d cycles after the reset", i);
                        errors = errors + 1;
                    end
                end
                scheme <= init_scheme; op <= init_op; bsel <= init_buf;
            end
            // load A, B, C through the host port
            for (i = 0; i < 768; i = i + 1) begin
                h_we <= 1; h_buf <= i / 256; h_idx <= i % 256; h_wdata <= init_mem[i];
                @(posedge clk);
            end
            h_we <= 0;
            @(posedge clk);
            maxpass = 0;
            logging = 1;
            start <= 1;
            @(posedge clk);
            start <= 0;
            while (!done) @(posedge clk);
            @(posedge clk);
            logging = 0;
            if (busy) begin
                $display("ERROR: case %0d: busy after done", n);
                errors = errors + 1;
            end
            // read back and compare
            for (i = 0; i < 768; i = i + 1) begin
                h_re <= 1; h_buf <= i / 256; h_idx <= i % 256;
                @(posedge clk);
                h_re <= 0;
                #1;
                if (h_rdata !== exp_mem[i]) begin
                    if (errors < 20)
                        $display("ERROR: case %0d (scheme %0d op %0d): %s[%0d] expected %0d got %0d", n, init_scheme, init_op,
                                 (i / 256 == 0) ? "A" : (i / 256 == 1) ? "B" : "C", i % 256, exp_mem[i], h_rdata);
                    errors = errors + 1;
                end
            end
        end
        $fclose(ft);
        $display("%0d cases, P=%0d DIL_SPECIAL=%0d", ncases, P, DIL_SPECIAL);
        if (errors == 0) $display("TEST PASSED");
        else $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end
endmodule
