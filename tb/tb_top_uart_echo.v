// Echo top level: bytes sent into the board's receive pin must come back on its transmit pin,
// including a burst longer than the FIFO's 16 entries sent back to back, and after a button reset.
`timescale 1ns / 1ps
module tb_top_uart_echo;
    localparam CPB = 16;
    reg clk = 0, rstn = 0, line = 1, mon_rst = 1;
    always #5 clk = ~clk;
    wire txo;
    wire [3:0] led;
    top_uart_echo #(.CLKS_PER_BIT(CPB)) dut (.CLK100MHZ(clk), .CPU_RESETN(rstn), .UART_TXD_IN(line), .UART_RXD_OUT(txo), .LED(led));

    // decoder for the DUT's output, same framing as the PC would see
    wire dv, derr;
    wire [7:0] db;
    uart_rx #(.CLKS_PER_BIT(CPB)) mon (.clk(clk), .rst(mon_rst), .rx(txo), .out_valid(dv), .out_byte(db), .frame_err(derr));

    integer errors = 0, got = 0, i;
    reg [7:0] exp_q[0:255];
    always @(posedge clk) begin
        if (dv) begin
            if (db !== exp_q[got]) begin
                $display("ERROR: echo %0d expected %02x got %02x", got, exp_q[got], db);
                errors = errors + 1;
            end
            got = got + 1;
        end
        if (derr) begin
            $display("ERROR: framing error on the echo line");
            errors = errors + 1;
        end
    end

    task send(input [7:0] bb);
        integer k;
        begin
            line <= 0;
            repeat (CPB) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                line <= bb[k];
                repeat (CPB) @(posedge clk);
            end
            line <= 1;
            repeat (CPB) @(posedge clk);
        end
    endtask

    initial begin
        repeat (10) @(posedge clk);
        mon_rst <= 0;
        if (led[1] !== 1'b1) begin
            $display("ERROR: reset LED not lit while CPU_RESETN is low");
            errors = errors + 1;
        end
        rstn <= 1;
        repeat (10) @(posedge clk);
        if (led[1] !== 1'b0) begin
            $display("ERROR: still in reset after release");
            errors = errors + 1;
        end
        for (i = 0; i < 40; i = i + 1) begin  // back to back: TX keeps up with RX at equal baud
            exp_q[i] = (i * 37 + 11) & 8'hff;
            send(exp_q[i]);
        end
        repeat (4 * 10 * CPB) @(posedge clk);
        if (got != 40) begin
            $display("ERROR: %0d of 40 bytes echoed", got);
            errors = errors + 1;
        end
        rstn <= 0;
        repeat (5) @(posedge clk);
        rstn <= 1;
        repeat (10) @(posedge clk);
        exp_q[40] = 8'h3C;
        send(8'h3C);
        repeat (12 * CPB) @(posedge clk);
        if (got != 41) begin
            $display("ERROR: no echo after reset (%0d bytes)", got);
            errors = errors + 1;
        end
        if (errors == 0) $display("TEST PASSED");
        else $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end
endmodule
