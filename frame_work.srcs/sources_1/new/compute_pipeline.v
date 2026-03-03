`timescale 1ns / 1ps

module compute_pipeline #(
    parameter PARALLELISM = 8,
    parameter DATA_WIDTH  = 64
)(
    input  wire clk,
    input  wire [PARALLELISM*DATA_WIDTH-1:0] matrix_values,
    input  wire [PARALLELISM*DATA_WIDTH-1:0] x_values,
    // input  wire [PARALLELISM*16-1:0]         dest_row_idx, // Not used in compute, passed through
    
    // Output routed to partial products
    output wire [PARALLELISM*DATA_WIDTH-1:0] routed_products,
    output wire [PARALLELISM-1:0]            valid_mask
);

    // FP64 Multiply: Use behavioral real arithmetic for simulation
    // For synthesis: replace with Vivado FP IP (floating_point multiplier)
    //TODO replace with real fp IP/DSP
    
    genvar k;
    generate
        for (k = 0; k < PARALLELISM; k = k + 1) begin : gen_mult
            wire [63:0] a = matrix_values[k*64 +: 64];
            wire [63:0] b = x_values[k*64 +: 64];
            
            // Behavioral FP64 multiplication for simulation
            reg [63:0] prod;
            
            // synthesis translate_off
            // Simulation only: use real arithmetic
            real a_real, b_real, prod_real;
            always @(*) begin
                a_real = $bitstoreal(a);
                b_real = $bitstoreal(b);
                prod_real = a_real * b_real;
            end
            
            always @(posedge clk) begin
                prod <= $realtobits(prod_real); // 1 cycle latency
            end
            // synthesis translate_on
            
            // synthesis code would instantiate FP IP here
            // For now, assign prod for synthesis (will be optimized away or replaced)
            `ifdef SYNTHESIS
            // TODO: Instantiate Vivado floating_point IP
            // fp_mult u_fp_mult (.aclk(clk), .s_axis_a_tdata(a), .s_axis_b_tdata(b), .m_axis_result_tdata(prod));
            `endif
            
            assign routed_products[k*64 +: 64] = prod;
            assign valid_mask[k] = 1'b1; // Always valid if pipeline is full
        end
    endgenerate

endmodule
