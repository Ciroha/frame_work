`timescale 1ns / 1ps

module compute_pipeline #(
    parameter PARALLELISM = 8,
    parameter DATA_WIDTH  = 64,
    parameter MUL_LATENCY = 8
)(
    input  wire clk,
    input  wire in_valid,
    input  wire [PARALLELISM*DATA_WIDTH-1:0] matrix_values,
    input  wire [PARALLELISM*DATA_WIDTH-1:0] x_values_main,
    input  wire [PARALLELISM*DATA_WIDTH-1:0] x_values_sym,
    output wire [PARALLELISM*DATA_WIDTH-1:0] routed_products_main,
    output wire [PARALLELISM*DATA_WIDTH-1:0] routed_products_sym,
    output wire [PARALLELISM-1:0]            valid_mask_main,
    output wire [PARALLELISM-1:0]            valid_mask_sym
);

    genvar k;
    generate
        for (k = 0; k < PARALLELISM; k = k + 1) begin : gen_mul_lane
            wire [DATA_WIDTH-1:0] main_result_bits;
            wire [DATA_WIDTH-1:0] sym_result_bits;
            wire [4:0]            main_status_bits;
            wire [4:0]            sym_status_bits;
            wire                  main_valid;
            wire                  sym_valid;
            wire                  main_ready;
            wire                  sym_ready;
            wire                  unused_status;

            fp64_mul_xilinx_wrapper #(
                .LATENCY(MUL_LATENCY)
            ) u_mul_main (
                .clk(clk),
                .s_valid(in_valid),
                .s_ready(main_ready),
                .s_a_bits(matrix_values[k*DATA_WIDTH +: DATA_WIDTH]),
                .s_b_bits(x_values_main[k*DATA_WIDTH +: DATA_WIDTH]),
                .m_valid(main_valid),
                .m_ready(1'b1),
                .m_result_bits(main_result_bits),
                .m_status(main_status_bits)
            );

            fp64_mul_xilinx_wrapper #(
                .LATENCY(MUL_LATENCY)
            ) u_mul_sym (
                .clk(clk),
                .s_valid(in_valid),
                .s_ready(sym_ready),
                .s_a_bits(matrix_values[k*DATA_WIDTH +: DATA_WIDTH]),
                .s_b_bits(x_values_sym[k*DATA_WIDTH +: DATA_WIDTH]),
                .m_valid(sym_valid),
                .m_ready(1'b1),
                .m_result_bits(sym_result_bits),
                .m_status(sym_status_bits)
            );

            assign routed_products_main[k*DATA_WIDTH +: DATA_WIDTH] = main_result_bits;
            assign routed_products_sym[k*DATA_WIDTH +: DATA_WIDTH]  = sym_result_bits;
            assign valid_mask_main[k] = main_valid;
            assign valid_mask_sym[k]  = sym_valid;
            assign unused_status = &{1'b0, main_status_bits, sym_status_bits, main_ready, sym_ready};
        end
    endgenerate

endmodule
