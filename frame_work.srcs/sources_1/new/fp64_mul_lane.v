`timescale 1ns / 1ps

// ============================================================================
// Module: fp64_mul_lane
// 功能描述:
//   单 lane IEEE 风格 FP64 乘法器
//
// 状态位定义:
//   m_status[4] = invalid
//   m_status[3] = overflow
//   m_status[2] = underflow
//   m_status[1] = inexact
//   m_status[0] = reserved
//
// 实现说明:
//   - 支持 zero / subnormal / inf / NaN
//   - 舍入模式固定为 round-to-nearest-even
//   - 接口保留 ready/valid 风格，但 v1 不支持停顿，s_ready 恒为 1
// ============================================================================
module fp64_mul_lane #(
    parameter LATENCY = 6
)(
    input  wire        clk,
    input  wire        s_valid,
    output wire        s_ready,
    input  wire [63:0] s_a_bits,
    input  wire [63:0] s_b_bits,
    output wire        m_valid,
    input  wire        m_ready,
    output wire [63:0] m_result_bits,
    output wire [4:0]  m_status
);

    localparam [63:0] CANONICAL_QNAN = 64'h7ff8_0000_0000_0000;
    localparam integer STATUS_INVALID   = 4;
    localparam integer STATUS_OVERFLOW  = 3;
    localparam integer STATUS_UNDERFLOW = 2;
    localparam integer STATUS_INEXACT   = 1;

    function integer lead_one_pos_106;
        input [105:0] value;
        integer idx;
        begin
            lead_one_pos_106 = -1;
            for (idx = 105; idx >= 0; idx = idx - 1) begin
                if ((lead_one_pos_106 == -1) && value[idx]) begin
                    lead_one_pos_106 = idx;
                end
            end
        end
    endfunction

    function low_bits_nonzero_106;
        input [105:0] value;
        input integer bit_count;
        integer idx;
        begin
            low_bits_nonzero_106 = 1'b0;
            for (idx = 0; idx < 106; idx = idx + 1) begin
                if ((idx < bit_count) && value[idx]) begin
                    low_bits_nonzero_106 = 1'b1;
                end
            end
        end
    endfunction

    function [68:0] pack_finite_fp64;
        input               sign;
        input signed [13:0] exp_norm;
        input [105:0]       norm_prod;
        reg [63:0]          result_bits_f;
        reg [4:0]           status_bits_f;
        reg [52:0]          sig53_f;
        reg [53:0]          sig53_rounded_f;
        reg [51:0]          frac52_f;
        reg [52:0]          frac52_rounded_f;
        reg                 guard_f;
        reg                 round_f;
        reg                 sticky_f;
        reg                 sticky_shift_f;
        reg                 increment_f;
        reg [105:0]         shifted_prod_f;
        reg signed [13:0]   exp_work_f;
        integer             sub_shift_f;
        begin
            result_bits_f = {sign, 63'd0};
            status_bits_f = 5'b0;

            if (norm_prod == 106'd0) begin
                pack_finite_fp64 = {status_bits_f, result_bits_f};
            end else if (exp_norm >= 14'sd2047) begin
                status_bits_f[STATUS_OVERFLOW] = 1'b1;
                status_bits_f[STATUS_INEXACT]  = 1'b1;
                result_bits_f = {sign, 11'h7ff, 52'd0};
                pack_finite_fp64 = {status_bits_f, result_bits_f};
            end else if (exp_norm > 0) begin
                sig53_f  = norm_prod[104:52];
                guard_f  = norm_prod[51];
                round_f  = norm_prod[50];
                sticky_f = |norm_prod[49:0];
                increment_f = guard_f && (round_f || sticky_f || sig53_f[0]);
                sig53_rounded_f = {1'b0, sig53_f} + increment_f;
                exp_work_f = exp_norm;

                if (sig53_rounded_f[53]) begin
                    sig53_f = sig53_rounded_f[53:1];
                    exp_work_f = exp_work_f + 14'sd1;
                end else begin
                    sig53_f = sig53_rounded_f[52:0];
                end

                status_bits_f[STATUS_INEXACT] = guard_f || round_f || sticky_f;

                if (exp_work_f >= 14'sd2047) begin
                    status_bits_f[STATUS_OVERFLOW] = 1'b1;
                    status_bits_f[STATUS_INEXACT]  = 1'b1;
                    result_bits_f = {sign, 11'h7ff, 52'd0};
                end else begin
                    result_bits_f = {sign, exp_work_f[10:0], sig53_f[51:0]};
                end

                pack_finite_fp64 = {status_bits_f, result_bits_f};
            end else begin
                sub_shift_f = 1 - exp_norm;

                if (sub_shift_f > 106) begin
                    sticky_f = |norm_prod;
                    status_bits_f[STATUS_UNDERFLOW] = sticky_f;
                    status_bits_f[STATUS_INEXACT]   = sticky_f;
                    result_bits_f = {sign, 63'd0};
                    pack_finite_fp64 = {status_bits_f, result_bits_f};
                end else begin
                    shifted_prod_f = norm_prod >> sub_shift_f;
                    frac52_f       = shifted_prod_f[103:52];
                    guard_f        = shifted_prod_f[51];
                    round_f        = shifted_prod_f[50];
                    sticky_shift_f = low_bits_nonzero_106(norm_prod, sub_shift_f);
                    sticky_f       = sticky_shift_f || (|shifted_prod_f[49:0]);
                    increment_f    = guard_f && (round_f || sticky_f || frac52_f[0]);
                    frac52_rounded_f = {1'b0, frac52_f} + increment_f;

                    status_bits_f[STATUS_UNDERFLOW] = guard_f || round_f || sticky_f;
                    status_bits_f[STATUS_INEXACT]   = guard_f || round_f || sticky_f;

                    if (frac52_rounded_f[52]) begin
                        result_bits_f = {sign, 11'd1, 52'd0};
                    end else begin
                        result_bits_f = {sign, 11'd0, frac52_rounded_f[51:0]};
                    end

                    pack_finite_fp64 = {status_bits_f, result_bits_f};
                end
            end
        end
    endfunction

    assign s_ready = 1'b1;

    reg               valid_s0;
    reg               sign_s0;
    reg [52:0]        mant_a_s0;
    reg [52:0]        mant_b_s0;
    reg signed [13:0] exp_sum_s0;
    reg               a_nan_s0;
    reg               b_nan_s0;
    reg               a_inf_s0;
    reg               b_inf_s0;
    reg               a_zero_s0;
    reg               b_zero_s0;

    reg               valid_s1;
    reg               sign_s1;
    reg [105:0]       product_s1;
    reg signed [13:0] exp_sum_s1;
    reg               a_nan_s1;
    reg               b_nan_s1;
    reg               a_inf_s1;
    reg               b_inf_s1;
    reg               a_zero_s1;
    reg               b_zero_s1;

    reg               valid_s2;
    reg               sign_s2;
    reg [105:0]       norm_prod_s2;
    reg signed [13:0] exp_norm_s2;
    reg               a_nan_s2;
    reg               b_nan_s2;
    reg               a_inf_s2;
    reg               b_inf_s2;
    reg               a_zero_s2;
    reg               b_zero_s2;

    reg               valid_s3;
    reg [63:0]        result_s3;
    reg [4:0]         status_s3;

    reg               valid_s4;
    reg [63:0]        result_s4;
    reg [4:0]         status_s4;

    reg               valid_s5;
    reg [63:0]        result_s5;
    reg [4:0]         status_s5;

    wire unused_ready = &{1'b0, m_ready};

    always @(posedge clk) begin
        valid_s0 <= s_valid;
        sign_s0  <= s_a_bits[63] ^ s_b_bits[63];
        mant_a_s0 <= (s_a_bits[62:52] == 11'd0) ? {1'b0, s_a_bits[51:0]} : {1'b1, s_a_bits[51:0]};
        mant_b_s0 <= (s_b_bits[62:52] == 11'd0) ? {1'b0, s_b_bits[51:0]} : {1'b1, s_b_bits[51:0]};
        exp_sum_s0 <= $signed({3'b000, ((s_a_bits[62:52] == 11'd0) ? 11'd1 : s_a_bits[62:52])}) +
                      $signed({3'b000, ((s_b_bits[62:52] == 11'd0) ? 11'd1 : s_b_bits[62:52])}) -
                      14'sd1023;
        a_nan_s0  <= (s_a_bits[62:52] == 11'h7ff) && (s_a_bits[51:0] != 52'd0);
        b_nan_s0  <= (s_b_bits[62:52] == 11'h7ff) && (s_b_bits[51:0] != 52'd0);
        a_inf_s0  <= (s_a_bits[62:52] == 11'h7ff) && (s_a_bits[51:0] == 52'd0);
        b_inf_s0  <= (s_b_bits[62:52] == 11'h7ff) && (s_b_bits[51:0] == 52'd0);
        a_zero_s0 <= (s_a_bits[62:52] == 11'd0) && (s_a_bits[51:0] == 52'd0);
        b_zero_s0 <= (s_b_bits[62:52] == 11'd0) && (s_b_bits[51:0] == 52'd0);
    end

    always @(posedge clk) begin
        valid_s1   <= valid_s0;
        sign_s1    <= sign_s0;
        product_s1 <= mant_a_s0 * mant_b_s0;
        exp_sum_s1 <= exp_sum_s0;
        a_nan_s1   <= a_nan_s0;
        b_nan_s1   <= b_nan_s0;
        a_inf_s1   <= a_inf_s0;
        b_inf_s1   <= b_inf_s0;
        a_zero_s1  <= a_zero_s0;
        b_zero_s1  <= b_zero_s0;
    end

    always @(posedge clk) begin
        valid_s2  <= valid_s1;
        sign_s2   <= sign_s1;
        a_nan_s2  <= a_nan_s1;
        b_nan_s2  <= b_nan_s1;
        a_inf_s2  <= a_inf_s1;
        b_inf_s2  <= b_inf_s1;
        a_zero_s2 <= a_zero_s1;
        b_zero_s2 <= b_zero_s1;

        if (product_s1 == 106'd0) begin
            norm_prod_s2 <= 106'd0;
            exp_norm_s2  <= 14'sd0;
        end else begin
            if (lead_one_pos_106(product_s1) >= 105) begin
                norm_prod_s2 <= product_s1 >> 1;
                exp_norm_s2  <= exp_sum_s1 + 14'sd1;
            end else begin
                norm_prod_s2 <= product_s1 << (104 - lead_one_pos_106(product_s1));
                exp_norm_s2  <= exp_sum_s1 - (104 - lead_one_pos_106(product_s1));
            end
        end
    end

    always @(posedge clk) begin
        valid_s3 <= valid_s2;
        result_s3 <= 64'd0;
        status_s3 <= 5'd0;

        if (a_nan_s2 || b_nan_s2) begin
            result_s3 <= CANONICAL_QNAN;
        end else if ((a_inf_s2 && b_zero_s2) || (b_inf_s2 && a_zero_s2)) begin
            result_s3 <= CANONICAL_QNAN;
            status_s3[STATUS_INVALID] <= 1'b1;
        end else if (a_inf_s2 || b_inf_s2) begin
            result_s3 <= {sign_s2, 11'h7ff, 52'd0};
        end else if (a_zero_s2 || b_zero_s2) begin
            result_s3 <= {sign_s2, 63'd0};
        end else begin
            {status_s3, result_s3} <= pack_finite_fp64(sign_s2, exp_norm_s2, norm_prod_s2);
        end
    end

    always @(posedge clk) begin
        valid_s4  <= valid_s3;
        result_s4 <= result_s3;
        status_s4 <= status_s3;
    end

    always @(posedge clk) begin
        valid_s5  <= valid_s4;
        result_s5 <= result_s4;
        status_s5 <= status_s4;
    end

    assign m_valid       = valid_s5;
    assign m_result_bits = result_s5;
    assign m_status      = status_s5;

endmodule
