// UART transmitter, 8N1, LSB first. Accepts a byte when in_valid && in_ready.
module uart_tx #(
    parameter CLKS_PER_BIT = 868
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       in_valid,
    input  wire [7:0] in_byte,
    output wire       in_ready,
    output reg        tx
);
    reg        busy;
    reg [9:0]  sh;  // {stop, data[7:0], start}, shifted out LSB first
    reg [3:0]  bitn;
    reg [15:0] cnt;
    assign in_ready = !busy;

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            tx   <= 1'b1;
        end else if (!busy) begin
            tx <= 1'b1;
            if (in_valid) begin
                busy <= 1'b1;
                sh   <= {1'b1, in_byte, 1'b0};
                bitn <= 0;
                cnt  <= 0;
            end
        end else begin
            if (cnt == 0) begin
                tx   <= sh[0];
                sh   <= {1'b1, sh[9:1]};
                cnt  <= CLKS_PER_BIT - 1;
                bitn <= bitn + 1;
                if (bitn == 4'd10) begin  // start + 8 data + stop have been on the line
                    busy <= 1'b0;
                    tx   <= 1'b1;
                end
            end else cnt <= cnt - 1;
        end
    end
endmodule
