`timescale 1ns / 1ps

module tb_b8c_top_ram();

    parameter AXI_WIDTH    = 512;
    parameter PARALLELISM  = 8;
    parameter VECTOR_DEPTH = 16; // Small depth for simulation
    parameter Y_ELEMS      = 23; // Expected output vector elements
    localparam Y_BEATS     = (Y_ELEMS + PARALLELISM - 1) / PARALLELISM;

    // =========================================================
    // FP64 Constants (IEEE 754 Double Precision)
    // =========================================================
    localparam [63:0] FP64_1_0 = 64'h3FF0_0000_0000_0000; // 1.0
    localparam [63:0] FP64_2_0 = 64'h4000_0000_0000_0000; // 2.0
    localparam [63:0] FP64_0_0 = 64'h0000_0000_0000_0000; // 0.0
    
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
    
    // Golden output for automatic checking
    real         golden_y      [0:Y_ELEMS-1];
    logic [63:0] golden_y_bits [0:Y_ELEMS-1];
    
    // Instance
    b8c_top #(
        .AXI_WIDTH(AXI_WIDTH),
        .PARALLELISM(PARALLELISM),
        .VECTOR_DEPTH(VECTOR_DEPTH),
        .Y_ELEMS(Y_ELEMS)
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
        int error_count;
        int beat_count;
        int scalar_idx;
        bit saw_tlast;

        clk = 0;
        rst_n = 0;
        s_axis_tvalid = 0;
        s_axis_tdata = 0;
        s_axis_tlast = 0;
        m_axis_tready = 1;
        error_count = 0;
        beat_count = 0;
        scalar_idx = 0;
        saw_tlast = 0;

        build_golden_y();
        
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
        // 1. Stream X (FP64: 1.0/2.0 alternating) - Burst Mode
        // ------------------------------------------------
        $display("Starting Load X (Burst: %0d beats of 8x FP64 = 1.0/2.0 alternating)...", VECTOR_DEPTH);
        feed_burst_const({FP64_1_0, FP64_2_0, FP64_1_0, FP64_2_0,
                          FP64_1_0, FP64_2_0, FP64_1_0, FP64_2_0}, 
                         VECTOR_DEPTH, 0);  // No tlast
        
        // ------------------------------------------------
        // 2. Stream Y Initial (FP64: All 0.0) - Burst Mode
        // ------------------------------------------------
        $display("Starting Load Y (Burst: %0d beats of 8x FP64 = 0.0)...", Y_BEATS);
        feed_burst_const({FP64_0_0, FP64_0_0, FP64_0_0, FP64_0_0,
                          FP64_0_0, FP64_0_0, FP64_0_0, FP64_0_0}, 
                         Y_BEATS, 0);  // No tlast
        
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
        while (beat_count < Y_BEATS) begin
            @(posedge clk);
            if (m_axis_tvalid && m_axis_tready) begin
                $display("Y[%0d] = %h %h %h %h %h %h %h %h", beat_count,
                    m_axis_tdata[64*7 +: 64], m_axis_tdata[64*6 +: 64],
                    m_axis_tdata[64*5 +: 64], m_axis_tdata[64*4 +: 64],
                    m_axis_tdata[64*3 +: 64], m_axis_tdata[64*2 +: 64],
                    m_axis_tdata[64*1 +: 64], m_axis_tdata[64*0 +: 64]);

                // Check 8 scalars in lane order: lane0..lane7
                for (int lane = 0; lane < PARALLELISM; lane++) begin
                    logic [63:0] act;
                    act = m_axis_tdata[lane*64 +: 64];
                    if (scalar_idx < Y_ELEMS) begin
                        if (act !== golden_y_bits[scalar_idx]) begin
                            $error("Y mismatch at scalar %0d: exp=%h got=%h",
                                   scalar_idx, golden_y_bits[scalar_idx], act);
                            error_count++;
                        end
                    end else begin
                        // Padding lanes after Y_ELEMS must be zero.
                        if (act !== FP64_0_0) begin
                            $error("Padding lane mismatch at scalar %0d: exp=0 got=%h",
                                   scalar_idx, act);
                            error_count++;
                        end
                    end
                    scalar_idx++;
                end

                // TLAST must be asserted only on the final output beat.
                if ((beat_count == Y_BEATS-1) && !m_axis_tlast) begin
                    $error("Missing TLAST on final beat %0d", beat_count);
                    error_count++;
                end
                if ((beat_count != Y_BEATS-1) && m_axis_tlast) begin
                    $error("Unexpected TLAST on non-final beat %0d", beat_count);
                    error_count++;
                end
                if (m_axis_tlast) saw_tlast = 1;

                beat_count++;
            end
        end

        if (!saw_tlast) begin
            $error("TLAST was never observed on output stream.");
            error_count++;
        end
        if (scalar_idx != Y_BEATS * PARALLELISM) begin
            $error("Output scalar count mismatch: got=%0d exp=%0d",
                   scalar_idx, Y_BEATS * PARALLELISM);
            error_count++;
        end
        if (error_count == 0) begin
            $display("AUTO-CHECK PASSED: %0d valid scalars + %0d padding scalars",
                     Y_ELEMS, Y_BEATS*PARALLELISM - Y_ELEMS);
        end else begin
            $fatal(1, "AUTO-CHECK FAILED with %0d mismatches", error_count);
        end
        
        $display("Test Done.");
        #100;
        $finish;
    end

    task automatic build_golden_y;
        real matrix_v;
        real x_v;
        int r;
        begin
            // Initialize with 0.0
            for (int idx = 0; idx < Y_ELEMS; idx++) begin
                golden_y[idx] = 0.0;
            end

            // Reconstruct expected Y for this testcase pattern:
            // matrix row i has value 1.0 (even i) or 2.0 (odd i)
            // lane l reads X lane value: lane even -> 2.0, lane odd -> 1.0
            // destination row = i + l
            for (int i = 0; i < 16; i++) begin
                matrix_v = (i % 2 == 0) ? 1.0 : 2.0;
                for (int lane = 0; lane < PARALLELISM; lane++) begin
                    x_v = (lane % 2 == 0) ? 2.0 : 1.0;
                    r = i + lane;
                    if (r < Y_ELEMS) begin
                        golden_y[r] = golden_y[r] + matrix_v * x_v;
                    end
                end
            end

            for (int idx = 0; idx < Y_ELEMS; idx++) begin
                golden_y_bits[idx] = $realtobits(golden_y[idx]);
            end
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
