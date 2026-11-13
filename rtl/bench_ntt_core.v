// Out-of-context measurement wrapper for ntt_core: registers every port so that all timed paths
// are register to register. Resource numbers are read for the u_core instance only
// (route_util_hier.rpt). The trace taps are left unconnected and are removed by synthesis.
module bench_ntt_core #(
    parameter P = 1,
    parameter DIL_SPECIAL = 0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [1:0]  op,
    input  wire        scheme,
    input  wire [1:0]  buf_sel,
    output reg         busy,
    output reg         done,
    output reg  [31:0] cycles,
    input  wire        h_we,
    input  wire        h_re,
    input  wire [1:0]  h_buf,
    input  wire [7:0]  h_idx,
    input  wire [22:0] h_wdata,
    output reg  [22:0] h_rdata
);
    reg        r_rst, r_start, r_scheme, r_we, r_re;
    reg [1:0]  r_op, r_buf, r_hbuf;
    reg [7:0]  r_idx;
    reg [22:0] r_wdata;
    wire       w_busy, w_done;
    wire [31:0] w_cycles;
    wire [22:0] w_rdata;
    always @(posedge clk) begin
        r_rst <= rst; r_start <= start; r_scheme <= scheme; r_op <= op; r_buf <= buf_sel;
        r_we <= h_we; r_re <= h_re; r_hbuf <= h_buf; r_idx <= h_idx; r_wdata <= h_wdata;
        busy <= w_busy; done <= w_done; cycles <= w_cycles; h_rdata <= w_rdata;
    end
    ntt_core #(.P(P), .DIL_SPECIAL(DIL_SPECIAL)) u_core (
        .clk(clk), .rst(r_rst), .start(r_start), .op(r_op), .scheme(r_scheme), .buf_sel(r_buf),
        .busy(w_busy), .done(w_done), .cycles(w_cycles),
        .h_we(r_we), .h_re(r_re), .h_buf(r_hbuf), .h_idx(r_idx), .h_wdata(r_wdata), .h_rdata(w_rdata),
        .dbg_issue(), .dbg_kind(), .dbg_u(), .dbg_v(), .dbg_we(), .dbg_waddr(), .dbg_wdata()
    );
endmodule
