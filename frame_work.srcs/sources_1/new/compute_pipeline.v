`timescale 1ns / 1ps

module compute_pipeline #(
    parameter PARALLELISM = 8,
    parameter DATA_WIDTH  = 64,
    parameter MUL_LATENCY = 8,
    parameter SIM_USE_IP  = 1'b1,
    parameter ENABLE_SYM_PATH = 1'b1
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

`ifndef SYNTHESIS
    generate
        if (SIM_USE_IP) begin : gen_mul_ip
            genvar k_ip;
            for (k_ip = 0; k_ip < PARALLELISM; k_ip = k_ip + 1) begin : gen_mul_lane
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
                    .s_a_bits(matrix_values[k_ip*DATA_WIDTH +: DATA_WIDTH]),
                    .s_b_bits(x_values_main[k_ip*DATA_WIDTH +: DATA_WIDTH]),
                    .m_valid(main_valid),
                    .m_ready(1'b1),
                    .m_result_bits(main_result_bits),
                    .m_status(main_status_bits)
                );

                if (ENABLE_SYM_PATH) begin : gen_sym_ip
                    fp64_mul_xilinx_wrapper #(
                        .LATENCY(MUL_LATENCY)
                    ) u_mul_sym (
                        .clk(clk),
                        .s_valid(in_valid),
                        .s_ready(sym_ready),
                        .s_a_bits(matrix_values[k_ip*DATA_WIDTH +: DATA_WIDTH]),
                        .s_b_bits(x_values_sym[k_ip*DATA_WIDTH +: DATA_WIDTH]),
                        .m_valid(sym_valid),
                        .m_ready(1'b1),
                        .m_result_bits(sym_result_bits),
                        .m_status(sym_status_bits)
                    );
                end else begin : gen_sym_ip_off
                    assign sym_result_bits = {DATA_WIDTH{1'b0}};
                    assign sym_valid = 1'b0;
                    assign sym_ready = 1'b1;
                    assign sym_status_bits = 5'b0;
                end

                assign routed_products_main[k_ip*DATA_WIDTH +: DATA_WIDTH] = main_result_bits;
                assign routed_products_sym[k_ip*DATA_WIDTH +: DATA_WIDTH]  = sym_result_bits;
                assign valid_mask_main[k_ip] = main_valid;
                assign valid_mask_sym[k_ip]  = sym_valid;
                assign unused_status = &{1'b0, main_status_bits, sym_status_bits, main_ready, sym_ready};
            end
        end else begin : gen_mul_behavior
            genvar k_beh;
            for (k_beh = 0; k_beh < PARALLELISM; k_beh = k_beh + 1) begin : gen_mul_lane
                reg [DATA_WIDTH-1:0] main_data_pipe [0:MUL_LATENCY-1];
                reg [DATA_WIDTH-1:0] sym_data_pipe [0:MUL_LATENCY-1];
                reg                  main_valid_pipe [0:MUL_LATENCY-1];
                reg                  sym_valid_pipe [0:MUL_LATENCY-1];
                real                 main_mul_real;
                real                 sym_mul_real;
                integer              pipe_idx;

                always @(posedge clk) begin
                    for (pipe_idx = MUL_LATENCY-1; pipe_idx > 0; pipe_idx = pipe_idx - 1) begin
                        main_data_pipe[pipe_idx] <= main_data_pipe[pipe_idx-1];
                        sym_data_pipe[pipe_idx] <= sym_data_pipe[pipe_idx-1];
                        main_valid_pipe[pipe_idx] <= main_valid_pipe[pipe_idx-1];
                        sym_valid_pipe[pipe_idx] <= sym_valid_pipe[pipe_idx-1];
                    end

                    if (in_valid) begin
                        main_mul_real = $bitstoreal(matrix_values[k_beh*DATA_WIDTH +: DATA_WIDTH]) *
                                        $bitstoreal(x_values_main[k_beh*DATA_WIDTH +: DATA_WIDTH]);
                        main_data_pipe[0] <= $realtobits(main_mul_real);
                        main_valid_pipe[0] <= 1'b1;
                        if (ENABLE_SYM_PATH) begin
                            sym_mul_real = $bitstoreal(matrix_values[k_beh*DATA_WIDTH +: DATA_WIDTH]) *
                                           $bitstoreal(x_values_sym[k_beh*DATA_WIDTH +: DATA_WIDTH]);
                            sym_data_pipe[0] <= $realtobits(sym_mul_real);
                            sym_valid_pipe[0] <= 1'b1;
                        end else begin
                            sym_data_pipe[0] <= {DATA_WIDTH{1'b0}};
                            sym_valid_pipe[0] <= 1'b0;
                        end
                    end else begin
                        main_data_pipe[0] <= {DATA_WIDTH{1'b0}};
                        sym_data_pipe[0] <= {DATA_WIDTH{1'b0}};
                        main_valid_pipe[0] <= 1'b0;
                        sym_valid_pipe[0] <= 1'b0;
                    end
                end

                assign routed_products_main[k_beh*DATA_WIDTH +: DATA_WIDTH] = main_data_pipe[MUL_LATENCY-1];
                assign routed_products_sym[k_beh*DATA_WIDTH +: DATA_WIDTH]  = sym_data_pipe[MUL_LATENCY-1];
                assign valid_mask_main[k_beh] = main_valid_pipe[MUL_LATENCY-1];
                assign valid_mask_sym[k_beh]  = sym_valid_pipe[MUL_LATENCY-1];
            end
        end
    endgenerate
`else
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

            if (ENABLE_SYM_PATH) begin : gen_sym_ip
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
            end else begin : gen_sym_ip_off
                assign sym_result_bits = {DATA_WIDTH{1'b0}};
                assign sym_valid = 1'b0;
                assign sym_ready = 1'b1;
                assign sym_status_bits = 5'b0;
            end

            assign routed_products_main[k*DATA_WIDTH +: DATA_WIDTH] = main_result_bits;
            assign routed_products_sym[k*DATA_WIDTH +: DATA_WIDTH]  = sym_result_bits;
            assign valid_mask_main[k] = main_valid;
            assign valid_mask_sym[k]  = sym_valid;
            assign unused_status = &{1'b0, main_status_bits, sym_status_bits, main_ready, sym_ready};
        end
    endgenerate
`endif

endmodule
