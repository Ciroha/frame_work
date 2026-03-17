`timescale 1ns / 1ps

// ============================================================================
// Module: x_mem_banks
// 功能描述:
//   X向量存储器组 - 存储X向量供SpMV计算使用
//
// 架构:
//   - 采用Banked存储结构,每个Bank存储一部分元素
//   - 支持并行随机读取(PARALLELISM个独立地址)
//   - 支持全局任意地址读取(用于对称矩阵优化)
//
// 存储容量:
//   - 每个Bank深度: DEPTH (默认4096)
//   - 总容量: DEPTH × PARALLELISM 个FP64元素
//
// 接口:
//   - Port A: 加载接口(线性写入)
//   - Port B: 计算接口(随机读取,每个Bank独立地址)
//   - Port C: 任意地址读取接口(全局地址,用于对称路径)
// ============================================================================
module x_mem_banks #(
    // ========================================================================
    // 参数定义
    // ========================================================================
    parameter PARALLELISM = 8,          // 并行度(Bank数量)
    parameter DATA_WIDTH  = 64,         // 数据位宽(FP64)
    parameter DEPTH       = 4096,       // 每个Bank深度(4K元素)
    parameter ADDR_WIDTH  = $clog2(DEPTH), // Bank地址位宽
    parameter GLOBAL_ADDR_WIDTH = $clog2(DEPTH * PARALLELISM) // 全局地址位宽
)(
    input  wire clk,

    // ========================================================================
    // Port A: 加载接口 (仅写入,线性访问)
    // 假设并行写入所有Bank (Broadside Load)
    // 数据打包格式: [Element 7, Element 6, ..., Element 0]
    // ========================================================================
    input  wire                                load_en,
    input  wire [ADDR_WIDTH-1:0]               load_addr,
    input  wire [PARALLELISM*DATA_WIDTH-1:0]   load_data,

    // ========================================================================
    // Port B: 计算接口 (仅读取,随机访问)
    // PARALLELISM个独立地址
    // ========================================================================
    input  wire [PARALLELISM*ADDR_WIDTH-1:0]   rd_addr_vec,
    output wire [PARALLELISM*DATA_WIDTH-1:0]   rd_data_vec,

    // ========================================================================
    // Port C: 任意地址读取接口
    // 使用全局地址索引,支持任意镜像读取(用于对称矩阵优化)
    // ========================================================================
    input  wire [PARALLELISM*GLOBAL_ADDR_WIDTH-1:0] arb_rd_global_idx_vec,
    output wire [PARALLELISM*DATA_WIDTH-1:0]        arb_rd_data_vec
);

    localparam integer TOTAL_ELEMS = DEPTH * PARALLELISM; // 总元素数

    // ========================================================================
    // Banked RAM结构 - 主路径读取
    // ========================================================================
    genvar k;
    generate
        for (k = 0; k < PARALLELISM; k = k + 1) begin : gen_banks

            // 提取该Bank的信号
            wire [DATA_WIDTH-1:0] bank_din = load_data[k*DATA_WIDTH +: DATA_WIDTH];
            wire [ADDR_WIDTH-1:0] bank_ra  = rd_addr_vec[k*ADDR_WIDTH +: ADDR_WIDTH];
            reg  [DATA_WIDTH-1:0] bank_dout;

            // 推断BRAM (Block RAM)
            (* ram_style = "block" *) reg [DATA_WIDTH-1:0] ram [0:DEPTH-1];

            always @(posedge clk) begin
                if (load_en) begin
                    ram[load_addr] <= bank_din;   // 写操作
                end
                // 读操作(1周期延迟)
                bank_dout <= ram[bank_ra];
            end

            assign rd_data_vec[k*DATA_WIDTH +: DATA_WIDTH] = bank_dout;

        end
    endgenerate

    // ========================================================================
    // 对称路径全局读取
    // 仿真保留任意地址模型；综合路径先占位为0，待后续替换为多端口/复制bank实现。
    // ========================================================================
`ifndef SYNTHESIS
    reg [DATA_WIDTH-1:0] flat_ram [0:TOTAL_ELEMS-1];
    reg [DATA_WIDTH-1:0] arb_dout [0:PARALLELISM-1];
    wire [GLOBAL_ADDR_WIDTH-1:0] arb_idx [0:PARALLELISM-1];

    generate
        for (k = 0; k < PARALLELISM; k = k + 1) begin : gen_arb_extract
            assign arb_idx[k] = arb_rd_global_idx_vec[k*GLOBAL_ADDR_WIDTH +: GLOBAL_ADDR_WIDTH];
            assign arb_rd_data_vec[k*DATA_WIDTH +: DATA_WIDTH] = arb_dout[k];
        end
    endgenerate

    integer i;
    always @(posedge clk) begin
        if (load_en) begin
            for (i = 0; i < PARALLELISM; i = i + 1) begin
                flat_ram[load_addr * PARALLELISM + i] <= load_data[i*DATA_WIDTH +: DATA_WIDTH];
            end
        end

        for (i = 0; i < PARALLELISM; i = i + 1) begin
            if (arb_idx[i] < TOTAL_ELEMS) begin
                arb_dout[i] <= flat_ram[arb_idx[i]];
            end else begin
                arb_dout[i] <= {DATA_WIDTH{1'b0}};
            end
        end
    end
`else
    wire unused_arb_addr;
    assign unused_arb_addr = &{1'b0, arb_rd_global_idx_vec};
    assign arb_rd_data_vec = {PARALLELISM*DATA_WIDTH{1'b0}};
`endif

endmodule
