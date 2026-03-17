// ============================================================================
// Module: stream_demux
// 功能描述:
//   流解复用器 - 16:5比例控制
//   将输入的混合数据流按照16拍数据:5拍元数据的比例分离到两个输出FIFO
//
// 工作原理:
//   状态机在S_DATA和S_META之间切换:
//   - S_DATA状态: 连续接收16拍数据写入val FIFO
//   - S_META状态: 连续接收5拍元数据写入meta FIFO
//
// 数据格式:
//   输入: [数据拍x16][元数据拍x5][数据拍x16][元数据拍x5]...
//   输出: val FIFO <- 数据流, meta FIFO <- 元数据流
// ============================================================================
module stream_demux #(
    // ========================================================================
    // 参数定义
    // ========================================================================
    parameter AXI_WIDTH = 512,          // AXI数据位宽
    parameter VAL_BATCH = 16,           // 数值批大小(16拍)
    parameter META_BATCH = 5            // 元数据批大小(5拍)
)(
    input  wire clk, rst_n,             // 时钟和复位
    input  wire [AXI_WIDTH-1:0] s_tdata,// 输入数据
    input  wire s_tvalid,               // 输入有效
    output reg  s_tready,               // 输入就绪

    // 数值FIFO接口
    output reg  val_wen,                // 数值写使能
    output reg  [AXI_WIDTH-1:0] val_din,// 数值写入数据
    input  wire val_full,               // 数值FIFO满

    // 元数据FIFO接口
    output reg  meta_wen,               // 元数据写使能
    output reg  [AXI_WIDTH-1:0] meta_din,// 元数据写入数据
    input  wire meta_full               // 元数据FIFO满
);

    // ========================================================================
    // 状态机定义
    // ========================================================================
    localparam S_DATA = 0, S_META = 1;  // 状态: 数据/元数据
    reg state, next_state;              // 当前状态和下一状态
    reg [4:0] cnt;                      // 计数器(最大16)

    // ========================================================================
    // 状态寄存器和计数器
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_DATA;
            cnt <= 0;
        end else if (s_tvalid && s_tready) begin
            state <= next_state;
            // 计数器逻辑: 状态结束时复位,否则递增
            if ((state == S_DATA && cnt == VAL_BATCH-1) ||
                (state == S_META && cnt == META_BATCH-1))
                cnt <= 0;
            else
                cnt <= cnt + 1;
        end
    end

    // ========================================================================
    // 输出逻辑(组合逻辑)
    // ========================================================================
    always @(*) begin
        next_state = state;
        s_tready = 0;
        val_wen = 0; meta_wen = 0;
        val_din = s_tdata; meta_din = s_tdata;

        case (state)
            S_DATA: begin
                // 数据状态: 写入数值FIFO
                s_tready = !val_full;
                if (s_tvalid && !val_full) begin
                    val_wen = 1;
                    if (cnt == VAL_BATCH-1) next_state = S_META; // 16拍完成,切换到元数据
                end
            end
            S_META: begin
                // 元数据状态: 写入meta FIFO
                s_tready = !meta_full;
                if (s_tvalid && !meta_full) begin
                    meta_wen = 1;
                    if (cnt == META_BATCH-1) next_state = S_DATA; // 5拍完成,切换到数据
                end
            end
        endcase
    end
endmodule