`timescale 1ns / 1ps

module compute_pipeline #(
    parameter PARALLELISM = 8,
    parameter DATA_WIDTH  = 64
)(
    input  wire clk,
    input  wire [PARALLELISM*DATA_WIDTH-1:0] matrix_values,
    input  wire [PARALLELISM*DATA_WIDTH-1:0] x_values,
    input  wire [PARALLELISM*16-1:0]         dest_row_idx, // Not used in compute, passed through or used for routing?
    
    // Output routed to partial products
    output wire [PARALLELISM*DATA_WIDTH-1:0] routed_products,
    output wire [PARALLELISM-1:0]            valid_mask
);

    // Mock Compute: Just multiply
    // In real FP64, this takes many cycles. 
    // We will assume simplified output for connectivity check.
    
    genvar k;
    generate
        for (k = 0; k < PARALLELISM; k = k + 1) begin : gen_mult
            wire [63:0] a = matrix_values[k*64 +: 64];
            wire [63:0] b = x_values[k*64 +: 64];
            
            // Simplified multiplication (Integer for demo, or real * if supported)
            // For behavioral simulation of data flow, we can just pass through or *
            reg [63:0] prod;
            always @(posedge clk) begin
                prod <= a * b; // 1 cycle latency
            end
            
            assign routed_products[k*64 +: 64] = prod;
            assign valid_mask[k] = 1'b1; // Always valid if pipeline is full
        end
    endgenerate

endmodule
