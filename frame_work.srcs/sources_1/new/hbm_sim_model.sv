`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Sub-module: HBM Simulation Model (Behavioral)
// ============================================================================
// Description:
// Simulates an HBM interface acting as an AXI-Stream Master.
// Reads data from a memory array (initialized via file) and streams it out.
// Supports backpressure via tready.
//////////////////////////////////////////////////////////////////////////////////

module hbm_sim_model #(
    parameter AXI_WIDTH = 512,
    parameter DEPTH     = 4096,
    parameter INIT_FILE = ""   // Path to .hex file for initialization
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   en,             // Start streaming
    
    // AXI-Stream Master Interface
    output reg  [AXI_WIDTH-1:0]   m_axis_tdata,
    output reg                    m_axis_tvalid,
    input  wire                   m_axis_tready
);

    // Memory Array
    reg [AXI_WIDTH-1:0] mem [0:DEPTH-1];
    
    // Pointers
    integer ptr;
    
    // Initialization
    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
            $display("[%t] [HBM_MODEL] Initialized memory from file: %s", $time, INIT_FILE);
        end else begin
            // Default Pattern: Incremental
            integer i;
            for (i = 0; i < DEPTH; i = i + 1) begin
                mem[i] = { (AXI_WIDTH/32) {i[31:0]} }; // Fill with repeated index
            end
            $display("[%t] [HBM_MODEL] Initialized memory with default pattern.", $time);
        end
    end

    // Streaming Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axis_tvalid <= 0;
            m_axis_tdata  <= 0;
            ptr           <= 0;
        end else begin
            if (en) begin
                // Simple Valid/Ready Handshake Logic
                // If valid is low, we can try to put data if we have lines left
                // If valid is high, we wait for ready before moving to next line
                
                if (!m_axis_tvalid || m_axis_tready) begin
                    if (ptr < DEPTH) begin
                        m_axis_tdata  <= mem[ptr];
                        m_axis_tvalid <= 1;
                        ptr           <= ptr + 1;
                    end else begin
                        m_axis_tvalid <= 0; // End of stream
                        // Optional: ptr <= 0; // Loop?
                    end
                end
            end else begin
                // Reset pointer (?) or just pause?
                // Typically 'en' acts as a start trigger or gate.
                // Keeping valid low if en is low.
                m_axis_tvalid <= 0;
                ptr <= 0;
            end
        end
    end

endmodule
