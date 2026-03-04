`timescale 1ns / 1ps

module tb_b8c_top_ram();

    parameter AXI_WIDTH    = 512;
    parameter PARALLELISM  = 8;
    parameter MODE_ID52    = 1'b1;
    parameter VECTOR_DEPTH = 512;   // hpcg_16-1: 4096 cols / 8 lanes
    parameter Y_ELEMS      = 4096;  // hpcg_16-1 rows
    parameter MAT_DATA_BEATS = 12704; // hpcg_16-1 data beats (multiple of 16)
    localparam Y_BEATS        = (Y_ELEMS + PARALLELISM - 1) / PARALLELISM;
    localparam META_BEATS     = (MAT_DATA_BEATS / 16) * 5;
    localparam COMPUTE_BEATS  = MAT_DATA_BEATS + META_BEATS;
    localparam ID_VALS_PER_BEAT = AXI_WIDTH / 8;
    localparam ID_DATA_BEATS  = (MAT_DATA_BEATS * PARALLELISM + ID_VALS_PER_BEAT - 1) / ID_VALS_PER_BEAT;
    localparam COMPUTE_ID_BEATS = ID_DATA_BEATS + META_BEATS;
    localparam ACTIVE_COMPUTE_BEATS = MODE_ID52 ? COMPUTE_ID_BEATS : COMPUTE_BEATS;
    localparam COMPUTE_STREAM_MEM_BEATS = (COMPUTE_BEATS > COMPUTE_ID_BEATS) ? COMPUTE_BEATS : COMPUTE_ID_BEATS;

    parameter string X_STREAM_FILE       = "../../../../frame_work.srcs/sim_1/data/hpcg_16-1/x_stream.hex";
    parameter string Y_STREAM_FILE       = "../../../../frame_work.srcs/sim_1/data/hpcg_16-1/y_stream.hex";
    parameter string COMPUTE_STREAM_FILE = "../../../../frame_work.srcs/sim_1/data/hpcg_16-1/compute_stream.hex";
    parameter string COMPUTE_ID_STREAM_FILE = "../../../../frame_work.srcs/sim_1/data/hpcg_16-1/compute_id_stream.hex";
    parameter string LUT_FILE            = "../../../../frame_work.srcs/sim_1/data/hpcg_16-1/lut.hex";
    parameter string GOLDEN_Y_FILE       = "../../../../frame_work.srcs/sim_1/data/hpcg_16-1/golden_y.hex";

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
    
    // Stream data loaded from hex files
    logic [AXI_WIDTH-1:0] x_stream_mem       [0:VECTOR_DEPTH-1];
    logic [AXI_WIDTH-1:0] y_stream_mem       [0:Y_BEATS-1];
    logic [AXI_WIDTH-1:0] compute_stream_mem [0:COMPUTE_STREAM_MEM_BEATS-1];
    
    // Optional golden output (one 64-bit scalar per line)
    logic [63:0] golden_y_bits [0:Y_ELEMS-1];

    // Ready/backpressure stats during compute feed burst.
    int compute_ready_total_cycles;
    int compute_ready_high_cycles;
    int compute_ready_low_cycles;
    
    // Instance
    b8c_top #(
        .AXI_WIDTH(AXI_WIDTH),
        .PARALLELISM(PARALLELISM),
        .MODE_ID52(MODE_ID52),
        .LUT_INIT_FILE(LUT_FILE),
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
        bit enable_data_check;
        real ready_low_ratio;

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
        enable_data_check = 0;
        compute_ready_total_cycles = 0;
        compute_ready_high_cycles = 0;
        compute_ready_low_cycles = 0;
        
        if ((MAT_DATA_BEATS % 16) != 0) begin
            $fatal(1, "MAT_DATA_BEATS (%0d) must be a multiple of 16", MAT_DATA_BEATS);
        end

        // Load stream vectors from files.
        $readmemh(X_STREAM_FILE, x_stream_mem);
        $readmemh(Y_STREAM_FILE, y_stream_mem);
        if (MODE_ID52) begin
            $readmemh(COMPUTE_ID_STREAM_FILE, compute_stream_mem);
        end else begin
            $readmemh(COMPUTE_STREAM_FILE, compute_stream_mem);
        end
        $display("Loaded X stream from %s", X_STREAM_FILE);
        $display("Loaded Y stream from %s", Y_STREAM_FILE);
        if (MODE_ID52) begin
            $display("Loaded compute(ID+meta) stream from %s", COMPUTE_ID_STREAM_FILE);
            $display("Loaded LUT from %s", LUT_FILE);
        end else begin
            $display("Loaded compute stream from %s", COMPUTE_STREAM_FILE);
        end

        // Optional golden scalar output file.
        if (GOLDEN_Y_FILE != "") begin
            $readmemh(GOLDEN_Y_FILE, golden_y_bits);
            enable_data_check = 1;
            $display("Loaded golden Y from %s", GOLDEN_Y_FILE);
        end
        
        #50;
        rst_n = 1;
        #20;
        
        // ------------------------------------------------
        // 1. Stream X - Burst mode (from file)
        // ------------------------------------------------
        $display("Starting Load X (Burst: %0d beats from file)...", VECTOR_DEPTH);
        feed_burst_array(x_stream_mem, VECTOR_DEPTH, 0, 0);  // No tlast, no ready stats
        
        // ------------------------------------------------
        // 2. Stream Y Initial - Burst mode (from file)
        // ------------------------------------------------
        $display("Starting Load Y (Burst: %0d beats from file)...", Y_BEATS);
        feed_burst_array(y_stream_mem, Y_BEATS, 0, 0);  // No tlast, no ready stats
        
        // Wait 1 cycle for FSM to transition from LOAD_Y to COMPUTE
        @(posedge clk);
        
        // ------------------------------------------------
        // 3. Stream Matrix (Compute) - Burst Mode
        // ------------------------------------------------
        $display("[%0t] Starting Compute Stream (Burst: %0d beats from file)...", $time, ACTIVE_COMPUTE_BEATS);
        // Burst transfer all compute beats with tlast on final beat.
        feed_burst_array(compute_stream_mem, ACTIVE_COMPUTE_BEATS, 1, 1);
        $display("[%0t] All data sent!", $time);
        if (compute_ready_total_cycles > 0) begin
            ready_low_ratio = (compute_ready_low_cycles * 1.0) / compute_ready_total_cycles;
            $display("READY_STATS total=%0d high=%0d low=%0d low_ratio=%0.6f",
                     compute_ready_total_cycles,
                     compute_ready_high_cycles,
                     compute_ready_low_cycles,
                     ready_low_ratio);
        end
        
        // ------------------------------------------------
        // 4. Wait for Store Y
        // ------------------------------------------------
        $display("[%0t] Waiting for Store Y...", $time);
        wait(m_axis_tvalid);
        
        $display("[%0t] Y Writeback Started!", $time);
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
                    if (enable_data_check && (scalar_idx < Y_ELEMS)) begin
                        if (act !== golden_y_bits[scalar_idx]) begin
                            $error("Y mismatch at scalar %0d: exp=%h got=%h",
                                   scalar_idx, golden_y_bits[scalar_idx], act);
                            error_count++;
                        end
                    end else if (scalar_idx >= Y_ELEMS) begin
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
            if (enable_data_check) begin
                $display("AUTO-CHECK PASSED: %0d valid scalars + %0d padding scalars",
                         Y_ELEMS, Y_BEATS*PARALLELISM - Y_ELEMS);
            end else begin
                $display("PROTOCOL CHECK PASSED (no golden_y file provided).");
            end
        end else begin
            $fatal(1, "AUTO-CHECK FAILED with %0d mismatches", error_count);
        end
        
        $display("Test Done.");
        #100;
        $finish;
    end

    // Burst mode: continuous transfer from array (tvalid stays high)
    task feed_burst_array;
        input logic [AXI_WIDTH-1:0] data_arr[];
        input int count;
        input last_beat;  // Apply tlast on final beat?
        input bit track_ready_stats;
        begin
            @(posedge clk);
            s_axis_tvalid <= 1;
            
            for (int i = 0; i < count; i++) begin
                s_axis_tdata <= data_arr[i];
                s_axis_tlast <= (last_beat && (i == count - 1)) ? 1'b1 : 1'b0;
                @(posedge clk);
                if (track_ready_stats) begin
                    compute_ready_total_cycles++;
                    if (s_axis_tready) begin
                        compute_ready_high_cycles++;
                    end else begin
                        compute_ready_low_cycles++;
                    end
                end
                // Wait for handshake
                while (!s_axis_tready) begin
                    @(posedge clk);
                    if (track_ready_stats) begin
                        compute_ready_total_cycles++;
                        if (s_axis_tready) begin
                            compute_ready_high_cycles++;
                        end else begin
                            compute_ready_low_cycles++;
                        end
                    end
                end
            end
            
            s_axis_tvalid <= 0;
            s_axis_tlast <= 0;
        end
    endtask

endmodule
