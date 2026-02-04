`timescale 1ns / 1ps

module y_acc_banks #(
    parameter PARALLELISM = 8,
    parameter DATA_WIDTH  = 64,
    parameter DEPTH       = 4096,
    parameter ADDR_WIDTH  = $clog2(DEPTH)
)(
    input  wire clk,
    input  wire rst_n,

    // --- Mode Control ---
    // 00: Idle
    // 01: Load Mode (Write to Port A from Load Stream)
    // 10: Compute Mode (Read/Add/Write via Port B)
    // 11: Store Mode (Read from Port A to Output Stream)
    input  wire [1:0] mode, 

    // --- Port A: Load/Store Interface (Linear Access) ---
    input  wire [ADDR_WIDTH-1:0]               ls_addr, 
    input  wire [PARALLELISM*DATA_WIDTH-1:0]   load_data,
    output wire [PARALLELISM*DATA_WIDTH-1:0]   store_data,

    // --- Port B: Compute/Accumulate Interface (Random Access) ---
    // In compute mode, we need to:
    // 1. Read old Y (Latency 1 or 2)
    // 2. Add Partial Product
    // 3. Write new Y
    // This is complex for a single port RAM without stalling.
    // However, standard "Accumulator" design often caches the active tile.
    // For this task, we will expose the RAM ports directly and let top manage timing/hazards.
    // Or we assume Read-Modify-Write takes multiple cycles and pipeline handles it.
    
    // For simplicity in this step, we'll provide standard RAM interface.
    // The "Accumulate" definition in b8c_top implies logic OUTSIDE this module does the Add.
    // b8c_top has: y_acc_banks updates Y.
    // Actually, looking at b8c_top connections:
    // .partial_products(partial_products), .pp_valid(pp_valid), .y_local_addr...
    // This suggests 'y_acc_banks' encapsulates the Adder.
    
    input  wire [PARALLELISM*DATA_WIDTH-1:0]   partial_products,
    input  wire [PARALLELISM-1:0]              pp_valid,
    input  wire [PARALLELISM*ADDR_WIDTH-1:0]   y_local_addr
);

    // To handle the Read-Add-Write (RAW) latency, simpler to assume
    // we use True Dual Port RAM.
    // Port A: Load/Store (Seq)
    // Port B: Read for Compute
    //         Write for Compute? 
    // We cannot Read and Write different addresses on Port B in same cycle.
    // So we need distinct Read and Write cycles or True Dual Port.
    // If we use TDP RAM (A and B), Load/Store uses A. Compute uses A(Read)+B(Write)?
    // But Load/Store needs access too.
    
    // Let's implement simple atomic accumulation logic internal to this module.
    // Warning: Pipeline latency means we can't accumulate to same address back-to-back.
    // We will assume sparse updates or ignore hazard for this specific task level.
    
    genvar k;
    generate
        for (k = 0; k < PARALLELISM; k = k + 1) begin : gen_y_banks
            
            // Signals
            wire [DATA_WIDTH-1:0]       pp_val = partial_products[k*DATA_WIDTH +: DATA_WIDTH];
            wire                        pp_vld = pp_valid[k];
            wire [ADDR_WIDTH-1:0]       acc_addr = y_local_addr[k*ADDR_WIDTH +: ADDR_WIDTH];
            
            reg  [DATA_WIDTH-1:0]       ram [0:DEPTH-1];
            reg  [DATA_WIDTH-1:0]       r_acc_data;
            reg  [DATA_WIDTH-1:0]       r_store_data;
            
            // --- Port A Operation (Load/Store) ---
            always @(posedge clk) begin
                if (mode == 2'b01) begin // Load
                    ram[ls_addr] <= load_data[k*DATA_WIDTH +: DATA_WIDTH];
                end
                
                // Read for Store
                r_store_data <= ram[ls_addr];
            end

            // --- Port B Operation (Accumulate) ---
            // Simplified Read-Modify-Write
            // In real hardware this needs careful scheduling (Read cycle K, Add, Write cycle K+2).
            // Here we model "Behavioral Accumulate" which is not synthesizeable 1:1 with BlockRAM 
            // unless we use specific primitives or low freq.
            // But for functional correctness logic:
            
            // To make it synthesizeable to BRAM, we normally need:
            // clk edge -> Read -> Output
            // clk edge -> Write
            
            // We'll separate Read and Write.
            // But the interface is "Here is a partial product, add it."
            // This implies the module does the fetch and add.
            // Let's stick to behavioral for user's logic simulation request.
            
            always @(posedge clk) begin
                if (mode == 2'b10 && pp_vld) begin
                    ram[acc_addr] <= ram[acc_addr] + pp_val; // Behavioral RMW
                end
            end
            
            assign store_data[k*DATA_WIDTH +: DATA_WIDTH] = r_store_data;
            
        end
    endgenerate

endmodule
