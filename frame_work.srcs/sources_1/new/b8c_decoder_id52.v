`timescale 1ns / 1ps

module b8c_decoder_id52 #(
    parameter AXI_WIDTH     = 512,
    parameter PARALLELISM   = 8,
    parameter VAL_ID_BATCH  = 2,
    parameter META_BATCH    = 5,
    parameter ID_WIDTH      = 8,
    parameter DATA_WIDTH    = 64,
    parameter LUT_INIT_FILE = ""
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

    simple_sync_fifo #(.WIDTH(AXI_WIDTH), .DEPTH(512)) u_fifo_ids (
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
    // Parsers and decode
    // ------------------------------------------------------------------------
    wire meta_valid;
    wire [15:0] parser_row_base;
    wire [15:0] parser_col_base;
    wire [PARALLELISM*16-1:0] parser_row_delta;

    wire id_valid;
    wire [PARALLELISM*ID_WIDTH-1:0] id_vec;
    wire [PARALLELISM*DATA_WIDTH-1:0] fp_vec;
    reg  [PARALLELISM*DATA_WIDTH-1:0] fp_vec_d1;

    // Consume pulse: both parsers advance together.
    wire consume_step = compute_req_next && decoder_valid;

    meta_parser #(
        .AXI_WIDTH(AXI_WIDTH),
        .PARALLELISM(PARALLELISM)
    ) u_parser_meta (
        .clk(clk),
        .rst_n(rst_n),
        .fifo_dout(meta_fifo_dout),
        .fifo_empty(meta_empty),
        .fifo_ren(meta_ren),
        .next_cycle_req(consume_step),
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
        .next_cycle_req(consume_step),
        .parser_valid(id_valid),
        .out_id_vec(id_vec)
    );

    value_lut_decode #(
        .PARALLELISM(PARALLELISM),
        .ID_WIDTH(ID_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LUT_INIT_FILE(LUT_INIT_FILE)
    ) u_lut (
        .id_vec(id_vec),
        .fp_vec(fp_vec)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fp_vec_d1 <= {PARALLELISM*DATA_WIDTH{1'b0}};
        end else if (consume_step) begin
            fp_vec_d1 <= fp_vec;
        end
    end

    // ------------------------------------------------------------------------
    // Outputs
    // ------------------------------------------------------------------------
    assign decoder_valid   = id_valid && meta_valid;
    assign m_vals_data     = fp_vec_d1;
    assign m_row_deltas    = parser_row_delta;
    assign m_row_base      = parser_row_base;
    assign m_col_base      = parser_col_base;

    // Idle when both ingress FIFOs are empty and parsers are not emitting.
    assign o_pipeline_idle = id_empty && meta_empty && !id_valid && !meta_valid;

endmodule
