`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/02/02 10:00:32
// Design Name: 
// Module Name: b8c_top
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

module b8c_top #(
    parameter PARALLELISM = 8,       // 论文中的 C=8
    parameter DATA_WIDTH  = 64,      // FP64
    parameter ADDR_WIDTH  = 13,      // 8K 元素块大小
    parameter AXI_WIDTH   = 512      // HBM 接口位宽
)(
    input  wire clk,
    input  wire rst_n,

    // --- 1. AXI4-Stream Input (来自 HBM 的 b8c 数据流) ---
    // 包含：Matrix Values, Metadata (Row/Col indices)
    // 实际工程中，这些通常打包在 512-bit 总线中，需要解包
    input  wire [AXI_WIDTH-1:0]    s_axis_tdata,
    input  wire                    s_axis_tvalid,
    output wire                    s_axis_tready,

    // --- 2. DDR/HBM Interface for Vector Y (读/写) ---
    // 简化为读写端口，实际需对接 AXI4 Master
    output wire [PARALLELISM*DATA_WIDTH-1:0] m_y_wdata,
    output wire [PARALLELISM*ADDR_WIDTH-1:0] m_y_waddr,
    output wire [PARALLELISM-1:0]            m_y_wen,
    
    // --- 3. Vector X Load Interface (预加载) ---
    input  wire [PARALLELISM*DATA_WIDTH-1:0] s_x_preload_data,
    input  wire [PARALLELISM*ADDR_WIDTH-1:0] s_x_preload_addr,
    input  wire                              s_x_preload_en
    );

// =========================================================
    // 内部信号连接
    // =========================================================
    // 解包后的信号
    wire [PARALLELISM*DATA_WIDTH-1:0] matrix_values;
    wire [PARALLELISM*16-1:0]         meta_col_indices; // 用于 X 寻址
    wire [PARALLELISM*8-1:0]          meta_row_deltas;  // 用于结果路由

    // X 向量读取结果
    wire [PARALLELISM*DATA_WIDTH-1:0] x_read_data;

    // 乘法器输出
    wire [PARALLELISM*DATA_WIDTH-1:0] partial_products;
    wire [PARALLELISM-1:0]            pp_valid;

    // 新增信号声明
    wire [15:0] meta_row_base;
    wire [15:0] meta_col_base;
    wire decoder_val;

    // =========================================================
    // 模块 1: Stream Decoder (数据解包与控制)
    // =========================================================
    // 作用：将 512-bit HBM 数据流拆解为 Values 和 Metadata
    // 论文 Section III.B.4: "combine data and metadata in a single stream"
    b8c_decoder #(
        .AXI_WIDTH(AXI_WIDTH),
        .PARALLELISM(PARALLELISM)
    ) u_decoder (
        .clk(clk),
        .rst_n(rst_n),
        
        // Input Stream
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        
        // Handshake / Control
        .compute_req_next(1'b1), // Always request next data (Pipeline mode)
        .decoder_valid(decoder_val),
        
        // Outputs
        .m_vals_data(matrix_values),
        .m_row_deltas(meta_row_deltas),
        .m_row_base(meta_row_base),
        .m_col_base(meta_col_base)
    );
    
    // Logic: 生成列索引
    // ColBase 是 Stripe 的起始列，Super-row 的 8 个元素对应 ColBase + 0 .. 7
    genvar k;
    generate
        for (k=0; k<PARALLELISM; k=k+1) begin : gen_col_indices
            assign meta_col_indices[k*16 +: 16] = meta_col_base + k;
        end
    endgenerate

    // =========================================================
    // 模块 2: X-Vector Banked Memory (并行读取)
    // =========================================================
    // 作用：存储向量 X，支持并行随机读取 (Cyclic Partition)
    // 论文 Section IV.A
    x_mem_banks #(
        .PARALLELISM(PARALLELISM)
    ) u_x_mem (
        .clk(clk),
        .rst_n(rst_n),
        // 预加载端口 (Pre-fetching)
        .wr_en({PARALLELISM{s_x_preload_en}}),
        .wr_addr(s_x_preload_addr),
        .wr_data(s_x_preload_data),
        // 计算读取端口 (由 Metadata 驱动)
        .rd_addr(meta_col_indices),
        .rd_data(x_read_data)
    );

    // =========================================================
    // 模块 3: Compute Pipeline (乘法 + 路由)
    // =========================================================
    // 作用：执行 A * x，并将结果路由到正确的累加器行
    // 论文 Section IV.B: "8 x [8 x 8:1 mux]"
    compute_pipeline #(
        .PARALLELISM(PARALLELISM)
    ) u_compute (
        .clk(clk),
        .matrix_values(matrix_values),
        .x_values(x_read_data),
        .dest_row_idx(meta_row_deltas), // 控制 Mux
        .routed_products(partial_products),
        .valid_mask(pp_valid)
    );

    // =========================================================
    // 模块 4: Y-Vector Accumulators (加法树 + 回写)
    // =========================================================
    // 作用：累加部分积，更新 Y 值
    // 论文 Section IV.B.2 & 3
    y_acc_banks #(
        .PARALLELISM(PARALLELISM)
    ) u_y_acc (
        .clk(clk),
        .rst_n(rst_n),
        .partial_products(partial_products),
        .pp_valid(pp_valid),
        // 简化：假设 row_deltas 同时也映射了 Y 的局部地址
        .y_local_addr(meta_row_deltas), 
        
        .wb_data(m_y_wdata),
        .wb_addr(m_y_waddr),
        .wb_en(m_y_wen)
    );


endmodule
