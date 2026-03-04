`timescale 1ns / 1ps

// ============================================================================
// Sub-module: Stream Demux for ID:Meta = 2:5
// ============================================================================
module stream_demux_id52 #(
    parameter AXI_WIDTH = 512,
    parameter VAL_ID_BATCH = 2,
    parameter META_BATCH = 5
)(
    input  wire clk,
    input  wire rst_n,
    input  wire [AXI_WIDTH-1:0] s_tdata,
    input  wire s_tvalid,
    output reg  s_tready,

    output reg  val_wen,
    output reg  [AXI_WIDTH-1:0] val_din,
    input  wire val_full,

    output reg  meta_wen,
    output reg  [AXI_WIDTH-1:0] meta_din,
    input  wire meta_full
);
    localparam S_ID = 1'b0;
    localparam S_META = 1'b1;

    reg state, next_state;
    reg [3:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_ID;
            cnt <= 0;
        end else if (s_tvalid && s_tready) begin
            state <= next_state;
            if ((state == S_ID && cnt == VAL_ID_BATCH-1) ||
                (state == S_META && cnt == META_BATCH-1)) begin
                cnt <= 0;
            end else begin
                cnt <= cnt + 1'b1;
            end
        end
    end

    always @(*) begin
        next_state = state;
        s_tready = 1'b0;
        val_wen = 1'b0;
        meta_wen = 1'b0;
        val_din = s_tdata;
        meta_din = s_tdata;

        case (state)
            S_ID: begin
                s_tready = !val_full;
                if (s_tvalid && !val_full) begin
                    val_wen = 1'b1;
                    if (cnt == VAL_ID_BATCH-1) begin
                        next_state = S_META;
                    end
                end
            end
            S_META: begin
                s_tready = !meta_full;
                if (s_tvalid && !meta_full) begin
                    meta_wen = 1'b1;
                    if (cnt == META_BATCH-1) begin
                        next_state = S_ID;
                    end
                end
            end
            default: begin
                next_state = S_ID;
            end
        endcase
    end

endmodule

