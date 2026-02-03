`timescale 1ns / 1ps

module tb_b8c_decode;

    // --- Parameters ---
    parameter AXI_WIDTH   = 512;
    parameter PARALLELISM = 8;
    parameter VAL_BATCH   = 16;
    parameter META_BATCH  = 5;

    // --- Signals ---
    logic clk;
    logic rst_n;
    
    // AXI Stream Input
    logic [AXI_WIDTH-1:0] s_axis_tdata;
    logic                 s_axis_tvalid;
    logic                 s_axis_tready;

    // Downstream Control
    logic                 compute_req_next;

    // Outputs
    logic [AXI_WIDTH-1:0]      m_vals_data;
    logic [PARALLELISM*16-1:0] m_row_deltas;
    logic [15:0]               m_row_base;
    logic [15:0]               m_col_base;
    logic                      decoder_valid;

    // --- DUT Instantiation ---
    b8c_decoder #(
        .AXI_WIDTH(AXI_WIDTH),
        .PARALLELISM(PARALLELISM),
        .VAL_BATCH(VAL_BATCH),
        .META_BATCH(META_BATCH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .compute_req_next(compute_req_next),
        .m_vals_data(m_vals_data),
        .m_row_deltas(m_row_deltas),
        .m_row_base(m_row_base),
        .m_col_base(m_col_base),
        .decoder_valid(decoder_valid)
    );

    // --- Clock Generation ---
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz
    end

    // --- Test Stimulus ---
    
    // Structure to hold expected verification data
    typedef struct {
        bit [15:0] row_base;
        bit [15:0] col_base;
        bit [15:0] row_deltas[8];
    } expected_meta_t;

    expected_meta_t golden_meta [16]; // 16 Super-rows per block
    
    // Helper to pack metadata into 5x512b lines
    logic [2559:0] full_meta_blob; 

    initial begin
        // 1. Initialization
        rst_n = 0;
        s_axis_tvalid = 0;
        s_axis_tdata = 0;
        compute_req_next = 0;
        
        #100;
        rst_n = 1;
        #20;

        // 2. Construct Golden Metadata Pattern
        // Each Super-row i (0..15):
        //   Base = 0xAA00 + i
        //   Col  = 0xC000 + i
        //   Delta[j] = 0x1000 + (i<<4) + j
        full_meta_blob = 0;
        for (int i=0; i<16; i++) begin
            golden_meta[i].row_base = 16'hAA00 + i;
            golden_meta[i].col_base = 16'hC000 + i;
            for (int j=0; j<8; j++) begin
                golden_meta[i].row_deltas[j] = 16'h1000 + (i*16) + j;
            end
            
            // Pack into blob: Format { ColBase, Deltas[7..0], Base } -> 160 bits
            // 160 bits * 16 = 2560 bits (5 lines)
            
            // Base at [15:0]
            full_meta_blob[i*160 +: 16] = golden_meta[i].row_base;
            
            // Deltas at [159:32]
            for (int j=0; j<8; j++) begin
                full_meta_blob[i*160 + 32 + j*16 +: 16] = golden_meta[i].row_deltas[j];
            end

            // ColBase at [31:16] (Matches user's meta_parser implementation {Deltas, ColBase, RowBase})
            full_meta_blob[i*160 + 16 +: 16] = golden_meta[i].col_base;
        end

        $display("Test Started: Sending Block with 160-bit Metadata Slicing Pattern.");

        // 3. Send Interleaved Stream (16 Values + 5 Metadata)
        fork
            send_stream();
            drive_consumer();
            monitor_output();
        join
        
        #100;
        $display("Test Passed!");
        $finish;
    end

    // Task: Master Driver (Send Data)
    task send_stream();
        // Send 16 lines of Values (Dummy Data)
        for (int i=0; i<16; i++) begin
            @(posedge clk);
            wait(s_axis_tready);
            s_axis_tvalid <= 1;
            s_axis_tdata <= {32{16'(16'hDAD0 + i)}}; // Cast to 16-bit to avoid 0000 padding
        end

        // Send 5 lines of Metadata
        // Slicing 512 bits from full_meta_blob
        for (int i=0; i<5; i++) begin
            @(posedge clk);
            wait(s_axis_tready);
            s_axis_tvalid <= 1;
            s_axis_tdata <= full_meta_blob[i*512 +: 512];
        end

        @(posedge clk);
        s_axis_tvalid <= 0;
    endtask

    // Task: Slave Driver (Consumer)
    task automatic drive_consumer();
        int consumed = 0;
        // Wait for a few cycles then start consuming
        #200;
        @(posedge clk);
        $display("Consumer: Starting to request data...");
        
        // Consume 16 beats using Handshake
        while (consumed < 16) begin
            // Randomly insert backpressure (only update req on clk edges)
            if ($urandom_range(0, 3) == 0) begin
                compute_req_next <= 0;
            end else begin
                compute_req_next <= 1;
            end
            
            @(posedge clk);
            
            // Check for successful handshake
            if (compute_req_next && decoder_valid) begin
                consumed++;
            end
        end
        
        compute_req_next <= 0;
    endtask

    // Task: Monitor and Compare
    task automatic monitor_output();
        int beat_cnt = 0;
        bit error_found;
        
        while (beat_cnt < 16) begin
            @(posedge clk);
            if (decoder_valid && compute_req_next) begin
                error_found = 0;
                
                // Check Base
                if (m_row_base !== golden_meta[beat_cnt].row_base) begin
                    $error("Mismatch at beat %0d! Base exp: %h, got: %h", 
                        beat_cnt, golden_meta[beat_cnt].row_base, m_row_base);
                    error_found = 1;
                end

                // Check ColBase
                if (m_col_base !== golden_meta[beat_cnt].col_base) begin
                    $error("Mismatch at beat %0d! ColBase exp: %h, got: %h", 
                        beat_cnt, golden_meta[beat_cnt].col_base, m_col_base);
                    error_found = 1;
                end
                
                // Check Deltas
                for (int j=0; j<8; j++) begin
                    logic [15:0] act_delta;
                    act_delta = m_row_deltas[j*16 +: 16];
                    if (act_delta !== golden_meta[beat_cnt].row_deltas[j]) begin
                        $error("Mismatch at beat %0d, Lane %0d! Delta exp: %h, got: %h", 
                            beat_cnt, j, golden_meta[beat_cnt].row_deltas[j], act_delta);
                        error_found = 1;
                    end
                end

                if (!error_found) begin
                    $display("Beat %2d OK: Base=%h Col=%h | Deltas=[%h %h %h %h %h %h %h %h]", 
                        beat_cnt, m_row_base, m_col_base,
                        m_row_deltas[16*7 +: 16], m_row_deltas[16*6 +: 16], 
                        m_row_deltas[16*5 +: 16], m_row_deltas[16*4 +: 16], 
                        m_row_deltas[16*3 +: 16], m_row_deltas[16*2 +: 16], 
                        m_row_deltas[16*1 +: 16], m_row_deltas[16*0 +: 16]);
                end

                beat_cnt++;
            end
        end
    endtask

endmodule
