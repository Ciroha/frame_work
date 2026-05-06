`timescale 1ns / 1ps

// ============================================================================
// Module: b8c_top
// ============================================================================
// 功能描述:
//   这是SpMV（稀疏矩阵-向量乘法）加速器的顶层模块。
//   实现完整的 Y = A * X + Y 计算，其中A为稀疏矩阵，X和Y为稠密向量。
//
// 整体架构:
//   1. 数据加载阶段: 从AXI-Stream接口加载X向量和初始Y向量
//   2. 计算阶段: 解码稀疏矩阵数据，执行并行乘法累加
//   3. 输出阶段: 将计算结果Y向量输出到AXI-Stream接口
//
// 数据流格式:
//   输入流: [X向量拍] [Y向量拍] [矩阵数据拍(tlast标记结束)]
//   输出流: [Y结果拍]
//
// 支持两种模式:
//   - MODE_ID52=0: 传统模式，16拍FP64数据 + 5拍元数据
//   - MODE_ID52=1: ID压缩模式，2拍8位ID + 5拍元数据，通过LUT转换为FP64
//
// 状态机流程:
//   S_IDLE -> S_LOAD_X -> S_LOAD_Y -> S_COMPUTE -> S_STORE_Y -> S_DONE
//
// 并行度:
//   - PARALLELISM=8:  8通道并行计算（默认）
//   - PARALLELISM=16: 16通道并行计算（仅支持MODE_ID52模式）
//
// 对称矩阵优化:
//   - SYMMETRIC_UPPER_ONLY=1: 仅存储上三角，自动计算对称元素贡献
// ============================================================================

module b8c_top #(
    // ========================================================================
    // 参数定义
    // ========================================================================
    parameter PARALLELISM = 8,           // 并行计算通道数(8或16)
    parameter DATA_WIDTH  = 64,          // 数据位宽(FP64为64位)
    parameter AXI_WIDTH   = 512,         // AXI-Stream接口位宽
    parameter MODE_ID52   = 1'b0,        // 工作模式: 0=传统FP64模式, 1=ID-LUT压缩模式
    parameter SYMMETRIC_UPPER_ONLY = 1'b0, // 对称矩阵优化: 仅计算上三角
    parameter LUT_INIT_FILE = "",        // LUT初始化文件路径(MODE_ID52模式使用)
    parameter DECOUPLE_ID_META = 1'b0,   // ID/Meta解耦使能(提高吞吐量)
    parameter ID_Q_DEPTH = 8,            // ID队列深度
    parameter META_Q_DEPTH = 8,          // Meta队列深度
    parameter SIM_USE_MUL_IP = 1'b1,     // 仿真时乘法: 1=IP, 0=行为模型
    parameter SIM_USE_ADD_IP = 1'b1,     // 仿真时加法: 1=IP, 0=行为模型
    parameter Y_QUEUE_DEPTH = 256,       // Y累加队列深度
    parameter Y_LIMITED_BYPASS_WINDOW = 32, // Y累加旁路窗口
    parameter SIM_ENABLE_BANK_STATS = 1'b0,      // 仿真时输出bank热点统计
    parameter SIM_PRINT_BATCH_BANK_STATS = 1'b0, // 仿真时输出每batch bank命中
    parameter SIM_ENABLE_STALL_REASON_STATS = 1'b0,
    parameter VECTOR_DEPTH = 4096,       // X向量存储深度
    parameter Y_ELEMS      = 23,         // Y向量元素个数
    parameter ADDR_WIDTH   = ((((VECTOR_DEPTH > Y_ELEMS) ? VECTOR_DEPTH : Y_ELEMS) <= 1) ?
                              1 : $clog2((VECTOR_DEPTH > Y_ELEMS) ? VECTOR_DEPTH : Y_ELEMS))
)(
    // ========================================================================
    // 端口定义
    // ========================================================================
    input  wire clk,                    // 系统时钟
    input  wire rst_n,                  // 异步复位，低有效

    // AXI-Stream 从接口 (输入数据流)
    // 格式: [X向量] [Y向量] [矩阵稀疏数据(tlast标记结束)]
    input  wire [AXI_WIDTH-1:0] s_axis_tdata,
    input  wire                 s_axis_tvalid,
    input  wire                 s_axis_tlast,   // 矩阵数据最后一拍
    output wire                 s_axis_tready,

    // AXI-Stream 主接口 (输出Y向量结果)
    output wire [AXI_WIDTH-1:0] m_axis_tdata,
    output wire                 m_axis_tvalid,
    input  wire                 m_axis_tready,
    output wire                 m_axis_tlast    // Y向量最后一拍
);

    // ========================================================================
    // 状态机状态定义
    // ========================================================================
    localparam S_IDLE    = 3'd0;        // 空闲状态，等待输入
    localparam S_LOAD_X  = 3'd1;        // 加载X向量阶段
    localparam S_LOAD_Y  = 3'd2;        // 加载初始Y向量阶段
    localparam S_COMPUTE = 3'd3;        // 计算阶段(解码矩阵并累加)
    localparam S_STORE_Y = 3'd4;        // 输出Y向量结果阶段
    localparam S_DONE    = 3'd5;        // 完成状态

    // ========================================================================
    // 派生参数计算
    // ========================================================================
    localparam integer FP64_MUL_LATENCY = 8;      // FP64乘法IP固定延迟
    localparam integer META_OUT_STAGE = FP64_MUL_LATENCY + 1; // 元数据对齐到乘法输出
    localparam integer COMPUTE_DRAIN_CYCLES = FP64_MUL_LATENCY + 3;  // 计算流水线排空周期数
    localparam CONTINUOUS_ISSUE_MODE = MODE_ID52 &&
                                       ((PARALLELISM == 8) || (PARALLELISM == 16)) &&
                                       !SYMMETRIC_UPPER_ONLY;
    localparam SYMM_CONTINUOUS_ISSUE_MODE = MODE_ID52 &&
                                            (PARALLELISM == 16) &&
                                            SYMMETRIC_UPPER_ONLY;
    localparam CONTINUOUS_ADMISSION_MODE = CONTINUOUS_ISSUE_MODE || SYMM_CONTINUOUS_ISSUE_MODE;
    localparam integer IO_LANES = AXI_WIDTH / DATA_WIDTH;  // 每拍传输的数据个数(8)
    localparam integer LANE_RATIO = PARALLELISM / IO_LANES; // 并行度与IO比例(1或2)
    localparam integer X_AXI_BEATS = VECTOR_DEPTH * LANE_RATIO; // X向量传输拍数
    localparam integer Y_LOGICAL_BEATS = (Y_ELEMS + PARALLELISM - 1) / PARALLELISM; // Y逻辑拍数
    localparam integer Y_AXI_BEATS = (Y_ELEMS + IO_LANES - 1) / IO_LANES; // Y AXI拍数
    localparam integer COL_SHIFT = (PARALLELISM <= 1) ? 0 : $clog2(PARALLELISM); // 列地址移位量
    localparam integer X_TOTAL_ELEMS = VECTOR_DEPTH * PARALLELISM; // X总元素数
    localparam integer X_GLOBAL_AW = (X_TOTAL_ELEMS <= 1) ? 1 : $clog2(X_TOTAL_ELEMS); // X全局地址位宽

    // ========================================================================
    // 参数合法性检查
    // ========================================================================
`ifndef SYNTHESIS
    initial begin
        if (AXI_WIDTH % DATA_WIDTH != 0) begin
            $fatal(1, "AXI_WIDTH (%0d) must be multiple of DATA_WIDTH (%0d)", AXI_WIDTH, DATA_WIDTH);
        end
        if (PARALLELISM % IO_LANES != 0) begin
            $fatal(1, "PARALLELISM (%0d) must be multiple of IO_LANES (%0d)", PARALLELISM, IO_LANES);
        end
        if ((LANE_RATIO != 1) && (LANE_RATIO != 2)) begin
            $fatal(1, "Unsupported LANE_RATIO=%0d (only 1 or 2 supported)", LANE_RATIO);
        end
        if ((PARALLELISM == 16) && (MODE_ID52 == 1'b0)) begin
            $fatal(1, "PARALLELISM=16 is only supported for MODE_ID52=1 in this version");
        end
        if (SYMMETRIC_UPPER_ONLY && ((MODE_ID52 == 1'b0) || (PARALLELISM != 16))) begin
            $fatal(1, "SYMMETRIC_UPPER_ONLY currently requires MODE_ID52=1 and PARALLELISM=16");
        end
    end
`endif

    // ========================================================================
    // 状态机寄存器
    // ========================================================================
    reg [2:0] state;                    // 当前状态
    reg [31:0] load_cnt;                // 加载计数器(用于X/Y向量加载)
    reg        tlast_seen;              // 是否已收到tlast(计算完成标志)
    reg [3:0]  drain_cnt;              // 排空计数器(等待流水线完成)

    // ========================================================================
    // 解码器输出信号
    // ========================================================================
    wire decoder_val;                   // 解码器输出有效
    wire [PARALLELISM*DATA_WIDTH-1:0] dec_vals;      // 解码后的矩阵值(8/16个FP64)
    wire [PARALLELISM*16-1:0]         dec_row_deltas; // 行偏移量数组
    wire [15:0]                       dec_row_base;   // 行基址
    wire [15:0]                       dec_col_base;   // 列基址
    wire                              dec_fifo_empty; // 解码器FIFO空标志

    // ========================================================================
    reg [PARALLELISM*DATA_WIDTH-1:0] dec_vals_d1;
    reg [PARALLELISM*DATA_WIDTH-1:0] dec_vals_d2;
    reg                               compute_valid_d1;
    reg                               compute_valid_d2;
    reg [PARALLELISM*16-1:0]          dec_row_deltas_pipe [0:META_OUT_STAGE];
    reg [15:0]                        dec_row_base_pipe [0:META_OUT_STAGE];
    reg [15:0]                        dec_col_base_pipe [0:META_OUT_STAGE];
    reg [PARALLELISM-1:0]             dec_nonzero_pipe [0:META_OUT_STAGE];
    wire                              acc_ready;
    wire                              acc_idle;
    wire                              dec_ready_out;
    wire                              compute_req_next;
    wire                              compute_fire;
    // Keep the busy window long enough to cover compute_valid_d2
    // and the FP64 multiply output retirement into y_acc_banks.
    reg  [COMPUTE_DRAIN_CYCLES-1:0]    compute_inflight_pipe;
    wire                              compute_mul_busy;
    integer                           pipe_idx;

    assign compute_mul_busy = |compute_inflight_pipe;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dec_vals_d1 <= {PARALLELISM*DATA_WIDTH{1'b0}};
            dec_vals_d2 <= {PARALLELISM*DATA_WIDTH{1'b0}};
            compute_valid_d1 <= 1'b0;
            compute_valid_d2 <= 1'b0;
            compute_inflight_pipe <= {COMPUTE_DRAIN_CYCLES{1'b0}};
            for (pipe_idx = 0; pipe_idx <= META_OUT_STAGE; pipe_idx = pipe_idx + 1) begin
                dec_row_deltas_pipe[pipe_idx] <= {PARALLELISM*16{1'b0}};
                dec_row_base_pipe[pipe_idx]   <= 16'd0;
                dec_col_base_pipe[pipe_idx]   <= 16'd0;
                dec_nonzero_pipe[pipe_idx]    <= {PARALLELISM{1'b0}};
            end
        end else if (state == S_COMPUTE) begin
            compute_inflight_pipe[0] <= compute_fire;
            for (pipe_idx = 1; pipe_idx < COMPUTE_DRAIN_CYCLES; pipe_idx = pipe_idx + 1) begin
                compute_inflight_pipe[pipe_idx] <= compute_inflight_pipe[pipe_idx-1];
            end

            dec_vals_d1 <= compute_fire ? dec_vals : {PARALLELISM*DATA_WIDTH{1'b0}};
            dec_vals_d2 <= dec_vals_d1;
            compute_valid_d1 <= compute_fire;
            compute_valid_d2 <= compute_valid_d1;

            if (compute_fire) begin
                dec_row_deltas_pipe[0] <= dec_row_deltas;
                dec_row_base_pipe[0]   <= dec_row_base;
                dec_col_base_pipe[0]   <= dec_col_base;
                for (pipe_idx = 0; pipe_idx < PARALLELISM; pipe_idx = pipe_idx + 1) begin
                    dec_nonzero_pipe[0][pipe_idx] <= (dec_vals[pipe_idx*DATA_WIDTH +: DATA_WIDTH] != {DATA_WIDTH{1'b0}});
                end
            end else begin
                dec_row_deltas_pipe[0] <= {PARALLELISM*16{1'b0}};
                dec_row_base_pipe[0]   <= 16'd0;
                dec_col_base_pipe[0]   <= 16'd0;
                dec_nonzero_pipe[0]    <= {PARALLELISM{1'b0}};
            end

            for (pipe_idx = 1; pipe_idx <= META_OUT_STAGE; pipe_idx = pipe_idx + 1) begin
                dec_row_deltas_pipe[pipe_idx] <= dec_row_deltas_pipe[pipe_idx-1];
                dec_row_base_pipe[pipe_idx]   <= dec_row_base_pipe[pipe_idx-1];
                dec_col_base_pipe[pipe_idx]   <= dec_col_base_pipe[pipe_idx-1];
                dec_nonzero_pipe[pipe_idx]    <= dec_nonzero_pipe[pipe_idx-1];
            end
        end else begin
            dec_vals_d1 <= {PARALLELISM*DATA_WIDTH{1'b0}};
            dec_vals_d2 <= {PARALLELISM*DATA_WIDTH{1'b0}};
            compute_valid_d1 <= 1'b0;
            compute_valid_d2 <= 1'b0;
            compute_inflight_pipe <= {COMPUTE_DRAIN_CYCLES{1'b0}};
            for (pipe_idx = 0; pipe_idx <= META_OUT_STAGE; pipe_idx = pipe_idx + 1) begin
                dec_row_deltas_pipe[pipe_idx] <= {PARALLELISM*16{1'b0}};
                dec_row_base_pipe[pipe_idx]   <= 16'd0;
                dec_col_base_pipe[pipe_idx]   <= 16'd0;
                dec_nonzero_pipe[pipe_idx]    <= {PARALLELISM{1'b0}};
            end
        end
    end

    // ========================================================================
    // 存储器和计算单元接口信号
    // ========================================================================
    wire [PARALLELISM*DATA_WIDTH-1:0] x_rd_data;      // X存储器读取数据(主路径)
    wire [PARALLELISM*DATA_WIDTH-1:0] x_sym_rd_data;  // X存储器读取数据(对称路径)
    wire [PARALLELISM*DATA_WIDTH-1:0] y_store_data;   // Y累加器输出数据
    wire [PARALLELISM*ADDR_WIDTH-1:0] x_rd_addr_mapped; // X读取地址(主路径)
    wire [PARALLELISM*X_GLOBAL_AW-1:0] x_sym_rd_addr_global; // X读取地址(对称路径)
    wire [PARALLELISM*DATA_WIDTH-1:0] pp_data_main;   // 乘积结果(主路径)
    wire [PARALLELISM*DATA_WIDTH-1:0] pp_data_sym;    // 乘积结果(对称路径)
    wire [PARALLELISM-1:0]            pp_valid_main;  // 主路径有效掩码
    wire [PARALLELISM-1:0]            pp_valid_sym;   // 对称路径有效掩码

    // ========================================================================
    // 状态机组合逻辑
    // ========================================================================
    reg [2:0]  next_state;
    reg [31:0] next_load_cnt;
    reg        next_tlast_seen;
    reg [3:0]  next_drain_cnt;

    wire in_handshake = s_axis_tvalid && s_axis_tready;  // 输入握手
    wire out_handshake = m_axis_tvalid && m_axis_tready; // 输出握手

    // 状态转移组合逻辑
    always @(*) begin
        next_state = state;
        next_load_cnt = load_cnt;
        next_tlast_seen = tlast_seen;
        next_drain_cnt = drain_cnt;

        case (state)
            // 空闲状态: 等待输入数据
            S_IDLE: begin
                next_load_cnt = 0;
                next_tlast_seen = 1'b0;
                next_drain_cnt = 0;
                if (in_handshake) begin
                    if (X_AXI_BEATS <= 1) begin
                        next_state = S_LOAD_Y;  // X向量只有1拍,直接加载Y
                        next_load_cnt = 0;
                    end else begin
                        next_state = S_LOAD_X;  // 开始加载X向量
                        next_load_cnt = 1;
                    end
                end
            end

            // 加载X向量状态
            S_LOAD_X: begin
                if (in_handshake) begin
                    if (load_cnt == X_AXI_BEATS - 1) begin
                        next_state = S_LOAD_Y;  // X加载完成,转入Y加载
                        next_load_cnt = 0;
                    end else begin
                        next_load_cnt = load_cnt + 1;
                    end
                end
            end

            // 加载Y向量状态
            S_LOAD_Y: begin
                if (in_handshake) begin
                    if (load_cnt == Y_AXI_BEATS - 1) begin
                        next_state = S_COMPUTE; // Y加载完成,转入计算
                        next_load_cnt = 0;
                    end else begin
                        next_load_cnt = load_cnt + 1;
                    end
                end
            end

            // 计算状态: 接收稀疏矩阵数据并执行SpMV
            S_COMPUTE: begin
                if (!tlast_seen) begin
                    if (in_handshake && s_axis_tlast) begin
                        next_tlast_seen = 1'b1;  // 检测到最后一个数据
                    end
                end else begin
                    if (dec_fifo_empty && acc_idle && !compute_mul_busy) begin
                        next_state = S_STORE_Y;  // 排空完成,转入输出
                        next_load_cnt = 0;
                        next_tlast_seen = 1'b0;
                    end else begin
                        next_drain_cnt = COMPUTE_DRAIN_CYCLES;
                    end
                end
            end

            // 输出Y向量状态
            S_STORE_Y: begin
                if (out_handshake) begin
                    if (load_cnt == Y_AXI_BEATS - 1) begin
                        next_state = S_DONE;  // Y输出完成
                    end else begin
                        next_load_cnt = load_cnt + 1;
                    end
                end
            end

            // 完成状态: 保持不变
            S_DONE: begin
                next_state = S_DONE;
            end

            default: begin
                next_state = S_IDLE;
            end
        endcase
    end

    // 状态寄存器更新
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            load_cnt <= 0;
            tlast_seen <= 1'b0;
            drain_cnt <= 0;
        end else begin
            state <= next_state;
            load_cnt <= next_load_cnt;
            tlast_seen <= next_tlast_seen;
            drain_cnt <= next_drain_cnt;
        end
    end

    // ========================================================================
    // 解码器接口信号
    // ========================================================================
    wire axis_to_dec_valid = (state == S_COMPUTE) && s_axis_tvalid; // 计算阶段才允许解码
    // Continuous admission is enabled only for validated/gated ID paths.
    // Other modes keep the conservative drain-based gating.
    assign compute_req_next = CONTINUOUS_ADMISSION_MODE ?
                              ((state == S_COMPUTE) && acc_ready) :
                              ((state == S_COMPUTE) && acc_idle && !compute_mul_busy);
    assign compute_fire = decoder_val && compute_req_next;

    // s_axis_tready 生成: 根据状态决定是否接收数据
    reg s_axis_tready_comb;
    always @(*) begin
        case (state)
            S_IDLE, S_LOAD_X, S_LOAD_Y: s_axis_tready_comb = 1'b1;  // 加载阶段始终接收
            S_COMPUTE:                  s_axis_tready_comb = dec_ready_out; // 计算阶段由解码器控制
            default:                    s_axis_tready_comb = 1'b0;  // 其他状态不接收
        endcase
    end
    assign s_axis_tready = s_axis_tready_comb;

    // ========================================================================
    // 解码器实例化
    // 根据MODE_ID52参数选择解码器类型
    // ========================================================================
    generate
        if (MODE_ID52 == 1'b0) begin : gen_decoder_legacy
            // 传统模式: 直接传递FP64值, 16拍数据+5拍元数据
            b8c_decoder #(
                .AXI_WIDTH(AXI_WIDTH),
                .PARALLELISM(PARALLELISM),
                .VAL_BATCH(16),
                .META_BATCH(5)
            ) u_decoder (
                .clk(clk),
                .rst_n(rst_n),
                .s_axis_tdata(s_axis_tdata),
                .s_axis_tvalid(axis_to_dec_valid),
                .s_axis_tready(dec_ready_out),
                .compute_req_next(compute_req_next),
                .decoder_valid(decoder_val),
                .m_vals_data(dec_vals),
                .m_row_deltas(dec_row_deltas),
                .m_row_base(dec_row_base),
                .m_col_base(dec_col_base),
                .o_pipeline_idle(dec_fifo_empty)
            );
        end else begin : gen_decoder_id52
            // ID压缩模式: 2拍8位ID+5拍元数据, 通过LUT转换为FP64
            b8c_decoder_id52 #(
                .AXI_WIDTH(AXI_WIDTH),
                .PARALLELISM(PARALLELISM),
                .VAL_ID_BATCH(2),
                .META_BATCH(5),
                .ID_WIDTH(8),
                .DATA_WIDTH(DATA_WIDTH),
                .LUT_INIT_FILE(LUT_INIT_FILE),
                .DECOUPLE_ID_META(DECOUPLE_ID_META),
                .ID_Q_DEPTH(ID_Q_DEPTH),
                .META_Q_DEPTH(META_Q_DEPTH)
            ) u_decoder (
                .clk(clk),
                .rst_n(rst_n),
                .s_axis_tdata(s_axis_tdata),
                .s_axis_tvalid(axis_to_dec_valid),
                .s_axis_tready(dec_ready_out),
                .compute_req_next(compute_req_next),
                .decoder_valid(decoder_val),
                .m_vals_data(dec_vals),
                .m_row_deltas(dec_row_deltas),
                .m_row_base(dec_row_base),
                .m_col_base(dec_col_base),
                .o_pipeline_idle(dec_fifo_empty)
            );
        end
    endgenerate

    // ========================================================================
    // X存储器地址映射
    // col_base用于计算X向量的读取地址
    // ========================================================================
    genvar i;
    generate
        for (i = 0; i < PARALLELISM; i = i + 1) begin : gen_x_addr
            // 主路径: 列基址 + 通道偏移, 右移得到bank地址
            assign x_rd_addr_mapped[i*ADDR_WIDTH +: ADDR_WIDTH] = (dec_col_base_pipe[0] + i) >> COL_SHIFT;
        end
    endgenerate

    // ========================================================================
    // 对称路径地址计算 (用于对称矩阵优化)
    // 使用行地址作为对称元素的列地址
    // ========================================================================
    generate
        for (i = 0; i < PARALLELISM; i = i + 1) begin : gen_x_sym_addr
            wire [15:0] sym_delta = dec_row_deltas_pipe[0][i*16 +: 16];
            wire [15:0] sym_row_abs = dec_row_base_pipe[0] + sym_delta;
            // 对称路径使用全局地址索引
            assign x_sym_rd_addr_global[i*X_GLOBAL_AW +: X_GLOBAL_AW] = sym_row_abs[X_GLOBAL_AW-1:0];
        end
    endgenerate

    // ========================================================================
    // X向量加载逻辑
    // 支持LANE_RATIO=1(512->8通道) 或 LANE_RATIO=2(512->16通道)
    // ========================================================================
    reg [AXI_WIDTH-1:0] x_half_buf;  // 半拍数据缓存(用于LANE_RATIO=2)
    wire x_phase = (state == S_IDLE) || (state == S_LOAD_X);
    wire x_first_half = (LANE_RATIO == 2) && x_phase && in_handshake && (load_cnt[0] == 1'b0);
    wire x_load_fire = x_phase && in_handshake && ((LANE_RATIO == 1) || (load_cnt[0] == 1'b1));
    wire [31:0] x_load_addr_full = (LANE_RATIO == 1) ? load_cnt : (load_cnt >> 1);
    wire [PARALLELISM*DATA_WIDTH-1:0] x_load_data_w;

    // 半拍数据缓存
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_half_buf <= {AXI_WIDTH{1'b0}};
        end else if (x_first_half) begin
            x_half_buf <= s_axis_tdata;
        end
    end

    // 数据拼接(用于LANE_RATIO=2)
    generate
        if (LANE_RATIO == 1) begin : gen_x_load_direct
            assign x_load_data_w = s_axis_tdata;
        end else begin : gen_x_load_pair
            assign x_load_data_w = {s_axis_tdata, x_half_buf};
        end
    endgenerate

    // ========================================================================
    // X向量存储器实例化
    // 存储256*PARALLELISM个FP64元素
    // ========================================================================
    x_mem_banks #(
        .PARALLELISM(PARALLELISM),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DEPTH(VECTOR_DEPTH),
        .GLOBAL_ADDR_WIDTH(X_GLOBAL_AW)
    ) u_x_mem (
        .clk(clk),
        .load_en(x_load_fire),
        .load_addr(x_load_addr_full[ADDR_WIDTH-1:0]),
        .load_data(x_load_data_w),
        .rd_addr_vec(x_rd_addr_mapped),      // 主路径读取地址
        .rd_data_vec(x_rd_data),             // 主路径读取数据
        .arb_rd_global_idx_vec(x_sym_rd_addr_global), // 对称路径全局地址
        .arb_rd_data_vec(x_sym_rd_data)      // 对称路径读取数据
    );

    // ========================================================================
    // 计算流水线实例化
    // 执行 matrix_value * x_value 的FP64乘法
    // ========================================================================
    compute_pipeline #(
        .PARALLELISM(PARALLELISM),
        .MUL_LATENCY(FP64_MUL_LATENCY),
        .SIM_USE_IP(SIM_USE_MUL_IP),
        .ENABLE_SYM_PATH(SYMMETRIC_UPPER_ONLY)
    ) u_compute (
        .clk(clk),
        .in_valid(compute_valid_d2),
        .matrix_values(dec_vals_d2),         // 矩阵元素值，与 X 读数据对齐
        .x_values_main(x_rd_data),           // X向量值(主路径)
        .x_values_sym(x_sym_rd_data),        // X向量值(对称路径)
        .routed_products_main(pp_data_main), // 乘积结果(主路径)
        .routed_products_sym(pp_data_sym),   // 乘积结果(对称路径)
        .valid_mask_main(pp_valid_main),     // 主路径有效掩码
        .valid_mask_sym(pp_valid_sym)        // 对称路径有效掩码
    );

    // ========================================================================
    // Y累加器模式控制
    // ========================================================================
    reg [1:0] y_mode;
    always @(*) begin
        case (state)
            S_LOAD_Y:  y_mode = 2'b01;  // 加载模式: 写入初始Y值
            S_COMPUTE: y_mode = 2'b10;  // 计算模式: 累加部分积
            S_STORE_Y: y_mode = 2'b11;  // 输出模式: 读取Y值
            default:   y_mode = 2'b00;  // 空闲模式
        endcase
    end

    // ========================================================================
    // Y累加器地址计算
    // 用于计算部分积写入Y向量的目标地址
    // ========================================================================
    wire [PARALLELISM*ADDR_WIDTH-1:0] y_compute_addr;      // 主路径Y地址
    wire [PARALLELISM*ADDR_WIDTH-1:0] y_compute_addr_sym;  // 对称路径Y地址
    wire [PARALLELISM*ADDR_WIDTH-1:0] y_preview_addr;      // 当前batch预览Y地址
    wire [PARALLELISM*ADDR_WIDTH-1:0] y_preview_addr_sym;  // 当前batch预览对称Y地址
    wire [PARALLELISM-1:0]            y_preview_valid;     // 主路径预留有效掩码
    wire [PARALLELISM-1:0]            y_preview_valid_sym; // 对称路径预留有效掩码
    wire [PARALLELISM-1:0]            pp_valid_main_acc;   // 主路径最终累加有效掩码
    wire [PARALLELISM-1:0]            y_sym_diag_mask;     // 对角线掩码(对角线元素不重复计算)
    wire [PARALLELISM-1:0]            pp_valid_sym_masked; // 对称路径最终有效掩码
    generate
        for (i = 0; i < PARALLELISM; i = i + 1) begin : gen_y_addr
            wire [15:0] delta_p = dec_row_deltas[i*16 +: 16];
            wire [15:0] row_abs_p = dec_row_base + delta_p;
            wire [15:0] col_abs_p = dec_col_base + i;
            wire [15:0] delta_d = dec_row_deltas_pipe[META_OUT_STAGE][i*16 +: 16];
            wire [15:0] row_abs_d = dec_row_base_pipe[META_OUT_STAGE] + delta_d;  // 绝对行地址
            wire [15:0] col_abs_d = dec_col_base_pipe[META_OUT_STAGE] + i;         // 绝对列地址
            wire        dec_nonzero_p = (dec_vals[i*DATA_WIDTH +: DATA_WIDTH] != {DATA_WIDTH{1'b0}});
            assign y_preview_addr[i*ADDR_WIDTH +: ADDR_WIDTH] = row_abs_p[ADDR_WIDTH-1:0];
            assign y_preview_addr_sym[i*ADDR_WIDTH +: ADDR_WIDTH] = col_abs_p[ADDR_WIDTH-1:0];
            assign y_preview_valid[i] =
                CONTINUOUS_ISSUE_MODE ? decoder_val :
                (SYMM_CONTINUOUS_ISSUE_MODE && decoder_val && dec_nonzero_p && (row_abs_p < Y_ELEMS));
            assign y_preview_valid_sym[i] =
                SYMM_CONTINUOUS_ISSUE_MODE && decoder_val &&
                dec_nonzero_p &&
                (row_abs_p != col_abs_p) &&
                (col_abs_p < Y_ELEMS);
            // 主路径: 按行累加 Y[row] += A[row,col] * X[col]
            assign y_compute_addr[i*ADDR_WIDTH +: ADDR_WIDTH] = row_abs_d[ADDR_WIDTH-1:0];
            // 对称路径: 按列累加 Y[col] += A[row,col] * X[row] (利用对称性)
            assign y_compute_addr_sym[i*ADDR_WIDTH +: ADDR_WIDTH] = col_abs_d[ADDR_WIDTH-1:0];
            // 对角线检测: 行列相等时跳过对称路径
            assign y_sym_diag_mask[i] = (row_abs_d == col_abs_d);
        end
    endgenerate

    generate
        for (i = 0; i < PARALLELISM; i = i + 1) begin : gen_sym_valid_mask
            wire [15:0] delta_d = dec_row_deltas_pipe[META_OUT_STAGE][i*16 +: 16];
            wire [15:0] row_abs_d = dec_row_base_pipe[META_OUT_STAGE] + delta_d;
            wire [15:0] col_abs_d = dec_col_base_pipe[META_OUT_STAGE] + i;
            assign pp_valid_main_acc[i] =
                pp_valid_main[i] &
                (!SYMM_CONTINUOUS_ISSUE_MODE ||
                 (dec_nonzero_pipe[META_OUT_STAGE][i] && (row_abs_d < Y_ELEMS)));
            assign pp_valid_sym_masked[i] =
                pp_valid_sym[i] &
                SYMMETRIC_UPPER_ONLY &
                dec_nonzero_pipe[META_OUT_STAGE][i] &
                ~y_sym_diag_mask[i] &
                (!SYMM_CONTINUOUS_ISSUE_MODE || (col_abs_d < Y_ELEMS));
        end
    endgenerate

`ifndef SYNTHESIS
    integer sym_dbg_issue_count;
    integer sym_dbg_retire_count;
    reg [PARALLELISM-1:0] preview_valid_a_pipe [0:META_OUT_STAGE];
    reg [PARALLELISM-1:0] preview_valid_b_pipe [0:META_OUT_STAGE];
    reg [PARALLELISM*ADDR_WIDTH-1:0] preview_addr_a_pipe [0:META_OUT_STAGE];
    reg [PARALLELISM*ADDR_WIDTH-1:0] preview_addr_b_pipe [0:META_OUT_STAGE];
    integer preview_pipe_idx;
    integer preview_check_idx;
    initial begin
        sym_dbg_issue_count = 0;
        sym_dbg_retire_count = 0;
        for (preview_pipe_idx = 0; preview_pipe_idx <= META_OUT_STAGE; preview_pipe_idx = preview_pipe_idx + 1) begin
            preview_valid_a_pipe[preview_pipe_idx] = {PARALLELISM{1'b0}};
            preview_valid_b_pipe[preview_pipe_idx] = {PARALLELISM{1'b0}};
            preview_addr_a_pipe[preview_pipe_idx] = {PARALLELISM*ADDR_WIDTH{1'b0}};
            preview_addr_b_pipe[preview_pipe_idx] = {PARALLELISM*ADDR_WIDTH{1'b0}};
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            sym_dbg_issue_count <= 0;
            sym_dbg_retire_count <= 0;
            for (preview_pipe_idx = 0; preview_pipe_idx <= META_OUT_STAGE; preview_pipe_idx = preview_pipe_idx + 1) begin
                preview_valid_a_pipe[preview_pipe_idx] <= {PARALLELISM{1'b0}};
                preview_valid_b_pipe[preview_pipe_idx] <= {PARALLELISM{1'b0}};
                preview_addr_a_pipe[preview_pipe_idx] <= {PARALLELISM*ADDR_WIDTH{1'b0}};
                preview_addr_b_pipe[preview_pipe_idx] <= {PARALLELISM*ADDR_WIDTH{1'b0}};
            end
        end else if (SYMMETRIC_UPPER_ONLY) begin
            preview_valid_a_pipe[0] <= compute_fire ? y_preview_valid : {PARALLELISM{1'b0}};
            preview_valid_b_pipe[0] <= compute_fire ? y_preview_valid_sym : {PARALLELISM{1'b0}};
            preview_addr_a_pipe[0] <= compute_fire ? y_preview_addr : {PARALLELISM*ADDR_WIDTH{1'b0}};
            preview_addr_b_pipe[0] <= compute_fire ? y_preview_addr_sym : {PARALLELISM*ADDR_WIDTH{1'b0}};
            for (preview_pipe_idx = 1; preview_pipe_idx <= META_OUT_STAGE; preview_pipe_idx = preview_pipe_idx + 1) begin
                preview_valid_a_pipe[preview_pipe_idx] <= preview_valid_a_pipe[preview_pipe_idx-1];
                preview_valid_b_pipe[preview_pipe_idx] <= preview_valid_b_pipe[preview_pipe_idx-1];
                preview_addr_a_pipe[preview_pipe_idx] <= preview_addr_a_pipe[preview_pipe_idx-1];
                preview_addr_b_pipe[preview_pipe_idx] <= preview_addr_b_pipe[preview_pipe_idx-1];
            end

            if (compute_valid_d2 && (sym_dbg_issue_count < 8)) begin
                $display("SYMDBG_ISSUE idx=%0d row_base=%0d col_base=%0d x_main0=%h x_sym0=%h mat0=%h",
                         sym_dbg_issue_count,
                         dec_row_base_pipe[2],
                         dec_col_base_pipe[2],
                         x_rd_data[0 +: DATA_WIDTH],
                         x_sym_rd_data[0 +: DATA_WIDTH],
                         dec_vals_d2[0 +: DATA_WIDTH]);
                sym_dbg_issue_count <= sym_dbg_issue_count + 1;
            end
            if ((|pp_valid_main || |pp_valid_sym || |pp_valid_sym_masked) && (sym_dbg_retire_count < 8)) begin
                $display("SYMDBG_RETIRE idx=%0d main=%h sym=%h masked=%h diag=%h nz=%h y_addr_a0=%0d y_addr_b0=%0d pp_main0=%h pp_sym0=%h",
                         sym_dbg_retire_count,
                         pp_valid_main,
                         pp_valid_sym,
                         pp_valid_sym_masked,
                         y_sym_diag_mask,
                         dec_nonzero_pipe[META_OUT_STAGE],
                         y_compute_addr[0 +: ADDR_WIDTH],
                         y_compute_addr_sym[0 +: ADDR_WIDTH],
                         pp_data_main[0 +: DATA_WIDTH],
                         pp_data_sym[0 +: DATA_WIDTH]);
                sym_dbg_retire_count <= sym_dbg_retire_count + 1;
            end

            if (SYMM_CONTINUOUS_ISSUE_MODE) begin
                for (preview_check_idx = 0; preview_check_idx < PARALLELISM; preview_check_idx = preview_check_idx + 1) begin
                    if (preview_valid_a_pipe[META_OUT_STAGE][preview_check_idx] !== pp_valid_main_acc[preview_check_idx]) begin
                        $error("SYM_PREVIEW_A_VALID mismatch lane=%0d exp=%0b got=%0b",
                               preview_check_idx,
                               preview_valid_a_pipe[META_OUT_STAGE][preview_check_idx],
                               pp_valid_main_acc[preview_check_idx]);
                    end
                    if (preview_valid_b_pipe[META_OUT_STAGE][preview_check_idx] !== pp_valid_sym_masked[preview_check_idx]) begin
                        $error("SYM_PREVIEW_B_VALID mismatch lane=%0d exp=%0b got=%0b",
                               preview_check_idx,
                               preview_valid_b_pipe[META_OUT_STAGE][preview_check_idx],
                               pp_valid_sym_masked[preview_check_idx]);
                    end
                    if (preview_valid_a_pipe[META_OUT_STAGE][preview_check_idx] &&
                        (preview_addr_a_pipe[META_OUT_STAGE][preview_check_idx*ADDR_WIDTH +: ADDR_WIDTH] !=
                         y_compute_addr[preview_check_idx*ADDR_WIDTH +: ADDR_WIDTH])) begin
                        $error("SYM_PREVIEW_A_ADDR mismatch lane=%0d exp=%0d got=%0d",
                               preview_check_idx,
                               preview_addr_a_pipe[META_OUT_STAGE][preview_check_idx*ADDR_WIDTH +: ADDR_WIDTH],
                               y_compute_addr[preview_check_idx*ADDR_WIDTH +: ADDR_WIDTH]);
                    end
                    if (preview_valid_b_pipe[META_OUT_STAGE][preview_check_idx] &&
                        (preview_addr_b_pipe[META_OUT_STAGE][preview_check_idx*ADDR_WIDTH +: ADDR_WIDTH] !=
                         y_compute_addr_sym[preview_check_idx*ADDR_WIDTH +: ADDR_WIDTH])) begin
                        $error("SYM_PREVIEW_B_ADDR mismatch lane=%0d exp=%0d got=%0d",
                               preview_check_idx,
                               preview_addr_b_pipe[META_OUT_STAGE][preview_check_idx*ADDR_WIDTH +: ADDR_WIDTH],
                               y_compute_addr_sym[preview_check_idx*ADDR_WIDTH +: ADDR_WIDTH]);
                    end
                end
            end
        end
    end
`endif

    // ========================================================================
    // Y向量加载逻辑
    // ========================================================================
    reg [AXI_WIDTH-1:0] y_half_buf;  // 半拍数据缓存(用于LANE_RATIO=2)
    wire y_load_first_half = (LANE_RATIO == 2) && (state == S_LOAD_Y) && in_handshake && (load_cnt[0] == 1'b0);
    wire y_load_tail_single = (LANE_RATIO == 2) && (state == S_LOAD_Y) && in_handshake &&
                              (load_cnt[0] == 1'b0) && (load_cnt == Y_AXI_BEATS - 1);
    wire y_load_fire = (state == S_LOAD_Y) && in_handshake &&
                       ((LANE_RATIO == 1) || (load_cnt[0] == 1'b1) || y_load_tail_single);
    wire [31:0] y_load_addr_full = (LANE_RATIO == 1) ? load_cnt : (load_cnt >> 1);
    wire [PARALLELISM*DATA_WIDTH-1:0] y_load_data_w;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_half_buf <= {AXI_WIDTH{1'b0}};
        end else if (y_load_first_half) begin
            y_half_buf <= s_axis_tdata;
        end
    end

    generate
        if (LANE_RATIO == 1) begin : gen_y_load_direct
            assign y_load_data_w = s_axis_tdata;
        end else begin : gen_y_load_pair
            assign y_load_data_w = y_load_tail_single ? {{AXI_WIDTH{1'b0}}, s_axis_tdata} :
                                                     {s_axis_tdata, y_half_buf};
        end
    endgenerate

    // ========================================================================
    // Y向量输出控制状态机
    // ========================================================================
    reg [ADDR_WIDTH-1:0]               y_store_req_addr;      // 输出请求地址
    reg                                y_store_fetch_pending; // 读请求挂起标志
    reg [PARALLELISM*DATA_WIDTH-1:0]   y_store_buf;           // 输出数据缓存
    reg                                y_store_buf_valid;     // 缓存有效标志
    reg                                store_half_sel;        // 半拍选择(LANE_RATIO=2)

    wire y_store_fetch_req = (state == S_STORE_Y) &&
                             !y_store_fetch_pending &&
                             !y_store_buf_valid &&
                             (y_store_req_addr < Y_LOGICAL_BEATS);

    // Y加载/存储地址选择
    wire [ADDR_WIDTH-1:0] y_ls_addr = (state == S_LOAD_Y) ?
                                      y_load_addr_full[ADDR_WIDTH-1:0] :
                                      y_store_req_addr;
    wire y_ls_en = (state == S_LOAD_Y) ? y_load_fire :
                   ((state == S_STORE_Y) ? y_store_fetch_req : 1'b0);

    // 输出AXI数据选择(LANE_RATIO=2时需要分两次输出)
    wire [AXI_WIDTH-1:0] y_store_axi_word =
        (LANE_RATIO == 2) ?
            (store_half_sel ? y_store_buf[AXI_WIDTH +: AXI_WIDTH] : y_store_buf[0 +: AXI_WIDTH]) :
            y_store_buf[0 +: AXI_WIDTH];

    // Y输出控制状态机
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_store_req_addr <= {ADDR_WIDTH{1'b0}};
            y_store_fetch_pending <= 1'b0;
            y_store_buf <= {PARALLELISM*DATA_WIDTH{1'b0}};
            y_store_buf_valid <= 1'b0;
            store_half_sel <= 1'b0;
        end else if (state != S_STORE_Y) begin
            // 非输出状态时复位输出控制
            y_store_req_addr <= {ADDR_WIDTH{1'b0}};
            y_store_fetch_pending <= 1'b0;
            y_store_buf <= {PARALLELISM*DATA_WIDTH{1'b0}};
            y_store_buf_valid <= 1'b0;
            store_half_sel <= 1'b0;
        end else begin
            // 发起读请求
            if (y_store_fetch_req) begin
                y_store_fetch_pending <= 1'b1;
                y_store_req_addr <= y_store_req_addr + 1'b1;
            end

            // 接收读数据
            if (y_store_fetch_pending) begin
                y_store_fetch_pending <= 1'b0;
                y_store_buf <= y_store_data;
                y_store_buf_valid <= 1'b1;
                store_half_sel <= 1'b0;
            end

            // AXI输出握手
            if (out_handshake) begin
                if (LANE_RATIO == 1) begin
                    y_store_buf_valid <= 1'b0;
                end else if (!store_half_sel) begin
                    store_half_sel <= 1'b1;  // 第一半拍完成,输出第二半拍
                end else begin
                    store_half_sel <= 1'b0;
                    y_store_buf_valid <= 1'b0;  // 两半拍都完成
                end
            end
        end
    end

    // ========================================================================
    // Y累加器实例化
    // ========================================================================
    y_acc_banks #(
        .PARALLELISM(PARALLELISM),
        .DEPTH(Y_ELEMS),
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .QUEUE_DEPTH(Y_QUEUE_DEPTH),
        .LIMITED_BYPASS_WINDOW(Y_LIMITED_BYPASS_WINDOW),
        .SIM_USE_IP(SIM_USE_ADD_IP),
        .ENABLE_PREVIEW_RESERVE(CONTINUOUS_ADMISSION_MODE),
        .SIM_ENABLE_BANK_STATS(SIM_ENABLE_BANK_STATS),
        .SIM_PRINT_BATCH_BANK_STATS(SIM_PRINT_BATCH_BANK_STATS),
        .SIM_ENABLE_STALL_REASON_STATS(SIM_ENABLE_STALL_REASON_STATS),
        .ENABLE_LIMITED_BYPASS(CONTINUOUS_ADMISSION_MODE)
    ) u_y_acc (
        .clk(clk),
        .mode(y_mode),
        .ls_en(y_ls_en),
        .ls_addr(y_ls_addr),
        .load_data(y_load_data_w),
        .store_data(y_store_data),
        .acc_ready(acc_ready),
        .acc_idle(acc_idle),
        .batch_fire(compute_fire),
        .preview_valid_a(y_preview_valid),
        .preview_y_local_addr_a(y_preview_addr),
        .preview_valid_b(y_preview_valid_sym),
        .preview_y_local_addr_b(y_preview_addr_sym),
        // 主路径累加: Y[row] += A[row,col] * X[col]
        .partial_products_a(pp_data_main),
        .pp_valid_a(pp_valid_main_acc),
        .y_local_addr_a(y_compute_addr),
        // 对称路径累加: Y[col] += A[row,col] * X[row]
        .partial_products_b(pp_data_sym),
        .pp_valid_b(pp_valid_sym_masked),
        .y_local_addr_b(y_compute_addr_sym)
    );

    // ========================================================================
    // 输出AXI-Stream信号
    // ========================================================================
    assign m_axis_tdata  = y_store_axi_word;
    assign m_axis_tvalid = (state == S_STORE_Y) && y_store_buf_valid;
    assign m_axis_tlast  = m_axis_tvalid && (load_cnt == Y_AXI_BEATS - 1);

endmodule

