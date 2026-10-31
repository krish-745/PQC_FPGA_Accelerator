// mod_mul against the golden vectors, then random inputs with the mode changing every cycle.
// Define EXHAUSTIVE to also run all 3329^2 ML-KEM pairs (about 11 million cycles).
// Define VCD to dump waveforms to build/tb_mod_mul.vcd.
`timescale 1ns/1ps
`ifndef VEC_DIR
`define VEC_DIR "vectors/"
`endif

module tb_mod_mul;
`include "pqc_params.vh"

    localparam N_RAND = 200000;
    localparam MAXV   = 1009;  // lines in each modmul file, see vectors/README.md

    reg clk = 0;
    always #5 clk = ~clk;

    reg         in_valid = 0;
    reg         mode = 0;
    reg  [23:0] a = 0, b = 0;
    wire        out_valid;
    wire [23:0] y;

    mod_mul dut (
        .clk(clk), .in_valid(in_valid), .mode(mode), .a(a), .b(b),
        .out_valid(out_valid), .y(y)
    );

    // Expected results wait in a ring buffer; at most 4 are in flight.
    reg  [23:0] expected [0:15];
    reg  [71:0] vec [0:MAXV-1];
    reg  [63:0] q, x, z;
    reg  [31:0] r;
    integer n_in, n_out, errors, seed, i, j, m;

    always @(posedge clk) begin
        if (out_valid) begin
            if (y !== expected[n_out % 16]) begin
                if (errors < 10)
                    $display("FAIL output %0d: got %0d, expected %0d", n_out, y, expected[n_out % 16]);
                errors = errors + 1;
            end
            n_out = n_out + 1;
        end
    end

    task send(input md, input [23:0] x, input [23:0] z, input [23:0] p);
        begin
            @(negedge clk);
            in_valid <= 1;
            mode <= md;
            a <= x;
            b <= z;
            expected[n_in % 16] = p;
            n_in = n_in + 1;
        end
    endtask

    task run_file(input md, input [8*64-1:0] path);
        begin
            for (i = 0; i < MAXV; i = i + 1) vec[i] = 72'bx;
            $readmemh(path, vec);
            for (i = 0; i < MAXV && ^vec[i] !== 1'bx; i = i + 1)
                send(md, vec[i][71:48], vec[i][47:24], vec[i][23:0]);
            $display("  %0s: %0d vectors", path, i);
        end
    endtask

    initial begin
`ifdef VCD
        $dumpfile("build/tb_mod_mul.vcd");
        $dumpvars(0, tb_mod_mul);
`endif
        n_in = 0;
        n_out = 0;
        errors = 0;
        seed = 2;

        run_file(MODE_KEM, {`VEC_DIR, "kyber_modmul.hex"});
        run_file(MODE_DSA, {`VEC_DIR, "dilithium_modmul.hex"});

        for (i = 0; i < N_RAND; i = i + 1) begin
            r = $random(seed);
            m = r[0];
            q = m ? Q_DSA : Q_KEM;
            r = $random(seed); x = r % q;
            r = $random(seed); z = r % q;
            send(m, x, z, (x * z) % q);
        end
        $display("  random, mode switching every cycle: %0d inputs", N_RAND);

`ifdef EXHAUSTIVE
        for (i = 0; i < Q_KEM; i = i + 1)
            for (j = 0; j < Q_KEM; j = j + 1)
                send(MODE_KEM, i, j, (i * j) % Q_KEM);
        $display("  exhaustive ML-KEM: %0d inputs", Q_KEM * Q_KEM);
`endif

        @(negedge clk) in_valid <= 0;
        repeat (8) @(negedge clk);

        if (n_out != n_in)
            $display("FAIL tb_mod_mul: %0d inputs but %0d outputs", n_in, n_out);
        else if (errors == 0)
            $display("PASS tb_mod_mul: %0d products", n_out);
        else
            $display("FAIL tb_mod_mul: %0d of %0d products wrong", errors, n_out);
        $finish;
    end

endmodule
