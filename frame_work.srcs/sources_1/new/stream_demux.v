// ============================================================================
// Sub-module: Stream Demux (16:5 Ratio Control)
// ============================================================================
module stream_demux #(
    parameter AXI_WIDTH = 512,
    parameter VAL_BATCH = 16,
    parameter META_BATCH = 5
)(
    input  wire clk, rst_n,
    input  wire [AXI_WIDTH-1:0] s_tdata,
    input  wire s_tvalid,
    output reg  s_tready,
    
    output reg  val_wen, output reg [AXI_WIDTH-1:0] val_din, input wire val_full,
    output reg  meta_wen, output reg [AXI_WIDTH-1:0] meta_din, input wire meta_full
);
    localparam S_DATA = 0, S_META = 1;
    reg state, next_state;
    reg [4:0] cnt; // Max 16

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_DATA;
            cnt <= 0;
        end else if (s_tvalid && s_tready) begin
            state <= next_state;
            // 计数器逻辑
            if ((state == S_DATA && cnt == VAL_BATCH-1) || 
                (state == S_META && cnt == META_BATCH-1))
                cnt <= 0;
            else
                cnt <= cnt + 1;
        end
    end

    always @(*) begin
        next_state = state;
        s_tready = 0;
        val_wen = 0; meta_wen = 0;
        val_din = s_tdata; meta_din = s_tdata;

        case (state)
            S_DATA: begin
                s_tready = !val_full;
                if (s_tvalid && !val_full) begin
                    val_wen = 1;
                    if (cnt == VAL_BATCH-1) next_state = S_META;
                end
            end
            S_META: begin
                s_tready = !meta_full;
                if (s_tvalid && !meta_full) begin
                    meta_wen = 1;
                    if (cnt == META_BATCH-1) next_state = S_DATA;
                end
            end
        endcase
    end
endmodule