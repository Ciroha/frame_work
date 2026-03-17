`timescale 1ns / 1ps

// ============================================================================
// Module: y_acc_banks
// 功能描述:
//   Y累加器 - 用于SpMV计算结果累加
//
// 功能:
//   - 存储Y向量(结果向量)
//   - 支持三种工作模式: 加载/计算/输出
//   - 支持并行累加(PARALLELISM个通道同时写入)
//
// 工作模式:
//   - 00: 空闲
//   - 01: 加载模式 - 从流写入初始Y值
//   - 10: 计算模式 - 累加部分积到Y向量
//   - 11: 输出模式 - 读取Y向量到输出流
//
// 累加机制:
//   - 提供两路累加输入(main和sym)用于对称矩阵优化
//   - 处理同一地址的写冲突(仿真模型)
//
// 注意:
//   行为级仿真模型,不解决跨通道的写冲突
//   实际硬件需要更复杂的冲突解决机制
// ============================================================================

module y_acc_banks #(
    // ========================================================================
    // 参数定义
    // ========================================================================
    parameter PARALLELISM = 8,          // 并行度
    parameter DATA_WIDTH  = 64,         // 数据位宽(FP64)
    parameter DEPTH       = 128,        // Y向量长度
    parameter ADDR_WIDTH  = $clog2(DEPTH) // 地址位宽
)(
    input  wire clk,

    // ========================================================================
    // 模式控制
    // ========================================================================
    // 00: 空闲
    // 01: 加载模式 (从流写入初始Y)
    // 10: 计算模式 (累加部分积)
    // 11: 输出模式 (读取Y到输出流)
    input  wire [1:0] mode,

    // ========================================================================
    // 加载/输出接口 (线性访问)
    // ========================================================================
    input  wire                                ls_en,
    input  wire [ADDR_WIDTH-1:0]               ls_addr,
    input  wire [PARALLELISM*DATA_WIDTH-1:0]   load_data,
    output wire [PARALLELISM*DATA_WIDTH-1:0]   store_data,

    // ========================================================================
    // 计算/累加接口
    // ========================================================================
    input  wire [PARALLELISM*DATA_WIDTH-1:0]   partial_products_a,  // 主路径部分积
    input  wire [PARALLELISM-1:0]              pp_valid_a,          // 主路径有效掩码
    input  wire [PARALLELISM*ADDR_WIDTH-1:0]   y_local_addr_a,      // 主路径Y地址
    input  wire [PARALLELISM*DATA_WIDTH-1:0]   partial_products_b,  // 对称路径部分积
    input  wire [PARALLELISM-1:0]              pp_valid_b,          // 对称路径有效掩码
    input  wire [PARALLELISM*ADDR_WIDTH-1:0]   y_local_addr_b       // 对称路径Y地址
);

    localparam UPDATE_CHANNELS = PARALLELISM * 2; // 更新通道数(主+对称)
    localparam integer BANK_DEPTH = (DEPTH + PARALLELISM - 1) / PARALLELISM;
    localparam integer BANK_ADDR_WIDTH = (BANK_DEPTH <= 1) ? 1 : $clog2(BANK_DEPTH);

    // 输出寄存器
    reg [PARALLELISM*DATA_WIDTH-1:0] r_store_data;
    assign store_data = r_store_data;

`ifndef SYNTHESIS
    // =========================================================================
    // 仿真模型: 单向量存储 + 行为级累加
    // =========================================================================
    (* ram_style = "distributed" *) reg [DATA_WIDTH-1:0] y_ram [0:DEPTH-1];

    // 从ls_addr*8开始写入8个元素
    integer i;
    always @(posedge clk) begin
        if (mode == 2'b01 && ls_en) begin
            for (i = 0; i < PARALLELISM; i = i + 1) begin
                if ((ls_addr * PARALLELISM + i) < DEPTH) begin
                    y_ram[ls_addr * PARALLELISM + i] <= load_data[i*DATA_WIDTH +: DATA_WIDTH];
                end
            end
        end
    end

    always @(posedge clk) begin
        if (mode == 2'b11 && ls_en) begin
            for (i = 0; i < PARALLELISM; i = i + 1) begin
                if ((ls_addr * PARALLELISM + i) < DEPTH) begin
                    r_store_data[i*DATA_WIDTH +: DATA_WIDTH] <= y_ram[ls_addr * PARALLELISM + i];
                end else begin
                    r_store_data[i*DATA_WIDTH +: DATA_WIDTH] <= {DATA_WIDTH{1'b0}};
                end
            end
        end
    end

    wire [UPDATE_CHANNELS*ADDR_WIDTH-1:0] y_local_addr_all = {y_local_addr_b, y_local_addr_a};
    wire [UPDATE_CHANNELS*DATA_WIDTH-1:0] pp_all = {partial_products_b, partial_products_a};
    wire [UPDATE_CHANNELS-1:0] pp_valid_all = {pp_valid_b, pp_valid_a};
    wire [ADDR_WIDTH-1:0] addr [0:UPDATE_CHANNELS-1];
    wire [DATA_WIDTH-1:0] pp   [0:UPDATE_CHANNELS-1];

    genvar k;
    generate
        for (k = 0; k < UPDATE_CHANNELS; k = k + 1) begin : gen_extract
            assign addr[k] = y_local_addr_all[k*ADDR_WIDTH +: ADDR_WIDTH];
            assign pp[k]   = pp_all[k*DATA_WIDTH +: DATA_WIDTH];
        end
    endgenerate

    // 同一周期同一地址的写入会先合并,然后写入一次。
    integer j;
    reg has_prev_hit;
    real acc_real;
    real add_real;
    always @(posedge clk) begin
        if (mode == 2'b10) begin
            for (i = 0; i < UPDATE_CHANNELS; i = i + 1) begin
                has_prev_hit = 1'b0;
                for (j = 0; j < i; j = j + 1) begin
                    if (pp_valid_all[j] && (addr[j] < DEPTH) && (addr[j] == addr[i])) begin
                        has_prev_hit = 1'b1;
                    end
                end

                if (pp_valid_all[i] && (addr[i] < DEPTH) && !has_prev_hit) begin
                    acc_real = $bitstoreal(y_ram[addr[i]]);
                    for (j = i; j < UPDATE_CHANNELS; j = j + 1) begin
                        if (pp_valid_all[j] && (addr[j] < DEPTH) && (addr[j] == addr[i])) begin
                            add_real = $bitstoreal(pp[j]);
                            acc_real = acc_real + add_real;
                        end
                    end
                    y_ram[addr[i]] <= $realtobits(acc_real);
                end
            end
        end
    end
`else
    // =========================================================================
    // 综合模型: 每个lane一个bank，避免把单数组综合成多读多写存储器
    // =========================================================================
    genvar bank_idx;
    generate
        for (bank_idx = 0; bank_idx < PARALLELISM; bank_idx = bank_idx + 1) begin : gen_y_bank
            (* ram_style = "distributed" *) reg [DATA_WIDTH-1:0] bank_ram [0:BANK_DEPTH-1];

            wire [ADDR_WIDTH:0] abs_idx = (ls_addr * PARALLELISM) + bank_idx;
            wire bank_in_range = (abs_idx < DEPTH);
            wire [BANK_ADDR_WIDTH-1:0] bank_addr = ls_addr[BANK_ADDR_WIDTH-1:0];

            always @(posedge clk) begin
                if ((mode == 2'b01) && ls_en && bank_in_range && (ls_addr < BANK_DEPTH)) begin
                    bank_ram[bank_addr] <= load_data[bank_idx*DATA_WIDTH +: DATA_WIDTH];
                end

                if ((mode == 2'b11) && ls_en) begin
                    if (bank_in_range && (ls_addr < BANK_DEPTH)) begin
                        r_store_data[bank_idx*DATA_WIDTH +: DATA_WIDTH] <= bank_ram[bank_addr];
                    end else begin
                        r_store_data[bank_idx*DATA_WIDTH +: DATA_WIDTH] <= {DATA_WIDTH{1'b0}};
                    end
                end
            end
        end
    endgenerate

    wire unused_compute_inputs;
    assign unused_compute_inputs = &{1'b0, partial_products_a, pp_valid_a, y_local_addr_a,
                                     partial_products_b, pp_valid_b, y_local_addr_b};
`endif

endmodule
