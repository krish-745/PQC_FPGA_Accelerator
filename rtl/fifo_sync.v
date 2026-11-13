// Small synchronous FIFO (first word fall-through). Writes when full and reads when empty are ignored.
module fifo_sync #(
    parameter WIDTH = 8,
    parameter DEPTH_LOG2 = 4
) (
    input  wire             clk,
    input  wire             rst,
    input  wire             wr_en,
    input  wire [WIDTH-1:0] wr_data,
    input  wire             rd_en,
    output wire [WIDTH-1:0] rd_data,
    output wire             empty,
    output wire             full
);
    reg [WIDTH-1:0]    mem[0:(1<<DEPTH_LOG2)-1];
    reg [DEPTH_LOG2:0] wp, rp;  // one extra bit tells full from empty
    assign empty   = (wp == rp);
    assign full    = (wp[DEPTH_LOG2] != rp[DEPTH_LOG2]) && (wp[DEPTH_LOG2-1:0] == rp[DEPTH_LOG2-1:0]);
    assign rd_data = mem[rp[DEPTH_LOG2-1:0]];
    always @(posedge clk) begin
        if (rst) begin
            wp <= 0;
            rp <= 0;
        end else begin
            if (wr_en && !full) begin
                mem[wp[DEPTH_LOG2-1:0]] <= wr_data;
                wp <= wp + 1;
            end
            if (rd_en && !empty) rp <= rp + 1;
        end
    end
endmodule
