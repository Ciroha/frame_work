`timescale 1ns / 1ps
// ============================================================================
// Sub-module: Metadata Parser (5 lines in -> 16 lines out)
// ============================================================================
module meta_parser #(
    parameter AXI_WIDTH = 512,
    parameter PARALLELISM = 8
)(
    input  wire clk, rst_n,
    input  wire [AXI_WIDTH-1:0] fifo_dout,
    input  wire                 fifo_empty,
    output reg                  fifo_ren,
    
    input  wire                 next_cycle_req,
    output reg                  parser_valid,
    
    output reg [15:0]           out_row_base,    // 16b Base
    output reg [15:0]           out_col_base,    // 16b Col Base
    output reg [PARALLELISM*16-1:0] out_row_delta  // 8x16b = 128b
);
    localparam META_BATCH = 5;
    localparam OUT_W = 160;
    localparam EMIT_COUNT = (META_BATCH * AXI_WIDTH) / OUT_W; // 16 cycles

    reg [AXI_WIDTH-1:0] cache0 [0:META_BATCH-1];
    reg [AXI_WIDTH-1:0] cache1 [0:META_BATCH-1];
    reg bank_ready0, bank_ready1;

    reg emit_active;
    reg emit_bank;
    reg [4:0] emit_ptr; // 0..15

    reg fill_active;
    reg fill_bank;
    reg [2:0] fill_req_cnt; // 0..5
    reg [2:0] fill_cap_cnt; // 0..5
    reg fifo_ren_d;

    reg [META_BATCH*AXI_WIDTH-1:0] flattened_cache0;
    reg [META_BATCH*AXI_WIDTH-1:0] flattened_cache1;
    reg [OUT_W-1:0] current_slice;
    integer i;
    always @(*) begin
        for (i = 0; i < META_BATCH; i = i + 1) begin
            flattened_cache0[i*AXI_WIDTH +: AXI_WIDTH] = cache0[i];
            flattened_cache1[i*AXI_WIDTH +: AXI_WIDTH] = cache1[i];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bank_ready0 <= 1'b0;
            bank_ready1 <= 1'b0;

            emit_active <= 1'b0;
            emit_bank <= 1'b0;
            emit_ptr <= 0;

            fill_active <= 1'b1;
            fill_bank <= 1'b0;
            fill_req_cnt <= 0;
            fill_cap_cnt <= 0;

            fifo_ren <= 1'b0;
            fifo_ren_d <= 1'b0;
        end else begin
            fifo_ren <= 1'b0;

            // Continuous request in fill stage (no forced bubble between reads).
            if (fill_active && (fill_req_cnt < META_BATCH) && !fifo_empty) begin
                fifo_ren <= 1'b1;
                fill_req_cnt <= fill_req_cnt + 1'b1;
            end

            // FIFO has 1-cycle read latency.
            fifo_ren_d <= fifo_ren;
            if (fifo_ren_d) begin
                if (fill_bank == 1'b0) begin
                    cache0[fill_cap_cnt] <= fifo_dout;
                end else begin
                    cache1[fill_cap_cnt] <= fifo_dout;
                end

                if (fill_cap_cnt == META_BATCH-1) begin
                    if (fill_bank == 1'b0) begin
                        bank_ready0 <= 1'b1;
                    end else begin
                        bank_ready1 <= 1'b1;
                    end
                    fill_active <= 1'b0;
                    fill_req_cnt <= 0;
                    fill_cap_cnt <= 0;
                end else begin
                    fill_cap_cnt <= fill_cap_cnt + 1'b1;
                end
            end

            // Emit current bank while the other bank can be filled.
            // When finishing a block, directly switch to the opposite ready bank
            // to remove the 1-cycle block-boundary bubble.
            if (emit_active && next_cycle_req) begin
                if (emit_ptr == EMIT_COUNT-1) begin
                    if (emit_bank == 1'b0) begin
                        bank_ready0 <= 1'b0;
                        if (bank_ready1) begin
                            emit_active <= 1'b1;
                            emit_bank <= 1'b1;
                            emit_ptr <= 0;
                        end else begin
                            emit_active <= 1'b0;
                            emit_ptr <= 0;
                        end
                    end else begin
                        bank_ready1 <= 1'b0;
                        if (bank_ready0) begin
                            emit_active <= 1'b1;
                            emit_bank <= 1'b0;
                            emit_ptr <= 0;
                        end else begin
                            emit_active <= 1'b0;
                            emit_ptr <= 0;
                        end
                    end
                end else begin
                    emit_ptr <= emit_ptr + 1'b1;
                end
            end else if (!emit_active) begin
                // Start emit when any full bank is ready.
                if (bank_ready0) begin
                    emit_active <= 1'b1;
                    emit_bank <= 1'b0;
                    emit_ptr <= 0;
                end else if (bank_ready1) begin
                    emit_active <= 1'b1;
                    emit_bank <= 1'b1;
                    emit_ptr <= 0;
                end
            end

            // Keep pre-filling the non-emitting bank when available.
            if (!fill_active) begin
                if (!bank_ready0 && !(emit_active && (emit_bank == 1'b0))) begin
                    fill_active <= 1'b1;
                    fill_bank <= 1'b0;
                    fill_req_cnt <= 0;
                    fill_cap_cnt <= 0;
                end else if (!bank_ready1 && !(emit_active && (emit_bank == 1'b1))) begin
                    fill_active <= 1'b1;
                    fill_bank <= 1'b1;
                    fill_req_cnt <= 0;
                    fill_cap_cnt <= 0;
                end
            end
        end
    end

    always @(*) begin
        parser_valid = emit_active;
        if (emit_active) begin
            if (emit_bank == 1'b0) begin
                current_slice = flattened_cache0[emit_ptr*OUT_W +: OUT_W];
            end else begin
                current_slice = flattened_cache1[emit_ptr*OUT_W +: OUT_W];
            end
        end else begin
            current_slice = {OUT_W{1'b0}};
        end

        out_row_base = current_slice[15:0];
        for (i = 0; i < PARALLELISM; i = i + 1) begin
            out_row_delta[i*16 +: 16] = current_slice[32 + i*16 +: 16];
        end
        out_col_base = current_slice[31:16];
    end

endmodule
