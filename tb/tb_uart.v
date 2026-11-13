// UART loopback: uart_tx -> uart_rx for all 256 byte values back to back, then a frame with a bad
// stop bit (frame_err must fire, no byte), a short glitch (ignored), and a byte after recovery.
`timescale 1ns / 1ps
module tb_uart;
    localparam CPB = 16;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg        tv = 0, force_line = 0, forced = 1;
    reg  [7:0] tb_byte = 0;
    wire       tready, txline, rv, ferr;
    wire [7:0] rbyte;
    uart_tx #(.CLKS_PER_BIT(CPB)) u_tx (.clk(clk), .rst(rst), .in_valid(tv), .in_byte(tb_byte), .in_ready(tready), .tx(txline));
    wire line = force_line ? forced : txline;
    uart_rx #(.CLKS_PER_BIT(CPB)) u_rx (.clk(clk), .rst(rst), .rx(line), .out_valid(rv), .out_byte(rbyte), .frame_err(ferr));

    integer errors = 0, got = 0, ferrs = 0, i;
    reg [7:0] expect_q[0:511];
    always @(posedge clk) begin
        if (rv) begin
            if (rbyte !== expect_q[got]) begin
                $display("ERROR: byte %0d expected %02x got %02x", got, expect_q[got], rbyte);
                errors = errors + 1;
            end
            got = got + 1;
        end
        if (ferr) ferrs = ferrs + 1;
    end

    task send(input [7:0] bb);
        begin
            while (!tready) @(posedge clk);
            tv <= 1; tb_byte <= bb;
            @(posedge clk);
            tv <= 0;
            @(posedge clk);
        end
    endtask
    task bit_out(input bv, input integer n);
        begin
            forced <= bv;
            repeat (n) @(posedge clk);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst <= 0;
        for (i = 0; i < 256; i = i + 1) begin
            expect_q[i] = i;
            send(i);
        end
        while (!tready) @(posedge clk);
        repeat (2 * CPB) @(posedge clk);
        if (got != 256) begin
            $display("ERROR: received %0d of 256 bytes", got);
            errors = errors + 1;
        end
        // bad stop bit: start, 8 x '1', stop = 0
        force_line <= 1;
        bit_out(1, 3 * CPB);
        bit_out(0, CPB);
        for (i = 0; i < 8; i = i + 1) bit_out(1, CPB);
        bit_out(0, CPB);
        bit_out(1, 3 * CPB);
        if (ferrs != 1 || got != 256) begin
            $display("ERROR: bad stop bit: frame errors %0d (want 1), bytes %0d (want 256)", ferrs, got);
            errors = errors + 1;
        end
        // glitch shorter than half a bit: must not start a frame
        bit_out(0, CPB / 4);
        bit_out(1, 3 * CPB);
        force_line <= 0;
        expect_q[256] = 8'hA5;
        send(8'hA5);
        while (!tready) @(posedge clk);
        repeat (2 * CPB) @(posedge clk);
        if (got != 257 || ferrs != 1) begin
            $display("ERROR: after recovery: bytes %0d (want 257), frame errors %0d", got, ferrs);
            errors = errors + 1;
        end
        if (errors == 0) $display("TEST PASSED");
        else $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end
endmodule
