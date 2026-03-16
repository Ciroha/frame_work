`timescale 1ns / 1ps

module x_mem_banks #(
    parameter PARALLELISM = 8,
    parameter DATA_WIDTH  = 64,
    parameter DEPTH       = 4096, // 4K depth per bank -> 32K elements total
    parameter ADDR_WIDTH  = $clog2(DEPTH),
    parameter GLOBAL_ADDR_WIDTH = $clog2(DEPTH * PARALLELISM)
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
    output wire [PARALLELISM*DATA_WIDTH-1:0]   rd_data_vec,

    // Port C: duplicated full-vector storage for arbitrary mirrored reads
    input  wire [PARALLELISM*GLOBAL_ADDR_WIDTH-1:0] arb_rd_global_idx_vec,
    output wire [PARALLELISM*DATA_WIDTH-1:0]        arb_rd_data_vec
);
    localparam TOTAL_ELEMS = DEPTH * PARALLELISM;

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

    reg [DATA_WIDTH-1:0] flat_ram [0:TOTAL_ELEMS-1];
    reg [DATA_WIDTH-1:0] arb_dout [0:PARALLELISM-1];
    wire [GLOBAL_ADDR_WIDTH-1:0] arb_idx [0:PARALLELISM-1];

    generate
        for (k = 0; k < PARALLELISM; k = k + 1) begin : gen_arb_extract
            assign arb_idx[k] = arb_rd_global_idx_vec[k*GLOBAL_ADDR_WIDTH +: GLOBAL_ADDR_WIDTH];
            assign arb_rd_data_vec[k*DATA_WIDTH +: DATA_WIDTH] = arb_dout[k];
        end
    endgenerate

    integer i;
    always @(posedge clk) begin
        if (load_en) begin
            for (i = 0; i < PARALLELISM; i = i + 1) begin
                flat_ram[load_addr * PARALLELISM + i] <= load_data[i*DATA_WIDTH +: DATA_WIDTH];
            end
        end

        for (i = 0; i < PARALLELISM; i = i + 1) begin
            if (arb_idx[i] < TOTAL_ELEMS) begin
                arb_dout[i] <= flat_ram[arb_idx[i]];
            end else begin
                arb_dout[i] <= {DATA_WIDTH{1'b0}};
            end
        end
    end

endmodule
