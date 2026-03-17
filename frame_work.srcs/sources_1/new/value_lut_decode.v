`timescale 1ns / 1ps

// ============================================================================
// Module: value_lut_decode
// 功能描述:
//   值LUT解码器 - 将8位ID通过查找表转换为FP64值
//
// 工作原理:
//   - 使用分布式ROM(Distributed RAM)存储查找表
//   - 8位ID可索引256个FP64值
//   - 并行处理PARALLELISM个ID,每个周期输出8个FP64值
//
// 用途:
//   用于MODE_ID52模式,实现矩阵元素值压缩存储
//   将8位索引通过LUT还原为64位FP64值
// ============================================================================
module value_lut_decode #(
    // ========================================================================
    // 参数定义
    // ========================================================================
    parameter PARALLELISM = 8,          // 并行度(8个ID同时转换)
    parameter ID_WIDTH = 8,             // ID位宽(8位,可索引256个值)
    parameter DATA_WIDTH = 64,          // 输出数据位宽(FP64)
    parameter LUT_INIT_FILE = ""        // LUT初始化文件路径
)(
    input  wire [PARALLELISM*ID_WIDTH-1:0] id_vec,    // 输入ID向量(8个ID)
    output wire [PARALLELISM*DATA_WIDTH-1:0] fp_vec   // 输出FP64向量(8个FP64)
);

    // ========================================================================
    // LUT存储器
    // ========================================================================
    localparam LUT_SIZE = (1 << ID_WIDTH); // LUT大小(256项)

    // 使用分布式RAM存储LUT(综合时会被映射为LUT RAM)
    (* rom_style = "distributed" *) reg [DATA_WIDTH-1:0] lut_mem [0:LUT_SIZE-1];

    // ========================================================================
    // LUT初始化
    // ========================================================================
    integer i;
    initial begin
        // 默认初始化为0
        for (i = 0; i < LUT_SIZE; i = i + 1) begin
            lut_mem[i] = {DATA_WIDTH{1'b0}};
        end
        // 从文件加载LUT数据
        if (LUT_INIT_FILE != "") begin
            $readmemh(LUT_INIT_FILE, lut_mem);
        end
    end

    // ========================================================================
    // 并行LUT查找
    // ========================================================================
    genvar k;
    generate
        for (k = 0; k < PARALLELISM; k = k + 1) begin : gen_lut
            wire [ID_WIDTH-1:0] id = id_vec[k*ID_WIDTH +: ID_WIDTH];
            // 异步读取: ID直接作为地址索引LUT
            assign fp_vec[k*DATA_WIDTH +: DATA_WIDTH] = lut_mem[id];
        end
    endgenerate

endmodule
