`timescale 1ns / 1ps

module csr_decoder #(
    parameter AXI_WIDTH   = 512,
    parameter PARALLELISM = 8,
    parameter DATA_WIDTH  = 64,
    parameter ADDR_WIDTH  = 16
)(
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire [AXI_WIDTH-1:0]         s_axis_tdata,
    input  wire                         s_axis_tvalid,
    output wire                         s_axis_tready,
    input  wire                         compute_req_next,
    output wire [PARALLELISM*DATA_WIDTH-1:0] m_vals_data,
    output wire [PARALLELISM*ADDR_WIDTH-1:0] m_rows_abs,
    output wire [PARALLELISM*ADDR_WIDTH-1:0] m_cols_abs,
    output wire [PARALLELISM-1:0]       m_valid_mask,
    output wire                         decoder_valid,
    output wire                         o_pipeline_idle
);
    localparam integer CSR_TUPLE_BITS = 97;
    localparam integer CSR_GROUP_BITS = 1024;
    localparam integer CSR_RESERVED_LSB = CSR_TUPLE_BITS * 8;

    reg [AXI_WIDTH-1:0] lower_beat;
    reg                 have_lower;
    reg [CSR_GROUP_BITS-1:0] group_reg;
    reg                 group_valid;

    wire accept_beat = s_axis_tvalid && s_axis_tready;
    wire consume_group = compute_req_next && group_valid;
    wire [CSR_GROUP_BITS-1:0] assembled_group = {s_axis_tdata, lower_beat};

    assign s_axis_tready = !group_valid;
    assign decoder_valid = group_valid;
    assign o_pipeline_idle = !group_valid && !have_lower;

    genvar lane;
    generate
        for (lane = 0; lane < PARALLELISM; lane = lane + 1) begin : gen_tuple
            localparam integer BASE = lane * CSR_TUPLE_BITS;
            wire tuple_valid = group_reg[BASE];
            wire [15:0] tuple_row = group_reg[BASE + 1 +: 16];
            wire [15:0] tuple_col = group_reg[BASE + 17 +: 16];
            wire [DATA_WIDTH-1:0] tuple_value = group_reg[BASE + 33 +: DATA_WIDTH];

            assign m_valid_mask[lane] = tuple_valid;
            assign m_rows_abs[lane*ADDR_WIDTH +: ADDR_WIDTH] = tuple_valid ? tuple_row[ADDR_WIDTH-1:0] : {ADDR_WIDTH{1'b0}};
            assign m_cols_abs[lane*ADDR_WIDTH +: ADDR_WIDTH] = tuple_valid ? tuple_col[ADDR_WIDTH-1:0] : {ADDR_WIDTH{1'b0}};
            assign m_vals_data[lane*DATA_WIDTH +: DATA_WIDTH] = tuple_valid ? tuple_value : {DATA_WIDTH{1'b0}};
        end
    endgenerate

    integer check_lane;
    integer check_base;
    reg [15:0] check_col;

`ifndef SYNTHESIS
    reg stats_active;
    reg stats_reported;
    reg [31:0] id_empty_cycles;
    reg [31:0] id_full_cycles;
    reg [31:0] meta_empty_cycles;
    reg [31:0] meta_full_cycles;
    reg [31:0] pair_wait_cycles;
    reg [31:0] consume_cycles;
    reg [31:0] decoder_valid_cycles;
    reg [31:0] compute_req_cycles;
    reg [31:0] compute_backpressure_cycles;
    reg [31:0] no_decoder_valid_cycles;
    reg [31:0] both_ready_cycles;
    reg [31:0] both_empty_cycles;
    reg [31:0] id_only_wait_cycles;
    reg [31:0] meta_only_wait_cycles;
    reg [31:0] id_q_occupancy_sum;
    reg [31:0] meta_q_occupancy_sum;
    reg [31:0] id_q_occupancy_max;
    reg [31:0] meta_q_occupancy_max;

    wire stats_start = accept_beat;
    wire stats_id_empty = !group_valid;
    wire stats_id_full = group_valid;
    wire stats_decoder_valid = group_valid;
    wire stats_consume = consume_group;
    wire stats_compute_backpressure = group_valid && !compute_req_next;
    wire stats_both_empty = !group_valid && !have_lower;
    wire stats_done = stats_active && !stats_reported && o_pipeline_idle && !s_axis_tvalid;
`endif

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lower_beat <= {AXI_WIDTH{1'b0}};
            have_lower <= 1'b0;
            group_reg <= {CSR_GROUP_BITS{1'b0}};
            group_valid <= 1'b0;
        end else begin
            if (consume_group) begin
                group_valid <= 1'b0;
                group_reg <= {CSR_GROUP_BITS{1'b0}};
            end

            if (accept_beat) begin
                if (!have_lower) begin
                    lower_beat <= s_axis_tdata;
                    have_lower <= 1'b1;
                end else begin
                    group_reg <= assembled_group;
                    group_valid <= 1'b1;
                    have_lower <= 1'b0;
`ifndef SYNTHESIS
                    if (PARALLELISM != 8) begin
                        $fatal(1, "csr_decoder supports only PARALLELISM=8, got %0d", PARALLELISM);
                    end
                    if (AXI_WIDTH != 512) begin
                        $fatal(1, "csr_decoder supports only AXI_WIDTH=512, got %0d", AXI_WIDTH);
                    end
                    if (assembled_group[CSR_GROUP_BITS-1:CSR_RESERVED_LSB] != {CSR_GROUP_BITS-CSR_RESERVED_LSB{1'b0}}) begin
                        $fatal(1, "CSR reserved bits [1023:776] must be zero: %h", assembled_group[CSR_GROUP_BITS-1:CSR_RESERVED_LSB]);
                    end
                    for (check_lane = 0; check_lane < PARALLELISM; check_lane = check_lane + 1) begin
                        check_base = check_lane * CSR_TUPLE_BITS;
                        check_col = assembled_group[check_base + 17 +: 16];
                        if (assembled_group[check_base]) begin
                            if ((check_col % PARALLELISM) != check_lane) begin
                                $fatal(1, "CSR lane-bank invariant failed lane=%0d col=%0d", check_lane, check_col);
                            end
                        end else if (assembled_group[check_base +: CSR_TUPLE_BITS] != {CSR_TUPLE_BITS{1'b0}}) begin
                            $fatal(1, "CSR invalid lane payload must be zero lane=%0d payload=%h", check_lane, assembled_group[check_base +: CSR_TUPLE_BITS]);
                        end
                    end
`endif
                end
            end
        end
    end

`ifndef SYNTHESIS
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
            decoder_valid_cycles <= 32'd0;
            compute_req_cycles <= 32'd0;
            compute_backpressure_cycles <= 32'd0;
            no_decoder_valid_cycles <= 32'd0;
            both_ready_cycles <= 32'd0;
            both_empty_cycles <= 32'd0;
            id_only_wait_cycles <= 32'd0;
            meta_only_wait_cycles <= 32'd0;
            id_q_occupancy_sum <= 32'd0;
            meta_q_occupancy_sum <= 32'd0;
            id_q_occupancy_max <= 32'd0;
            meta_q_occupancy_max <= 32'd0;
        end else begin
            if (stats_start && !stats_active && !stats_reported) begin
                stats_active <= 1'b1;
            end

            if (stats_active && !stats_done) begin
                if (stats_id_empty) id_empty_cycles <= id_empty_cycles + 1'b1;
                if (stats_id_full) id_full_cycles <= id_full_cycles + 1'b1;
                if (stats_consume) consume_cycles <= consume_cycles + 1'b1;
                if (stats_decoder_valid) decoder_valid_cycles <= decoder_valid_cycles + 1'b1;
                if (compute_req_next) compute_req_cycles <= compute_req_cycles + 1'b1;
                if (stats_compute_backpressure) compute_backpressure_cycles <= compute_backpressure_cycles + 1'b1;
                if (!stats_decoder_valid) no_decoder_valid_cycles <= no_decoder_valid_cycles + 1'b1;
                if (stats_decoder_valid) both_ready_cycles <= both_ready_cycles + 1'b1;
                if (stats_both_empty) both_empty_cycles <= both_empty_cycles + 1'b1;
                id_q_occupancy_sum <= id_q_occupancy_sum + {31'd0, group_valid};
                if ({31'd0, group_valid} > id_q_occupancy_max) id_q_occupancy_max <= {31'd0, group_valid};
            end

            if (stats_done) begin
                stats_active <= 1'b0;
                stats_reported <= 1'b1;
                $display("DEC_STATS id_empty=%0d id_full=%0d meta_empty=%0d meta_full=%0d pair_wait=%0d consume=%0d",
                         id_empty_cycles, id_full_cycles, meta_empty_cycles, meta_full_cycles, pair_wait_cycles, consume_cycles);
                $display("DEC_DETAIL_STATS decoder_valid=%0d compute_req=%0d compute_backpressure=%0d no_decoder_valid=%0d both_ready=%0d both_empty=%0d id_only_wait=%0d meta_only_wait=%0d id_q_sum=%0d meta_q_sum=%0d id_q_max=%0d meta_q_max=%0d",
                         decoder_valid_cycles, compute_req_cycles, compute_backpressure_cycles, no_decoder_valid_cycles,
                         both_ready_cycles, both_empty_cycles, id_only_wait_cycles, meta_only_wait_cycles,
                         id_q_occupancy_sum, meta_q_occupancy_sum, id_q_occupancy_max, meta_q_occupancy_max);
            end
        end
    end
`endif
endmodule
