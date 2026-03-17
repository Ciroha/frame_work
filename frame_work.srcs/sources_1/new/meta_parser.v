`timescale 1ns / 1ps

// ============================================================================
// Module: meta_parser
// 功能描述:
//   元数据解析器 - 将5拍512位输入扩展为16拍160位输出
//
// 工作原理:
//   - 采用双缓冲设计(cache0/cache1),实现流水线操作
//   - Fill阶段: 从FIFO读取5拍元数据填充一个缓存
//   - Emit阶段: 从缓存中切片输出16拍控制信号
//   - Fill和Emit交替使用两个缓存,消除气泡
//
// 元数据格式(每拍160位):
//   [15:0]   row_base    - 行基址
//   [31:16]  col_base    - 列基址
//   [159:32] row_deltas  - 8个行偏移量(每个16位)
//
// 输入: 5拍 x 512位 = 2560位
// 输出: 16拍 x 160位 = 2560位
// ============================================================================
module meta_parser #(
    // ========================================================================
    // 参数定义
    // ========================================================================
    parameter AXI_WIDTH = 512,          // AXI数据位宽
    parameter PARALLELISM = 8           // 并行度
)(
    input  wire clk, rst_n,
    input  wire [AXI_WIDTH-1:0] fifo_dout, // FIFO输出数据
    input  wire                 fifo_empty,// FIFO空标志
    output reg                  fifo_ren,  // FIFO读使能

    input  wire                 next_cycle_req, // 下游请求下一拍
    output reg                  parser_valid,   // 解析器输出有效

    output reg [15:0]           out_row_base,   // 输出行基址
    output reg [15:0]           out_col_base,   // 输出列基址
    output reg [PARALLELISM*16-1:0] out_row_delta // 输出行偏移数组
);

    // ========================================================================
    // 常量定义
    // ========================================================================
    localparam META_BATCH = 5;          // 元数据批大小(5拍)
    localparam OUT_W = PARALLELISM * 16 + 32; // 每拍输出位宽(160位)
    localparam EMIT_COUNT = (META_BATCH * AXI_WIDTH) / OUT_W; // 输出拍数(16拍)

    // ========================================================================
    // 双缓冲存储器
    // ========================================================================
    reg [AXI_WIDTH-1:0] cache0 [0:META_BATCH-1]; // 缓存0
    reg [AXI_WIDTH-1:0] cache1 [0:META_BATCH-1]; // 缓存1
    reg bank_ready0, bank_ready1;       // 缓存就绪标志

    // ========================================================================
    // Emit阶段控制
    // ========================================================================
    reg emit_active;                    // Emit活动标志
    reg emit_bank;                      // 当前Emit的缓存(0/1)
    reg [4:0] emit_ptr;                 // Emit指针(0..15)

    // ========================================================================
    // Fill阶段控制
    // ========================================================================
    reg fill_active;                    // Fill活动标志
    reg fill_bank;                      // 当前Fill的缓存(0/1)
    reg [2:0] fill_req_cnt;             // Fill请求计数(0..5)
    reg [2:0] fill_cap_cnt;             // Fill捕获计数(0..5)
    reg fifo_ren_d;                     // FIFO读使能延迟1拍

    // ========================================================================
    // 数据展平和切片
    // ========================================================================
    reg [META_BATCH*AXI_WIDTH-1:0] flattened_cache0; // 展平的缓存0
    reg [META_BATCH*AXI_WIDTH-1:0] flattened_cache1; // 展平的缓存1
    reg [OUT_W-1:0] current_slice;      // 当前切片
    integer i;

    // 将缓存数组展平为位向量,便于切片操作
    always @(*) begin
        for (i = 0; i < META_BATCH; i = i + 1) begin
            flattened_cache0[i*AXI_WIDTH +: AXI_WIDTH] = cache0[i];
            flattened_cache1[i*AXI_WIDTH +: AXI_WIDTH] = cache1[i];
        end
    end

    // 缓存数据本身不参与异步复位，避免综合成带set/reset的寄存器阵列。
    always @(posedge clk) begin
        if (fifo_ren_d) begin
            if (fill_bank == 1'b0) begin
                cache0[fill_cap_cnt] <= fifo_dout;
            end else begin
                cache1[fill_cap_cnt] <= fifo_dout;
            end
        end
    end

    // ========================================================================
    // 主状态机 - Fill和Emit控制
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // 复位
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

            // ============================================================
            // Fill阶段: 从FIFO连续读取5拍数据填充缓存
            // ============================================================
            if (fill_active && (fill_req_cnt < META_BATCH) && !fifo_empty) begin
                fifo_ren <= 1'b1;
                fill_req_cnt <= fill_req_cnt + 1'b1;
            end

            // FIFO有1周期读延迟,需要延迟捕获数据
            fifo_ren_d <= fifo_ren;
            if (fifo_ren_d) begin
                // 5拍全部接收完成
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

            // ============================================================
            // Emit阶段: 从缓存切片输出16拍控制信号
            // ============================================================
            if (emit_active && next_cycle_req) begin
                if (emit_ptr == EMIT_COUNT-1) begin
                    // 当前缓存Emit完成
                    if (emit_bank == 1'b0) begin
                        bank_ready0 <= 1'b0;
                        // 尝试切换到另一个就绪的缓存
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
                // 开始Emit: 当任意缓存就绪时启动
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

            // ============================================================
            // 预填充: 当非Emit的缓存空闲时开始填充
            // ============================================================
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

    // ========================================================================
    // 输出组合逻辑 - 切片并提取字段
    // ========================================================================
    always @(*) begin
        parser_valid = emit_active;
        if (emit_active) begin
            // 从当前缓存的emit_ptr位置切片160位
            if (emit_bank == 1'b0) begin
                current_slice = flattened_cache0[emit_ptr*OUT_W +: OUT_W];
            end else begin
                current_slice = flattened_cache1[emit_ptr*OUT_W +: OUT_W];
            end
        end else begin
            current_slice = {OUT_W{1'b0}};
        end

        // 提取各字段
        // 格式: {row_deltas[7:0], col_base, row_base}
        out_row_base = current_slice[15:0];
        for (i = 0; i < PARALLELISM; i = i + 1) begin
            out_row_delta[i*16 +: 16] = current_slice[32 + i*16 +: 16];
        end
        out_col_base = current_slice[31:16];
    end

endmodule
