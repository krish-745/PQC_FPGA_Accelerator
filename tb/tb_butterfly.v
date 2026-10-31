// butterfly against the golden CT and GS vectors for both schemes, then random inputs with
// mode and direction changing every cycle. Define VCD to dump waveforms to build/tb_butterfly.vcd.
`timescale 1ns/1ps
`ifndef VEC_DIR
`define VEC_DIR "vectors/"
`endif

module tb_butterfly;
`include "pqc_params.vh"

    localparam N_RAND = 100000;
    localparam MAXV   = 1027;  // lines in each ct and gs file, see vectors/README.md

    reg clk = 0;
    always #5 clk = ~clk;

    reg         in_valid = 0;
    reg         mode = 0, inv = 0;
    reg  [23:0] a = 0, b = 0, w = 0;
    wire        out_valid;
    wire [23:0] u, v;

    butterfly dut (
        .clk(clk), .in_valid(in_valid), .mode(mode), .inv(inv), .a(a), .b(b), .w(w),
        .out_valid(out_valid), .u(u), .v(v)
    );

    // Expected results wait in a ring buffer; at most 6 are in flight.
    reg  [23:0] exp_u [0:15];
    reg  [23:0] exp_v [0:15];
    reg  [119:0] vec [0:MAXV-1];
    reg  [63:0] q, x, z, tw, t;
    reg  [31:0] r;
    integer n_in, n_out, errors, seed, i, m, d;

    always @(posedge clk) begin
        if (out_valid) begin
            if (u !== exp_u[n_out % 16] || v !== exp_v[n_out % 16]) begin
                if (errors < 10)
                    $display("FAIL output %0d: got (%0d, %0d), expected (%0d, %0d)",
                             n_out, u, v, exp_u[n_out % 16], exp_v[n_out % 16]);
                errors = errors + 1;
            end
            n_out = n_out + 1;
        end
    end

    task send(input md, input dir, input [23:0] x_in, input [23:0] z_in, input [23:0] w_in,
              input [23:0] eu, input [23:0] ev);
        begin
            @(negedge clk);
            in_valid <= 1;
            mode <= md;
            inv <= dir;
            a <= x_in;
            b <= z_in;
            w <= w_in;
            exp_u[n_in % 16] = eu;
            exp_v[n_in % 16] = ev;
            n_in = n_in + 1;
        end
    endtask

    task run_file(input md, input dir, input [8*64-1:0] path);
        begin
            for (i = 0; i < MAXV; i = i + 1) vec[i] = 120'bx;
            $readmemh(path, vec);
            for (i = 0; i < MAXV && ^vec[i] !== 1'bx; i = i + 1)
                send(md, dir, vec[i][119:96], vec[i][95:72], vec[i][71:48], vec[i][47:24], vec[i][23:0]);
            $display("  %0s: %0d vectors", path, i);
        end
    endtask

    initial begin
`ifdef VCD
        $dumpfile("build/tb_butterfly.vcd");
        $dumpvars(0, tb_butterfly);
`endif
        n_in = 0;
        n_out = 0;
        errors = 0;
        seed = 3;

        run_file(MODE_KEM, 0, {`VEC_DIR, "kyber_ct.hex"});
        run_file(MODE_KEM, 1, {`VEC_DIR, "kyber_gs.hex"});
        run_file(MODE_DSA, 0, {`VEC_DIR, "dilithium_ct.hex"});
        run_file(MODE_DSA, 1, {`VEC_DIR, "dilithium_gs.hex"});

        for (i = 0; i < N_RAND; i = i + 1) begin
            r = $random(seed);
            m = r[0];
            d = r[1];
            q = m ? Q_DSA : Q_KEM;
            r = $random(seed); x = r % q;
            r = $random(seed); z = r % q;
            r = $random(seed); tw = r % q;
            if (d == 0) begin
                t = (tw * z) % q;
                send(m, d, x, z, tw, (x + t) % q, (x + q - t) % q);
            end else
                send(m, d, x, z, tw, (x + z) % q, (tw * ((z + q - x) % q)) % q);
        end
        $display("  random, mode and direction switching every cycle: %0d inputs", N_RAND);

        @(negedge clk) in_valid <= 0;
        repeat (10) @(negedge clk);

        if (n_out != n_in)
            $display("FAIL tb_butterfly: %0d inputs but %0d outputs", n_in, n_out);
        else if (errors == 0)
            $display("PASS tb_butterfly: %0d butterflies", n_out);
        else
            $display("FAIL tb_butterfly: %0d of %0d butterflies wrong", errors, n_out);
        $finish;
    end

endmodule
