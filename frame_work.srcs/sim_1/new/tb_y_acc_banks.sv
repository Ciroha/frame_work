`timescale 1ns / 1ps

module tb_y_acc_banks #(
    parameter SIM_USE_MUL_IP = 1'b1,
    parameter SIM_USE_ADD_IP = 1'b1
)();

    localparam PARALLELISM = 8;
    localparam DATA_WIDTH  = 64;
    localparam DEPTH       = 32;
    localparam ADDR_WIDTH  = $clog2(DEPTH);

    localparam [63:0] FP64_ZERO  = 64'h0000_0000_0000_0000;
    localparam [63:0] FP64_ONE   = 64'h3FF0_0000_0000_0000;
    localparam [63:0] FP64_TWO   = 64'h4000_0000_0000_0000;
    localparam [63:0] FP64_THREE = 64'h4008_0000_0000_0000;

    reg clk;
    reg [1:0] mode;
    reg ls_en;
    reg [ADDR_WIDTH-1:0] ls_addr;
    reg [PARALLELISM*DATA_WIDTH-1:0] load_data;
    wire [PARALLELISM*DATA_WIDTH-1:0] store_data;
    wire acc_ready;
    wire acc_idle;
    reg batch_fire;
    reg [PARALLELISM*DATA_WIDTH-1:0] partial_products_a;
    reg [PARALLELISM-1:0] pp_valid_a;
    reg [PARALLELISM*ADDR_WIDTH-1:0] y_local_addr_a;
    reg [PARALLELISM*DATA_WIDTH-1:0] partial_products_b;
    reg [PARALLELISM-1:0] pp_valid_b;
    reg [PARALLELISM*ADDR_WIDTH-1:0] y_local_addr_b;

    integer errors;
    wire unused_sim_params;

    assign unused_sim_params = &{1'b0, SIM_USE_MUL_IP, SIM_USE_ADD_IP};

    y_acc_banks #(
        .PARALLELISM(PARALLELISM),
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(DEPTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .QUEUE_DEPTH(2)
    ) dut (
        .clk(clk),
        .mode(mode),
        .ls_en(ls_en),
        .ls_addr(ls_addr),
        .load_data(load_data),
        .store_data(store_data),
        .acc_ready(acc_ready),
        .acc_idle(acc_idle),
        .batch_fire(batch_fire),
        .preview_valid_a(pp_valid_a),
        .preview_y_local_addr_a(y_local_addr_a),
        .preview_valid_b(pp_valid_b),
        .preview_y_local_addr_b(y_local_addr_b),
        .partial_products_a(partial_products_a),
        .pp_valid_a(pp_valid_a),
        .y_local_addr_a(y_local_addr_a),
        .partial_products_b(partial_products_b),
        .pp_valid_b(pp_valid_b),
        .y_local_addr_b(y_local_addr_b)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 1'b0;
        mode = 2'b00;
        ls_en = 1'b0;
        ls_addr = {ADDR_WIDTH{1'b0}};
        load_data = {PARALLELISM*DATA_WIDTH{1'b0}};
        batch_fire = 1'b0;
        partial_products_a = {PARALLELISM*DATA_WIDTH{1'b0}};
        pp_valid_a = {PARALLELISM{1'b0}};
        y_local_addr_a = {PARALLELISM*ADDR_WIDTH{1'b0}};
        partial_products_b = {PARALLELISM*DATA_WIDTH{1'b0}};
        pp_valid_b = {PARALLELISM{1'b0}};
        y_local_addr_b = {PARALLELISM*ADDR_WIDTH{1'b0}};
        errors = 0;

        repeat (4) @(posedge clk);

        clear_memory;
        case_unique_banks;
        clear_memory;
        case_same_bank_same_addr;
        clear_memory;
        case_same_bank_diff_addr;
        clear_memory;
        case_bank_credit_boundary;

        if (errors == 0) begin
            $display("tb_y_acc_banks PASSED");
        end else begin
            $fatal(1, "tb_y_acc_banks FAILED with %0d errors", errors);
        end

        #20;
        $finish;
    end

    task clear_memory;
        integer beat;
        begin
            mode = 2'b01;
            ls_en = 1'b1;
            load_data = {PARALLELISM{FP64_ZERO}};
            for (beat = 0; beat < (DEPTH / PARALLELISM); beat = beat + 1) begin
                ls_addr = beat[ADDR_WIDTH-1:0];
                @(posedge clk);
            end
            ls_en = 1'b0;
            load_data = {PARALLELISM*DATA_WIDTH{1'b0}};
            mode = 2'b00;
            repeat (2) @(posedge clk);
        end
    endtask

    task drive_compute_once;
        input [PARALLELISM*DATA_WIDTH-1:0] in_pp_a;
        input [PARALLELISM-1:0]            in_valid_a;
        input [PARALLELISM*ADDR_WIDTH-1:0] in_addr_a;
        input [PARALLELISM*DATA_WIDTH-1:0] in_pp_b;
        input [PARALLELISM-1:0]            in_valid_b;
        input [PARALLELISM*ADDR_WIDTH-1:0] in_addr_b;
        begin
            mode = 2'b10;
            partial_products_a = in_pp_a;
            pp_valid_a = in_valid_a;
            y_local_addr_a = in_addr_a;
            partial_products_b = in_pp_b;
            pp_valid_b = in_valid_b;
            y_local_addr_b = in_addr_b;
            batch_fire = 1'b1;

            @(posedge clk);
            partial_products_a = {PARALLELISM*DATA_WIDTH{1'b0}};
            pp_valid_a = {PARALLELISM{1'b0}};
            y_local_addr_a = {PARALLELISM*ADDR_WIDTH{1'b0}};
            partial_products_b = {PARALLELISM*DATA_WIDTH{1'b0}};
            pp_valid_b = {PARALLELISM{1'b0}};
            y_local_addr_b = {PARALLELISM*ADDR_WIDTH{1'b0}};
            batch_fire = 1'b0;

            wait (acc_idle);
            @(posedge clk);
            mode = 2'b00;
            @(posedge clk);
        end
    endtask

    task read_store_beat;
        input [ADDR_WIDTH-1:0] beat_addr;
        output [PARALLELISM*DATA_WIDTH-1:0] beat_data;
        begin
            mode = 2'b11;
            ls_en = 1'b1;
            ls_addr = beat_addr;
            @(posedge clk);
            #1;
            beat_data = store_data;
            ls_en = 1'b0;
            mode = 2'b00;
            @(posedge clk);
        end
    endtask

    task expect_word;
        input [63:0] actual;
        input [63:0] expected;
        input [255:0] label;
        begin
            if (actual !== expected) begin
                $error("%0s exp=%h got=%h", label, expected, actual);
                errors = errors + 1;
            end
        end
    endtask

    task case_unique_banks;
        reg [PARALLELISM*DATA_WIDTH-1:0] beat0;
        begin
            $display("CASE unique banks");
            drive_compute_once(
                {FP64_ONE, FP64_ONE, FP64_ONE, FP64_ONE, FP64_ONE, FP64_ONE, FP64_ONE, FP64_ONE},
                8'b1111_1111,
                {5'd7, 5'd6, 5'd5, 5'd4, 5'd3, 5'd2, 5'd1, 5'd0},
                {PARALLELISM*DATA_WIDTH{1'b0}},
                {PARALLELISM{1'b0}},
                {PARALLELISM*ADDR_WIDTH{1'b0}}
            );
            read_store_beat(5'd0, beat0);
            expect_word(beat0[ 63:  0], FP64_ONE, "unique lane0");
            expect_word(beat0[127: 64], FP64_ONE, "unique lane1");
            expect_word(beat0[191:128], FP64_ONE, "unique lane2");
            expect_word(beat0[255:192], FP64_ONE, "unique lane3");
            expect_word(beat0[319:256], FP64_ONE, "unique lane4");
            expect_word(beat0[383:320], FP64_ONE, "unique lane5");
            expect_word(beat0[447:384], FP64_ONE, "unique lane6");
            expect_word(beat0[511:448], FP64_ONE, "unique lane7");
        end
    endtask

    task case_same_bank_same_addr;
        reg [PARALLELISM*DATA_WIDTH-1:0] beat0;
        begin
            $display("CASE same bank same addr");
            drive_compute_once(
                {{7{FP64_ZERO}}, FP64_ONE},
                8'b0000_0001,
                {{7{5'd0}}, 5'd0},
                {{7{FP64_ZERO}}, FP64_TWO},
                8'b0000_0001,
                {{7{5'd0}}, 5'd0}
            );
            read_store_beat(5'd0, beat0);
            expect_word(beat0[ 63:  0], FP64_THREE, "same addr lane0");
            expect_word(beat0[127: 64], FP64_ZERO,  "same addr lane1");
        end
    endtask

    task case_same_bank_diff_addr;
        reg [PARALLELISM*DATA_WIDTH-1:0] beat0;
        reg [PARALLELISM*DATA_WIDTH-1:0] beat1;
        begin
            $display("CASE same bank diff addr");
            drive_compute_once(
                {{6{FP64_ZERO}}, FP64_TWO, FP64_ONE},
                8'b0000_0011,
                {{6{5'd0}}, 5'd8, 5'd0},
                {PARALLELISM*DATA_WIDTH{1'b0}},
                {PARALLELISM{1'b0}},
                {PARALLELISM*ADDR_WIDTH{1'b0}}
            );
            read_store_beat(5'd0, beat0);
            read_store_beat(5'd1, beat1);
            expect_word(beat0[ 63:  0], FP64_ONE, "diff addr beat0 lane0");
            expect_word(beat1[ 63:  0], FP64_TWO, "diff addr beat1 lane0");
        end
    endtask

    task case_bank_credit_boundary;
        reg [PARALLELISM*DATA_WIDTH-1:0] beat0;
        reg [PARALLELISM*DATA_WIDTH-1:0] beat1;
        reg [PARALLELISM*DATA_WIDTH-1:0] beat2;
        begin
            $display("CASE bank credit boundary");
            mode = 2'b10;
            partial_products_a = {FP64_ZERO, FP64_ZERO, FP64_ZERO, FP64_ZERO, FP64_ZERO, FP64_ONE, FP64_ONE, FP64_ONE};
            pp_valid_a = 8'b0000_0111;
            y_local_addr_a = {5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd16, 5'd8, 5'd0};
            partial_products_b = {PARALLELISM*DATA_WIDTH{1'b0}};
            pp_valid_b = {PARALLELISM{1'b0}};
            y_local_addr_b = {PARALLELISM*ADDR_WIDTH{1'b0}};
            batch_fire = 1'b1;

            #1;
            if (acc_ready !== 1'b0) begin
                $error("bank credit boundary acc_ready exp=0 got=%b", acc_ready);
                errors = errors + 1;
            end

            @(posedge clk);
            partial_products_a = {PARALLELISM*DATA_WIDTH{1'b0}};
            pp_valid_a = {PARALLELISM{1'b0}};
            y_local_addr_a = {PARALLELISM*ADDR_WIDTH{1'b0}};
            batch_fire = 1'b0;
            mode = 2'b00;
            @(posedge clk);

            read_store_beat(5'd0, beat0);
            read_store_beat(5'd1, beat1);
            read_store_beat(5'd2, beat2);
            expect_word(beat0[ 63:  0], FP64_ZERO, "credit boundary beat0 lane0");
            expect_word(beat1[ 63:  0], FP64_ZERO, "credit boundary beat1 lane0");
            expect_word(beat2[ 63:  0], FP64_ZERO, "credit boundary beat2 lane0");
        end
    endtask

endmodule
