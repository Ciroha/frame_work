`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: simple_sync_fifo
// 功能描述:
//   简单同步FIFO模块
//   使用双端口RAM实现,支持同时读写
//
// 特性:
//   - 同步时钟设计(单时钟域)
//   - 可配置数据宽度和深度
//   - 提供满/空状态信号
//   - 读操作有1周期延迟
//
// 参数:
//   WIDTH - 数据位宽(默认512位)
//   DEPTH - FIFO深度(默认512个元素)
//////////////////////////////////////////////////////////////////////////////////
module simple_sync_fifo #(parameter WIDTH=512, DEPTH=512)(
    input  wire clk,                    // 时钟
    input  wire rst_n,                  // 异步复位(低有效)
    input  wire wen,                    // 写使能
    input  wire ren,                    // 读使能
    input  wire [WIDTH-1:0] din,        // 写入数据
    output reg  [WIDTH-1:0] dout,       // 读出数据(1周期延迟)
    output wire full,                   // 满标志
    output wire empty                   // 空标志
);

    // ========================================================================
    // 内部存储器和指针
    // ========================================================================
    localparam integer ADDR_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
    localparam integer COUNT_WIDTH = $clog2(DEPTH + 1);

    (* ram_style = "block" *) reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [ADDR_WIDTH-1:0] wptr;
    reg [ADDR_WIDTH-1:0] rptr;
    reg [COUNT_WIDTH-1:0] cnt;

    wire write_fire = wen && !full;
    wire read_fire  = ren && !empty;

    wire [ADDR_WIDTH-1:0] wptr_next =
        (wptr == DEPTH-1) ? {ADDR_WIDTH{1'b0}} : (wptr + 1'b1);
    wire [ADDR_WIDTH-1:0] rptr_next =
        (rptr == DEPTH-1) ? {ADDR_WIDTH{1'b0}} : (rptr + 1'b1);

    // ========================================================================
    // 存储器访问
    // ========================================================================
    always @(posedge clk) begin
        if (write_fire) begin
            mem[wptr] <= din;
        end

        if (read_fire) begin
            dout <= mem[rptr];
        end
    end

    // ========================================================================
    // 指针和计数器
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr <= {ADDR_WIDTH{1'b0}};
            rptr <= {ADDR_WIDTH{1'b0}};
            cnt  <= {COUNT_WIDTH{1'b0}};
        end else begin
            if (write_fire) begin
                wptr <= wptr_next;
            end

            if (read_fire) begin
                rptr <= rptr_next;
            end

            case ({write_fire, read_fire})
                2'b10: cnt <= cnt + 1'b1;
                2'b01: cnt <= cnt - 1'b1;
                default: cnt <= cnt;
            endcase
        end
    end

    // ========================================================================
    // 状态信号
    // ========================================================================
    assign full  = (cnt == DEPTH);      // 计数器等于深度时FIFO满
    assign empty = (cnt == 0);          // 计数器等于0时FIFO空

endmodule
