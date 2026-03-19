`timescale 1ns / 1ps

module fp64_add_xilinx_wrapper #(
    parameter LATENCY = 8
)(
    input  wire        clk,
    input  wire        s_valid,
    output wire        s_ready,
    input  wire [63:0] s_a_bits,
    input  wire [63:0] s_b_bits,
    output wire        m_valid,
    input  wire        m_ready,
    output wire [63:0] m_result_bits,
    output wire [4:0]  m_status
);

    wire ip_a_ready;
    wire ip_b_ready;

    fp64_add_ip u_ip (
        .aclk(clk),
        .s_axis_a_tvalid(s_valid),
        .s_axis_a_tready(ip_a_ready),
        .s_axis_a_tdata(s_a_bits),
        .s_axis_b_tvalid(s_valid),
        .s_axis_b_tready(ip_b_ready),
        .s_axis_b_tdata(s_b_bits),
        .m_axis_result_tvalid(m_valid),
        .m_axis_result_tready(m_ready),
        .m_axis_result_tdata(m_result_bits)
    );

    assign s_ready = ip_a_ready & ip_b_ready;
    assign m_status = 5'b0;

endmodule
