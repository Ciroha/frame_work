`timescale 1ns / 1ps

// ============================================================================
// Module: compute_pipeline
// 功能描述:
//   计算流水线 - 执行FP64乘法运算
//
// 工作原理:
//   - 并行执行PARALLELISM个FP64乘法
//   - 输入: 矩阵元素值 × X向量值
//   - 输出: 部分积(乘积结果)
//
// 流水线:
//   - 使用行为级real类型进行仿真(综合时需替换为浮点IP)
//   - 1周期乘法延迟
//
// 对称矩阵优化:
//   - 提供两路乘法路径(main和sym)用于对称矩阵优化
//   - main路径: 正常计算 A[row,col] * X[col]
//   - sym路径: 对称计算 A[row,col] * X[row]
// ============================================================================
module compute_pipeline #(
    // ========================================================================
    // 参数定义
    // ========================================================================
    parameter PARALLELISM = 8,          // 并行度(8个乘法器)
    parameter DATA_WIDTH  = 64          // 数据位宽(FP64)
)(
    input  wire clk,
    // 输入数据
    input  wire [PARALLELISM*DATA_WIDTH-1:0] matrix_values,   // 矩阵元素(8个FP64)
    input  wire [PARALLELISM*DATA_WIDTH-1:0] x_values_main,   // X向量主路径(8个FP64)
    input  wire [PARALLELISM*DATA_WIDTH-1:0] x_values_sym,    // X向量对称路径(8个FP64)

    // 输出部分积
    output wire [PARALLELISM*DATA_WIDTH-1:0] routed_products_main, // 主路径乘积
    output wire [PARALLELISM*DATA_WIDTH-1:0] routed_products_sym,  // 对称路径乘积
    output wire [PARALLELISM-1:0]            valid_mask_main,      // 主路径有效掩码
    output wire [PARALLELISM-1:0]            valid_mask_sym        // 对称路径有效掩码
);

    // ========================================================================
    // FP64乘法器阵列
    // 注意: 当前使用行为级real类型进行仿真
    // 综合时需要替换为Vivado浮点IP (floating_point multiplier)
    // ========================================================================

    genvar k;
    generate
        for (k = 0; k < PARALLELISM; k = k + 1) begin : gen_mult
            // 提取各通道数据
            wire [DATA_WIDTH-1:0] a = matrix_values[k*DATA_WIDTH +: DATA_WIDTH];
            wire [DATA_WIDTH-1:0] b_main = x_values_main[k*DATA_WIDTH +: DATA_WIDTH];
            wire [DATA_WIDTH-1:0] b_sym = x_values_sym[k*DATA_WIDTH +: DATA_WIDTH];

            // 行为级仿真保留 real 模型; 综合路径仅保留一拍占位寄存器。
            reg [DATA_WIDTH-1:0] prod_main;
            reg [DATA_WIDTH-1:0] prod_sym;

`ifndef SYNTHESIS
            real a_real;
            real b_main_real;
            real b_sym_real;
            real prod_main_real;
            real prod_sym_real;

            always @(*) begin
                a_real = $bitstoreal(a);
                b_main_real = $bitstoreal(b_main);
                b_sym_real = $bitstoreal(b_sym);
                prod_main_real = a_real * b_main_real;
                prod_sym_real = a_real * b_sym_real;
            end

            always @(posedge clk) begin
                prod_main <= $realtobits(prod_main_real);
                prod_sym <= $realtobits(prod_sym_real);
            end
`else
            always @(posedge clk) begin
                prod_main <= {DATA_WIDTH{1'b0}};
                prod_sym <= {DATA_WIDTH{1'b0}};
            end
`endif

            // 输出连接
            assign routed_products_main[k*DATA_WIDTH +: DATA_WIDTH] = prod_main;
            assign routed_products_sym[k*DATA_WIDTH +: DATA_WIDTH] = prod_sym;
            assign valid_mask_main[k] = 1'b1;  // 流水线满时始终有效
            assign valid_mask_sym[k] = 1'b1;
        end
    endgenerate

endmodule
