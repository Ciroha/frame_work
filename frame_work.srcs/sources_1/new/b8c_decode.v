`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/02/02 11:16:54
// Design Name: 
// Module Name: b8c_decode
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module b8c_decoder #(
    parameter AXI_WIDTH   = 512, // HBM Interface Width
    parameter PARALLELISM = 8,   // C=8 (8 parallel lanes)
    parameter VAL_BATCH   = 16,  // 16 lines of Values
    parameter META_BATCH  = 5    // 5 lines of Metadata
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // --- 1. Input: Combined Stream form HBM (Values + Metadata) ---
    input  wire [AXI_WIDTH-1:0]   s_axis_tdata,
    input  wire                   s_axis_tvalid,
    output wire                   s_axis_tready,

    // --- 2. Output: Decoded Streams to Compute Pipeline ---
    // 下游计算单元请求下一拍数据
    input  wire                   compute_req_next, 
    
    // 输出给乘法器的矩阵数值
    output wire [AXI_WIDTH-1:0]   m_vals_data,   // 8x FP64
    
    // 输出给 X Memory 的列索引 (用于寻址)
    // output wire [PARALLELISM*16-1:0] m_col_indices, // REMOVED
    
    // 输出给 Accumulator 的行偏移 (用于路由)
    output wire [PARALLELISM*16-1:0]  m_row_deltas,  // 8x 16-bit
    output wire [15:0]                m_row_base,    // 16-bit Base
    output wire [15:0]                m_col_base,    // 16-bit Col Base
    
    // 全局有效信号 (当数值和解析后的元数据都准备好时置 1)
    output wire                   decoder_valid
);

    // 内部信号
    wire [AXI_WIDTH-1:0] val_fifo_din, val_fifo_dout;
    wire [AXI_WIDTH-1:0] meta_fifo_din, meta_fifo_dout;
    wire val_wen, val_full, val_empty, val_ren;
    wire meta_wen, meta_full, meta_empty, meta_ren;
    
    wire parser_ready;
    wire [15:0]               parser_row_base;
    wire [15:0]               parser_col_base;
    wire [PARALLELISM*16-1:0] parser_row_delta;

    // =========================================================
    // Sub-module 1: Stream Demux (16 Data : 5 Metadata)
    // =========================================================
    // 负责将混合流拆分写入两个 FIFO
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
    // Sub-module 2: Dual FIFOs
    // =========================================================
    // Values FIFO (深度较大，因为数据量大)
    simple_sync_fifo #(.WIDTH(AXI_WIDTH), .DEPTH(512)) u_fifo_vals (
        .clk(clk), .rst_n(rst_n),
        .wen(val_wen), .din(val_fifo_din), .full(val_full),
        .ren(val_ren), .dout(val_fifo_dout), .empty(val_empty)
    );

    // Metadata FIFO (深度较小，因为只有 5/16 的量)
    simple_sync_fifo #(.WIDTH(AXI_WIDTH), .DEPTH(128)) u_fifo_meta (
        .clk(clk), .rst_n(rst_n),
        .wen(meta_wen), .din(meta_fifo_din), .full(meta_full),
        .ren(meta_ren), .dout(meta_fifo_dout), .empty(meta_empty)
    );

    // =========================================================
    // Sub-module 3: Metadata Parser (The Expander)
    // =========================================================
    // 负责从 Meta FIFO 读 5 行，吐出 16 行控制信号
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
    // Output Logic & Handshake
    // =========================================================
    // 只有当 Data FIFO 有数，且 Parser 解析完毕时，输出才有效
    assign decoder_valid = (!val_empty) && parser_ready;
    
    // 当下游请求数据，且我们也准备好了时，读取 FIFO 并推进 Parser
    assign val_ren = compute_req_next && decoder_valid;

    // 输出赋值
    assign m_vals_data = val_fifo_dout;
    // assign m_col_indices = parser_col_idx;
    assign m_row_deltas = parser_row_delta;
    assign m_row_base   = parser_row_base;
    assign m_col_base   = parser_col_base;

endmodule
