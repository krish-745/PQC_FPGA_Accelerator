// Board bring-up design: every byte received on the USB-UART is sent back.
// LED0 blinks (clock alive), LED1 is on while in reset, LED2 toggles per byte, LED3 latches a framing error.
module top_uart_echo #(
    parameter CLKS_PER_BIT = 868
) (
    input  wire       CLK100MHZ,
    input  wire       CPU_RESETN,
    input  wire       UART_TXD_IN,   // from the PC (FPGA receive)
    output wire       UART_RXD_OUT,  // to the PC (FPGA transmit)
    output wire [3:0] LED
);
    wire clk = CLK100MHZ;
    wire rst;
    reset_sync u_rst (.clk(clk), .rst_n_async(CPU_RESETN), .rst(rst));

    wire       rx_valid, rx_err, tx_ready, empty, full;
    wire [7:0] rx_byte, fifo_out;
    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk), .rst(rst), .rx(UART_TXD_IN), .out_valid(rx_valid), .out_byte(rx_byte), .frame_err(rx_err)
    );
    fifo_sync #(.WIDTH(8), .DEPTH_LOG2(4)) u_fifo (
        .clk(clk), .rst(rst), .wr_en(rx_valid), .wr_data(rx_byte),
        .rd_en(tx_ready && !empty), .rd_data(fifo_out), .empty(empty), .full(full)
    );
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst(rst), .in_valid(!empty), .in_byte(fifo_out), .in_ready(tx_ready), .tx(UART_RXD_OUT)
    );

    reg [26:0] beat;
    reg        toggle, err_seen;
    always @(posedge clk) begin
        if (rst) begin
            beat <= 0;
            toggle <= 0;
            err_seen <= 0;
        end else begin
            beat <= beat + 1;
            if (rx_valid) toggle <= ~toggle;
            if (rx_err) err_seen <= 1'b1;
        end
    end
    assign LED = {err_seen, toggle, rst, beat[26]};
endmodule
