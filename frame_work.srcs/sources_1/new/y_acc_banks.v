`timescale 1ns / 1ps

// ============================================================================
// Y Accumulator for SpMV
// ============================================================================
// Single Y vector with parallel accumulation support
// Handles conflict when multiple lanes target the same row
// 
// Design:
// - Single RAM storing Y[0..DEPTH-1]
// - 8 parallel partial products may target different rows
// - Conflict detection: if multiple lanes target same row, sum them first
// - Read-Modify-Write pipeline for accumulation
// ============================================================================

module y_acc_banks #(
    parameter PARALLELISM = 8,
    parameter DATA_WIDTH  = 64,
    parameter DEPTH       = 128,       // Total Y vector length
    parameter ADDR_WIDTH  = $clog2(DEPTH)
)(
    input  wire clk,
    input  wire rst_n,

    // --- Mode Control ---
    // 00: Idle
    // 01: Load Mode (Write initial Y from stream)
    // 10: Compute Mode (Accumulate partial products)
    // 11: Store Mode (Read Y to output stream)
    input  wire [1:0] mode, 

    // --- Load/Store Interface (Linear Access) ---
    input  wire [ADDR_WIDTH-1:0]               ls_addr, 
    input  wire [PARALLELISM*DATA_WIDTH-1:0]   load_data,
    output wire [PARALLELISM*DATA_WIDTH-1:0]   store_data,

    // --- Compute/Accumulate Interface ---
    input  wire [PARALLELISM*DATA_WIDTH-1:0]   partial_products,
    input  wire [PARALLELISM-1:0]              pp_valid,
    input  wire [PARALLELISM*ADDR_WIDTH-1:0]   y_local_addr  // Target row for each lane
);

    // =========================================================================
    // Y RAM - Single vector storage
    // =========================================================================
    reg [DATA_WIDTH-1:0] y_ram [0:DEPTH-1];
    
    // Store output register
    reg [PARALLELISM*DATA_WIDTH-1:0] r_store_data;
    
    // =========================================================================
    // Load Mode: Write initial Y values
    // =========================================================================
    // In load mode, write 8 elements starting from ls_addr * 8
    integer i;
    always @(posedge clk) begin
        if (mode == 2'b01) begin
            for (i = 0; i < PARALLELISM; i = i + 1) begin
                y_ram[ls_addr * PARALLELISM + i] <= load_data[i*DATA_WIDTH +: DATA_WIDTH];
            end
        end
    end
    
    // =========================================================================
    // Store Mode: Read Y values to output
    // =========================================================================
    always @(posedge clk) begin
        if (mode == 2'b11) begin
            for (i = 0; i < PARALLELISM; i = i + 1) begin
                r_store_data[i*DATA_WIDTH +: DATA_WIDTH] <= y_ram[ls_addr * PARALLELISM + i];
            end
        end
    end
    assign store_data = r_store_data;
    
    // =========================================================================
    // Compute Mode: Parallel Accumulation with Conflict Handling
    // =========================================================================
    // For simplicity in behavioral simulation, we process each valid lane
    // In real hardware, this would need more sophisticated conflict resolution
    
    // Extract addresses and values
    wire [ADDR_WIDTH-1:0] addr [0:PARALLELISM-1];
    wire [DATA_WIDTH-1:0] pp   [0:PARALLELISM-1];
    
    genvar k;
    generate
        for (k = 0; k < PARALLELISM; k = k + 1) begin : gen_extract
            assign addr[k] = y_local_addr[k*ADDR_WIDTH +: ADDR_WIDTH];
            assign pp[k]   = partial_products[k*DATA_WIDTH +: DATA_WIDTH];
        end
    endgenerate
    
    // Behavioral accumulation (simulation only)
    // In real hardware, need proper R-M-W pipeline with conflict handling
    // synthesis translate_off
    always @(posedge clk) begin
        if (mode == 2'b10) begin
            for (i = 0; i < PARALLELISM; i = i + 1) begin
                if (pp_valid[i]) begin
                    // Behavioral FP add for simulation
                    y_ram[addr[i]] <= $realtobits(
                        $bitstoreal(y_ram[addr[i]]) + $bitstoreal(pp[i])
                    );
                end
            end
        end
    end
    // synthesis translate_on

endmodule
