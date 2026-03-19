`timescale 1ns / 1ps

// ============================================================================
// Module: fp64_add_lane
// ============================================================================
// 功能描述:
//   IEEE 754 双精度浮点加法器 (FP64 Adder)
//   实现完整的 A + B 运算，支持所有特殊情况 (NaN/Inf/Zero/Denormal)
//
// 算法流程:
//   Stage 0: 解包与特殊值处理 - 拆分sign/exp/frac，处理NaN/Inf/Zero
//   Stage 1: 指数比较与对齐 - 较小操作数尾数右移，生成GRS位
//   Stage 2: 加减运算 - 同号相加，异号相减
//   Stage 3: 规格化检测 - 前导零计数，确定移位方向
//   Stage 4: 规格化执行 - 移位调整，处理上溢/下溢
//   Stage 5: 舍入与打包 - Round-to-nearest-even，生成最终结果
//
// 接口约定:
//   - s_valid/s_ready: 输入握手 (当前s_ready固定为1)
//   - m_valid/m_ready: 输出握手 (当前m_ready保留接口未实现)
//   - m_status[4:0]: 状态位 {invalid, overflow, underflow, inexact, reserved}
//
// 流水线特性:
//   - 固定6级流水线 (LATENCY=6)
//   - II=1 (每周期可接收新数据)
//   - 目标时钟: 250MHz
// ============================================================================

module fp64_add_lane #(
    parameter LATENCY = 6               // 流水线级数 (固定为6)
)(
    input  wire        clk,             // 系统时钟
    input  wire        s_valid,         // 输入有效信号
    output wire        s_ready,         // 输入就绪信号 (固定为1)
    input  wire [63:0] s_a_bits,        // 输入操作数A (FP64格式)
    input  wire [63:0] s_b_bits,        // 输入操作数B (FP64格式)
    output wire        m_valid,         // 输出有效信号
    input  wire        m_ready,         // 输出就绪信号 (保留接口)
    output wire [63:0] m_result_bits,   // 输出结果 (FP64格式)
    output wire [4:0]  m_status         // 输出状态 {invalid, overflow, underflow, inexact, reserved}
);

    // ========================================================================
    // 常量定义
    // ========================================================================
    // IEEE 754 规定的标准静默NaN (Canonical Quiet NaN)
    // 格式: sign=0, exp=0x7FF, frac=0x8000000000000 (最高位为1)
    localparam [63:0] CANONICAL_QNAN = 64'h7ff8_0000_0000_0000;

    // 状态位位置定义
    localparam integer STATUS_INVALID   = 4;  // 无效操作 (如 Inf + -Inf)
    localparam integer STATUS_OVERFLOW  = 3;  // 上溢
    localparam integer STATUS_UNDERFLOW = 2;  // 下溢
    localparam integer STATUS_INEXACT   = 1;  // 不精确 (舍入发生)

    // ========================================================================
    // 输入接口 - 固定背压模式
    // ========================================================================
    // 当前版本: s_ready固定为1，表示始终可以接收输入
    // 后续版本: 可实现真正的背压控制
    assign s_ready = 1'b1;

    // ========================================================================
    // 命名约定说明
    // ========================================================================
    // 无后缀: 流水线寄存器 (如 valid_s0, sig53_s4)
    // _w:     Wire，组合逻辑输出 (如 a_nan_s0_w)
    // _v:     Variable，组合逻辑内部临时变量 (如 small_ext_idx_s1_v)
    // _n:     Next，组合逻辑计算的结果，准备存入下一级寄存器 (如 sig53_s4_n)
    // _s0~s5: Stage 0~5，表示数据所在的流水级
    // ========================================================================

    // ========================================================================
    // Stage 0 寄存器: 解包后的操作数字段
    // ========================================================================
    reg               valid_s0;             // 有效信号传递
    reg               special_s0;           // 特殊值标志 (NaN/Inf/Zero)
    reg [63:0]        special_result_s0;    // 特殊值结果
    reg [4:0]         special_status_s0;    // 特殊值状态

    reg               sign_a_s0;            // 操作数A的符号位
    reg               sign_b_s0;            // 操作数B的符号位
    reg [10:0]        exp_eff_a_s0;         // 操作数A的有效指数 (denormal处理为1)
    reg [10:0]        exp_eff_b_s0;         // 操作数B的有效指数
    reg [52:0]        sig_a_s0;             // 操作数A的53位有效数字 (含隐含位)
    reg [52:0]        sig_b_s0;             // 操作数B的53位有效数字

    // ========================================================================
    // Stage 1 寄存器: 对齐后的操作数
    // ========================================================================
    reg               valid_s1;
    reg               special_s1;
    reg [63:0]        special_result_s1;
    reg [4:0]         special_status_s1;

    reg               large_sign_s1;        // 较大操作数的符号
    reg               signs_equal_s1;       // 两操作数符号是否相同
    reg [10:0]        large_exp_eff_s1;     // 较大操作数的有效指数
    reg [55:0]        large_ext_s1;         // 较大操作数的扩展尾数 (53+3位GRS)
    reg [55:0]        small_ext_s1;         // 较小操作数对齐后的扩展尾数

    // ========================================================================
    // Stage 2 寄存器: 加减运算结果
    // ========================================================================
    reg               valid_s2;
    reg               special_s2;
    reg [63:0]        special_result_s2;
    reg [4:0]         special_status_s2;

    reg               result_sign_s2;       // 结果符号
    reg               exact_zero_s2;        // 是否精确为零 (异号相消)
    reg [10:0]        large_exp_eff_s2;     // 指数传递
    reg [56:0]        arithmetic_ext_s2;    // 加减运算结果 (57位，含进位位)

    // ========================================================================
    // Stage 3 寄存器: 规格化参数
    // ========================================================================
    reg               valid_s3;
    reg               special_s3;
    reg [63:0]        special_result_s3;
    reg [4:0]         special_status_s3;

    reg               finite_zero_s3;       // 有限数结果为零
    reg               result_sign_s3;
    reg [56:0]        arithmetic_ext_s3;    // 运算结果传递
    reg [10:0]        large_exp_eff_s3;
    reg               norm_carry_s3;        // 是否有进位需要右移规格化
    reg [5:0]         norm_shift_s3;        // 规格化左移量

    // ========================================================================
    // Stage 4 寄存器: 规格化后的值
    // ========================================================================
    reg               valid_s4;
    reg               special_s4;
    reg [63:0]        special_result_s4;
    reg [4:0]         special_status_s4;

    reg               finite_zero_s4;
    reg               result_sign_s4;
    reg signed [13:0] exp_eff_norm_s4;      // 规格化后的有效指数 (14位有符号)
    reg [55:0]        norm_ext_s4;          // 规格化后的扩展尾数

    // 舍入相关字段
    reg [52:0]        sig53_s4;             // 53位有效数字
    reg [51:0]        frac52_s4;            // 52位小数部分 (用于denormal)
    reg               guard_s4;             // 保护位 (G)
    reg               round_s4;             // 舍入位 (R)
    reg               sticky_s4;            // 粘滞位 (S)

    // ========================================================================
    // Stage 5 寄存器: 最终结果
    // ========================================================================
    reg               valid_s5;
    reg [63:0]        result_bits_s5;       // 最终结果
    reg [4:0]         status_s5;            // 最终状态

    // ========================================================================
    // 组合逻辑信号 (_w后缀)
    // ========================================================================
    // Stage 0: 特殊值检测信号
    wire              a_nan_s0_w;           // A是否为NaN
    wire              b_nan_s0_w;           // B是否为NaN
    wire              a_inf_s0_w;           // A是否为无穷
    wire              b_inf_s0_w;           // B是否为无穷
    wire              a_zero_s0_w;          // A是否为零
    wire              b_zero_s0_w;          // B是否为零

    // Stage 1: 操作数选择信号
    wire              sel_a_large_s1_w;     // 选择A为较大操作数
    wire              signs_equal_s1_w;     // 符号是否相同
    wire              large_sign_s1_w;      // 较大操作数的符号
    wire [10:0]       large_exp_eff_s1_w;   // 较大操作数的指数
    wire [55:0]       large_ext_s1_w;       // 较大操作数的扩展尾数
    wire [55:0]       small_ext_raw_s1_w;   // 较小操作数的原始扩展尾数
    wire [10:0]       shift_amt_s1_w;       // 对齐移位量

    // Stage 1: 对齐计算 (_w输出, _v内部变量)
    reg [55:0]        small_ext_s1_w;       // 对齐后的较小操作数尾数
    reg               small_ext_sticky_s1_v; // sticky位收集变量
    integer           small_ext_idx_s1_v;   // 循环索引

    // Stage 3: 前导零检测 (_w输出, _v内部变量)
    reg [5:0]         norm_shift_s3_w;      // 规格化左移量
    integer           lead_pos_s3_v;        // 前导1的位置
    integer           lead_idx_s3_v;        // 循环索引

    // ========================================================================
    // Stage 4: 规格化计算信号 (_n后缀 = next值)
    // ========================================================================
    reg signed [13:0] exp_eff_norm_s4_n;    // 下一拍的有效指数
    reg [55:0]        norm_ext_s4_n;        // 下一拍的规格化尾数
    reg [52:0]        sig53_s4_n;           // 下一拍的53位有效数字
    reg [51:0]        frac52_s4_n;          // 下一拍的52位小数部分
    reg               guard_s4_n;           // 下一拍的保护位
    reg               round_s4_n;           // 下一拍的舍入位
    reg               sticky_s4_n;          // 下一拍的粘滞位

    // 下溢处理临时变量 (_v后缀)
    integer           sub_shift_s4_v;       // denormal右移量
    reg [55:0]        norm_ext_shifted_s4_v; // 右移后的尾数
    reg               norm_ext_sticky_s4_v; // sticky位收集
    integer           norm_ext_idx_s4_v;    // 循环索引

    // ========================================================================
    // Stage 5: 舍入计算信号 (_n后缀 = next值, _v后缀 = 内部变量)
    // ========================================================================
    reg [63:0]        result_bits_s5_n;     // 下一拍的最终结果
    reg [4:0]         status_s5_n;          // 下一拍的状态
    reg               increment_s5_v;       // 舍入增量
    reg [53:0]        sig53_rounded_s5_v;   // 舍入后的54位有效数字
    reg [52:0]        sig53_post_round_s5_v; // 重规格化后的53位
    reg [52:0]        frac52_rounded_s5_v;  // denormal舍入后
    reg signed [13:0] exp_work_s5_v;        // 工作指数

    // ========================================================================
    // Stage 0 组合逻辑: 特殊值检测
    // ========================================================================
    // IEEE 754 FP64格式:
    //   NaN:  exp = 0x7FF, frac != 0
    //   Inf:  exp = 0x7FF, frac = 0
    //   Zero: exp = 0, frac = 0
    //   Denormal: exp = 0, frac != 0
    //   Normal: 1 <= exp <= 0x7FE
    // ========================================================================

    assign a_nan_s0_w = (s_a_bits[62:52] == 11'h7ff) && (s_a_bits[51:0] != 52'd0);
    assign b_nan_s0_w = (s_b_bits[62:52] == 11'h7ff) && (s_b_bits[51:0] != 52'd0);
    assign a_inf_s0_w = (s_a_bits[62:52] == 11'h7ff) && (s_a_bits[51:0] == 52'd0);
    assign b_inf_s0_w = (s_b_bits[62:52] == 11'h7ff) && (s_b_bits[51:0] == 52'd0);
    assign a_zero_s0_w = (s_a_bits[62:52] == 11'd0) && (s_a_bits[51:0] == 52'd0);
    assign b_zero_s0_w = (s_b_bits[62:52] == 11'd0) && (s_b_bits[51:0] == 52'd0);

    // ========================================================================
    // Stage 1 组合逻辑: 操作数选择
    // ========================================================================
    // sel_a_large: 当A的指数较大，或指数相等但尾数较大时，选择A为较大操作数
    // ========================================================================

    assign sel_a_large_s1_w = (exp_eff_a_s0 > exp_eff_b_s0) ||
                              ((exp_eff_a_s0 == exp_eff_b_s0) && (sig_a_s0 >= sig_b_s0));

    // signs_equal: 两个操作数符号相同则做加法，不同则做减法
    assign signs_equal_s1_w = ~(sign_a_s0 ^ sign_b_s0);

    // 选择较大操作数的属性
    assign large_sign_s1_w = sel_a_large_s1_w ? sign_a_s0 : sign_b_s0;
    assign large_exp_eff_s1_w = sel_a_large_s1_w ? exp_eff_a_s0 : exp_eff_b_s0;

    // 扩展尾数: 53位有效数字 + 3位GRS (Guard/Round/Sticky)
    // 格式: [55:3] = 53位有效数字, [2:0] = GRS位
    assign large_ext_s1_w = sel_a_large_s1_w ? {sig_a_s0, 3'b000} : {sig_b_s0, 3'b000};
    assign small_ext_raw_s1_w = sel_a_large_s1_w ? {sig_b_s0, 3'b000} : {sig_a_s0, 3'b000};

    // 移位量: 较大指数 - 较小指数
    assign shift_amt_s1_w = sel_a_large_s1_w ? (exp_eff_a_s0 - exp_eff_b_s0) : (exp_eff_b_s0 - exp_eff_a_s0);

    // ========================================================================
    // Stage 1 组合逻辑: 尾数对齐
    // ========================================================================
    // 将较小操作数的尾数右移，使其指数与较大操作数对齐
    // 同时收集移出的位作为sticky位，用于后续舍入
    // ========================================================================

    always @* begin
        // 初始化
        small_ext_s1_w = 56'd0;
        small_ext_sticky_s1_v = 1'b0;

        if (shift_amt_s1_w == 0) begin
            // 无需移位，直接使用原值
            small_ext_s1_w = small_ext_raw_s1_w;
        end else if (shift_amt_s1_w >= 56) begin
            // 移位量超过尾数宽度，结果只保留sticky位
            // 只要有任意位为1，sticky就为1
            small_ext_s1_w = {55'd0, |small_ext_raw_s1_w};
        end else begin
            // 正常移位: 右移对齐
            small_ext_s1_w = small_ext_raw_s1_w >> shift_amt_s1_w;

            // 收集移出的位作为sticky位
            // 遍历所有被移出的位，只要有1就设置sticky
            for (small_ext_idx_s1_v = 0; small_ext_idx_s1_v < 56; small_ext_idx_s1_v = small_ext_idx_s1_v + 1) begin
                if ((small_ext_idx_s1_v < shift_amt_s1_w) && small_ext_raw_s1_w[small_ext_idx_s1_v]) begin
                    small_ext_sticky_s1_v = 1'b1;
                end
            end

            // 将sticky位合并到最低位
            small_ext_s1_w[0] = small_ext_s1_w[0] | small_ext_sticky_s1_v;
        end
    end

    // ========================================================================
    // Stage 3 组合逻辑: 前导零检测 (Leading Zero Count)
    // ========================================================================
    // 对于减法结果，可能产生前导零，需要左移规格化
    // 从高位向低位扫描，找到第一个1的位置
    // ========================================================================

    always @* begin
        norm_shift_s3_w = 6'd0;
        lead_pos_s3_v = -1;  // -1表示未找到

        // 只有非零且无进位时才需要检测前导零
        if (!exact_zero_s2 && !arithmetic_ext_s2[56]) begin
            // 从最高位(55)向最低位(0)扫描
            for (lead_idx_s3_v = 55; lead_idx_s3_v >= 0; lead_idx_s3_v = lead_idx_s3_v - 1) begin
                if ((lead_pos_s3_v == -1) && arithmetic_ext_s2[lead_idx_s3_v]) begin
                    lead_pos_s3_v = lead_idx_s3_v;  // 记录第一个1的位置
                end
            end

            // 计算左移量: 需要移到第55位
            if (lead_pos_s3_v >= 0) begin
                norm_shift_s3_w = 6'd55 - lead_pos_s3_v;
            end
        end
    end

    // ========================================================================
    // Stage 4 组合逻辑: 规格化执行
    // ========================================================================
    // 根据进位或前导零情况执行移位，并调整指数
    // 同时处理下溢(denormal)情况
    // ========================================================================

    always @* begin
        // 初始化所有输出
        exp_eff_norm_s4_n = 14'sd0;
        norm_ext_s4_n = 56'd0;
        sig53_s4_n = 53'd0;
        frac52_s4_n = 52'd0;
        guard_s4_n = 1'b0;
        round_s4_n = 1'b0;
        sticky_s4_n = 1'b0;
        norm_ext_shifted_s4_v = 56'd0;
        norm_ext_sticky_s4_v = 1'b0;

        if (!finite_zero_s3) begin
            // ============================================================
            // 情况1: 有进位 (加法结果溢出，如 1.1 + 0.1 = 10.0)
            // ============================================================
            if (norm_carry_s3) begin
                // 右移1位规格化
                norm_ext_s4_n = arithmetic_ext_s3[56:1];
                // 合并被移出的最低2位到sticky
                norm_ext_s4_n[0] = arithmetic_ext_s3[1] | arithmetic_ext_s3[0];
                // 指数+1
                exp_eff_norm_s4_n = $signed({3'b000, large_exp_eff_s3}) + 14'sd1;
            end
            // ============================================================
            // 情况2: 有前导零 (减法相消，如 1.1 - 1.0 = 0.1)
            // ============================================================
            else begin
                // 左移规格化
                norm_ext_s4_n = arithmetic_ext_s3[55:0] << norm_shift_s3;
                // 指数减去移位量
                exp_eff_norm_s4_n = $signed({3'b000, large_exp_eff_s3}) - $signed({8'd0, norm_shift_s3});
            end

            // ============================================================
            // 提取GRS位 (Guard/Round/Sticky)
            // ============================================================
            if (exp_eff_norm_s4_n > 14'sd0) begin
                // 正常数: 直接从扩展尾数中提取
                // [55:3] = 53位有效数字 (第55位是隐含的1)
                // [2] = Guard位
                // [1] = Round位
                // [0] = Sticky位
                sig53_s4_n = norm_ext_s4_n[55:3];
                frac52_s4_n = norm_ext_s4_n[54:3];  // 小数部分 (不含隐含位)
                guard_s4_n = norm_ext_s4_n[2];
                round_s4_n = norm_ext_s4_n[1];
                sticky_s4_n = norm_ext_s4_n[0];
            end else begin
                // ========================================================
                // 下溢处理: 指数 <= 0，需要生成denormal数
                // ========================================================
                // 计算额外右移量
                sub_shift_s4_v = 1 - exp_eff_norm_s4_n;

                if (sub_shift_s4_v <= 0) begin
                    norm_ext_shifted_s4_v = norm_ext_s4_n;
                end else if (sub_shift_s4_v >= 56) begin
                    // 移位量太大，只保留sticky
                    norm_ext_shifted_s4_v = {55'd0, |norm_ext_s4_n};
                end else begin
                    // 右移生成denormal
                    norm_ext_shifted_s4_v = norm_ext_s4_n >> sub_shift_s4_v;
                    // 收集移出的位作为sticky
                    norm_ext_sticky_s4_v = 1'b0;
                    for (norm_ext_idx_s4_v = 0; norm_ext_idx_s4_v < 56; norm_ext_idx_s4_v = norm_ext_idx_s4_v + 1) begin
                        if ((norm_ext_idx_s4_v < sub_shift_s4_v) && norm_ext_s4_n[norm_ext_idx_s4_v]) begin
                            norm_ext_sticky_s4_v = 1'b1;
                        end
                    end
                    norm_ext_shifted_s4_v[0] = norm_ext_shifted_s4_v[0] | norm_ext_sticky_s4_v;
                end

                norm_ext_s4_n = norm_ext_shifted_s4_v;
                frac52_s4_n = norm_ext_shifted_s4_v[54:3];
                guard_s4_n = norm_ext_shifted_s4_v[2];
                round_s4_n = norm_ext_shifted_s4_v[1];
                sticky_s4_n = norm_ext_shifted_s4_v[0];
            end
        end
    end

    // ========================================================================
    // Stage 5 组合逻辑: 舍入与结果打包
    // ========================================================================
    // 实现 Round-to-Nearest-Even (IEEE 754 默认舍入模式)
    // 舍入规则:
    //   - GR < 0.5: 截断 (不变)
    //   - GR > 0.5: 进位
    //   - GR = 0.5: 向偶数舍入 (最低位为0则不变，为1则进位)
    // ========================================================================

    always @* begin
        // 初始化
        result_bits_s5_n = 64'd0;
        status_s5_n = 5'd0;
        increment_s5_v = 1'b0;
        sig53_rounded_s5_v = 54'd0;
        sig53_post_round_s5_v = 53'd0;
        frac52_rounded_s5_v = 53'd0;
        exp_work_s5_v = 14'sd0;

        // ================================================================
        // 情况1: 特殊值 (NaN/Inf/Zero) - 直接传递
        // ================================================================
        if (special_s4) begin
            result_bits_s5_n = special_result_s4;
            status_s5_n = special_status_s4;
        end
        // ================================================================
        // 情况2: 有限数结果为零
        // ================================================================
        else if (finite_zero_s4) begin
            result_bits_s5_n = {1'b0, 11'd0, 52'd0};  // +0
        end
        // ================================================================
        // 情况3: 上溢 - 返回无穷
        // ================================================================
        else if (exp_eff_norm_s4 >= 14'sd2047) begin
            result_bits_s5_n = {result_sign_s4, 11'h7ff, 52'd0};  // ±Inf
            status_s5_n = 5'b01010;  // overflow + inexact
        end
        // ================================================================
        // 情况4: 正常规格化数
        // ================================================================
        else if (exp_eff_norm_s4 > 14'sd0) begin
            // Round-to-nearest-even 判断
            // 需要进位的条件: G=1 且 (R=1 或 S=1 或 最低有效位=1)
            increment_s5_v = guard_s4 && (round_s4 || sticky_s4 || sig53_s4[0]);

            // 执行舍入
            sig53_rounded_s5_v = {1'b0, sig53_s4} + increment_s5_v;
            sig53_post_round_s5_v = sig53_rounded_s5_v[52:0];
            exp_work_s5_v = exp_eff_norm_s4;

            // 舍入后可能产生进位，需要再规格化
            if (sig53_rounded_s5_v[53]) begin
                sig53_post_round_s5_v = sig53_rounded_s5_v[53:1];
                exp_work_s5_v = exp_work_s5_v + 14'sd1;
            end

            // 检查舍入后是否上溢
            if (exp_work_s5_v >= 14'sd2047) begin
                result_bits_s5_n = {result_sign_s4, 11'h7ff, 52'd0};
                status_s5_n = 5'b01010;
            end else begin
                // 打包结果: sign + exp + fraction
                result_bits_s5_n = {result_sign_s4, exp_work_s5_v[10:0], sig53_post_round_s5_v[51:0]};
                // 设置inexact标志
                status_s5_n = (guard_s4 || round_s4 || sticky_s4) ? 5'b00010 : 5'b00000;
            end
        end
        // ================================================================
        // 情况5: Denormal数 (指数为0)
        // ================================================================
        else begin
            // Denormal的舍入
            increment_s5_v = guard_s4 && (round_s4 || sticky_s4 || frac52_s4[0]);
            frac52_rounded_s5_v = {1'b0, frac52_s4} + increment_s5_v;

            // 检查舍入后是否变为最小正常数
            if (frac52_rounded_s5_v[52]) begin
                result_bits_s5_n = {result_sign_s4, 11'd1, 52'd0};  // 最小正常数
            end else begin
                result_bits_s5_n = {result_sign_s4, 11'd0, frac52_rounded_s5_v[51:0]};
            end

            // 设置underflow + inexact标志
            status_s5_n = (guard_s4 || round_s4 || sticky_s4) ? 5'b00110 : 5'b00000;
        end
    end

    // ========================================================================
    // 时序逻辑: Stage 0 寄存器
    // ========================================================================
    // 功能: 解包输入数据，处理特殊值
    // ========================================================================

    always @(posedge clk) begin
        // 有效信号传递
        valid_s0 <= s_valid;

        // 拆分操作数A的字段
        sign_a_s0 <= s_a_bits[63];
        sign_b_s0 <= s_b_bits[63];

        // 有效指数处理: denormal数的隐含位为0，有效指数为1
        exp_eff_a_s0 <= (s_a_bits[62:52] == 11'd0) ? 11'd1 : s_a_bits[62:52];
        exp_eff_b_s0 <= (s_b_bits[62:52] == 11'd0) ? 11'd1 : s_b_bits[62:52];

        // 有效数字: 添加隐含位
        // denormal: 隐含位=0, normal: 隐含位=1
        sig_a_s0 <= (s_a_bits[62:52] == 11'd0) ? {1'b0, s_a_bits[51:0]} : {1'b1, s_a_bits[51:0]};
        sig_b_s0 <= (s_b_bits[62:52] == 11'd0) ? {1'b0, s_b_bits[51:0]} : {1'b1, s_b_bits[51:0]};

        // 特殊值处理 (按IEEE 754优先级)
        special_s0 <= 1'b1;
        special_result_s0 <= 64'd0;
        special_status_s0 <= 5'd0;

        // 优先级1: NaN传播
        if (a_nan_s0_w || b_nan_s0_w) begin
            special_result_s0 <= CANONICAL_QNAN;
        end
        // 优先级2: Inf + (-Inf) = Invalid
        else if (a_inf_s0_w && b_inf_s0_w && (s_a_bits[63] ^ s_b_bits[63])) begin
            special_result_s0 <= CANONICAL_QNAN;
            special_status_s0[STATUS_INVALID] <= 1'b1;
        end
        // 优先级3: Inf传播
        else if (a_inf_s0_w) begin
            special_result_s0 <= {s_a_bits[63], 11'h7ff, 52'd0};
        end
        else if (b_inf_s0_w) begin
            special_result_s0 <= {s_b_bits[63], 11'h7ff, 52'd0};
        end
        // 优先级4: 零 + 零
        else if (a_zero_s0_w && b_zero_s0_w) begin
            // (+0)+(+0)=+0, (-0)+(-0)=-0, (+0)+(-0)=+0 (IEEE 754规定)
            special_result_s0 <= {(s_a_bits[63] & s_b_bits[63]), 63'd0};
        end
        // 优先级5: 零 + 非零 = 非零
        else if (a_zero_s0_w) begin
            special_result_s0 <= s_b_bits;
        end
        else if (b_zero_s0_w) begin
            special_result_s0 <= s_a_bits;
        end
        // 正常数: 标记为非特殊值，进入正常流水线
        else begin
            special_s0 <= 1'b0;
        end
    end

    // ========================================================================
    // 时序逻辑: Stage 1 寄存器
    // ========================================================================
    // 功能: 锁存对齐后的操作数
    // ========================================================================

    always @(posedge clk) begin
        // 流水线控制信号传递
        valid_s1 <= valid_s0;
        special_s1 <= special_s0;
        special_result_s1 <= special_result_s0;
        special_status_s1 <= special_status_s0;

        // 对齐后的操作数属性
        signs_equal_s1 <= signs_equal_s1_w;
        large_sign_s1 <= large_sign_s1_w;
        large_exp_eff_s1 <= large_exp_eff_s1_w;
        large_ext_s1 <= large_ext_s1_w;
        small_ext_s1 <= small_ext_s1_w;
    end

    // ========================================================================
    // 时序逻辑: Stage 2 寄存器
    // ========================================================================
    // 功能: 执行加法/减法运算
    // ========================================================================

    always @(posedge clk) begin
        // 流水线控制信号传递
        valid_s2 <= valid_s1;
        special_s2 <= special_s1;
        special_result_s2 <= special_result_s1;
        special_status_s2 <= special_status_s1;

        // 指数传递
        large_exp_eff_s2 <= large_exp_eff_s1;

        // 核心运算: 同号加法，异号减法
        if (signs_equal_s1) begin
            // 同号: 尾数相加
            // 57位: 1位进位 + 56位扩展尾数
            arithmetic_ext_s2 <= {1'b0, large_ext_s1} + {1'b0, small_ext_s1};
            result_sign_s2 <= large_sign_s1;
            exact_zero_s2 <= 1'b0;  // 同号加法不可能为零
        end else begin
            // 异号: 尾数相减 (大减小)
            arithmetic_ext_s2 <= {1'b0, large_ext_s1} - {1'b0, small_ext_s1};
            result_sign_s2 <= large_sign_s1;
            // 检测精确为零 (大数正好等于小数)
            exact_zero_s2 <= ({1'b0, large_ext_s1} == {1'b0, small_ext_s1});
        end
    end

    // ========================================================================
    // 时序逻辑: Stage 3 寄存器
    // ========================================================================
    // 功能: 检测规格化方向，计算移位量
    // ========================================================================

    always @(posedge clk) begin
        // 流水线控制信号传递
        valid_s3 <= valid_s2;
        special_s3 <= special_s2;
        special_result_s3 <= special_result_s2;
        special_status_s3 <= special_status_s2;

        // 数据传递
        arithmetic_ext_s3 <= arithmetic_ext_s2;
        large_exp_eff_s3 <= large_exp_eff_s2;
        finite_zero_s3 <= exact_zero_s2;
        result_sign_s3 <= result_sign_s2;

        // 规格化参数初始化
        norm_carry_s3 <= 1'b0;
        norm_shift_s3 <= 6'd0;

        // 非零结果才需要规格化
        if (!exact_zero_s2) begin
            if (arithmetic_ext_s2[56]) begin
                // 有进位: 需要右移1位规格化
                norm_carry_s3 <= 1'b1;
                norm_shift_s3 <= 6'd1;
            end else begin
                // 无进位: 使用前导零检测结果 (左移)
                norm_shift_s3 <= norm_shift_s3_w;
            end
        end
    end

    // ========================================================================
    // 时序逻辑: Stage 4 寄存器
    // ========================================================================
    // 功能: 锁存规格化后的值和GRS位
    // ========================================================================

    always @(posedge clk) begin
        // 流水线控制信号传递
        valid_s4 <= valid_s3;
        special_s4 <= special_s3;
        special_result_s4 <= special_result_s3;
        special_status_s4 <= special_status_s3;

        // 规格化后的数据
        finite_zero_s4 <= finite_zero_s3;
        result_sign_s4 <= result_sign_s3;
        exp_eff_norm_s4 <= exp_eff_norm_s4_n;
        norm_ext_s4 <= norm_ext_s4_n;

        // GRS位
        sig53_s4 <= sig53_s4_n;
        frac52_s4 <= frac52_s4_n;
        guard_s4 <= guard_s4_n;
        round_s4 <= round_s4_n;
        sticky_s4 <= sticky_s4_n;
    end

    // ========================================================================
    // 时序逻辑: Stage 5 寄存器
    // ========================================================================
    // 功能: 锁存最终结果
    // ========================================================================

    always @(posedge clk) begin
        valid_s5 <= valid_s4;
        result_bits_s5 <= result_bits_s5_n;
        status_s5 <= status_s5_n;
    end

    // ========================================================================
    // 输出赋值
    // ========================================================================

    assign m_valid       = valid_s5;
    assign m_result_bits = result_bits_s5;
    assign m_status      = status_s5;

endmodule