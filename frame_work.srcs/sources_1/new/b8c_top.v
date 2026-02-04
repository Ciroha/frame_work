`timescale 1ns / 1ps

module b8c_top #(
    parameter PARALLELISM = 8,       // 论文中的 C=8
    parameter DATA_WIDTH  = 64,      // FP64
    parameter ADDR_WIDTH  = 13,      // 8K 元素块大小
    parameter AXI_WIDTH   = 512,     // HBM 接口位宽
    // New Parameters for Loading
    parameter VECTOR_DEPTH = 4096    // Number of 512-bit beats to load for X and Y
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
    
    reg [2:0] state;
    reg [ADDR_WIDTH-1:0] load_cnt;
    
    // Internal Signals
    // Decoder Outputs
    wire decoder_val;
    wire [PARALLELISM*DATA_WIDTH-1:0] dec_vals;
    wire [PARALLELISM*16-1:0]         dec_row_deltas;
    wire [15:0]                       dec_row_base;
    wire [15:0]                       dec_col_base;
    wire dec_req_next;
    
    // Pipeline Registers: Delay decoder outputs by 1 cycle to align with X RAM read
    // Cycle N:   decoder_val=1, dec_vals, dec_row_deltas, dec_col_base valid
    //            X RAM receives rd_addr (based on dec_col_base)
    // Cycle N+1: X RAM outputs x_rd_data
    //            dec_vals_d1, dec_row_deltas_d1 valid → compute can proceed
    reg                               decoder_val_d1;
    reg [PARALLELISM*DATA_WIDTH-1:0]  dec_vals_d1;
    reg [PARALLELISM*16-1:0]          dec_row_deltas_d1;
    reg [15:0]                        dec_row_base_d1;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            decoder_val_d1    <= 0;
            dec_vals_d1       <= 0;
            dec_row_deltas_d1 <= 0;
            dec_row_base_d1   <= 0;
        end else begin
            decoder_val_d1    <= decoder_val;
            dec_vals_d1       <= dec_vals;
            dec_row_deltas_d1 <= dec_row_deltas;
            dec_row_base_d1   <= dec_row_base;
        end
    end
    
    // Bank Signals
    wire [PARALLELISM*DATA_WIDTH-1:0] x_rd_data;
    wire [PARALLELISM*DATA_WIDTH-1:0] y_wb_data;
    wire [PARALLELISM*DATA_WIDTH-1:0] y_store_data;
    wire [PARALLELISM*16-1:0]         x_rd_addr_vec;
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
    wire handshake = s_axis_tvalid && s_axis_tready;
    
    always @(*) begin
        // Default: hold current values
        next_state = state;
        next_load_cnt = load_cnt;
        
        case (state)
            S_IDLE: begin
                next_load_cnt = 0;
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
                    if (load_cnt == VECTOR_DEPTH - 1) begin
                        // Last Y beat received (Y[15] when VECTOR_DEPTH=16)
                        next_state = S_COMPUTE;
                        next_load_cnt = 0;
                    end else begin
                        next_load_cnt = load_cnt + 1;
                    end
                end
            end
            
            S_COMPUTE: begin
                if (handshake && s_axis_tlast) begin
                    next_state = S_STORE_Y;
                    next_load_cnt = 0;
                end
            end
            
            S_STORE_Y: begin
                if (m_axis_tready) begin
                    next_load_cnt = load_cnt + 1;
                    if (load_cnt == VECTOR_DEPTH) begin
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
        end else begin
            state <= next_state;
            load_cnt <= next_load_cnt;
        end
    end
    
    // Effective state for data path: use NEXT state when handshake occurs
    // This allows data to be processed in the same cycle as the state transition
    wire [2:0] effective_state = (handshake) ? next_state : state;

    // =========================================================
    // Module Connections
    // =========================================================
    
    // --- 1. Decoder (Active in COMPUTE) ---
    // Use effective_state for immediate reaction
    wire axis_to_dec_valid = (effective_state == S_COMPUTE) && s_axis_tvalid;
    wire dec_ready_out;
    
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

    b8c_decoder #(
        .AXI_WIDTH(AXI_WIDTH),
        .PARALLELISM(PARALLELISM)
    ) u_decoder (
        .clk(clk),
        .rst_n(rst_n),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(axis_to_dec_valid),
        .s_axis_tready(dec_ready_out),
        
        .compute_req_next(1'b1), // Always hungry for now
        .decoder_valid(decoder_val),
        .m_vals_data(dec_vals),
        .m_row_deltas(dec_row_deltas),
        .m_row_base(dec_row_base),
        .m_col_base(dec_col_base)
    );

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
        .dest_row_idx(dec_row_deltas_d1), // Delayed by 1 cycle
        .routed_products(pp_data),
        .valid_mask(pp_valid)
    );

    // --- 4. Y Accumulator / Storage ---
    // Mode control
    reg [1:0] y_mode;
    // y_mode based on current state (not effective_state)
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
    wire [PARALLELISM*ADDR_WIDTH-1:0] y_compute_addr;
    generate
        for(i=0; i<PARALLELISM; i=i+1) begin : gen_y_addr
             wire [15:0] delta_d1 = dec_row_deltas_d1[i*16 +: 16];
             // Addr = (Base + Delta) / 8 - use delayed signals
             assign y_compute_addr[i*ADDR_WIDTH +: ADDR_WIDTH] = (dec_row_base_d1 + delta_d1) >> 3;
        end
    endgenerate

    y_acc_banks #(
        .PARALLELISM(PARALLELISM),
        .DEPTH(VECTOR_DEPTH)
    ) u_y_acc (
        .clk(clk),
        .rst_n(rst_n),
        .mode(y_mode),
        
        // Load/Store Port - load_cnt holds correct address for current beat
        .ls_addr(load_cnt),
        .load_data(s_axis_tdata),
        .store_data(y_store_data),
        
        // Compute Port - use delayed decoder_val for timing alignment
        .partial_products(pp_data),
        .pp_valid(pp_valid & {PARALLELISM{decoder_val_d1}}), // Gate with delayed valid
        .y_local_addr(y_compute_addr)
    );

    // --- 5. Output Logic ---
    assign m_axis_tdata  = y_store_data;
    assign m_axis_tvalid = (state == S_STORE_Y);
    assign m_axis_tlast  = (state == S_STORE_Y) & (load_cnt == VECTOR_DEPTH - 1);

endmodule
