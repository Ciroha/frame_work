`timescale 1ns / 1ps

// ============================================================================
// Sub-module: ID Unpack Parser (2x512b in -> 16x64b out)
// ============================================================================
module id_unpack_parser #(
    parameter AXI_WIDTH = 512,
    parameter ID_BATCH = 2,
    parameter PARALLELISM = 8,
    parameter ID_WIDTH = 8
)(
    input  wire clk,
    input  wire rst_n,
    input  wire [AXI_WIDTH-1:0] fifo_dout,
    input  wire                 fifo_empty,
    output reg                  fifo_ren,

    input  wire                 next_cycle_req,
    output reg                  parser_valid,
    output reg [PARALLELISM*ID_WIDTH-1:0] out_id_vec
);
    localparam OUT_W = PARALLELISM * ID_WIDTH; // 64 bits for 8 lanes x 8-bit IDs
    localparam EMIT_COUNT = (ID_BATCH * AXI_WIDTH) / OUT_W; // 16 cycles for 2x512 -> 16x64

    reg [AXI_WIDTH-1:0] cache0 [0:ID_BATCH-1];
    reg [AXI_WIDTH-1:0] cache1 [0:ID_BATCH-1];
    reg bank_ready0, bank_ready1;

    reg emit_active;
    reg emit_bank;
    reg [5:0] emit_ptr;

    reg fill_active;
    reg fill_bank;
    reg [2:0] fill_req_cnt;
    reg [2:0] fill_cap_cnt;
    reg fifo_ren_d;

    reg [ID_BATCH*AXI_WIDTH-1:0] flattened_cache0;
    reg [ID_BATCH*AXI_WIDTH-1:0] flattened_cache1;
    reg [OUT_W-1:0] current_slice;

    integer i;
    always @(*) begin
        for (i = 0; i < ID_BATCH; i = i + 1) begin
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
            if (fill_active && (fill_req_cnt < ID_BATCH) && !fifo_empty) begin
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

                if (fill_cap_cnt == ID_BATCH-1) begin
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
            if (emit_active && next_cycle_req) begin
                if (emit_ptr == EMIT_COUNT-1) begin
                    if (emit_bank == 1'b0) begin
                        bank_ready0 <= 1'b0;
                    end else begin
                        bank_ready1 <= 1'b0;
                    end
                    emit_active <= 1'b0;
                    emit_ptr <= 0;
                end else begin
                    emit_ptr <= emit_ptr + 1'b1;
                end
            end

            // Start emit when any full bank is ready.
            if (!emit_active) begin
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
            out_id_vec = current_slice;
        end else begin
            current_slice = {OUT_W{1'b0}};
            out_id_vec = {OUT_W{1'b0}};
        end
    end

endmodule
