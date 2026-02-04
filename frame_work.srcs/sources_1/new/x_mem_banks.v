`timescale 1ns / 1ps

module x_mem_banks #(
    parameter PARALLELISM = 8,
    parameter DATA_WIDTH  = 64,
    parameter DEPTH       = 4096, // 4K depth per bank -> 32K elements total
    parameter ADDR_WIDTH  = $clog2(DEPTH)
)(
    input  wire clk,
    
    // Port A: Load Interface (Write Only, usually Sequential/Linear)
    // Assumes writing all banks in parallel (Broadside Load) 
    // Data is packed: [Element 7, Element 6, ..., Element 0]
    input  wire                                load_en,
    input  wire [ADDR_WIDTH-1:0]               load_addr,
    input  wire [PARALLELISM*DATA_WIDTH-1:0]   load_data,
    
    // Port B: Compute Interface (Read Only, Random Scatters)
    // 8 independent addresses
    input  wire [PARALLELISM*ADDR_WIDTH-1:0]   rd_addr_vec,
    output wire [PARALLELISM*DATA_WIDTH-1:0]   rd_data_vec
);

    genvar k;
    generate
        for (k = 0; k < PARALLELISM; k = k + 1) begin : gen_banks
            
            // Extract signals for this bank
            wire [DATA_WIDTH-1:0] bank_din = load_data[k*DATA_WIDTH +: DATA_WIDTH];
            wire [ADDR_WIDTH-1:0] bank_ra  = rd_addr_vec[k*ADDR_WIDTH +: ADDR_WIDTH];
            reg  [DATA_WIDTH-1:0] bank_dout;
            
            // Infer BRAM
            (* ram_style = "block" *) reg [DATA_WIDTH-1:0] ram [0:DEPTH-1];
            
            always @(posedge clk) begin
                if (load_en) begin
                    ram[load_addr] <= bank_din;
                end
                // Read implies 1 cycle latency
                bank_dout <= ram[bank_ra];
            end
            
            assign rd_data_vec[k*DATA_WIDTH +: DATA_WIDTH] = bank_dout;
            
        end
    endgenerate

endmodule
