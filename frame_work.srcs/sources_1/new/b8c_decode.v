`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: b8c_decoder
//////////////////////////////////////////////////////////////////////////////////
// 功能描述:
//   SpMV解码器模块 - 传统模式
//   将混合的数据流(16拍FP64数据 + 5拍元数据)拆分并解码为计算所需的格式
//
// 数据格式:
//   输入: [FP64数据拍 x 16] [元数据拍 x 5] ... (重复)
//   输出: 8个FP64矩阵值 + 8个行偏移 + 行基址 + 列基址 (每拍)
//
// 架构:
//   1. stream_demux: 流解复用器，将数据流分离为数值流和元数据流
//   2. 双FIFO: 分别缓存数值和元数据
//   3. meta_parser: 元数据解析器，将5拍元数据扩展为16拍控制信号
//
// 元数据格式(每160位):
//   [15:0]   row_base    - 行基址
//   [31:16]  col_base    - 列基址
//   [159:32] row_deltas  - 8个行偏移量(每个16位)
//////////////////////////////////////////////////////////////////////////////////

module b8c_decoder #(
    // ========================================================================
    // 参数定义
    // ========================================================================
    parameter AXI_WIDTH   = 512,   // HBM接口位宽(512位)
    parameter PARALLELISM = 8,     // 并行度(C=8, 8个并行计算通道)
    parameter VAL_BATCH   = 16,    // 数值批大小(16拍FP64数据)
    parameter META_BATCH  = 5      // 元数据批大小(5拍元数据)
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // --- 1. 输入接口: 来自HBM的混合流 (数值 + 元数据) ---
    input  wire [AXI_WIDTH-1:0]   s_axis_tdata,
    input  wire                   s_axis_tvalid,
    output wire                   s_axis_tready,

    // --- 2. 输出接口: 解码后的数据送计算流水线 ---
    // 下游计算单元请求下一拍数据
    input  wire                   compute_req_next,

    // 输出给乘法器的矩阵数值 (8个FP64)
    output wire [AXI_WIDTH-1:0]   m_vals_data,

    // 输出给Accumulator的行偏移 (用于路由)
    output wire [PARALLELISM*16-1:0]  m_row_deltas,  // 8x 16-bit行偏移
    output wire [15:0]                m_row_base,    // 16-bit行基址
    output wire [15:0]                m_col_base,    // 16-bit列基址

    // 全局有效信号 (当数值和解析后的元数据都准备好时置1)
    output wire                   decoder_valid,

    // 流水线空闲信号: 数值FIFO为空时表示所有数据已消费
    output wire                   o_pipeline_idle
);

    // ========================================================================
    // 内部信号定义
    // ========================================================================
    wire [AXI_WIDTH-1:0] val_fifo_din, val_fifo_dout;  // 数值FIFO数据
    wire [AXI_WIDTH-1:0] meta_fifo_din, meta_fifo_dout; // 元数据FIFO数据
    wire val_wen, val_full, val_empty, val_ren;        // 数值FIFO控制信号
    wire meta_wen, meta_full, meta_empty, meta_ren;    // 元数据FIFO控制信号

    wire parser_ready;                                  // 解析器就绪信号
    wire [15:0]               parser_row_base;         // 解析后的行基址
    wire [15:0]               parser_col_base;         // 解析后的列基址
    wire [PARALLELISM*16-1:0] parser_row_delta;        // 解析后的行偏移数组
    reg                       val_stage_valid;         // 数值FIFO读出后对齐到当前拍的有效标志
    reg [15:0]                meta_row_base_stage;     // 与val_fifo_dout对齐的行基址
    reg [15:0]                meta_col_base_stage;     // 与val_fifo_dout对齐的列基址
    reg [PARALLELISM*16-1:0]  meta_row_delta_stage;    // 与val_fifo_dout对齐的行偏移
    wire                      decoder_consume;
    wire                      val_issue_read;

    // =========================================================
    // 子模块1: 流解复用器 (16数据 : 5元数据)
    // =========================================================
    // 功能: 将混合流按照16:5的比例拆分写入两个FIFO
    stream_demux #(
        .AXI_WIDTH(AXI_WIDTH),
        .VAL_BATCH(VAL_BATCH),
        .META_BATCH(META_BATCH)
    ) u_demux (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(s_axis_tdata),
        .s_tvalid(s_axis_tvalid),
        .s_tready(s_axis_tready),
        
        .val_wen(val_wen), .val_din(val_fifo_din), .val_full(val_full),
        .meta_wen(meta_wen), .meta_din(meta_fifo_din), .meta_full(meta_full)
    );

    // =========================================================
    // 子模块2: 双FIFO缓存
    // =========================================================
    // 数值FIFO - 深度较大(512),因为数据量大(16/21 ≈ 76%)
    simple_sync_fifo #(.WIDTH(AXI_WIDTH), .DEPTH(512)) u_fifo_vals (
        .clk(clk), .rst_n(rst_n),
        .wen(val_wen), .din(val_fifo_din), .full(val_full),
        .ren(val_ren), .dout(val_fifo_dout), .empty(val_empty)
    );

    // 元数据FIFO - 深度较小(128),因为数据量小(5/21 ≈ 24%)
    simple_sync_fifo #(.WIDTH(AXI_WIDTH), .DEPTH(128)) u_fifo_meta (
        .clk(clk), .rst_n(rst_n),
        .wen(meta_wen), .din(meta_fifo_din), .full(meta_full),
        .ren(meta_ren), .dout(meta_fifo_dout), .empty(meta_empty)
    );

    // =========================================================
    // 子模块3: 元数据解析器 (扩展器)
    // =========================================================
    // 功能: 从Meta FIFO读取5拍数据,输出16拍控制信号
    // 解析格式: 每拍160位 = {row_base, col_base, row_deltas[7:0]}
    meta_parser #(
        .AXI_WIDTH(AXI_WIDTH),
        .PARALLELISM(PARALLELISM)
    ) u_parser (
        .clk(clk), .rst_n(rst_n),
        .fifo_dout(meta_fifo_dout),
        .fifo_empty(meta_empty),
        .fifo_ren(meta_ren),
        
        .next_cycle_req(val_ren), // 当数据 FIFO 被读取时，Parser 也推进一步
        .parser_valid(parser_ready), // Parser 准备好当前拍的控制信号
        
        .out_row_base(parser_row_base),
        .out_col_base(parser_col_base),
        .out_row_delta(parser_row_delta)
    );

    // =========================================================
    // 输出逻辑与握手控制
    // =========================================================
    // simple_sync_fifo 读口有1拍延迟；因此需要把 metadata 先暂存一拍，
    // 再与下一拍出现的 val_fifo_dout 对齐输出。
    assign decoder_valid = val_stage_valid;
    assign decoder_consume = compute_req_next && decoder_valid;
    assign val_issue_read = parser_ready && !val_empty && (!val_stage_valid || decoder_consume);

    // 当需要装填新的对齐拍时，读取FIFO并推进解析器。
    assign val_ren = val_issue_read;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            val_stage_valid <= 1'b0;
            meta_row_base_stage <= 16'd0;
            meta_col_base_stage <= 16'd0;
            meta_row_delta_stage <= {PARALLELISM*16{1'b0}};
        end else begin
            if (val_issue_read) begin
                meta_row_base_stage <= parser_row_base;
                meta_col_base_stage <= parser_col_base;
                meta_row_delta_stage <= parser_row_delta;
            end

            if (val_stage_valid && !decoder_consume && !val_issue_read) begin
                val_stage_valid <= 1'b1;
            end else begin
                val_stage_valid <= val_issue_read;
            end
        end
    end

    // 输出赋值
    assign m_vals_data = val_fifo_dout;             // 数值来自FIFO读出结果
    assign m_row_deltas = meta_row_delta_stage;     // 行偏移与数值对齐
    assign m_row_base   = meta_row_base_stage;      // 行基址与数值对齐
    assign m_col_base   = meta_col_base_stage;      // 列基址与数值对齐

    // 流水线空闲: 无待读数据且无已对齐待消费的数据
    assign o_pipeline_idle = val_empty && !val_stage_valid;

`ifndef SYNTHESIS
    reg stats_active;
    reg stats_reported;
    reg [31:0] id_empty_cycles;
    reg [31:0] id_full_cycles;
    reg [31:0] meta_empty_cycles;
    reg [31:0] meta_full_cycles;
    reg [31:0] pair_wait_cycles;
    reg [31:0] consume_cycles;
    reg [31:0] decoder_valid_cycles;
    reg [31:0] compute_req_cycles;
    reg [31:0] compute_backpressure_cycles;
    reg [31:0] no_decoder_valid_cycles;
    reg [31:0] both_ready_cycles;
    reg [31:0] both_empty_cycles;
    reg [31:0] id_only_wait_cycles;
    reg [31:0] meta_only_wait_cycles;
    reg [31:0] id_q_occupancy_sum;
    reg [31:0] meta_q_occupancy_sum;
    reg [31:0] id_q_occupancy_max;
    reg [31:0] meta_q_occupancy_max;

    wire stats_start = val_wen || meta_wen;
    wire stats_id_empty = val_empty && !val_stage_valid;
    wire stats_id_full = val_full;
    wire stats_meta_empty = !parser_ready;
    wire stats_meta_full = meta_full;
    wire stats_pair_wait = stats_id_empty ^ stats_meta_empty;
    wire stats_decoder_valid = decoder_valid;
    wire stats_consume = decoder_consume;
    wire stats_both_ready = !stats_id_empty && !stats_meta_empty;
    wire stats_both_empty = stats_id_empty && stats_meta_empty;
    wire stats_id_only_wait = !stats_id_empty && stats_meta_empty;
    wire stats_meta_only_wait = stats_id_empty && !stats_meta_empty;
    wire stats_compute_backpressure = decoder_valid && !compute_req_next;
    wire stats_done = stats_active && !stats_reported && o_pipeline_idle && !s_axis_tvalid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stats_active <= 1'b0;
            stats_reported <= 1'b0;
            id_empty_cycles <= 32'd0;
            id_full_cycles <= 32'd0;
            meta_empty_cycles <= 32'd0;
            meta_full_cycles <= 32'd0;
            pair_wait_cycles <= 32'd0;
            consume_cycles <= 32'd0;
            decoder_valid_cycles <= 32'd0;
            compute_req_cycles <= 32'd0;
            compute_backpressure_cycles <= 32'd0;
            no_decoder_valid_cycles <= 32'd0;
            both_ready_cycles <= 32'd0;
            both_empty_cycles <= 32'd0;
            id_only_wait_cycles <= 32'd0;
            meta_only_wait_cycles <= 32'd0;
            id_q_occupancy_sum <= 32'd0;
            meta_q_occupancy_sum <= 32'd0;
            id_q_occupancy_max <= 32'd0;
            meta_q_occupancy_max <= 32'd0;
        end else begin
            if (stats_start && !stats_active && !stats_reported) begin
                stats_active <= 1'b1;
            end

            if (stats_active && !stats_done) begin
                if (stats_id_empty) id_empty_cycles <= id_empty_cycles + 1'b1;
                if (stats_id_full) id_full_cycles <= id_full_cycles + 1'b1;
                if (stats_meta_empty) meta_empty_cycles <= meta_empty_cycles + 1'b1;
                if (stats_meta_full) meta_full_cycles <= meta_full_cycles + 1'b1;
                if (stats_pair_wait) pair_wait_cycles <= pair_wait_cycles + 1'b1;
                if (stats_consume) consume_cycles <= consume_cycles + 1'b1;
                if (stats_decoder_valid) decoder_valid_cycles <= decoder_valid_cycles + 1'b1;
                if (compute_req_next) compute_req_cycles <= compute_req_cycles + 1'b1;
                if (stats_compute_backpressure) compute_backpressure_cycles <= compute_backpressure_cycles + 1'b1;
                if (!stats_decoder_valid) no_decoder_valid_cycles <= no_decoder_valid_cycles + 1'b1;
                if (stats_both_ready) both_ready_cycles <= both_ready_cycles + 1'b1;
                if (stats_both_empty) both_empty_cycles <= both_empty_cycles + 1'b1;
                if (stats_id_only_wait) id_only_wait_cycles <= id_only_wait_cycles + 1'b1;
                if (stats_meta_only_wait) meta_only_wait_cycles <= meta_only_wait_cycles + 1'b1;
            end

            if (stats_done) begin
                stats_active <= 1'b0;
                stats_reported <= 1'b1;
                $display("DEC_STATS id_empty=%0d id_full=%0d meta_empty=%0d meta_full=%0d pair_wait=%0d consume=%0d",
                         id_empty_cycles, id_full_cycles, meta_empty_cycles, meta_full_cycles, pair_wait_cycles, consume_cycles);
                $display("DEC_DETAIL_STATS decoder_valid=%0d compute_req=%0d compute_backpressure=%0d no_decoder_valid=%0d both_ready=%0d both_empty=%0d id_only_wait=%0d meta_only_wait=%0d id_q_sum=%0d meta_q_sum=%0d id_q_max=%0d meta_q_max=%0d",
                         decoder_valid_cycles, compute_req_cycles, compute_backpressure_cycles, no_decoder_valid_cycles,
                         both_ready_cycles, both_empty_cycles, id_only_wait_cycles, meta_only_wait_cycles,
                         id_q_occupancy_sum, meta_q_occupancy_sum, id_q_occupancy_max, meta_q_occupancy_max);
            end
        end
    end
`endif

endmodule
