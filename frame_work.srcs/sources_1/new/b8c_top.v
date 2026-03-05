`timescale 1ns / 1ps

module b8c_top #(
    parameter PARALLELISM = 8,       // C=8
    parameter DATA_WIDTH  = 64,      // FP64
    parameter ADDR_WIDTH  = 13,      // Address width for vector element indexing
    parameter AXI_WIDTH   = 512,     // HBM interface width
    parameter MODE_ID52   = 1'b0,    // 0: legacy 16:5 FP64 stream, 1: 2:5 ID+meta stream
    parameter LUT_INIT_FILE = "",    // LUT file used when MODE_ID52=1
    parameter DECOUPLE_ID_META = 1'b0,
    parameter ID_Q_DEPTH = 8,
    parameter META_Q_DEPTH = 8,
    // New Parameters for Loading
    parameter VECTOR_DEPTH = 4096,   // Number of 512-bit beats to load for X
    parameter Y_ELEMS      = 23      // Number of scalar FP64 elements in output Y
)(
    input  wire clk,
    input  wire rst_n,

    // --- 1. AXI4-Stream Input (Main Interface) ---
    // [Phase 1: Vector X] -> [Phase 2: Vector Y] -> [Phase 3: Matrix/Meta]
    input  wire [AXI_WIDTH-1:0]    s_axis_tdata,
    input  wire                    s_axis_tvalid,
    input  wire                    s_axis_tlast, // Added TLAST to detect Matrix stream end
    output wire                    s_axis_tready,

    // --- 2. DDR/HBM Interface for Vector Y Writeback (Output Stream) ---
    output wire [AXI_WIDTH-1:0]    m_axis_tdata,
    output wire                    m_axis_tvalid,
    input  wire                    m_axis_tready,
    output wire                    m_axis_tlast
);

    // =========================================================
    // FSM Definitions
    // =========================================================
    localparam S_IDLE       = 3'd0;
    localparam S_LOAD_X     = 3'd1;
    localparam S_LOAD_Y     = 3'd2;
    localparam S_COMPUTE    = 3'd3;
    localparam S_STORE_Y    = 3'd4;
    localparam S_DONE       = 3'd5;
    
    // Pipeline drain cycles after decoder FIFO empties:
    // decoder_val_d1(1) + X_RAM_read(1) + compute_mult(1) + y_acc_write(1) = 4 cycles
    localparam COMPUTE_DRAIN_CYCLES = 4;
    localparam integer Y_BEATS = (Y_ELEMS + PARALLELISM - 1) / PARALLELISM;
    
    reg [2:0] state;
    reg [ADDR_WIDTH-1:0] load_cnt;
    reg tlast_seen;           // Flag: s_axis_tlast has been received
    reg [3:0] drain_cnt;      // Counter for pipeline drain cycles (needs to count to 4)
    
    // Internal Signals
    // Decoder Outputs
    wire decoder_val;
    wire [PARALLELISM*DATA_WIDTH-1:0] dec_vals;
    wire [PARALLELISM*16-1:0]         dec_row_deltas;
    wire [15:0]                       dec_row_base;
    wire [15:0]                       dec_col_base;
    wire                              dec_fifo_empty;  // True when decoder val_fifo is empty
    
    // Pipeline Registers: Delay decoder outputs by 1 cycle to align with X RAM read
    // Cycle N:   decoder_val=1, dec_vals, dec_row_deltas, dec_col_base valid
    //            X RAM receives rd_addr (based on dec_col_base)
    // Cycle N+1: X RAM outputs x_rd_data
    //            dec_vals_d1, dec_row_deltas_d1 valid ??compute receives inputs
    // Cycle N+2: compute outputs pp_data (1 cycle multiply latency)
    //            dec_vals_d2, dec_row_deltas_d2 valid ??aligned with pp_data
    
    // Stage 1: Align with X RAM output
    reg                               decoder_val_d1;
    reg [PARALLELISM*DATA_WIDTH-1:0]  dec_vals_d1;
    reg [PARALLELISM*16-1:0]          dec_row_deltas_d1;
    reg [15:0]                        dec_row_base_d1;
    
    // Stage 2: Align with compute_pipeline output (pp_data)
    reg                               decoder_val_d2;
    reg [PARALLELISM*16-1:0]          dec_row_deltas_d2;
    reg [15:0]                        dec_row_base_d2;

    //Stage 3: Align with compute_pipeline output (pp_data)
    reg                               decoder_val_d3;
    reg [PARALLELISM*16-1:0]          dec_row_deltas_d3;
    reg [15:0]                        dec_row_base_d3;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Stage 1
            decoder_val_d1    <= 0;
            dec_vals_d1       <= 0;
            dec_row_deltas_d1 <= 0;
            dec_row_base_d1   <= 0;
            // Stage 2
            decoder_val_d2    <= 0;
            dec_row_deltas_d2 <= 0;
            dec_row_base_d2   <= 0;
            //Stage 3
            decoder_val_d3    <= 0;
            dec_row_deltas_d3 <= 0;
            dec_row_base_d3   <= 0;
            
        end else begin
            // Stage 1
            decoder_val_d1    <= decoder_val;
            dec_vals_d1       <= dec_vals;
            dec_row_deltas_d1 <= dec_row_deltas;
            dec_row_base_d1   <= dec_row_base;
            // Stage 2
            decoder_val_d2    <= decoder_val_d1;
            dec_row_deltas_d2 <= dec_row_deltas_d1;
            dec_row_base_d2   <= dec_row_base_d1;
            //Stage 3
            decoder_val_d3    <= decoder_val_d2;
            dec_row_deltas_d3 <= dec_row_deltas_d2;
            dec_row_base_d3   <= dec_row_base_d2;
        end
    end
    
    // Bank Signals
    wire [PARALLELISM*DATA_WIDTH-1:0] x_rd_data;
    wire [PARALLELISM*DATA_WIDTH-1:0] y_store_data;
    wire [PARALLELISM*ADDR_WIDTH-1:0] x_rd_addr_mapped;
    
    // Compute
    wire [PARALLELISM*DATA_WIDTH-1:0] pp_data;
    wire [PARALLELISM-1:0]            pp_valid;
    
    // =========================================================
    // FSM Logic (Two-Process Style)
    // =========================================================
    
    // Next state calculation (combinational)
    reg [2:0] next_state;
    reg [ADDR_WIDTH-1:0] next_load_cnt;
    reg next_tlast_seen;
    reg [3:0] next_drain_cnt;
    wire handshake = s_axis_tvalid && s_axis_tready;
    
    always @(*) begin
        // Default: hold current values
        next_state = state;
        next_load_cnt = load_cnt;
        next_tlast_seen = tlast_seen;
        next_drain_cnt = drain_cnt;
        
        case (state)
            S_IDLE: begin
                next_load_cnt = 0;
                next_tlast_seen = 0;
                next_drain_cnt = 0;
                if (handshake) begin
                    next_state = S_LOAD_X;
                    next_load_cnt = 1;  // X[0] uses addr 0, X[1] will use addr 1
                end
            end
            
            S_LOAD_X: begin
                if (handshake) begin
                    if (load_cnt == VECTOR_DEPTH - 1) begin
                        // Last X beat received (X[15] when VECTOR_DEPTH=16)
                        next_state = S_LOAD_Y;
                        next_load_cnt = 0;  // Y[0] will use addr 0
                    end else begin
                        next_load_cnt = load_cnt + 1;
                    end
                end
            end
            
            S_LOAD_Y: begin
                if (handshake) begin
                    if (load_cnt == Y_BEATS - 1) begin
                        // Last Y beat received (for Y_ELEMS=23, Y_BEATS=3)
                        next_state = S_COMPUTE;
                        next_load_cnt = 0;
                    end else begin
                        next_load_cnt = load_cnt + 1;
                    end
                end
            end
            
            S_COMPUTE: begin
                // Three-phase completion logic:
                // Phase 1: Accept input until tlast
                // Phase 2: Wait for decoder FIFO to empty (val_fifo becomes empty)
                // Phase 3: Wait for downstream pipeline to drain (4 cycles)
                
                if (!tlast_seen) begin
                    // Phase 1: Still receiving input
                    if (handshake && s_axis_tlast) begin
                        next_tlast_seen = 1;
                    end
                end
                else begin
                    // Phase 2 & 3: Input done, waiting for completion
                    // Use dec_fifo_empty (val_empty) instead of decoder_val
                    // because decoder_val can be 0 while parser is in S_FILL state
                    if (!dec_fifo_empty) begin
                        // FIFO still has data - keep drain counter reset
                        next_drain_cnt = COMPUTE_DRAIN_CYCLES;
                    end
                    else begin
                        // FIFO empty - count down pipeline drain
                        if (drain_cnt == 0) begin
                            // Pipeline fully drained
                            next_state = S_STORE_Y;
                            next_load_cnt = 0;
                            next_tlast_seen = 0;
                        end
                        else begin
                            next_drain_cnt = drain_cnt - 1;
                        end
                    end
                end
            end
            
            S_STORE_Y: begin
                if (m_axis_tready) begin
                    next_load_cnt = load_cnt + 1;
                    if (load_cnt == Y_BEATS - 1) begin
                        next_state = S_DONE;
                    end
                end
            end
            
            S_DONE: begin
                next_state = S_DONE;
            end
        endcase
    end
    
    // State register (sequential)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            load_cnt <= 0;
            tlast_seen <= 0;
            drain_cnt <= 0;
        end else begin
            state <= next_state;
            load_cnt <= next_load_cnt;
            tlast_seen <= next_tlast_seen;
            drain_cnt <= next_drain_cnt;
        end
    end
    
    // =========================================================
    // Module Connections
    // =========================================================
    
    // --- 1. Decoder (Active in COMPUTE) ---
    // Use current state to avoid sending Y data to decoder
    // during LOAD_Y->COMPUTE transition
    wire axis_to_dec_valid = (state == S_COMPUTE) && s_axis_tvalid;
    wire dec_ready_out;
    // Future-ready hook: compute side may deassert ready in hardwareized pipeline.
    wire compute_in_ready = 1'b1;
    wire compute_req_next = (state == S_COMPUTE) && compute_in_ready;
    
    // s_axis_tready: Combinational logic only (no multi-driver)
    reg s_axis_tready_comb;
    always @(*) begin
        case (state)
            S_IDLE, S_LOAD_X, S_LOAD_Y: s_axis_tready_comb = 1'b1;
            S_COMPUTE:                  s_axis_tready_comb = dec_ready_out;
            default:                    s_axis_tready_comb = 1'b0;
        endcase
    end
    assign s_axis_tready = s_axis_tready_comb;

    generate
        if (MODE_ID52 == 1'b0) begin : gen_decoder_legacy
            b8c_decoder #(
                .AXI_WIDTH(AXI_WIDTH),
                .PARALLELISM(PARALLELISM),
                .VAL_BATCH(16),
                .META_BATCH(5)
            ) u_decoder (
                .clk(clk),
                .rst_n(rst_n),
                .s_axis_tdata(s_axis_tdata),
                .s_axis_tvalid(axis_to_dec_valid),
                .s_axis_tready(dec_ready_out),
                .compute_req_next(compute_req_next),
                .decoder_valid(decoder_val),
                .m_vals_data(dec_vals),
                .m_row_deltas(dec_row_deltas),
                .m_row_base(dec_row_base),
                .m_col_base(dec_col_base),
                .o_pipeline_idle(dec_fifo_empty)
            );
        end else begin : gen_decoder_id52
            b8c_decoder_id52 #(
                .AXI_WIDTH(AXI_WIDTH),
                .PARALLELISM(PARALLELISM),
                .VAL_ID_BATCH(2),
                .META_BATCH(5),
                .ID_WIDTH(8),
                .DATA_WIDTH(DATA_WIDTH),
                .LUT_INIT_FILE(LUT_INIT_FILE),
                .DECOUPLE_ID_META(DECOUPLE_ID_META),
                .ID_Q_DEPTH(ID_Q_DEPTH),
                .META_Q_DEPTH(META_Q_DEPTH)
            ) u_decoder (
                .clk(clk),
                .rst_n(rst_n),
                .s_axis_tdata(s_axis_tdata),
                .s_axis_tvalid(axis_to_dec_valid),
                .s_axis_tready(dec_ready_out),
                .compute_req_next(compute_req_next),
                .decoder_valid(decoder_val),
                .m_vals_data(dec_vals),
                .m_row_deltas(dec_row_deltas),
                .m_row_base(dec_row_base),
                .m_col_base(dec_col_base),
                .o_pipeline_idle(dec_fifo_empty)
            );
        end
    endgenerate

    // --- 2. X Memory Banks ---
    // Mapping:
    // Load: Direct linear map
    // Read: meta_col_indices = col_base + k
    // We simplify: just use `dec_col_base` for all.
    // Address for Bank K = (Base + k) / 8 -> Base/8 (if Base%8==0).
    // Let's assume Base is 64-bit aligned (element index).
    // The provided b8c_top.v logic: `assign meta_col_indices[k*16+...] = base + k`
    // We need to map `base+k` to `ram_addr`.
    // Since we bank by LSB (interleaved), `addr = global_idx >> 3`.
    genvar i;
    generate
        for(i=0; i<PARALLELISM; i=i+1) begin
             assign x_rd_addr_mapped[i*ADDR_WIDTH +: ADDR_WIDTH] = (dec_col_base + i) >> 3; 
        end
    endgenerate

    x_mem_banks #(
        .PARALLELISM(PARALLELISM),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DEPTH(VECTOR_DEPTH)
    ) u_x_mem (
        .clk(clk),
        // Load X: accepts data when in IDLE (first beat) or LOAD_X
        .load_en(((state == S_IDLE) || (state == S_LOAD_X)) && handshake),
        .load_addr(load_cnt),  // load_cnt holds correct address for current beat
        .load_data(s_axis_tdata),
        .rd_addr_vec(x_rd_addr_mapped),
        .rd_data_vec(x_rd_data)
    );

    // --- 3. Compute Pipeline ---
    // Uses delayed decoder outputs (d1) aligned with X RAM read data
    compute_pipeline #(
        .PARALLELISM(PARALLELISM)
    ) u_compute (
        .clk(clk),
        .matrix_values(dec_vals_d1),    // Delayed by 1 cycle
        .x_values(x_rd_data),           // X RAM output (1 cycle after addr)
        // .dest_row_idx removed - not used in compute_pipeline
        .routed_products(pp_data),
        .valid_mask(pp_valid)
    );

    // --- 4. Y Accumulator / Storage ---
    // Mode control
    reg [1:0] y_mode;
    // y_mode based on current state
    // This ensures data goes to correct module during state transitions
    always @(*) begin
        case(state)
            S_LOAD_X: begin
                // When transitioning LOAD_X->LOAD_Y on last beat, still use LOAD_X mode for X data
                y_mode = 2'b00;
            end
            S_LOAD_Y: y_mode = 2'b01;
            S_COMPUTE: y_mode = 2'b10;
            S_STORE_Y: y_mode = 2'b11;
            default: y_mode = 2'b00;
        endcase
    end
    
    // Row Delta Mapping
    // row_deltas are relative to row_base? Or absolute?
    // b8c implies relative. We assume `row_base + delta` is the global index.
    // `dec_row_ Deltas` are 8-bit? Top says 8-bit in wire, decoder says 16?
    // Let's use `dec_row_deltas` (16-bit output from decoder).
    // Addr = (row_base + row_delta) >> 3.
    // This requires simple address calc.
    // We assume strict banking alignment for simplicity or just wire `row_base` into Y Acc.
    // Actually, `y_acc_banks` expects `y_local_addr` for each bank.
    // Let's perform the Add calculation here.
    // Row Destination Mapping for Y accumulation
    // Real_Row_Index[i] = RowBase + RowDelta[i]
    // This is the actual row of Y to accumulate into
    // NOTE: Use d3 registers to align with pp_data and Y-acc write timing
    wire [PARALLELISM*ADDR_WIDTH-1:0] y_compute_addr;
    generate
        for(i=0; i<PARALLELISM; i=i+1) begin : gen_y_addr
             wire [15:0] delta_d3 = dec_row_deltas_d3[i*16 +: 16];
             // Real row index = Base + Delta (no division needed)
             assign y_compute_addr[i*ADDR_WIDTH +: ADDR_WIDTH] = dec_row_base_d3 + delta_d3;
        end
    endgenerate

    y_acc_banks #(
        .PARALLELISM(PARALLELISM),
        .DEPTH(Y_ELEMS),
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_y_acc (
        .clk(clk),
        .mode(y_mode),
        
        // Load/Store Port - load_cnt holds correct address for current beat
        .ls_addr(load_cnt),
        .load_data(s_axis_tdata),
        .store_data(y_store_data),
        
        // Compute Port - use d3 delayed decoder_val for timing alignment with pp_data
        .partial_products(pp_data),
        .pp_valid(pp_valid & {PARALLELISM{decoder_val_d3}}), // Gate with d3 valid (aligned with compute output)
        .y_local_addr(y_compute_addr)
    );

    // --- 5. Output Logic ---
    // y_acc_banks has 1-cycle read latency in store mode
    // Delay valid signal to align with actual data output
    reg store_valid_d1;
    reg [ADDR_WIDTH-1:0] load_cnt_d1;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            store_valid_d1 <= 0;
            load_cnt_d1 <= 0;
        end else begin
            store_valid_d1 <= (state == S_STORE_Y);
            load_cnt_d1 <= load_cnt;
        end
    end
    
    assign m_axis_tdata  = y_store_data;
    assign m_axis_tvalid = store_valid_d1;  // Delayed by 1 cycle to match data
    assign m_axis_tlast  = store_valid_d1 & (load_cnt_d1 == Y_BEATS - 1);

endmodule

