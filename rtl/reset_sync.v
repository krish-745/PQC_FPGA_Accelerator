// Reset synchronizer: asserts immediately when the CPU_RESET button (active low) is pressed,
// releases synchronously, STAGES clock cycles after the button is let go. Also holds reset for
// the first STAGES cycles after configuration.
module reset_sync #(
    parameter STAGES = 4
) (
    input  wire clk,
    input  wire rst_n_async,
    output wire rst
);
    reg [STAGES-1:0] sh = {STAGES{1'b1}};
    always @(posedge clk or negedge rst_n_async) begin
        if (!rst_n_async) sh <= {STAGES{1'b1}};
        else sh <= {sh[STAGES-2:0], 1'b0};
    end
    assign rst = sh[STAGES-1];
endmodule
