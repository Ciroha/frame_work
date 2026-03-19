`timescale 1ns / 1ps

module tb_fp64_mul_lane;

    localparam int LATENCY = 8;
    localparam [4:0] STATUS_OK        = 5'b00000;
    localparam [4:0] STATUS_INVALID   = 5'b10000;
    localparam [4:0] STATUS_OVERFLOW  = 5'b01010; // overflow + inexact
    localparam [4:0] STATUS_UNDERFLOW = 5'b00110; // underflow + inexact
    localparam [4:0] STATUS_INEXACT   = 5'b00010;
    localparam [63:0] CANONICAL_QNAN  = 64'h7ff8_0000_0000_0000;

    logic        clk;
    logic        s_valid;
    wire         s_ready;
    logic [63:0] s_a_bits;
    logic [63:0] s_b_bits;
    wire         m_valid;
    logic        m_ready;
    wire [63:0]  m_result_bits;
    wire [4:0]   m_status;

    string       exp_name_q[$];
    logic [63:0] exp_result_q[$];
    logic [4:0]  exp_status_q[$];
    int          sent_cases;
    int          recv_cases;
    int          error_count;

    fp64_mul_xilinx_wrapper #(
        .LATENCY(LATENCY)
    ) dut (
        .clk(clk),
        .s_valid(s_valid),
        .s_ready(s_ready),
        .s_a_bits(s_a_bits),
        .s_b_bits(s_b_bits),
        .m_valid(m_valid),
        .m_ready(m_ready),
        .m_result_bits(m_result_bits),
        .m_status(m_status)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (m_valid === 1'b1) begin
            string name;
            logic [63:0] exp_result;
            if (exp_name_q.size() == 0) begin
                $error("Unexpected output without queued expectation: result=%h status=%b",
                       m_result_bits, m_status);
                error_count++;
            end else begin
                name       = exp_name_q.pop_front();
                exp_result = exp_result_q.pop_front();
                void'(exp_status_q.pop_front());

                if (m_result_bits !== exp_result) begin
                    $error("[%s] result mismatch: exp=%h got=%h",
                           name, exp_result, m_result_bits);
                    error_count++;
                end
                if ($isunknown(m_status)) begin
                    $error("[%s] status contains X/Z: got=%b",
                           name, m_status);
                    error_count++;
                end
            end

            recv_cases++;
        end
    end

    task automatic queue_case(
        input string case_name,
        input logic [63:0] a_bits,
        input logic [63:0] b_bits,
        input logic [63:0] exp_bits,
        input logic [4:0]  exp_status
    );
        begin
            exp_name_q.push_back(case_name);
            exp_result_q.push_back(exp_bits);
            exp_status_q.push_back(exp_status);

            @(negedge clk);
            s_valid  <= 1'b1;
            s_a_bits <= a_bits;
            s_b_bits <= b_bits;
            sent_cases++;
        end
    endtask

    initial begin
        clk        = 1'b0;
        s_valid    = 1'b0;
        s_a_bits   = 64'd0;
        s_b_bits   = 64'd0;
        m_ready    = 1'b1;
        sent_cases = 0;
        recv_cases = 0;
        error_count = 0;

        if (s_ready !== 1'b1) begin
            $error("s_ready should be tied high in v1.");
            error_count++;
        end

        // Flush unknown valid pipeline state since this module has no reset.
        repeat (LATENCY + 2) @(posedge clk);

        queue_case("normal_2x3",
                   64'h4000_0000_0000_0000,
                   64'h4008_0000_0000_0000,
                   64'h4018_0000_0000_0000,
                   STATUS_OK);

        queue_case("signed_zero",
                   64'h0000_0000_0000_0000,
                   64'hc000_0000_0000_0000,
                   64'h8000_0000_0000_0000,
                   STATUS_OK);

        queue_case("inf_times_negative_two",
                   64'h7ff0_0000_0000_0000,
                   64'hc000_0000_0000_0000,
                   64'hfff0_0000_0000_0000,
                   STATUS_OK);

        queue_case("inf_times_zero_invalid",
                   64'h7ff0_0000_0000_0000,
                   64'h0000_0000_0000_0000,
                   CANONICAL_QNAN,
                   STATUS_INVALID);

        queue_case("qnan_propagation",
                   64'h7ff8_0000_0000_0001,
                   64'h3ff0_0000_0000_0000,
                   CANONICAL_QNAN,
                   STATUS_OK);

        queue_case("min_subnormal_pass_through",
                   64'h0000_0000_0000_0001,
                   64'h3ff0_0000_0000_0000,
                   64'h0000_0000_0000_0001,
                   STATUS_OK);

        queue_case("min_normal_to_exact_subnormal",
                   64'h0010_0000_0000_0000,
                   64'h3fe0_0000_0000_0000,
                   64'h0008_0000_0000_0000,
                   STATUS_OK);

        // Exact halfway case between 1 ulp and 2 ulp of the subnormal range.
        // Round-to-nearest-even should choose 0x2.
        queue_case("tie_to_even_subnormal",
                   64'h0000_0000_0000_0001,
                   64'h3ff8_0000_0000_0000,
                   64'h0000_0000_0000_0002,
                   STATUS_UNDERFLOW);

        // Product keeps the rounded mantissa but still drops low-order bits.
        queue_case("rounding_inexact",
                   64'h3ff0_0000_0000_0001,
                   64'h3ff0_0000_0000_0001,
                   64'h3ff0_0000_0000_0002,
                   STATUS_INEXACT);

        queue_case("overflow_to_inf",
                   64'h7fef_ffff_ffff_ffff,
                   64'h4000_0000_0000_0000,
                   64'h7ff0_0000_0000_0000,
                   STATUS_OVERFLOW);

        @(negedge clk);
        s_valid  <= 1'b0;
        s_a_bits <= 64'd0;
        s_b_bits <= 64'd0;

        wait (recv_cases == sent_cases);
        repeat (2) @(posedge clk);

        if (exp_name_q.size() != 0) begin
            $error("Expectation queue not empty after simulation. Remaining=%0d", exp_name_q.size());
            error_count++;
        end

        if (error_count == 0) begin
            $display("tb_fp64_mul_lane PASSED: %0d cases checked.", sent_cases);
        end else begin
            $fatal(1, "tb_fp64_mul_lane FAILED with %0d errors.", error_count);
        end

        $finish;
    end

endmodule
