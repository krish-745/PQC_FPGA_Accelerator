// Full system for the Nexys 4 DDR: USB-UART <-> command controller <-> NTT core + Keccak core.
// LED0 heartbeat, LED1 NTT core busy, LED2 last response was an error, LED3 in reset.
module top #(
    parameter P = 1,
    parameter DIL_SPECIAL = 0,
    parameter CLKS_PER_BIT = 868,       // 115200 baud at 100 MHz
    parameter TIMEOUT = 1_000_000       // 10 ms inter-byte timeout inside a request
) (
    input  wire       CLK100MHZ,
    input  wire       CPU_RESETN,
    input  wire       UART_TXD_IN,
    output wire       UART_RXD_OUT,
    output wire [3:0] LED
);
    wire clk = CLK100MHZ;
    wire rst;
    reset_sync u_rst (.clk(clk), .rst_n_async(CPU_RESETN), .rst(rst));

    wire       rx_valid, rx_err, tx_valid, tx_ready;
    wire [7:0] rx_byte, tx_byte;
    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk), .rst(rst), .rx(UART_TXD_IN), .out_valid(rx_valid), .out_byte(rx_byte), .frame_err(rx_err)
    );
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst(rst), .in_valid(tx_valid), .in_byte(tx_byte), .in_ready(tx_ready), .tx(UART_RXD_OUT)
    );

    wire        c_start, c_scheme, c_busy, c_done, h_we, h_re;
    wire [1:0]  c_op, c_buf, h_buf;
    wire [31:0] c_cycles;
    wire [7:0]  h_idx;
    wire [22:0] h_wdata, h_rdata;
    ntt_core #(.P(P), .DIL_SPECIAL(DIL_SPECIAL)) u_core (
        .clk(clk), .rst(rst), .start(c_start), .op(c_op), .scheme(c_scheme), .buf_sel(c_buf),
        .busy(c_busy), .done(c_done), .cycles(c_cycles),
        .h_we(h_we), .h_re(h_re), .h_buf(h_buf), .h_idx(h_idx), .h_wdata(h_wdata), .h_rdata(h_rdata),
        .dbg_issue(), .dbg_kind(), .dbg_u(), .dbg_v(), .dbg_we(), .dbg_waddr(), .dbg_wdata()
    );

    wire       k_init, k_in_valid, k_finish, k_in_ready, k_out_req, k_out_valid;
    wire [1:0] k_mode;
    wire [7:0] k_in_byte, k_out_byte;
    keccak_core u_keccak (
        .clk(clk), .rst(rst), .init(k_init), .mode(k_mode), .in_valid(k_in_valid), .in_byte(k_in_byte),
        .finish(k_finish), .in_ready(k_in_ready), .out_req(k_out_req), .out_valid(k_out_valid), .out_byte(k_out_byte)
    );

    wire [7:0] last_status;
    cmd_ctrl #(.P(P), .DIL_SPECIAL(DIL_SPECIAL), .TIMEOUT(TIMEOUT)) u_ctrl (
        .clk(clk), .rst(rst),
        .rx_valid(rx_valid), .rx_byte(rx_byte), .tx_valid(tx_valid), .tx_byte(tx_byte), .tx_ready(tx_ready),
        .c_start(c_start), .c_op(c_op), .c_scheme(c_scheme), .c_buf(c_buf), .c_busy(c_busy), .c_done(c_done),
        .c_cycles(c_cycles), .h_we(h_we), .h_re(h_re), .h_buf(h_buf), .h_idx(h_idx), .h_wdata(h_wdata),
        .h_rdata(h_rdata), .k_init(k_init), .k_mode(k_mode), .k_in_valid(k_in_valid), .k_in_byte(k_in_byte),
        .k_finish(k_finish), .k_in_ready(k_in_ready), .k_out_req(k_out_req), .k_out_valid(k_out_valid),
        .k_out_byte(k_out_byte), .last_status(last_status)
    );

    reg [26:0] beat;
    always @(posedge clk) beat <= rst ? 27'd0 : beat + 1;
    assign LED = {rst, last_status != 8'h00, c_busy, beat[26]};
endmodule
