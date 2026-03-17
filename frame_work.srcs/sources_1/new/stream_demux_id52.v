`timescale 1ns / 1ps

// ============================================================================
// Module: stream_demux_id52
// 功能描述:
//   流解复用器 - ID压缩模式(2:5比例)
//   将输入的混合数据流按照2拍ID:5拍元数据的比例分离到两个输出FIFO
//
// 工作原理:
//   状态机在S_ID和S_META之间切换:
//   - S_ID状态: 连续接收2拍ID数据(每拍64个8位ID)写入ID FIFO
//   - S_META状态: 连续接收5拍元数据写入meta FIFO
//
// 数据格式:
//   输入: [ID拍x2][元数据拍x5][ID拍x2][元数据拍x5]...
//   输出: ID FIFO <- ID流, meta FIFO <- 元数据流
//
// 用途:
//   用于MODE_ID52模式,将8位ID通过LUT转换为FP64值,实现数据压缩
// ============================================================================
module stream_demux_id52 #(
    // ========================================================================
    // 参数定义
    // ========================================================================
    parameter AXI_WIDTH = 512,          // AXI数据位宽
    parameter VAL_ID_BATCH = 2,         // ID批大小(2拍,每拍64个8位ID)
    parameter META_BATCH = 5            // 元数据批大小(5拍)
)(
    input  wire clk,
    input  wire rst_n,
    input  wire [AXI_WIDTH-1:0] s_tdata,// 输入数据
    input  wire s_tvalid,               // 输入有效
    output reg  s_tready,               // 输入就绪

    // ID FIFO接口
    output reg  val_wen,                // ID写使能
    output reg  [AXI_WIDTH-1:0] val_din,// ID写入数据
    input  wire val_full,               // ID FIFO满

    // 元数据FIFO接口
    output reg  meta_wen,               // 元数据写使能
    output reg  [AXI_WIDTH-1:0] meta_din,// 元数据写入数据
    input  wire meta_full               // 元数据FIFO满
);

    // ========================================================================
    // 状态机定义
    // ========================================================================
    localparam S_ID = 1'b0, S_META = 1'b1;  // 状态: ID/元数据
    reg state, next_state;              // 当前状态和下一状态
    reg [3:0] cnt;                      // 计数器(最大5)

    // ========================================================================
    // 状态寄存器和计数器
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_ID;
            cnt <= 0;
        end else if (s_tvalid && s_tready) begin
            state <= next_state;
            // 计数器逻辑: 状态结束时复位,否则递增
            if ((state == S_ID && cnt == VAL_ID_BATCH-1) ||
                (state == S_META && cnt == META_BATCH-1)) begin
                cnt <= 0;
            end else begin
                cnt <= cnt + 1'b1;
            end
        end
    end

    // ========================================================================
    // 输出逻辑(组合逻辑)
    // ========================================================================
    always @(*) begin
        next_state = state;
        s_tready = 1'b0;
        val_wen = 1'b0;
        meta_wen = 1'b0;
        val_din = s_tdata;
        meta_din = s_tdata;

        case (state)
            S_ID: begin
                // ID状态: 写入ID FIFO
                s_tready = !val_full;
                if (s_tvalid && !val_full) begin
                    val_wen = 1'b1;
                    if (cnt == VAL_ID_BATCH-1) next_state = S_META; // 2拍完成,切换到元数据
                end
            end
            S_META: begin
                // 元数据状态: 写入meta FIFO
                s_tready = !meta_full;
                if (s_tvalid && !meta_full) begin
                    meta_wen = 1'b1;
                    if (cnt == META_BATCH-1) next_state = S_ID; // 5拍完成,切换到ID
                end
            end
            default: begin
                next_state = S_ID;
            end
        endcase
    end

endmodule

