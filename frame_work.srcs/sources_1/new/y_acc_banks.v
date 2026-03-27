`timescale 1ns / 1ps

module y_acc_banks #(
    parameter PARALLELISM = 8,
    parameter DATA_WIDTH  = 64,
    parameter DEPTH       = 128,
    parameter ADDR_WIDTH  = $clog2(DEPTH),
    parameter SIM_USE_IP  = 1'b1,
    parameter ENABLE_PREVIEW_RESERVE = 1'b1
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
    localparam integer QUEUE_DEPTH = 256;
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
                        if (pp_valid_all[lane_idx] && (addr[lane_idx] < DEPTH)) begin
                            acc_value_real = y_real_mem[addr[lane_idx]] +
                                             $bitstoreal(pp[lane_idx]);
                            y_real_mem[addr[lane_idx]] = acc_value_real;
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
                integer preview_hit_idx;
                integer enqueue_idx;
                integer bank_hit_count;
                integer preview_bank_hit_count;
                integer queue_space;

                reg bank_issue_fire;
                reg bank_head_conflict;
                reg [BANK_ADDR_WIDTH-1:0] bank_issue_addr;
                reg [DATA_WIDTH-1:0] bank_issue_data;
                reg bank_ready;
                reg bank_idle;
                reg [QUEUE_PTR_WIDTH-1:0] q_head_next;
                reg [QUEUE_PTR_WIDTH-1:0] q_tail_next;
                reg [QUEUE_COUNT_WIDTH-1:0] q_count_next;
                reg [QUEUE_COUNT_WIDTH-1:0] q_reserved_next;
                reg [QUEUE_PTR_WIDTH-1:0] enq_ptr;

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

                    preview_bank_hit_count = 0;
                    for (preview_hit_idx = 0; preview_hit_idx < UPDATE_CHANNELS; preview_hit_idx = preview_hit_idx + 1) begin
                        if (preview_valid_all[preview_hit_idx] &&
                            (preview_addr[preview_hit_idx] < DEPTH) &&
                            (preview_bank_sel[preview_hit_idx] == bank_idx[BANK_SEL_WIDTH-1:0])) begin
                            preview_bank_hit_count = preview_bank_hit_count + 1;
                        end
                    end

                    if (ENABLE_PREVIEW_RESERVE) begin
                        queue_space = QUEUE_DEPTH - bank_q_count - bank_reserved_count;
                        bank_ready = (queue_space >= preview_bank_hit_count);
                        bank_idle = (bank_q_count == 0) && (bank_reserved_count == 0);
                    end else begin
                        queue_space = QUEUE_DEPTH - bank_q_count;
                        bank_ready = (queue_space >= bank_hit_count);
                        bank_idle = (bank_q_count == 0);
                    end
                    for (pipe_idx = 0; pipe_idx < ADD_LATENCY; pipe_idx = pipe_idx + 1) begin
                        if (bank_valid_pipe[pipe_idx]) begin
                            bank_idle = 1'b0;
                        end
                    end

                    bank_issue_fire = 1'b0;
                    bank_head_conflict = 1'b0;
                    bank_issue_addr = bank_q_addr[bank_q_head];
                    bank_issue_data = bank_q_data[bank_q_head];

                    if ((mode == 2'b10) && (bank_q_count != 0) && bank_q_valid[bank_q_head]) begin
                        for (pipe_idx = 0; pipe_idx < ADD_LATENCY; pipe_idx = pipe_idx + 1) begin
                            if (bank_valid_pipe[pipe_idx] && (bank_addr_pipe[pipe_idx] == bank_q_addr[bank_q_head])) begin
                                bank_head_conflict = 1'b1;
                            end
                        end
                        bank_issue_fire = !bank_head_conflict;
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

                        if (enqueue_fire && (!ENABLE_PREVIEW_RESERVE ? acc_ready_vec[bank_idx] : 1'b1)) begin
                            enq_ptr = bank_q_tail;
                            for (enqueue_idx = 0; enqueue_idx < UPDATE_CHANNELS; enqueue_idx = enqueue_idx + 1) begin
                                if (pp_valid_all[enqueue_idx] &&
                                    (addr[enqueue_idx] < DEPTH) &&
                                    (bank_sel[enqueue_idx] == bank_idx[BANK_SEL_WIDTH-1:0])) begin
                                    bank_q_valid[enq_ptr] <= 1'b1;
                                    bank_q_addr[enq_ptr] <= bank_addr[enqueue_idx];
                                    bank_q_data[enq_ptr] <= pp[enqueue_idx];
                                    if (enq_ptr == QUEUE_DEPTH-1) begin
                                        enq_ptr = {QUEUE_PTR_WIDTH{1'b0}};
                                    end else begin
                                        enq_ptr = enq_ptr + 1'b1;
                                    end
                                    q_count_next = q_count_next + 1'b1;
                                end
                            end
                            q_tail_next = enq_ptr;
                            if (ENABLE_PREVIEW_RESERVE) begin
                                q_reserved_next = q_reserved_next - bank_hit_count[QUEUE_COUNT_WIDTH-1:0];
                            end
                        end

                        for (pipe_idx = ADD_LATENCY-1; pipe_idx > 0; pipe_idx = pipe_idx - 1) begin
                            bank_valid_pipe[pipe_idx] <= bank_valid_pipe[pipe_idx-1];
                            bank_addr_pipe[pipe_idx] <= bank_addr_pipe[pipe_idx-1];
                        end
                        bank_valid_pipe[0] <= bank_issue_fire;
                        bank_addr_pipe[0] <= bank_issue_fire ? bank_issue_addr : {BANK_ADDR_WIDTH{1'b0}};

                        if (bank_issue_fire) begin
                            bank_q_valid[bank_q_head] <= 1'b0;
                            if (q_head_next == QUEUE_DEPTH-1) begin
                                q_head_next = {QUEUE_PTR_WIDTH{1'b0}};
                            end else begin
                                q_head_next = q_head_next + 1'b1;
                            end
                            q_count_next = q_count_next - 1'b1;
                        end

                        bank_q_head <= q_head_next;
                        bank_q_tail <= q_tail_next;
                        bank_q_count <= q_count_next;
                        bank_reserved_count <= q_reserved_next;

                        if (bank_result_valid) begin
                            bank_ram[bank_addr_pipe[ADD_LATENCY-1]] <= bank_new_data;
                        end
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

            reg bank_issue_fire;
            reg bank_head_conflict;
            reg [BANK_ADDR_WIDTH-1:0] bank_issue_addr;
            reg [DATA_WIDTH-1:0] bank_issue_data;
            reg bank_ready;
            reg bank_idle;
            reg [QUEUE_PTR_WIDTH-1:0] q_head_next;
            reg [QUEUE_PTR_WIDTH-1:0] q_tail_next;
            reg [QUEUE_COUNT_WIDTH-1:0] q_count_next;
            reg [QUEUE_PTR_WIDTH-1:0] enq_ptr;

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

                queue_space = QUEUE_DEPTH - bank_q_count;
                bank_ready = (queue_space >= bank_hit_count);
                bank_idle = (bank_q_count == 0);
                for (pipe_idx = 0; pipe_idx < ADD_LATENCY; pipe_idx = pipe_idx + 1) begin
                    if (bank_valid_pipe[pipe_idx]) begin
                        bank_idle = 1'b0;
                    end
                end

                bank_issue_fire = 1'b0;
                bank_head_conflict = 1'b0;
                bank_issue_addr = bank_q_addr[bank_q_head];
                bank_issue_data = bank_q_data[bank_q_head];

                if ((mode == 2'b10) && (bank_q_count != 0) && bank_q_valid[bank_q_head]) begin
                    for (pipe_idx = 0; pipe_idx < ADD_LATENCY; pipe_idx = pipe_idx + 1) begin
                        if (bank_valid_pipe[pipe_idx] && (bank_addr_pipe[pipe_idx] == bank_q_addr[bank_q_head])) begin
                            bank_head_conflict = 1'b1;
                        end
                    end
                    bank_issue_fire = !bank_head_conflict;
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

                    if (enqueue_fire && acc_ready_vec[bank_idx]) begin
                        enq_ptr = bank_q_tail;
                        for (enqueue_idx = 0; enqueue_idx < UPDATE_CHANNELS; enqueue_idx = enqueue_idx + 1) begin
                            if (pp_valid_all[enqueue_idx] &&
                                (addr[enqueue_idx] < DEPTH) &&
                                (bank_sel[enqueue_idx] == bank_idx[BANK_SEL_WIDTH-1:0])) begin
                                bank_q_valid[enq_ptr] <= 1'b1;
                                bank_q_addr[enq_ptr] <= bank_addr[enqueue_idx];
                                bank_q_data[enq_ptr] <= pp[enqueue_idx];
                                if (enq_ptr == QUEUE_DEPTH-1) begin
                                    enq_ptr = {QUEUE_PTR_WIDTH{1'b0}};
                                end else begin
                                    enq_ptr = enq_ptr + 1'b1;
                                end
                                q_count_next = q_count_next + 1'b1;
                            end
                        end
                        q_tail_next = enq_ptr;
                    end

                    for (pipe_idx = ADD_LATENCY-1; pipe_idx > 0; pipe_idx = pipe_idx - 1) begin
                        bank_valid_pipe[pipe_idx] <= bank_valid_pipe[pipe_idx-1];
                        bank_addr_pipe[pipe_idx] <= bank_addr_pipe[pipe_idx-1];
                    end
                    bank_valid_pipe[0] <= bank_issue_fire;
                    bank_addr_pipe[0] <= bank_issue_fire ? bank_issue_addr : {BANK_ADDR_WIDTH{1'b0}};

                    if (bank_issue_fire) begin
                        bank_q_valid[bank_q_head] <= 1'b0;
                        if (q_head_next == QUEUE_DEPTH-1) begin
                            q_head_next = {QUEUE_PTR_WIDTH{1'b0}};
                        end else begin
                            q_head_next = q_head_next + 1'b1;
                        end
                        q_count_next = q_count_next - 1'b1;
                    end

                    bank_q_head <= q_head_next;
                    bank_q_tail <= q_tail_next;
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
