`timescale 1ns / 1ps

// ============================================================================
// Module: id_unpack_parser
// 功能描述:
//   ID解包解析器 - 将2拍512位ID输入扩展为16拍64位输出
//
// 工作原理:
//   - 采用双缓冲设计(cache0/cache1),实现流水线操作
//   - Fill阶段: 从FIFO读取2拍ID数据填充一个缓存
//   - Emit阶段: 从缓存中切片输出16拍ID向量
//   - Fill和Emit交替使用两个缓存,消除气泡
//
// ID数据格式:
//   输入: 2拍 x 512位 = 1024位 = 128个8位ID
//   输出: 16拍 x 64位 = 1024位 = 16拍,每拍8个8位ID
//
// 用途:
//   用于MODE_ID52模式,将压缩的8位ID解包后送LUT转换为FP64
// ============================================================================
module id_unpack_parser #(
    // ========================================================================
    // 参数定义
    // ========================================================================
    parameter AXI_WIDTH = 512,          // AXI数据位宽
    parameter ID_BATCH = 2,             // ID批大小(2拍)
    parameter PARALLELISM = 8,          // 并行度
    parameter ID_WIDTH = 8              // ID位宽(8位)
)(
    input  wire clk,
    input  wire rst_n,
    input  wire [AXI_WIDTH-1:0] fifo_dout, // FIFO输出数据
    input  wire                 fifo_empty,// FIFO空标志
    output reg                  fifo_ren,  // FIFO读使能

    input  wire                 next_cycle_req, // 下游请求下一拍
    output reg                  parser_valid,   // 解析器输出有效
    output reg [PARALLELISM*ID_WIDTH-1:0] out_id_vec // 输出ID向量(8个ID)
);

    // ========================================================================
    // 常量定义
    // ========================================================================
    localparam OUT_W = PARALLELISM * ID_WIDTH; // 每拍输出位宽(64位=8个ID)
    localparam EMIT_COUNT = (ID_BATCH * AXI_WIDTH) / OUT_W; // 输出拍数(16拍)

    // ========================================================================
    // 双缓冲存储器
    // ========================================================================
    reg [AXI_WIDTH-1:0] cache0 [0:ID_BATCH-1]; // 缓存0
    reg [AXI_WIDTH-1:0] cache1 [0:ID_BATCH-1]; // 缓存1
    reg bank_ready0, bank_ready1;       // 缓存就绪标志

    // ========================================================================
    // Emit阶段控制
    // ========================================================================
    reg emit_active;                    // Emit活动标志
    reg emit_bank;                      // 当前Emit的缓存(0/1)
    reg [5:0] emit_ptr;                 // Emit指针(0..15)

    // ========================================================================
    // Fill阶段控制
    // ========================================================================
    reg fill_active;                    // Fill活动标志
    reg fill_bank;                      // 当前Fill的缓存(0/1)
    reg [2:0] fill_req_cnt;             // Fill请求计数(0..2)
    reg [2:0] fill_cap_cnt;             // Fill捕获计数(0..2)
    reg fifo_ren_d;                     // FIFO读使能延迟1拍

    // ========================================================================
    // 数据展平和切片
    // ========================================================================
    reg [ID_BATCH*AXI_WIDTH-1:0] flattened_cache0; // 展平的缓存0
    reg [ID_BATCH*AXI_WIDTH-1:0] flattened_cache1; // 展平的缓存1
    reg [OUT_W-1:0] current_slice;      // 当前切片

    integer i;

    // 将缓存数组展平为位向量,便于切片操作
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
            out_id_vec = current_slice;
        end else begin
            current_slice = {OUT_W{1'b0}};
            out_id_vec = {OUT_W{1'b0}};
        end
    end

endmodule
