`timescale 1ns / 1ps

module b8c_decoder_id52 #(
    parameter AXI_WIDTH         = 512,
    parameter PARALLELISM       = 8,
    parameter VAL_ID_BATCH      = 2,
    parameter META_BATCH        = 5,
    parameter ID_WIDTH          = 8,
    parameter DATA_WIDTH        = 64,
    parameter LUT_INIT_FILE     = "",
    parameter DECOUPLE_ID_META  = 1'b0,
    parameter ID_Q_DEPTH        = 8,
    parameter META_Q_DEPTH      = 8
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // Input combined stream: [ID beats][meta beats]...
    input  wire [AXI_WIDTH-1:0]   s_axis_tdata,
    input  wire                   s_axis_tvalid,
    output wire                   s_axis_tready,

    // Downstream consume request
    input  wire                   compute_req_next,

    // Decoded outputs (kept same as legacy decoder interface)
    output wire [AXI_WIDTH-1:0]   m_vals_data,   // 8x FP64 after LUT decode
    output wire [PARALLELISM*16-1:0]  m_row_deltas,
    output wire [15:0]            m_row_base,
    output wire [15:0]            m_col_base,
    output wire                   decoder_valid,
    output wire                   o_pipeline_idle
);
    localparam ID_VEC_W = PARALLELISM * ID_WIDTH;
    localparam META_VEC_W = PARALLELISM * 16 + 32; // {row_delta, col_base, row_base}
    localparam ID_Q_AW = (ID_Q_DEPTH <= 1) ? 1 : $clog2(ID_Q_DEPTH);
    localparam META_Q_AW = (META_Q_DEPTH <= 1) ? 1 : $clog2(META_Q_DEPTH);
    localparam ID_Q_CW = $clog2(ID_Q_DEPTH + 1);
    localparam META_Q_CW = $clog2(META_Q_DEPTH + 1);

    // ------------------------------------------------------------------------
    // Demux + FIFOs
    // ------------------------------------------------------------------------
    wire [AXI_WIDTH-1:0] id_fifo_din, id_fifo_dout;
    wire [AXI_WIDTH-1:0] meta_fifo_din, meta_fifo_dout;
    wire id_wen, id_full, id_empty, id_ren;
    wire meta_wen, meta_full, meta_empty, meta_ren;

    stream_demux_id52 #(
        .AXI_WIDTH(AXI_WIDTH),
        .VAL_ID_BATCH(VAL_ID_BATCH),
        .META_BATCH(META_BATCH)
    ) u_demux (
        .clk(clk),
        .rst_n(rst_n),
        .s_tdata(s_axis_tdata),
        .s_tvalid(s_axis_tvalid),
        .s_tready(s_axis_tready),
        .val_wen(id_wen),
        .val_din(id_fifo_din),
        .val_full(id_full),
        .meta_wen(meta_wen),
        .meta_din(meta_fifo_din),
        .meta_full(meta_full)
    );

    simple_sync_fifo #(.WIDTH(AXI_WIDTH), .DEPTH(64)) u_fifo_ids (
        .clk(clk),
        .rst_n(rst_n),
        .wen(id_wen),
        .din(id_fifo_din),
        .full(id_full),
        .ren(id_ren),
        .dout(id_fifo_dout),
        .empty(id_empty)
    );

    simple_sync_fifo #(.WIDTH(AXI_WIDTH), .DEPTH(128)) u_fifo_meta (
        .clk(clk),
        .rst_n(rst_n),
        .wen(meta_wen),
        .din(meta_fifo_din),
        .full(meta_full),
        .ren(meta_ren),
        .dout(meta_fifo_dout),
        .empty(meta_empty)
    );

    // ------------------------------------------------------------------------
    // Parsers
    // ------------------------------------------------------------------------
    wire meta_valid;
    wire [15:0] parser_row_base;
    wire [15:0] parser_col_base;
    wire [PARALLELISM*16-1:0] parser_row_delta;

    wire id_valid;
    wire [ID_VEC_W-1:0] id_vec;

    wire decoder_valid_lock = id_valid && meta_valid;
    wire consume_step_lock = compute_req_next && decoder_valid_lock;

    // Decouple queue control wires (become active only when DECOUPLE_ID_META=1).
    wire decoder_valid_dec;
    wire consume_step_dec;
    wire id_q_empty, id_q_full;
    wire meta_q_empty, meta_q_full;
    wire id_push_dec, id_pop_dec;
    wire meta_push_dec, meta_pop_dec;
    wire id_next_cycle_req = DECOUPLE_ID_META ? id_push_dec : consume_step_lock;
    wire meta_next_cycle_req = DECOUPLE_ID_META ? meta_push_dec : consume_step_lock;

    meta_parser #(
        .AXI_WIDTH(AXI_WIDTH),
        .PARALLELISM(PARALLELISM)
    ) u_parser_meta (
        .clk(clk),
        .rst_n(rst_n),
        .fifo_dout(meta_fifo_dout),
        .fifo_empty(meta_empty),
        .fifo_ren(meta_ren),
        .next_cycle_req(meta_next_cycle_req),
        .parser_valid(meta_valid),
        .out_row_base(parser_row_base),
        .out_col_base(parser_col_base),
        .out_row_delta(parser_row_delta)
    );

    id_unpack_parser #(
        .AXI_WIDTH(AXI_WIDTH),
        .ID_BATCH(VAL_ID_BATCH),
        .PARALLELISM(PARALLELISM),
        .ID_WIDTH(ID_WIDTH)
    ) u_parser_id (
        .clk(clk),
        .rst_n(rst_n),
        .fifo_dout(id_fifo_dout),
        .fifo_empty(id_empty),
        .fifo_ren(id_ren),
        .next_cycle_req(id_next_cycle_req),
        .parser_valid(id_valid),
        .out_id_vec(id_vec)
    );

    // ------------------------------------------------------------------------
    // Lockstep decode path (DECOUPLE_ID_META = 0)
    // ------------------------------------------------------------------------
    wire [PARALLELISM*DATA_WIDTH-1:0] fp_vec_lock;
    reg  [PARALLELISM*DATA_WIDTH-1:0] fp_vec_lock_d1;

    value_lut_decode #(
        .PARALLELISM(PARALLELISM),
        .ID_WIDTH(ID_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LUT_INIT_FILE(LUT_INIT_FILE)
    ) u_lut_lock (
        .id_vec(id_vec),
        .fp_vec(fp_vec_lock)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fp_vec_lock_d1 <= {PARALLELISM*DATA_WIDTH{1'b0}};
        end else if (consume_step_lock) begin
            fp_vec_lock_d1 <= fp_vec_lock;
        end
    end

    wire pipeline_idle_lock = id_empty && meta_empty && !id_valid && !meta_valid;

    // ------------------------------------------------------------------------
    // Decoupled token queues (DECOUPLE_ID_META = 1)
    // ------------------------------------------------------------------------
    reg [ID_VEC_W-1:0] id_queue [0:ID_Q_DEPTH-1];
    reg [ID_Q_AW-1:0] id_q_wptr, id_q_rptr;
    reg [ID_Q_CW-1:0] id_q_count;

    reg [META_VEC_W-1:0] meta_queue [0:META_Q_DEPTH-1];
    reg [META_Q_AW-1:0] meta_q_wptr, meta_q_rptr;
    reg [META_Q_CW-1:0] meta_q_count;

    assign id_q_empty = (id_q_count == 0);
    assign id_q_full  = (id_q_count == ID_Q_DEPTH);
    assign meta_q_empty = (meta_q_count == 0);
    assign meta_q_full  = (meta_q_count == META_Q_DEPTH);

    assign decoder_valid_dec = !id_q_empty && !meta_q_empty;
    assign consume_step_dec = compute_req_next && decoder_valid_dec;
    assign id_pop_dec = consume_step_dec;
    assign meta_pop_dec = consume_step_dec;
    assign id_push_dec = DECOUPLE_ID_META && id_valid && (!id_q_full || id_pop_dec);
    assign meta_push_dec = DECOUPLE_ID_META && meta_valid && (!meta_q_full || meta_pop_dec);

    wire [META_VEC_W-1:0] meta_pack = {parser_row_delta, parser_col_base, parser_row_base};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            id_q_wptr <= {ID_Q_AW{1'b0}};
            id_q_rptr <= {ID_Q_AW{1'b0}};
            id_q_count <= {ID_Q_CW{1'b0}};
            meta_q_wptr <= {META_Q_AW{1'b0}};
            meta_q_rptr <= {META_Q_AW{1'b0}};
            meta_q_count <= {META_Q_CW{1'b0}};
        end else if (DECOUPLE_ID_META) begin
            if (id_push_dec) begin
                id_queue[id_q_wptr] <= id_vec;
                if (id_q_wptr == ID_Q_DEPTH-1) begin
                    id_q_wptr <= {ID_Q_AW{1'b0}};
                end else begin
                    id_q_wptr <= id_q_wptr + 1'b1;
                end
            end
            if (id_pop_dec) begin
                if (id_q_rptr == ID_Q_DEPTH-1) begin
                    id_q_rptr <= {ID_Q_AW{1'b0}};
                end else begin
                    id_q_rptr <= id_q_rptr + 1'b1;
                end
            end
            case ({id_push_dec, id_pop_dec})
                2'b10: id_q_count <= id_q_count + 1'b1;
                2'b01: id_q_count <= id_q_count - 1'b1;
                default: id_q_count <= id_q_count;
            endcase

            if (meta_push_dec) begin
                meta_queue[meta_q_wptr] <= meta_pack;
                if (meta_q_wptr == META_Q_DEPTH-1) begin
                    meta_q_wptr <= {META_Q_AW{1'b0}};
                end else begin
                    meta_q_wptr <= meta_q_wptr + 1'b1;
                end
            end
            if (meta_pop_dec) begin
                if (meta_q_rptr == META_Q_DEPTH-1) begin
                    meta_q_rptr <= {META_Q_AW{1'b0}};
                end else begin
                    meta_q_rptr <= meta_q_rptr + 1'b1;
                end
            end
            case ({meta_push_dec, meta_pop_dec})
                2'b10: meta_q_count <= meta_q_count + 1'b1;
                2'b01: meta_q_count <= meta_q_count - 1'b1;
                default: meta_q_count <= meta_q_count;
            endcase
        end
    end

    wire [ID_VEC_W-1:0] id_head_dec =
        id_q_empty ? {ID_VEC_W{1'b0}} : id_queue[id_q_rptr];
    wire [META_VEC_W-1:0] meta_head_dec =
        meta_q_empty ? {META_VEC_W{1'b0}} : meta_queue[meta_q_rptr];

    wire [PARALLELISM*DATA_WIDTH-1:0] fp_vec_dec;
    reg  [PARALLELISM*DATA_WIDTH-1:0] fp_vec_dec_d1;

    value_lut_decode #(
        .PARALLELISM(PARALLELISM),
        .ID_WIDTH(ID_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LUT_INIT_FILE(LUT_INIT_FILE)
    ) u_lut_dec (
        .id_vec(id_head_dec),
        .fp_vec(fp_vec_dec)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fp_vec_dec_d1 <= {PARALLELISM*DATA_WIDTH{1'b0}};
        end else if (consume_step_dec) begin
            fp_vec_dec_d1 <= fp_vec_dec;
        end
    end

    wire [15:0] dec_row_base_dec = meta_head_dec[15:0];
    wire [15:0] dec_col_base_dec = meta_head_dec[31:16];
    wire [PARALLELISM*16-1:0] dec_row_deltas_dec = meta_head_dec[META_VEC_W-1:32];

    wire pipeline_idle_dec =
        id_empty && meta_empty &&
        id_q_empty && meta_q_empty &&
        !id_valid && !meta_valid;

    // ------------------------------------------------------------------------
    // Outputs
    // ------------------------------------------------------------------------
    assign decoder_valid = DECOUPLE_ID_META ? decoder_valid_dec : decoder_valid_lock;
    assign m_vals_data = DECOUPLE_ID_META ? fp_vec_dec_d1 : fp_vec_lock_d1;
    assign m_row_deltas = DECOUPLE_ID_META ? dec_row_deltas_dec : parser_row_delta;
    assign m_row_base = DECOUPLE_ID_META ? dec_row_base_dec : parser_row_base;
    assign m_col_base = DECOUPLE_ID_META ? dec_col_base_dec : parser_col_base;
    assign o_pipeline_idle = DECOUPLE_ID_META ? pipeline_idle_dec : pipeline_idle_lock;

    // ------------------------------------------------------------------------
    // Decoder bottleneck stats
    // ------------------------------------------------------------------------
    reg stats_active;
    reg stats_reported;
    reg [31:0] id_empty_cycles;
    reg [31:0] id_full_cycles;
    reg [31:0] meta_empty_cycles;
    reg [31:0] meta_full_cycles;
    reg [31:0] pair_wait_cycles;
    reg [31:0] consume_cycles;

    wire stats_start = s_axis_tvalid && s_axis_tready;
    wire stats_id_empty = DECOUPLE_ID_META ? id_q_empty : !id_valid;
    wire stats_meta_empty = DECOUPLE_ID_META ? meta_q_empty : !meta_valid;
    wire stats_id_full = DECOUPLE_ID_META ? id_q_full : 1'b0;
    wire stats_meta_full = DECOUPLE_ID_META ? meta_q_full : 1'b0;
    wire stats_pair_wait = stats_id_empty ^ stats_meta_empty;
    wire stats_consume = DECOUPLE_ID_META ? consume_step_dec : consume_step_lock;
    wire stats_done = stats_active && !stats_reported && o_pipeline_idle && !s_axis_tvalid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stats_active <= 1'b0;
            stats_reported <= 1'b0;
            id_empty_cycles <= 32'd0;
            id_full_cycles <= 32'd0;
            meta_empty_cycles <= 32'd0;
            meta_full_cycles <= 32'd0;
            pair_wait_cycles <= 32'd0;
            consume_cycles <= 32'd0;
        end else begin
            if (stats_start && !stats_active && !stats_reported) begin
                stats_active <= 1'b1;
            end

            if (stats_active) begin
                if (stats_id_empty) id_empty_cycles <= id_empty_cycles + 1'b1;
                if (stats_id_full) id_full_cycles <= id_full_cycles + 1'b1;
                if (stats_meta_empty) meta_empty_cycles <= meta_empty_cycles + 1'b1;
                if (stats_meta_full) meta_full_cycles <= meta_full_cycles + 1'b1;
                if (stats_pair_wait) pair_wait_cycles <= pair_wait_cycles + 1'b1;
                if (stats_consume) consume_cycles <= consume_cycles + 1'b1;
            end

            if (stats_done) begin
                stats_active <= 1'b0;
                stats_reported <= 1'b1;
                $display("DEC_STATS id_empty=%0d id_full=%0d meta_empty=%0d meta_full=%0d pair_wait=%0d consume=%0d",
                         id_empty_cycles, id_full_cycles, meta_empty_cycles, meta_full_cycles, pair_wait_cycles, consume_cycles);
            end
        end
    end

endmodule

