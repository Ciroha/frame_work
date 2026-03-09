`timescale 1ns / 1ps

module b8c_top #(
    parameter PARALLELISM = 8,
    parameter DATA_WIDTH  = 64,
    parameter ADDR_WIDTH  = 13,
    parameter AXI_WIDTH   = 512,
    parameter MODE_ID52   = 1'b0,
    parameter LUT_INIT_FILE = "",
    parameter DECOUPLE_ID_META = 1'b0,
    parameter ID_Q_DEPTH = 8,
    parameter META_Q_DEPTH = 8,
    parameter VECTOR_DEPTH = 4096,
    parameter Y_ELEMS      = 23
)(
    input  wire clk,
    input  wire rst_n,

    input  wire [AXI_WIDTH-1:0] s_axis_tdata,
    input  wire                 s_axis_tvalid,
    input  wire                 s_axis_tlast,
    output wire                 s_axis_tready,

    output wire [AXI_WIDTH-1:0] m_axis_tdata,
    output wire                 m_axis_tvalid,
    input  wire                 m_axis_tready,
    output wire                 m_axis_tlast
);

    localparam S_IDLE    = 3'd0;
    localparam S_LOAD_X  = 3'd1;
    localparam S_LOAD_Y  = 3'd2;
    localparam S_COMPUTE = 3'd3;
    localparam S_STORE_Y = 3'd4;
    localparam S_DONE    = 3'd5;

    localparam integer COMPUTE_DRAIN_CYCLES = 4;
    localparam integer IO_LANES = AXI_WIDTH / DATA_WIDTH;
    localparam integer LANE_RATIO = PARALLELISM / IO_LANES;
    localparam integer X_AXI_BEATS = VECTOR_DEPTH * LANE_RATIO;
    localparam integer Y_LOGICAL_BEATS = (Y_ELEMS + PARALLELISM - 1) / PARALLELISM;
    localparam integer Y_AXI_BEATS = (Y_ELEMS + IO_LANES - 1) / IO_LANES;
    localparam integer COL_SHIFT = (PARALLELISM <= 1) ? 0 : $clog2(PARALLELISM);

    initial begin
        if (AXI_WIDTH % DATA_WIDTH != 0) begin
            $fatal(1, "AXI_WIDTH (%0d) must be multiple of DATA_WIDTH (%0d)", AXI_WIDTH, DATA_WIDTH);
        end
        if (PARALLELISM % IO_LANES != 0) begin
            $fatal(1, "PARALLELISM (%0d) must be multiple of IO_LANES (%0d)", PARALLELISM, IO_LANES);
        end
        if ((LANE_RATIO != 1) && (LANE_RATIO != 2)) begin
            $fatal(1, "Unsupported LANE_RATIO=%0d (only 1 or 2 supported)", LANE_RATIO);
        end
        if ((PARALLELISM == 16) && (MODE_ID52 == 1'b0)) begin
            $fatal(1, "PARALLELISM=16 is only supported for MODE_ID52=1 in this version");
        end
    end

    reg [2:0] state;
    reg [31:0] load_cnt;
    reg        tlast_seen;
    reg [3:0]  drain_cnt;

    wire decoder_val;
    wire [PARALLELISM*DATA_WIDTH-1:0] dec_vals;
    wire [PARALLELISM*16-1:0]         dec_row_deltas;
    wire [15:0]                       dec_row_base;
    wire [15:0]                       dec_col_base;
    wire                              dec_fifo_empty;

    reg                               decoder_val_d1;
    reg [PARALLELISM*DATA_WIDTH-1:0]  dec_vals_d1;
    reg [PARALLELISM*16-1:0]          dec_row_deltas_d1;
    reg [15:0]                        dec_row_base_d1;

    reg                               decoder_val_d2;
    reg [PARALLELISM*16-1:0]          dec_row_deltas_d2;
    reg [15:0]                        dec_row_base_d2;

    reg                               decoder_val_d3;
    reg [PARALLELISM*16-1:0]          dec_row_deltas_d3;
    reg [15:0]                        dec_row_base_d3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            decoder_val_d1    <= 1'b0;
            dec_vals_d1       <= {PARALLELISM*DATA_WIDTH{1'b0}};
            dec_row_deltas_d1 <= {PARALLELISM*16{1'b0}};
            dec_row_base_d1   <= 16'd0;
            decoder_val_d2    <= 1'b0;
            dec_row_deltas_d2 <= {PARALLELISM*16{1'b0}};
            dec_row_base_d2   <= 16'd0;
            decoder_val_d3    <= 1'b0;
            dec_row_deltas_d3 <= {PARALLELISM*16{1'b0}};
            dec_row_base_d3   <= 16'd0;
        end else begin
            decoder_val_d1    <= decoder_val;
            dec_vals_d1       <= dec_vals;
            dec_row_deltas_d1 <= dec_row_deltas;
            dec_row_base_d1   <= dec_row_base;
            decoder_val_d2    <= decoder_val_d1;
            dec_row_deltas_d2 <= dec_row_deltas_d1;
            dec_row_base_d2   <= dec_row_base_d1;
            decoder_val_d3    <= decoder_val_d2;
            dec_row_deltas_d3 <= dec_row_deltas_d2;
            dec_row_base_d3   <= dec_row_base_d2;
        end
    end

    wire [PARALLELISM*DATA_WIDTH-1:0] x_rd_data;
    wire [PARALLELISM*DATA_WIDTH-1:0] y_store_data;
    wire [PARALLELISM*ADDR_WIDTH-1:0] x_rd_addr_mapped;
    wire [PARALLELISM*DATA_WIDTH-1:0] pp_data;
    wire [PARALLELISM-1:0]            pp_valid;

    reg [2:0]  next_state;
    reg [31:0] next_load_cnt;
    reg        next_tlast_seen;
    reg [3:0]  next_drain_cnt;

    wire in_handshake = s_axis_tvalid && s_axis_tready;
    wire out_handshake = m_axis_tvalid && m_axis_tready;

    always @(*) begin
        next_state = state;
        next_load_cnt = load_cnt;
        next_tlast_seen = tlast_seen;
        next_drain_cnt = drain_cnt;

        case (state)
            S_IDLE: begin
                next_load_cnt = 0;
                next_tlast_seen = 1'b0;
                next_drain_cnt = 0;
                if (in_handshake) begin
                    if (X_AXI_BEATS <= 1) begin
                        next_state = S_LOAD_Y;
                        next_load_cnt = 0;
                    end else begin
                        next_state = S_LOAD_X;
                        next_load_cnt = 1;
                    end
                end
            end

            S_LOAD_X: begin
                if (in_handshake) begin
                    if (load_cnt == X_AXI_BEATS - 1) begin
                        next_state = S_LOAD_Y;
                        next_load_cnt = 0;
                    end else begin
                        next_load_cnt = load_cnt + 1;
                    end
                end
            end

            S_LOAD_Y: begin
                if (in_handshake) begin
                    if (load_cnt == Y_AXI_BEATS - 1) begin
                        next_state = S_COMPUTE;
                        next_load_cnt = 0;
                    end else begin
                        next_load_cnt = load_cnt + 1;
                    end
                end
            end

            S_COMPUTE: begin
                if (!tlast_seen) begin
                    if (in_handshake && s_axis_tlast) begin
                        next_tlast_seen = 1'b1;
                    end
                end else begin
                    if (!dec_fifo_empty) begin
                        next_drain_cnt = COMPUTE_DRAIN_CYCLES;
                    end else if (drain_cnt == 0) begin
                        next_state = S_STORE_Y;
                        next_load_cnt = 0;
                        next_tlast_seen = 1'b0;
                    end else begin
                        next_drain_cnt = drain_cnt - 1'b1;
                    end
                end
            end

            S_STORE_Y: begin
                if (out_handshake) begin
                    if (load_cnt == Y_AXI_BEATS - 1) begin
                        next_state = S_DONE;
                    end else begin
                        next_load_cnt = load_cnt + 1;
                    end
                end
            end

            S_DONE: begin
                next_state = S_DONE;
            end

            default: begin
                next_state = S_IDLE;
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            load_cnt <= 0;
            tlast_seen <= 1'b0;
            drain_cnt <= 0;
        end else begin
            state <= next_state;
            load_cnt <= next_load_cnt;
            tlast_seen <= next_tlast_seen;
            drain_cnt <= next_drain_cnt;
        end
    end

    wire axis_to_dec_valid = (state == S_COMPUTE) && s_axis_tvalid;
    wire dec_ready_out;
    wire compute_in_ready = 1'b1;
    wire compute_req_next = (state == S_COMPUTE) && compute_in_ready;

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

    genvar i;
    generate
        for (i = 0; i < PARALLELISM; i = i + 1) begin : gen_x_addr
            assign x_rd_addr_mapped[i*ADDR_WIDTH +: ADDR_WIDTH] = (dec_col_base + i) >> COL_SHIFT;
        end
    endgenerate

    reg [AXI_WIDTH-1:0] x_half_buf;
    wire x_phase = (state == S_IDLE) || (state == S_LOAD_X);
    wire x_first_half = (LANE_RATIO == 2) && x_phase && in_handshake && (load_cnt[0] == 1'b0);
    wire x_load_fire = x_phase && in_handshake && ((LANE_RATIO == 1) || (load_cnt[0] == 1'b1));
    wire [31:0] x_load_addr_full = (LANE_RATIO == 1) ? load_cnt : (load_cnt >> 1);
    wire [PARALLELISM*DATA_WIDTH-1:0] x_load_data_w;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_half_buf <= {AXI_WIDTH{1'b0}};
        end else if (x_first_half) begin
            x_half_buf <= s_axis_tdata;
        end
    end

    generate
        if (LANE_RATIO == 1) begin : gen_x_load_direct
            assign x_load_data_w = s_axis_tdata;
        end else begin : gen_x_load_pair
            assign x_load_data_w = {s_axis_tdata, x_half_buf};
        end
    endgenerate

    x_mem_banks #(
        .PARALLELISM(PARALLELISM),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DEPTH(VECTOR_DEPTH)
    ) u_x_mem (
        .clk(clk),
        .load_en(x_load_fire),
        .load_addr(x_load_addr_full[ADDR_WIDTH-1:0]),
        .load_data(x_load_data_w),
        .rd_addr_vec(x_rd_addr_mapped),
        .rd_data_vec(x_rd_data)
    );

    compute_pipeline #(
        .PARALLELISM(PARALLELISM)
    ) u_compute (
        .clk(clk),
        .matrix_values(dec_vals_d1),
        .x_values(x_rd_data),
        .routed_products(pp_data),
        .valid_mask(pp_valid)
    );

    reg [1:0] y_mode;
    always @(*) begin
        case (state)
            S_LOAD_Y:  y_mode = 2'b01;
            S_COMPUTE: y_mode = 2'b10;
            S_STORE_Y: y_mode = 2'b11;
            default:   y_mode = 2'b00;
        endcase
    end

    wire [PARALLELISM*ADDR_WIDTH-1:0] y_compute_addr;
    generate
        for (i = 0; i < PARALLELISM; i = i + 1) begin : gen_y_addr
            wire [15:0] delta_d3 = dec_row_deltas_d3[i*16 +: 16];
            assign y_compute_addr[i*ADDR_WIDTH +: ADDR_WIDTH] = dec_row_base_d3 + delta_d3;
        end
    endgenerate

    reg [AXI_WIDTH-1:0] y_half_buf;
    wire y_load_first_half = (LANE_RATIO == 2) && (state == S_LOAD_Y) && in_handshake && (load_cnt[0] == 1'b0);
    wire y_load_fire = (state == S_LOAD_Y) && in_handshake && ((LANE_RATIO == 1) || (load_cnt[0] == 1'b1));
    wire [31:0] y_load_addr_full = (LANE_RATIO == 1) ? load_cnt : (load_cnt >> 1);
    wire [PARALLELISM*DATA_WIDTH-1:0] y_load_data_w;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_half_buf <= {AXI_WIDTH{1'b0}};
        end else if (y_load_first_half) begin
            y_half_buf <= s_axis_tdata;
        end
    end

    generate
        if (LANE_RATIO == 1) begin : gen_y_load_direct
            assign y_load_data_w = s_axis_tdata;
        end else begin : gen_y_load_pair
            assign y_load_data_w = {s_axis_tdata, y_half_buf};
        end
    endgenerate

    reg [ADDR_WIDTH-1:0]               y_store_req_addr;
    reg                                y_store_fetch_pending;
    reg [PARALLELISM*DATA_WIDTH-1:0]   y_store_buf;
    reg                                y_store_buf_valid;
    reg                                store_half_sel;

    wire y_store_fetch_req = (state == S_STORE_Y) &&
                             !y_store_fetch_pending &&
                             !y_store_buf_valid &&
                             (y_store_req_addr < Y_LOGICAL_BEATS);

    wire [ADDR_WIDTH-1:0] y_ls_addr = (state == S_LOAD_Y) ?
                                      y_load_addr_full[ADDR_WIDTH-1:0] :
                                      y_store_req_addr;
    wire y_ls_en = (state == S_LOAD_Y) ? y_load_fire :
                   ((state == S_STORE_Y) ? y_store_fetch_req : 1'b0);

    wire [AXI_WIDTH-1:0] y_store_axi_word =
        (LANE_RATIO == 2) ?
            (store_half_sel ? y_store_buf[AXI_WIDTH +: AXI_WIDTH] : y_store_buf[0 +: AXI_WIDTH]) :
            y_store_buf[0 +: AXI_WIDTH];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_store_req_addr <= {ADDR_WIDTH{1'b0}};
            y_store_fetch_pending <= 1'b0;
            y_store_buf <= {PARALLELISM*DATA_WIDTH{1'b0}};
            y_store_buf_valid <= 1'b0;
            store_half_sel <= 1'b0;
        end else if (state != S_STORE_Y) begin
            y_store_req_addr <= {ADDR_WIDTH{1'b0}};
            y_store_fetch_pending <= 1'b0;
            y_store_buf <= {PARALLELISM*DATA_WIDTH{1'b0}};
            y_store_buf_valid <= 1'b0;
            store_half_sel <= 1'b0;
        end else begin
            if (y_store_fetch_req) begin
                y_store_fetch_pending <= 1'b1;
                y_store_req_addr <= y_store_req_addr + 1'b1;
            end

            if (y_store_fetch_pending) begin
                y_store_fetch_pending <= 1'b0;
                y_store_buf <= y_store_data;
                y_store_buf_valid <= 1'b1;
                store_half_sel <= 1'b0;
            end

            if (out_handshake) begin
                if (LANE_RATIO == 1) begin
                    y_store_buf_valid <= 1'b0;
                end else if (!store_half_sel) begin
                    store_half_sel <= 1'b1;
                end else begin
                    store_half_sel <= 1'b0;
                    y_store_buf_valid <= 1'b0;
                end
            end
        end
    end

    y_acc_banks #(
        .PARALLELISM(PARALLELISM),
        .DEPTH(Y_ELEMS),
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_y_acc (
        .clk(clk),
        .mode(y_mode),
        .ls_en(y_ls_en),
        .ls_addr(y_ls_addr),
        .load_data(y_load_data_w),
        .store_data(y_store_data),
        .partial_products(pp_data),
        .pp_valid(pp_valid & {PARALLELISM{decoder_val_d3}}),
        .y_local_addr(y_compute_addr)
    );

    assign m_axis_tdata  = y_store_axi_word;
    assign m_axis_tvalid = (state == S_STORE_Y) && y_store_buf_valid;
    assign m_axis_tlast  = m_axis_tvalid && (load_cnt == Y_AXI_BEATS - 1);

endmodule

