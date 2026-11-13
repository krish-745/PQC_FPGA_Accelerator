// UART receiver, 8N1, LSB first. Samples each bit in its middle (CLKS_PER_BIT clocks per bit).
// out_valid pulses for one cycle with the byte; frame_err pulses instead if the stop bit is 0.
module uart_rx #(
    parameter CLKS_PER_BIT = 868  // 100 MHz / 115200 baud
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       rx,
    output reg        out_valid,
    output reg  [7:0] out_byte,
    output reg        frame_err
);
    // two-flop synchronizer: rx comes from another clock domain (the USB-UART bridge)
    reg rx_s1 = 1'b1, rx_s = 1'b1;
    always @(posedge clk) begin
        rx_s1 <= rx;
        rx_s  <= rx_s1;
    end

    localparam IDLE = 2'd0, START = 2'd1, DATA = 2'd2, STOP = 2'd3;
    reg [1:0]  state;
    reg [15:0] cnt;
    reg [2:0]  bitn;
    reg [7:0]  sh;

    always @(posedge clk) begin
        out_valid <= 1'b0;
        frame_err <= 1'b0;
        if (rst) begin
            state <= IDLE;
            cnt   <= 0;
            bitn  <= 0;
        end else begin
            case (state)
                IDLE:
                    if (!rx_s) begin
                        state <= START;
                        cnt   <= CLKS_PER_BIT / 2 - 1;  // go to the middle of the start bit
                    end
                START:
                    if (cnt == 0) begin
                        if (!rx_s) begin
                            state <= DATA;
                            cnt   <= CLKS_PER_BIT - 1;
                            bitn  <= 0;
                        end else state <= IDLE;  // glitch, not a start bit
                    end else cnt <= cnt - 1;
                DATA:
                    if (cnt == 0) begin
                        sh   <= {rx_s, sh[7:1]};
                        cnt  <= CLKS_PER_BIT - 1;
                        bitn <= bitn + 1;
                        if (bitn == 3'd7) state <= STOP;
                    end else cnt <= cnt - 1;
                STOP:
                    if (cnt == 0) begin
                        state <= IDLE;
                        if (rx_s) begin
                            out_valid <= 1'b1;
                            out_byte  <= sh;
                        end else frame_err <= 1'b1;
                    end else cnt <= cnt - 1;
            endcase
        end
    end
endmodule
