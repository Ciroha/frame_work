`timescale 1ns / 1ps

module y_acc_banks #(
    parameter PARALLELISM = 8,
    parameter DATA_WIDTH  = 64,
    parameter DEPTH       = 128,
    parameter ADDR_WIDTH  = $clog2(DEPTH),
    parameter SIM_USE_IP  = 1'b1,
    parameter ENABLE_PREVIEW_RESERVE = 1'b1,
    parameter QUEUE_DEPTH = 256,
    parameter LIMITED_BYPASS_WINDOW = 4,
    parameter SIM_ENABLE_BANK_STATS = 1'b0,
    parameter SIM_PRINT_BATCH_BANK_STATS = 1'b0,
    parameter SIM_ENABLE_STALL_REASON_STATS = 1'b0,
    parameter ENABLE_LIMITED_BYPASS = 1'b0
)(
    input  wire clk,
    input  wire [1:0] mode,
    input  wire                              ls_en,
    input  wire [ADDR_WIDTH-1:0]             ls_addr,
    input  wire [PARALLELISM*DATA_WIDTH-1:0] load_data,
    output wire [PARALLELISM*DATA_WIDTH-1:0] store_data,
    output wire                              acc_ready,
    output wire                              acc_idle,
    input  wire                              batch_fire,
    input  wire [PARALLELISM-1:0]            preview_valid_a,
    input  wire [PARALLELISM*ADDR_WIDTH-1:0] preview_y_local_addr_a,
    input  wire [PARALLELISM-1:0]            preview_valid_b,
    input  wire [PARALLELISM*ADDR_WIDTH-1:0] preview_y_local_addr_b,
    input  wire [PARALLELISM*DATA_WIDTH-1:0] partial_products_a,
    input  wire [PARALLELISM-1:0]            pp_valid_a,
    input  wire [PARALLELISM*ADDR_WIDTH-1:0] y_local_addr_a,
    input  wire [PARALLELISM*DATA_WIDTH-1:0] partial_products_b,
    input  wire [PARALLELISM-1:0]            pp_valid_b,
    input  wire [PARALLELISM*ADDR_WIDTH-1:0] y_local_addr_b
);

    localparam UPDATE_CHANNELS = PARALLELISM * 2;
    localparam integer BANK_DEPTH = (DEPTH + PARALLELISM - 1) / PARALLELISM;
    localparam integer BANK_SEL_WIDTH = (PARALLELISM <= 1) ? 1 : $clog2(PARALLELISM);
    localparam integer BANK_ADDR_WIDTH = (BANK_DEPTH <= 1) ? 1 : $clog2(BANK_DEPTH);
    localparam integer ADD_LATENCY = 8;
    localparam integer QUEUE_PTR_WIDTH = $clog2(QUEUE_DEPTH);
    localparam integer QUEUE_COUNT_WIDTH = $clog2(QUEUE_DEPTH + 1);

    reg [PARALLELISM*DATA_WIDTH-1:0] r_store_data;
    assign store_data = r_store_data;

    wire [UPDATE_CHANNELS*ADDR_WIDTH-1:0] y_local_addr_all = {y_local_addr_b, y_local_addr_a};
    wire [UPDATE_CHANNELS*ADDR_WIDTH-1:0] preview_y_local_addr_all = {preview_y_local_addr_b, preview_y_local_addr_a};
    wire [UPDATE_CHANNELS*DATA_WIDTH-1:0] pp_all = {partial_products_b, partial_products_a};
    wire [UPDATE_CHANNELS-1:0] pp_valid_all = {pp_valid_b, pp_valid_a};
    wire [UPDATE_CHANNELS-1:0] preview_valid_all = {preview_valid_b, preview_valid_a};
    wire [ADDR_WIDTH-1:0] addr [0:UPDATE_CHANNELS-1];
    wire [ADDR_WIDTH-1:0] preview_addr [0:UPDATE_CHANNELS-1];
    wire [BANK_SEL_WIDTH-1:0] bank_sel [0:UPDATE_CHANNELS-1];
    wire [BANK_SEL_WIDTH-1:0] preview_bank_sel [0:UPDATE_CHANNELS-1];
    wire [BANK_ADDR_WIDTH-1:0] bank_addr [0:UPDATE_CHANNELS-1];
    wire [DATA_WIDTH-1:0] pp [0:UPDATE_CHANNELS-1];
    wire enqueue_fire;
    wire unused_batch_fire;

    genvar k;
    generate
        for (k = 0; k < UPDATE_CHANNELS; k = k + 1) begin : gen_extract
            assign addr[k] = y_local_addr_all[k*ADDR_WIDTH +: ADDR_WIDTH];
            assign preview_addr[k] = preview_y_local_addr_all[k*ADDR_WIDTH +: ADDR_WIDTH];
            assign bank_sel[k] = addr[k][BANK_SEL_WIDTH-1:0];
            assign preview_bank_sel[k] = preview_addr[k][BANK_SEL_WIDTH-1:0];
            assign bank_addr[k] = addr[k] >> BANK_SEL_WIDTH;
            assign pp[k] = pp_all[k*DATA_WIDTH +: DATA_WIDTH];
        end
    endgenerate

    assign enqueue_fire = |pp_valid_all;
    assign unused_batch_fire = batch_fire;

`ifndef SYNTHESIS
    reg                              merged_enqueue_fire;
    reg                              merged_preview_valid [0:UPDATE_CHANNELS-1];
    reg                              merged_pp_valid [0:UPDATE_CHANNELS-1];
    reg [ADDR_WIDTH-1:0]             merged_preview_addr [0:UPDATE_CHANNELS-1];
    reg [ADDR_WIDTH-1:0]             merged_pp_addr [0:UPDATE_CHANNELS-1];
    reg [BANK_SEL_WIDTH-1:0]         merged_preview_bank [0:UPDATE_CHANNELS-1];
    reg [BANK_SEL_WIDTH-1:0]         merged_pp_bank [0:UPDATE_CHANNELS-1];
    reg [BANK_ADDR_WIDTH-1:0]        merged_pp_bank_addr [0:UPDATE_CHANNELS-1];
    reg [DATA_WIDTH-1:0]             merged_pp_data [0:UPDATE_CHANNELS-1];
    reg [QUEUE_COUNT_WIDTH-1:0]      merged_preview_bank_hit_count [0:PARALLELISM-1];
    reg [QUEUE_COUNT_WIDTH-1:0]      merged_pp_bank_hit_count [0:PARALLELISM-1];
    reg [QUEUE_COUNT_WIDTH-1:0]      raw_preview_bank_hit_count [0:PARALLELISM-1];
    reg [QUEUE_COUNT_WIDTH-1:0]      raw_pp_bank_hit_count [0:PARALLELISM-1];
    reg [QUEUE_COUNT_WIDTH-1:0]      raw_preview_bank_hit_count_a [0:PARALLELISM-1];
    reg [QUEUE_COUNT_WIDTH-1:0]      raw_preview_bank_hit_count_b [0:PARALLELISM-1];
    reg [QUEUE_COUNT_WIDTH-1:0]      merged_preview_bank_hit_count_a [0:PARALLELISM-1];
    reg [QUEUE_COUNT_WIDTH-1:0]      merged_preview_bank_hit_count_b [0:PARALLELISM-1];
    real                             merged_pp_sum_real [0:UPDATE_CHANNELS-1];
    integer                          merge_bank_idx;
    integer                          merge_idx;
    integer                          merge_insert_idx;
    integer                          merge_preview_idx;
    integer                          merge_pp_idx;
    integer                          merge_preview_match;
    integer                          merge_pp_match;
    integer                          stat_idx;
    integer                          stat_max_raw;
    integer                          stat_max_merged;
    integer                          stat_batch_seq;
    integer                          stat_preview_batches;
    integer                          stat_accepted_batches;
    integer                          stat_rejected_batches;
    integer                          stat_raw_total [0:PARALLELISM-1];
    integer                          stat_merged_total [0:PARALLELISM-1];
    integer                          stat_raw_total_a [0:PARALLELISM-1];
    integer                          stat_raw_total_b [0:PARALLELISM-1];
    integer                          stat_merged_total_a [0:PARALLELISM-1];
    integer                          stat_merged_total_b [0:PARALLELISM-1];
    integer                          stat_raw_max [0:PARALLELISM-1];
    integer                          stat_merged_max [0:PARALLELISM-1];
    integer                          stat_raw_hot_count [0:PARALLELISM-1];
    integer                          stat_merged_hot_count [0:PARALLELISM-1];
    reg                              stat_bank_dumped;

    always @(*) begin
        merged_enqueue_fire = 1'b0;
        for (merge_idx = 0; merge_idx < UPDATE_CHANNELS; merge_idx = merge_idx + 1) begin
            merged_preview_valid[merge_idx] = 1'b0;
            merged_pp_valid[merge_idx] = 1'b0;
            merged_preview_addr[merge_idx] = {ADDR_WIDTH{1'b0}};
            merged_pp_addr[merge_idx] = {ADDR_WIDTH{1'b0}};
            merged_preview_bank[merge_idx] = {BANK_SEL_WIDTH{1'b0}};
            merged_pp_bank[merge_idx] = {BANK_SEL_WIDTH{1'b0}};
            merged_pp_bank_addr[merge_idx] = {BANK_ADDR_WIDTH{1'b0}};
            merged_pp_data[merge_idx] = {DATA_WIDTH{1'b0}};
            merged_pp_sum_real[merge_idx] = 0.0;
        end

        for (merge_bank_idx = 0; merge_bank_idx < PARALLELISM; merge_bank_idx = merge_bank_idx + 1) begin
            merged_preview_bank_hit_count[merge_bank_idx] = {QUEUE_COUNT_WIDTH{1'b0}};
            merged_pp_bank_hit_count[merge_bank_idx] = {QUEUE_COUNT_WIDTH{1'b0}};
            raw_preview_bank_hit_count[merge_bank_idx] = {QUEUE_COUNT_WIDTH{1'b0}};
            raw_pp_bank_hit_count[merge_bank_idx] = {QUEUE_COUNT_WIDTH{1'b0}};
            raw_preview_bank_hit_count_a[merge_bank_idx] = {QUEUE_COUNT_WIDTH{1'b0}};
            raw_preview_bank_hit_count_b[merge_bank_idx] = {QUEUE_COUNT_WIDTH{1'b0}};
            merged_preview_bank_hit_count_a[merge_bank_idx] = {QUEUE_COUNT_WIDTH{1'b0}};
            merged_preview_bank_hit_count_b[merge_bank_idx] = {QUEUE_COUNT_WIDTH{1'b0}};
        end

        merge_preview_idx = 0;
        for (merge_idx = 0; merge_idx < UPDATE_CHANNELS; merge_idx = merge_idx + 1) begin
            if (preview_valid_all[merge_idx] && (preview_addr[merge_idx] < DEPTH)) begin
                raw_preview_bank_hit_count[preview_bank_sel[merge_idx]] =
                    raw_preview_bank_hit_count[preview_bank_sel[merge_idx]] + 1'b1;
                if (merge_idx < PARALLELISM) begin
                    raw_preview_bank_hit_count_a[preview_bank_sel[merge_idx]] =
                        raw_preview_bank_hit_count_a[preview_bank_sel[merge_idx]] + 1'b1;
                end else begin
                    raw_preview_bank_hit_count_b[preview_bank_sel[merge_idx]] =
                        raw_preview_bank_hit_count_b[preview_bank_sel[merge_idx]] + 1'b1;
                end
                merge_preview_match = -1;
                for (merge_insert_idx = 0; merge_insert_idx < merge_preview_idx; merge_insert_idx = merge_insert_idx + 1) begin
                    if (merged_preview_valid[merge_insert_idx] &&
                        (merged_preview_addr[merge_insert_idx] == preview_addr[merge_idx])) begin
                        merge_preview_match = merge_insert_idx;
                    end
                end

                if (merge_preview_match < 0) begin
                    merged_preview_valid[merge_preview_idx] = 1'b1;
                    merged_preview_addr[merge_preview_idx] = preview_addr[merge_idx];
                    merged_preview_bank[merge_preview_idx] = preview_bank_sel[merge_idx];
                    merged_preview_bank_hit_count[preview_bank_sel[merge_idx]] =
                        merged_preview_bank_hit_count[preview_bank_sel[merge_idx]] + 1'b1;
                    if (merge_idx < PARALLELISM) begin
                        merged_preview_bank_hit_count_a[preview_bank_sel[merge_idx]] =
                            merged_preview_bank_hit_count_a[preview_bank_sel[merge_idx]] + 1'b1;
                    end else begin
                        merged_preview_bank_hit_count_b[preview_bank_sel[merge_idx]] =
                            merged_preview_bank_hit_count_b[preview_bank_sel[merge_idx]] + 1'b1;
                    end
                    merge_preview_idx = merge_preview_idx + 1;
                end
            end
        end

        merge_pp_idx = 0;
        for (merge_idx = 0; merge_idx < UPDATE_CHANNELS; merge_idx = merge_idx + 1) begin
            if (pp_valid_all[merge_idx] && (addr[merge_idx] < DEPTH)) begin
                merged_enqueue_fire = 1'b1;
                raw_pp_bank_hit_count[bank_sel[merge_idx]] =
                    raw_pp_bank_hit_count[bank_sel[merge_idx]] + 1'b1;
                merge_pp_match = -1;
                for (merge_insert_idx = 0; merge_insert_idx < merge_pp_idx; merge_insert_idx = merge_insert_idx + 1) begin
                    if (merged_pp_valid[merge_insert_idx] &&
                        (merged_pp_addr[merge_insert_idx] == addr[merge_idx])) begin
                        merge_pp_match = merge_insert_idx;
                    end
                end

                if (merge_pp_match < 0) begin
                    merged_pp_valid[merge_pp_idx] = 1'b1;
                    merged_pp_addr[merge_pp_idx] = addr[merge_idx];
                    merged_pp_bank[merge_pp_idx] = bank_sel[merge_idx];
                    merged_pp_bank_addr[merge_pp_idx] = bank_addr[merge_idx];
                    merged_pp_data[merge_pp_idx] = pp[merge_idx];
                    merged_pp_sum_real[merge_pp_idx] = $bitstoreal(pp[merge_idx]);
                    merged_pp_bank_hit_count[bank_sel[merge_idx]] =
                        merged_pp_bank_hit_count[bank_sel[merge_idx]] + 1'b1;
                    merge_pp_idx = merge_pp_idx + 1;
                end else begin
                    merged_pp_sum_real[merge_pp_match] =
                        merged_pp_sum_real[merge_pp_match] + $bitstoreal(pp[merge_idx]);
                    merged_pp_data[merge_pp_match] =
                        $realtobits(merged_pp_sum_real[merge_pp_match]);
                end
            end
        end
    end

    initial begin
        stat_batch_seq = 0;
        stat_preview_batches = 0;
        stat_accepted_batches = 0;
        stat_rejected_batches = 0;
        stat_bank_dumped = 1'b0;
        for (stat_idx = 0; stat_idx < PARALLELISM; stat_idx = stat_idx + 1) begin
            stat_raw_total[stat_idx] = 0;
            stat_merged_total[stat_idx] = 0;
            stat_raw_total_a[stat_idx] = 0;
            stat_raw_total_b[stat_idx] = 0;
            stat_merged_total_a[stat_idx] = 0;
            stat_merged_total_b[stat_idx] = 0;
            stat_raw_max[stat_idx] = 0;
            stat_merged_max[stat_idx] = 0;
            stat_raw_hot_count[stat_idx] = 0;
            stat_merged_hot_count[stat_idx] = 0;
        end
    end

    always @(posedge clk) begin
        if (SIM_ENABLE_BANK_STATS) begin
            if (mode != 2'b10) begin
                if (mode == 2'b11) begin
                    if (ls_en && !stat_bank_dumped) begin
                        $display("BANK_STATS batches preview=%0d accepted=%0d rejected=%0d",
                                 stat_preview_batches, stat_accepted_batches, stat_rejected_batches);
                        for (stat_idx = 0; stat_idx < PARALLELISM; stat_idx = stat_idx + 1) begin
                            $display("BANK_STATS bank=%0d raw_total=%0d raw_a=%0d raw_b=%0d merged_total=%0d merged_a=%0d merged_b=%0d raw_max=%0d merged_max=%0d raw_hot=%0d merged_hot=%0d",
                                     stat_idx,
                                     stat_raw_total[stat_idx],
                                     stat_raw_total_a[stat_idx],
                                     stat_raw_total_b[stat_idx],
                                     stat_merged_total[stat_idx],
                                     stat_merged_total_a[stat_idx],
                                     stat_merged_total_b[stat_idx],
                                     stat_raw_max[stat_idx],
                                     stat_merged_max[stat_idx],
                                     stat_raw_hot_count[stat_idx],
                                     stat_merged_hot_count[stat_idx]);
                        end
                        stat_bank_dumped <= 1'b1;
                    end
                end else begin
                    stat_bank_dumped <= 1'b0;
                end
            end

            if ((mode == 2'b10) && (|preview_valid_all)) begin
                stat_batch_seq <= stat_batch_seq + 1;
                stat_preview_batches <= stat_preview_batches + 1;
                if (batch_fire && acc_ready) begin
                    stat_accepted_batches <= stat_accepted_batches + 1;
                end else if (!batch_fire) begin
                    stat_rejected_batches <= stat_rejected_batches + 1;
                end

                stat_max_raw = 0;
                stat_max_merged = 0;
                for (stat_idx = 0; stat_idx < PARALLELISM; stat_idx = stat_idx + 1) begin
                    if (raw_preview_bank_hit_count[stat_idx] > stat_max_raw) begin
                        stat_max_raw = raw_preview_bank_hit_count[stat_idx];
                    end
                    if (merged_preview_bank_hit_count[stat_idx] > stat_max_merged) begin
                        stat_max_merged = merged_preview_bank_hit_count[stat_idx];
                    end
                end

                for (stat_idx = 0; stat_idx < PARALLELISM; stat_idx = stat_idx + 1) begin
                    stat_raw_total[stat_idx] <= stat_raw_total[stat_idx] + raw_preview_bank_hit_count[stat_idx];
                    stat_merged_total[stat_idx] <= stat_merged_total[stat_idx] + merged_preview_bank_hit_count[stat_idx];
                    stat_raw_total_a[stat_idx] <= stat_raw_total_a[stat_idx] + raw_preview_bank_hit_count_a[stat_idx];
                    stat_raw_total_b[stat_idx] <= stat_raw_total_b[stat_idx] + raw_preview_bank_hit_count_b[stat_idx];
                    stat_merged_total_a[stat_idx] <= stat_merged_total_a[stat_idx] + merged_preview_bank_hit_count_a[stat_idx];
                    stat_merged_total_b[stat_idx] <= stat_merged_total_b[stat_idx] + merged_preview_bank_hit_count_b[stat_idx];
                    if (raw_preview_bank_hit_count[stat_idx] > stat_raw_max[stat_idx]) begin
                        stat_raw_max[stat_idx] <= raw_preview_bank_hit_count[stat_idx];
                    end
                    if (merged_preview_bank_hit_count[stat_idx] > stat_merged_max[stat_idx]) begin
                        stat_merged_max[stat_idx] <= merged_preview_bank_hit_count[stat_idx];
                    end
                    if ((stat_max_raw != 0) && (raw_preview_bank_hit_count[stat_idx] == stat_max_raw)) begin
                        stat_raw_hot_count[stat_idx] <= stat_raw_hot_count[stat_idx] + 1;
                    end
                    if ((stat_max_merged != 0) && (merged_preview_bank_hit_count[stat_idx] == stat_max_merged)) begin
                        stat_merged_hot_count[stat_idx] <= stat_merged_hot_count[stat_idx] + 1;
                    end
                end

                if (SIM_PRINT_BATCH_BANK_STATS) begin
                    $display("BANK_BATCH idx=%0d raw=%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d merged=%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d accepted=%0d",
                             stat_batch_seq,
                             raw_preview_bank_hit_count[0], raw_preview_bank_hit_count[1],
                             raw_preview_bank_hit_count[2], raw_preview_bank_hit_count[3],
                             raw_preview_bank_hit_count[4], raw_preview_bank_hit_count[5],
                             raw_preview_bank_hit_count[6], raw_preview_bank_hit_count[7],
                             merged_preview_bank_hit_count[0], merged_preview_bank_hit_count[1],
                             merged_preview_bank_hit_count[2], merged_preview_bank_hit_count[3],
                             merged_preview_bank_hit_count[4], merged_preview_bank_hit_count[5],
                             merged_preview_bank_hit_count[6], merged_preview_bank_hit_count[7],
                             batch_fire && acc_ready);
                end
            end
        end
    end

    generate
        if (!SIM_USE_IP) begin : gen_acc_behavior
            integer sim_idx;
            integer lane_idx;
            real y_real_mem [0:DEPTH-1];
            real acc_value_real;
            wire unused_preview_inputs;

            assign acc_ready = 1'b1;
            assign acc_idle = 1'b1;
            assign unused_preview_inputs = &{1'b0, batch_fire, preview_valid_all, preview_y_local_addr_all};

            initial begin
                for (sim_idx = 0; sim_idx < DEPTH; sim_idx = sim_idx + 1) begin
                    y_real_mem[sim_idx] = 0.0;
                end
            end

            always @(posedge clk) begin
                if (mode == 2'b01) begin
                    if (ls_en) begin
                        for (lane_idx = 0; lane_idx < PARALLELISM; lane_idx = lane_idx + 1) begin
                            if (((ls_addr * PARALLELISM) + lane_idx) < DEPTH) begin
                                y_real_mem[(ls_addr * PARALLELISM) + lane_idx] =
                                    $bitstoreal(load_data[lane_idx*DATA_WIDTH +: DATA_WIDTH]);
                            end
                        end
                    end
                end else if (mode == 2'b10) begin
                    for (lane_idx = 0; lane_idx < UPDATE_CHANNELS; lane_idx = lane_idx + 1) begin
                        if (merged_pp_valid[lane_idx] && (merged_pp_addr[lane_idx] < DEPTH)) begin
                            acc_value_real = y_real_mem[merged_pp_addr[lane_idx]] +
                                             $bitstoreal(merged_pp_data[lane_idx]);
                            y_real_mem[merged_pp_addr[lane_idx]] = acc_value_real;
                        end
                    end
                end else if (mode == 2'b11) begin
                    if (ls_en) begin
                        for (lane_idx = 0; lane_idx < PARALLELISM; lane_idx = lane_idx + 1) begin
                            if (((ls_addr * PARALLELISM) + lane_idx) < DEPTH) begin
                                r_store_data[lane_idx*DATA_WIDTH +: DATA_WIDTH] <=
                                    $realtobits(y_real_mem[(ls_addr * PARALLELISM) + lane_idx]);
                            end else begin
                                r_store_data[lane_idx*DATA_WIDTH +: DATA_WIDTH] <=
                                    {DATA_WIDTH{1'b0}};
                            end
                        end
                    end
                end
            end
        end else begin : gen_acc_ip_sim
            wire [PARALLELISM-1:0] acc_ready_vec;
            wire [PARALLELISM-1:0] acc_idle_vec;
            assign acc_ready = &acc_ready_vec;
            assign acc_idle = &acc_idle_vec;

            genvar bank_idx;
            for (bank_idx = 0; bank_idx < PARALLELISM; bank_idx = bank_idx + 1) begin : gen_y_bank
                (* ram_style = "distributed" *) reg [DATA_WIDTH-1:0] bank_ram [0:BANK_DEPTH-1];
                reg bank_valid_pipe [0:ADD_LATENCY-1];
                reg [BANK_ADDR_WIDTH-1:0] bank_addr_pipe [0:ADD_LATENCY-1];
                reg [QUEUE_COUNT_WIDTH-1:0] bank_q_count;
                reg [QUEUE_COUNT_WIDTH-1:0] bank_reserved_count;
                reg [QUEUE_PTR_WIDTH-1:0] bank_q_head;
                reg [QUEUE_PTR_WIDTH-1:0] bank_q_tail;
                reg bank_q_valid [0:QUEUE_DEPTH-1];
                reg [BANK_ADDR_WIDTH-1:0] bank_q_addr [0:QUEUE_DEPTH-1];
                reg [DATA_WIDTH-1:0] bank_q_data [0:QUEUE_DEPTH-1];

                integer init_idx;
                integer pipe_idx;
                integer hit_idx;
                integer enqueue_idx;
                integer bank_hit_count;
                integer preview_bank_hit_count;
                integer queue_space;
                integer issue_release_credit;

                reg bank_issue_fire;
                reg bank_head_conflict;
                reg [BANK_ADDR_WIDTH-1:0] bank_issue_addr;
                reg [DATA_WIDTH-1:0] bank_issue_data;
                reg [QUEUE_PTR_WIDTH-1:0] bank_issue_slot;
                reg bank_ready;
                reg bank_idle;
                reg bank_window_has_candidate;
                reg [QUEUE_PTR_WIDTH-1:0] q_head_next;
                reg [QUEUE_PTR_WIDTH-1:0] q_tail_next;
                reg [QUEUE_COUNT_WIDTH-1:0] q_count_next;
                reg [QUEUE_COUNT_WIDTH-1:0] q_reserved_next;
                reg [QUEUE_PTR_WIDTH-1:0] enq_ptr;
                integer issue_sel_idx;
                integer shift_idx;
                integer issue_limit;
                integer stat_ready_block_count;
                integer stat_ready_block_deficit_sum;
                integer stat_preview_reject_count;
                integer stat_queue_high_watermark;
                integer stat_reserved_high_watermark;
                integer stat_issue_fire_count;
                integer stat_issue_head_pick_count;
                integer stat_issue_bypass_pick_count;
                integer stat_issue_conflict_block_count;
                reg stat_stall_dumped_local;

                wire [ADDR_WIDTH:0] abs_idx = (ls_addr * PARALLELISM) + bank_idx;
                wire bank_in_range = (abs_idx < DEPTH);
                wire [BANK_ADDR_WIDTH-1:0] bank_ls_addr = ls_addr[BANK_ADDR_WIDTH-1:0];
                wire [DATA_WIDTH-1:0] bank_old_data;
                wire [DATA_WIDTH-1:0] bank_new_data;
                wire [4:0] bank_status;
                wire bank_result_valid;
                wire unused_status;

                assign acc_ready_vec[bank_idx] = bank_ready;
                assign acc_idle_vec[bank_idx] = bank_idle;

                always @(*) begin
                    bank_hit_count = merged_pp_bank_hit_count[bank_idx];
                    preview_bank_hit_count = merged_preview_bank_hit_count[bank_idx];

                    bank_issue_fire = 1'b0;
                    bank_head_conflict = 1'b0;
                    bank_issue_slot = {QUEUE_PTR_WIDTH{1'b0}};
                    bank_issue_addr = bank_q_addr[0];
                    bank_issue_data = bank_q_data[0];
                    bank_window_has_candidate = 1'b0;

                    if (mode == 2'b10) begin
                        issue_limit = 0;
                        if (bank_q_count != 0) begin
                            if (ENABLE_LIMITED_BYPASS) begin
                                issue_limit = (bank_q_count < LIMITED_BYPASS_WINDOW) ? bank_q_count : LIMITED_BYPASS_WINDOW;
                            end else begin
                                issue_limit = 1;
                            end
                        end

                        for (issue_sel_idx = 0; issue_sel_idx < issue_limit; issue_sel_idx = issue_sel_idx + 1) begin
                            bank_head_conflict = 1'b0;
                            if (bank_q_valid[issue_sel_idx]) begin
                                bank_window_has_candidate = 1'b1;
                                for (pipe_idx = 0; pipe_idx < ADD_LATENCY; pipe_idx = pipe_idx + 1) begin
                                    if (bank_valid_pipe[pipe_idx] && (bank_addr_pipe[pipe_idx] == bank_q_addr[issue_sel_idx])) begin
                                        bank_head_conflict = 1'b1;
                                    end
                                end
                                if (!bank_issue_fire && !bank_head_conflict) begin
                                    bank_issue_fire = 1'b1;
                                    bank_issue_slot = issue_sel_idx[QUEUE_PTR_WIDTH-1:0];
                                    bank_issue_addr = bank_q_addr[issue_sel_idx];
                                    bank_issue_data = bank_q_data[issue_sel_idx];
                                end
                            end
                        end
                    end

                    issue_release_credit = ((mode == 2'b10) && bank_issue_fire) ? 1 : 0;
                    if (ENABLE_PREVIEW_RESERVE) begin
                        queue_space = QUEUE_DEPTH - bank_q_count - bank_reserved_count + issue_release_credit;
                        bank_ready = (queue_space >= preview_bank_hit_count);
                        bank_idle = (bank_q_count == 0) && (bank_reserved_count == 0);
                    end else begin
                        queue_space = QUEUE_DEPTH - bank_q_count + issue_release_credit;
                        bank_ready = (queue_space >= bank_hit_count);
                        bank_idle = (bank_q_count == 0);
                    end
                    for (pipe_idx = 0; pipe_idx < ADD_LATENCY; pipe_idx = pipe_idx + 1) begin
                        if (bank_valid_pipe[pipe_idx]) begin
                            bank_idle = 1'b0;
                        end
                    end
                end

                assign bank_old_data = bank_ram[bank_issue_addr];
                assign unused_status = &{1'b0, bank_status};

                fp64_add_xilinx_wrapper #(
                    .LATENCY(ADD_LATENCY)
                ) u_bank_add (
                    .clk(clk),
                    .s_valid(bank_issue_fire),
                    .s_ready(),
                    .s_a_bits(bank_old_data),
                    .s_b_bits(bank_issue_data),
                    .m_valid(bank_result_valid),
                    .m_ready(1'b1),
                    .m_result_bits(bank_new_data),
                    .m_status(bank_status)
                );

                initial begin
                    for (init_idx = 0; init_idx < ADD_LATENCY; init_idx = init_idx + 1) begin
                        bank_valid_pipe[init_idx] = 1'b0;
                        bank_addr_pipe[init_idx] = {BANK_ADDR_WIDTH{1'b0}};
                    end
                    bank_q_count = {QUEUE_COUNT_WIDTH{1'b0}};
                    bank_reserved_count = {QUEUE_COUNT_WIDTH{1'b0}};
                    bank_q_head = {QUEUE_PTR_WIDTH{1'b0}};
                    bank_q_tail = {QUEUE_PTR_WIDTH{1'b0}};
                    stat_ready_block_count = 0;
                    stat_ready_block_deficit_sum = 0;
                    stat_preview_reject_count = 0;
                    stat_queue_high_watermark = 0;
                    stat_reserved_high_watermark = 0;
                    stat_issue_fire_count = 0;
                    stat_issue_head_pick_count = 0;
                    stat_issue_bypass_pick_count = 0;
                    stat_issue_conflict_block_count = 0;
                    stat_stall_dumped_local = 1'b0;
                    for (init_idx = 0; init_idx < QUEUE_DEPTH; init_idx = init_idx + 1) begin
                        bank_q_valid[init_idx] = 1'b0;
                        bank_q_addr[init_idx] = {BANK_ADDR_WIDTH{1'b0}};
                        bank_q_data[init_idx] = {DATA_WIDTH{1'b0}};
                    end
                end

                always @(posedge clk) begin
                    if ((mode == 2'b01) && ls_en && bank_in_range && (ls_addr < BANK_DEPTH)) begin
                        bank_ram[bank_ls_addr] <= load_data[bank_idx*DATA_WIDTH +: DATA_WIDTH];
                    end

                    if ((mode == 2'b11) && ls_en) begin
                        if (bank_in_range && (ls_addr < BANK_DEPTH)) begin
                            r_store_data[bank_idx*DATA_WIDTH +: DATA_WIDTH] <= bank_ram[bank_ls_addr];
                        end else begin
                            r_store_data[bank_idx*DATA_WIDTH +: DATA_WIDTH] <= {DATA_WIDTH{1'b0}};
                        end
                    end

                    if (mode != 2'b10) begin
                        bank_q_count <= {QUEUE_COUNT_WIDTH{1'b0}};
                        bank_reserved_count <= {QUEUE_COUNT_WIDTH{1'b0}};
                        bank_q_head <= {QUEUE_PTR_WIDTH{1'b0}};
                        bank_q_tail <= {QUEUE_PTR_WIDTH{1'b0}};
                        for (pipe_idx = 0; pipe_idx < ADD_LATENCY; pipe_idx = pipe_idx + 1) begin
                            bank_valid_pipe[pipe_idx] <= 1'b0;
                            bank_addr_pipe[pipe_idx] <= {BANK_ADDR_WIDTH{1'b0}};
                        end
                        for (pipe_idx = 0; pipe_idx < QUEUE_DEPTH; pipe_idx = pipe_idx + 1) begin
                            bank_q_valid[pipe_idx] <= 1'b0;
                            bank_q_addr[pipe_idx] <= {BANK_ADDR_WIDTH{1'b0}};
                            bank_q_data[pipe_idx] <= {DATA_WIDTH{1'b0}};
                        end
                    end else begin
                        q_head_next = bank_q_head;
                        q_tail_next = bank_q_tail;
                        q_count_next = bank_q_count;
                        q_reserved_next = bank_reserved_count;

                        if (ENABLE_PREVIEW_RESERVE && batch_fire && acc_ready) begin
                            q_reserved_next = q_reserved_next + preview_bank_hit_count[QUEUE_COUNT_WIDTH-1:0];
                        end

                        for (pipe_idx = ADD_LATENCY-1; pipe_idx > 0; pipe_idx = pipe_idx - 1) begin
                            bank_valid_pipe[pipe_idx] <= bank_valid_pipe[pipe_idx-1];
                            bank_addr_pipe[pipe_idx] <= bank_addr_pipe[pipe_idx-1];
                        end
                        bank_valid_pipe[0] <= bank_issue_fire;
                        bank_addr_pipe[0] <= bank_issue_fire ? bank_issue_addr : {BANK_ADDR_WIDTH{1'b0}};

                        if (bank_issue_fire) begin
                            for (shift_idx = 0; shift_idx < QUEUE_DEPTH-1; shift_idx = shift_idx + 1) begin
                                if (shift_idx >= bank_issue_slot) begin
                                    if (shift_idx < (bank_q_count - 1)) begin
                                        bank_q_valid[shift_idx] <= bank_q_valid[shift_idx+1];
                                        bank_q_addr[shift_idx] <= bank_q_addr[shift_idx+1];
                                        bank_q_data[shift_idx] <= bank_q_data[shift_idx+1];
                                    end else if (shift_idx == (bank_q_count - 1)) begin
                                        bank_q_valid[shift_idx] <= 1'b0;
                                        bank_q_addr[shift_idx] <= {BANK_ADDR_WIDTH{1'b0}};
                                        bank_q_data[shift_idx] <= {DATA_WIDTH{1'b0}};
                                    end
                                end
                            end
                            q_count_next = q_count_next - 1'b1;
                        end

                        if (merged_enqueue_fire && (!ENABLE_PREVIEW_RESERVE ? acc_ready_vec[bank_idx] : 1'b1)) begin
                            enq_ptr = q_count_next[QUEUE_PTR_WIDTH-1:0];
                            for (enqueue_idx = 0; enqueue_idx < UPDATE_CHANNELS; enqueue_idx = enqueue_idx + 1) begin
                                if (merged_pp_valid[enqueue_idx] &&
                                    (merged_pp_bank[enqueue_idx] == bank_idx[BANK_SEL_WIDTH-1:0])) begin
                                    bank_q_valid[enq_ptr] <= 1'b1;
                                    bank_q_addr[enq_ptr] <= merged_pp_bank_addr[enqueue_idx];
                                    bank_q_data[enq_ptr] <= merged_pp_data[enqueue_idx];
                                    enq_ptr = enq_ptr + 1'b1;
                                    q_count_next = q_count_next + 1'b1;
                                end
                            end
                            if (ENABLE_PREVIEW_RESERVE) begin
                                q_reserved_next = q_reserved_next - bank_hit_count[QUEUE_COUNT_WIDTH-1:0];
                            end
                        end

                        bank_q_head <= {QUEUE_PTR_WIDTH{1'b0}};
                        bank_q_tail <= q_count_next[QUEUE_PTR_WIDTH-1:0];
                        bank_q_count <= q_count_next;
                        bank_reserved_count <= q_reserved_next;

                        if (q_count_next > stat_queue_high_watermark) begin
                            stat_queue_high_watermark <= q_count_next;
                        end
                        if (q_reserved_next > stat_reserved_high_watermark) begin
                            stat_reserved_high_watermark <= q_reserved_next;
                        end
                        if ((preview_bank_hit_count != 0) && !batch_fire) begin
                            stat_preview_reject_count <= stat_preview_reject_count + 1;
                        end
                        if ((|preview_valid_all) && !bank_ready && (preview_bank_hit_count != 0)) begin
                            stat_ready_block_count <= stat_ready_block_count + 1;
                            if (preview_bank_hit_count > queue_space) begin
                                stat_ready_block_deficit_sum <= stat_ready_block_deficit_sum + (preview_bank_hit_count - queue_space);
                            end
                        end
                        if (bank_issue_fire) begin
                            stat_issue_fire_count <= stat_issue_fire_count + 1;
                            if (bank_issue_slot == {QUEUE_PTR_WIDTH{1'b0}}) begin
                                stat_issue_head_pick_count <= stat_issue_head_pick_count + 1;
                            end else begin
                                stat_issue_bypass_pick_count <= stat_issue_bypass_pick_count + 1;
                            end
                        end else if ((bank_q_count != 0) && bank_window_has_candidate) begin
                            stat_issue_conflict_block_count <= stat_issue_conflict_block_count + 1;
                        end

                        if (bank_result_valid) begin
                            bank_ram[bank_addr_pipe[ADD_LATENCY-1]] <= bank_new_data;
                        end
                    end

                    if ((mode == 2'b11) && ls_en && !stat_stall_dumped_local) begin
                        $display("STALL_STATS bank=%0d queue_high=%0d reserved_high=%0d preview_reject=%0d ready_block=%0d deficit_sum=%0d issue_fire=%0d issue_head=%0d issue_bypass=%0d issue_conflict_block=%0d",
                                 bank_idx,
                                 stat_queue_high_watermark,
                                 stat_reserved_high_watermark,
                                 stat_preview_reject_count,
                                 stat_ready_block_count,
                                 stat_ready_block_deficit_sum,
                                 stat_issue_fire_count,
                                 stat_issue_head_pick_count,
                                 stat_issue_bypass_pick_count,
                                 stat_issue_conflict_block_count);
                        stat_stall_dumped_local <= 1'b1;
                    end else if (mode != 2'b11) begin
                        stat_stall_dumped_local <= 1'b0;
                    end
                end
            end
        end
    endgenerate
`else
    wire [PARALLELISM-1:0] acc_ready_vec;
    wire [PARALLELISM-1:0] acc_idle_vec;
    assign acc_ready = &acc_ready_vec;
    assign acc_idle = &acc_idle_vec;

    genvar bank_idx;
    generate
        for (bank_idx = 0; bank_idx < PARALLELISM; bank_idx = bank_idx + 1) begin : gen_y_bank
            (* ram_style = "distributed" *) reg [DATA_WIDTH-1:0] bank_ram [0:BANK_DEPTH-1];
            reg bank_valid_pipe [0:ADD_LATENCY-1];
            reg [BANK_ADDR_WIDTH-1:0] bank_addr_pipe [0:ADD_LATENCY-1];
            reg [QUEUE_COUNT_WIDTH-1:0] bank_q_count;
            reg [QUEUE_PTR_WIDTH-1:0] bank_q_head;
            reg [QUEUE_PTR_WIDTH-1:0] bank_q_tail;
            reg bank_q_valid [0:QUEUE_DEPTH-1];
            reg [BANK_ADDR_WIDTH-1:0] bank_q_addr [0:QUEUE_DEPTH-1];
            reg [DATA_WIDTH-1:0] bank_q_data [0:QUEUE_DEPTH-1];

            integer init_idx;
            integer pipe_idx;
            integer hit_idx;
            integer enqueue_idx;
            integer bank_hit_count;
            integer queue_space;
            integer issue_release_credit;

            reg bank_issue_fire;
            reg bank_head_conflict;
            reg [BANK_ADDR_WIDTH-1:0] bank_issue_addr;
            reg [DATA_WIDTH-1:0] bank_issue_data;
            reg [QUEUE_PTR_WIDTH-1:0] bank_issue_slot;
            reg bank_ready;
            reg bank_idle;
            reg [QUEUE_PTR_WIDTH-1:0] q_head_next;
            reg [QUEUE_PTR_WIDTH-1:0] q_tail_next;
            reg [QUEUE_COUNT_WIDTH-1:0] q_count_next;
            reg [QUEUE_PTR_WIDTH-1:0] enq_ptr;
            integer issue_sel_idx;
            integer shift_idx;
            integer issue_limit;

            wire [ADDR_WIDTH:0] abs_idx = (ls_addr * PARALLELISM) + bank_idx;
            wire bank_in_range = (abs_idx < DEPTH);
            wire [BANK_ADDR_WIDTH-1:0] bank_ls_addr = ls_addr[BANK_ADDR_WIDTH-1:0];
            wire [DATA_WIDTH-1:0] bank_old_data;
            wire [DATA_WIDTH-1:0] bank_new_data;
            wire [4:0] bank_status;
            wire bank_result_valid;
            wire unused_status;

                assign acc_ready_vec[bank_idx] = bank_ready;
                assign acc_idle_vec[bank_idx] = bank_idle;

                always @(*) begin
                    bank_hit_count = 0;
                    for (hit_idx = 0; hit_idx < UPDATE_CHANNELS; hit_idx = hit_idx + 1) begin
                        if (pp_valid_all[hit_idx] &&
                            (addr[hit_idx] < DEPTH) &&
                            (bank_sel[hit_idx] == bank_idx[BANK_SEL_WIDTH-1:0])) begin
                            bank_hit_count = bank_hit_count + 1;
                        end
                    end

                    bank_issue_fire = 1'b0;
                    bank_head_conflict = 1'b0;
                    bank_issue_slot = {QUEUE_PTR_WIDTH{1'b0}};
                    bank_issue_addr = bank_q_addr[0];
                    bank_issue_data = bank_q_data[0];

                    if (mode == 2'b10) begin
                        issue_limit = 0;
                        if (bank_q_count != 0) begin
                            if (ENABLE_LIMITED_BYPASS) begin
                                issue_limit = (bank_q_count < LIMITED_BYPASS_WINDOW) ? bank_q_count : LIMITED_BYPASS_WINDOW;
                            end else begin
                                issue_limit = 1;
                            end
                        end

                        for (issue_sel_idx = 0; issue_sel_idx < QUEUE_DEPTH; issue_sel_idx = issue_sel_idx + 1) begin
                            bank_head_conflict = 1'b0;
                            if ((issue_sel_idx < issue_limit) && bank_q_valid[issue_sel_idx]) begin
                                for (pipe_idx = 0; pipe_idx < ADD_LATENCY; pipe_idx = pipe_idx + 1) begin
                                    if (bank_valid_pipe[pipe_idx] && (bank_addr_pipe[pipe_idx] == bank_q_addr[issue_sel_idx])) begin
                                        bank_head_conflict = 1'b1;
                                    end
                                end
                                if (!bank_issue_fire && !bank_head_conflict) begin
                                    bank_issue_fire = 1'b1;
                                    bank_issue_slot = issue_sel_idx[QUEUE_PTR_WIDTH-1:0];
                                    bank_issue_addr = bank_q_addr[issue_sel_idx];
                                    bank_issue_data = bank_q_data[issue_sel_idx];
                                end
                            end
                        end
                    end

                    issue_release_credit = ((mode == 2'b10) && bank_issue_fire) ? 1 : 0;
                    queue_space = QUEUE_DEPTH - bank_q_count + issue_release_credit;
                    bank_ready = (queue_space >= bank_hit_count);
                    bank_idle = (bank_q_count == 0);
                    for (pipe_idx = 0; pipe_idx < ADD_LATENCY; pipe_idx = pipe_idx + 1) begin
                        if (bank_valid_pipe[pipe_idx]) begin
                            bank_idle = 1'b0;
                        end
                    end
                end

            assign bank_old_data = bank_ram[bank_issue_addr];
            assign unused_status = &{1'b0, bank_status};

            fp64_add_xilinx_wrapper #(
                .LATENCY(ADD_LATENCY)
            ) u_bank_add (
                .clk(clk),
                .s_valid(bank_issue_fire),
                .s_ready(),
                .s_a_bits(bank_old_data),
                .s_b_bits(bank_issue_data),
                .m_valid(bank_result_valid),
                .m_ready(1'b1),
                .m_result_bits(bank_new_data),
                .m_status(bank_status)
            );

            initial begin
                for (init_idx = 0; init_idx < ADD_LATENCY; init_idx = init_idx + 1) begin
                    bank_valid_pipe[init_idx] = 1'b0;
                    bank_addr_pipe[init_idx] = {BANK_ADDR_WIDTH{1'b0}};
                end
                bank_q_count = {QUEUE_COUNT_WIDTH{1'b0}};
                bank_q_head = {QUEUE_PTR_WIDTH{1'b0}};
                bank_q_tail = {QUEUE_PTR_WIDTH{1'b0}};
                for (init_idx = 0; init_idx < QUEUE_DEPTH; init_idx = init_idx + 1) begin
                    bank_q_valid[init_idx] = 1'b0;
                    bank_q_addr[init_idx] = {BANK_ADDR_WIDTH{1'b0}};
                    bank_q_data[init_idx] = {DATA_WIDTH{1'b0}};
                end
            end

            always @(posedge clk) begin
                if ((mode == 2'b01) && ls_en && bank_in_range && (ls_addr < BANK_DEPTH)) begin
                    bank_ram[bank_ls_addr] <= load_data[bank_idx*DATA_WIDTH +: DATA_WIDTH];
                end

                if ((mode == 2'b11) && ls_en) begin
                    if (bank_in_range && (ls_addr < BANK_DEPTH)) begin
                        r_store_data[bank_idx*DATA_WIDTH +: DATA_WIDTH] <= bank_ram[bank_ls_addr];
                    end else begin
                        r_store_data[bank_idx*DATA_WIDTH +: DATA_WIDTH] <= {DATA_WIDTH{1'b0}};
                    end
                end

                if (mode != 2'b10) begin
                    bank_q_count <= {QUEUE_COUNT_WIDTH{1'b0}};
                    bank_q_head <= {QUEUE_PTR_WIDTH{1'b0}};
                    bank_q_tail <= {QUEUE_PTR_WIDTH{1'b0}};
                    for (pipe_idx = 0; pipe_idx < ADD_LATENCY; pipe_idx = pipe_idx + 1) begin
                        bank_valid_pipe[pipe_idx] <= 1'b0;
                        bank_addr_pipe[pipe_idx] <= {BANK_ADDR_WIDTH{1'b0}};
                    end
                    for (pipe_idx = 0; pipe_idx < QUEUE_DEPTH; pipe_idx = pipe_idx + 1) begin
                        bank_q_valid[pipe_idx] <= 1'b0;
                        bank_q_addr[pipe_idx] <= {BANK_ADDR_WIDTH{1'b0}};
                        bank_q_data[pipe_idx] <= {DATA_WIDTH{1'b0}};
                    end
                end else begin
                    q_head_next = bank_q_head;
                    q_tail_next = bank_q_tail;
                    q_count_next = bank_q_count;

                    for (pipe_idx = ADD_LATENCY-1; pipe_idx > 0; pipe_idx = pipe_idx - 1) begin
                        bank_valid_pipe[pipe_idx] <= bank_valid_pipe[pipe_idx-1];
                        bank_addr_pipe[pipe_idx] <= bank_addr_pipe[pipe_idx-1];
                    end
                    bank_valid_pipe[0] <= bank_issue_fire;
                    bank_addr_pipe[0] <= bank_issue_fire ? bank_issue_addr : {BANK_ADDR_WIDTH{1'b0}};

                    if (bank_issue_fire) begin
                        for (shift_idx = 0; shift_idx < QUEUE_DEPTH-1; shift_idx = shift_idx + 1) begin
                            if (shift_idx >= bank_issue_slot) begin
                                if (shift_idx < (bank_q_count - 1)) begin
                                    bank_q_valid[shift_idx] <= bank_q_valid[shift_idx+1];
                                    bank_q_addr[shift_idx] <= bank_q_addr[shift_idx+1];
                                    bank_q_data[shift_idx] <= bank_q_data[shift_idx+1];
                                end else if (shift_idx == (bank_q_count - 1)) begin
                                    bank_q_valid[shift_idx] <= 1'b0;
                                    bank_q_addr[shift_idx] <= {BANK_ADDR_WIDTH{1'b0}};
                                    bank_q_data[shift_idx] <= {DATA_WIDTH{1'b0}};
                                end
                            end
                        end
                        q_count_next = q_count_next - 1'b1;
                    end

                    if (enqueue_fire && acc_ready_vec[bank_idx]) begin
                        enq_ptr = q_count_next[QUEUE_PTR_WIDTH-1:0];
                        for (enqueue_idx = 0; enqueue_idx < UPDATE_CHANNELS; enqueue_idx = enqueue_idx + 1) begin
                            if (pp_valid_all[enqueue_idx] &&
                                (addr[enqueue_idx] < DEPTH) &&
                                (bank_sel[enqueue_idx] == bank_idx[BANK_SEL_WIDTH-1:0])) begin
                                bank_q_valid[enq_ptr] <= 1'b1;
                                bank_q_addr[enq_ptr] <= bank_addr[enqueue_idx];
                                bank_q_data[enq_ptr] <= pp[enqueue_idx];
                                enq_ptr = enq_ptr + 1'b1;
                                q_count_next = q_count_next + 1'b1;
                            end
                        end
                    end

                    bank_q_head <= {QUEUE_PTR_WIDTH{1'b0}};
                    bank_q_tail <= q_count_next[QUEUE_PTR_WIDTH-1:0];
                    bank_q_count <= q_count_next;

                    if (bank_result_valid) begin
                        bank_ram[bank_addr_pipe[ADD_LATENCY-1]] <= bank_new_data;
                    end
                end
            end
        end
    endgenerate
`endif

endmodule

