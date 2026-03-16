`timescale 1ns / 1ps

module compute_pipeline #(
    parameter PARALLELISM = 8,
    parameter DATA_WIDTH  = 64
)(
    input  wire clk,
    input  wire [PARALLELISM*DATA_WIDTH-1:0] matrix_values,
    input  wire [PARALLELISM*DATA_WIDTH-1:0] x_values_main,
    input  wire [PARALLELISM*DATA_WIDTH-1:0] x_values_sym,
    
    // Output routed to partial products
    output wire [PARALLELISM*DATA_WIDTH-1:0] routed_products_main,
    output wire [PARALLELISM*DATA_WIDTH-1:0] routed_products_sym,
    output wire [PARALLELISM-1:0]            valid_mask_main,
    output wire [PARALLELISM-1:0]            valid_mask_sym
);

    // FP64 Multiply: Use behavioral real arithmetic for simulation
    // For synthesis: replace with Vivado FP IP (floating_point multiplier)
    //TODO replace with real fp IP/DSP
    
    genvar k;
    generate
        for (k = 0; k < PARALLELISM; k = k + 1) begin : gen_mult
            wire [63:0] a = matrix_values[k*64 +: 64];
            wire [63:0] b_main = x_values_main[k*64 +: 64];
            wire [63:0] b_sym = x_values_sym[k*64 +: 64];
            
            // Behavioral FP64 multiplication for simulation
            reg [63:0] prod_main;
            reg [63:0] prod_sym;
            
            // synthesis translate_off
            // Simulation only: use real arithmetic
            real a_real, b_main_real, b_sym_real, prod_main_real, prod_sym_real;
            always @(*) begin
                a_real = $bitstoreal(a);
                b_main_real = $bitstoreal(b_main);
                b_sym_real = $bitstoreal(b_sym);
                prod_main_real = a_real * b_main_real;
                prod_sym_real = a_real * b_sym_real;
            end
            
            always @(posedge clk) begin
                prod_main <= $realtobits(prod_main_real); // 1 cycle latency
                prod_sym <= $realtobits(prod_sym_real); // 1 cycle latency
            end
            // synthesis translate_on
            
            // synthesis code would instantiate FP IP here
            // For now, assign prod for synthesis (will be optimized away or replaced)
            `ifdef SYNTHESIS
            // TODO: Instantiate Vivado floating_point IP
            // fp_mult u_fp_mult (.aclk(clk), .s_axis_a_tdata(a), .s_axis_b_tdata(b), .m_axis_result_tdata(prod));
            `endif
            
            assign routed_products_main[k*64 +: 64] = prod_main;
            assign routed_products_sym[k*64 +: 64] = prod_sym;
            assign valid_mask_main[k] = 1'b1; // Always valid if pipeline is full
            assign valid_mask_sym[k] = 1'b1; // Always valid if pipeline is full
        end
    endgenerate

endmodule
