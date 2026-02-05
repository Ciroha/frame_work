`timescale 1ns / 1ps

module tb_b8c_top_ram();

    parameter AXI_WIDTH    = 512;
    parameter PARALLELISM  = 8;
    parameter VECTOR_DEPTH = 16; // Small depth for simulation

    // =========================================================
    // FP64 Constants (IEEE 754 Double Precision)
    // =========================================================
    localparam [63:0] FP64_1_0 = 64'h3FF0_0000_0000_0000; // 1.0
    localparam [63:0] FP64_2_0 = 64'h4000_0000_0000_0000; // 2.0
    localparam [63:0] FP64_0_5 = 64'h3FE0_0000_0000_0000; // 0.5
    localparam [63:0] FP64_0_0 = 64'h0000_0000_0000_0000; // 0.0
    localparam [63:0] FP64_3_0 = 64'h4008_0000_0000_0000; // 3.0
    localparam [63:0] FP64_4_0 = 64'h4010_0000_0000_0000; // 4.0
    
    logic clk;
    logic rst_n;
    
    // AXI Stream Inputs
    logic [AXI_WIDTH-1:0] s_axis_tdata;
    logic                 s_axis_tvalid;
    logic                 s_axis_tlast;
    wire                  s_axis_tready;
    
    // AXI Stream Outputs
    wire [AXI_WIDTH-1:0] m_axis_tdata;
    wire                 m_axis_tvalid;
    logic                m_axis_tready;
    wire                 m_axis_tlast;
    
    // =========================================================
    // Metadata Blob (5 x 512 = 2560 bits for 16 Super-rows)
    // =========================================================
    logic [2559:0] full_meta_blob;
    
    // Instance
    b8c_top #(
        .AXI_WIDTH(AXI_WIDTH),
        .PARALLELISM(PARALLELISM),
        .VECTOR_DEPTH(VECTOR_DEPTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tready(s_axis_tready),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast)
    );
    
    // Clock
    always #5 clk = ~clk;
    
    initial begin
        clk = 0;
        rst_n = 0;
        s_axis_tvalid = 0;
        s_axis_tdata = 0;
        s_axis_tlast = 0;
        m_axis_tready = 1;
        
        // Build Metadata Blob (Same pattern as tb_b8c_decode)
        // Format: {RowDeltas[7:0], ColBase, RowBase} = 160 bits per Super-row
        full_meta_blob = 0;
        for (int i = 0; i < 16; i++) begin
            // RowBase at [15:0]
            full_meta_blob[i*160 +: 16] = 16'h0000 + i; // Base row = i
            // ColBase at [31:16]
            full_meta_blob[i*160 + 16 +: 16] = 16'h0000 + i*8; // Column base = i*8
            // Deltas at [159:32] - 8 x 16-bit
            for (int j = 0; j < 8; j++) begin
                full_meta_blob[i*160 + 32 + j*16 +: 16] = j; // Delta = lane index
            end
        end
        
        #50;
        rst_n = 1;
        #20;
        
        // ------------------------------------------------
        // 1. Stream X (FP64: All 1.0) - Burst Mode
        // ------------------------------------------------
        $display("Starting Load X (Burst: %0d beats of 8x FP64 = 1.0)...", VECTOR_DEPTH);
        feed_burst_const({FP64_1_0, FP64_2_0, FP64_1_0, FP64_2_0,
                          FP64_1_0, FP64_2_0, FP64_1_0, FP64_2_0}, 
                         VECTOR_DEPTH, 0);  // No tlast
        
        // ------------------------------------------------
        // 2. Stream Y Initial (FP64: All 0.0) - Burst Mode
        // ------------------------------------------------
        $display("Starting Load Y (Burst: %0d beats of 8x FP64 = 0.0)...", VECTOR_DEPTH);
        feed_burst_const({FP64_0_0, FP64_0_0, FP64_0_0, FP64_0_0,
                          FP64_0_0, FP64_0_0, FP64_0_0, FP64_0_0}, 
                         VECTOR_DEPTH, 0);  // No tlast
        
        // Wait 1 cycle for FSM to transition from LOAD_Y to COMPUTE
        @(posedge clk);
        
        // ------------------------------------------------
        // 3. Stream Matrix (Compute) - Burst Mode
        // ------------------------------------------------
        $display("Starting Compute Stream (Burst: 16 Data + 5 Metadata)...");
        
        // Prepare data array for burst (21 beats total)
        begin
            reg [AXI_WIDTH-1:0] matrix_burst [0:20];
            
            // 16 Data Lines (alternating 1.0/2.0)
            for (int i = 0; i < 16; i++) begin
                if (i % 2 == 0)
                    matrix_burst[i] = {FP64_1_0, FP64_1_0, FP64_1_0, FP64_1_0,
                                       FP64_1_0, FP64_1_0, FP64_1_0, FP64_1_0};
                else
                    matrix_burst[i] = {FP64_2_0, FP64_2_0, FP64_2_0, FP64_2_0,
                                       FP64_2_0, FP64_2_0, FP64_2_0, FP64_2_0};
            end
            
            // 5 Metadata Lines
            for (int i = 0; i < 5; i++) begin
                matrix_burst[16 + i] = full_meta_blob[i*512 +: 512];
            end
            
            // Burst transfer all 21 beats with tlast on final
            feed_burst_array(matrix_burst, 21, 1);
        end
        $display("[%0t] All data sent!", $time);
        
        // ------------------------------------------------
        // 4. Wait for Store Y
        // ------------------------------------------------
        $display("Waiting for Store Y...");
        wait(m_axis_tvalid);
        
        $display("Y Writeback Started!");
        for (int i = 0; i < VECTOR_DEPTH; i++) begin
            @(posedge clk);
            if (m_axis_tvalid && m_axis_tready) begin
                $display("Y[%0d] = %h %h %h %h %h %h %h %h", i,
                    m_axis_tdata[64*7 +: 64], m_axis_tdata[64*6 +: 64],
                    m_axis_tdata[64*5 +: 64], m_axis_tdata[64*4 +: 64],
                    m_axis_tdata[64*3 +: 64], m_axis_tdata[64*2 +: 64],
                    m_axis_tdata[64*1 +: 64], m_axis_tdata[64*0 +: 64]);
                if (m_axis_tlast) break;
            end
        end
        
        $display("Test Done.");
        #100;
        $finish;
    end
    
    // Single beat transfer (with gap between beats)
    task feed_data;
        input [AXI_WIDTH-1:0] data;
        input                 last;
        begin
            @(posedge clk);
            s_axis_tvalid <= 1;
            s_axis_tdata <= data;
            s_axis_tlast <= last;
            
            @(posedge clk);
            while (!s_axis_tready) begin
                @(posedge clk);
            end
            s_axis_tvalid <= 0;
            s_axis_tlast <= 0;
        end
    endtask
    
    // Burst mode: continuous transfer of constant data (tvalid stays high)
    task feed_burst_const;
        input [AXI_WIDTH-1:0] data;
        input int count;
        input last_beat;  // Apply tlast on final beat?
        begin
            @(posedge clk);
            s_axis_tvalid <= 1;
            s_axis_tdata <= data;
            
            for (int i = 0; i < count; i++) begin
                s_axis_tlast <= (last_beat && (i == count - 1)) ? 1'b1 : 1'b0;
                @(posedge clk);
                // Wait for handshake
                while (!s_axis_tready) begin
                    @(posedge clk);
                end
            end
            
            s_axis_tvalid <= 0;
            s_axis_tlast <= 0;
        end
    endtask
    
    // Burst mode: continuous transfer from array (tvalid stays high)
    task feed_burst_array;
        input reg [AXI_WIDTH-1:0] data_arr [0:20];
        input int count;
        input last_beat;  // Apply tlast on final beat?
        begin
            @(posedge clk);
            s_axis_tvalid <= 1;
            
            for (int i = 0; i < count; i++) begin
                s_axis_tdata <= data_arr[i];
                s_axis_tlast <= (last_beat && (i == count - 1)) ? 1'b1 : 1'b0;
                @(posedge clk);
                // Wait for handshake
                while (!s_axis_tready) begin
                    @(posedge clk);
                end
            end
            
            s_axis_tvalid <= 0;
            s_axis_tlast <= 0;
        end
    endtask

endmodule
