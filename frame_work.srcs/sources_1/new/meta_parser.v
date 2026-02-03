`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/02/02 16:03:36
// Design Name: 
// Module Name: meta_parser
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


// ============================================================================
// Sub-module: Metadata Parser (5 lines in -> 16 lines out)
// ============================================================================
module meta_parser #(
    parameter AXI_WIDTH = 512,
    parameter PARALLELISM = 8
)(
    input  wire clk, rst_n,
    input  wire [AXI_WIDTH-1:0] fifo_dout,
    input  wire                 fifo_empty,
    output reg                  fifo_ren,
    
    input  wire                 next_cycle_req,
    output reg                  parser_valid,
    
    output reg [15:0]           out_row_base,    // 16b Base
    output reg [15:0]           out_col_base,    // 16b Col Base
    output reg [PARALLELISM*16-1:0] out_row_delta  // 8x16b = 128b
    // Total needed per cycle = 160 bits
);
    // 缓存 5 行数据: 5 * 512 = 2560 bits
    reg [AXI_WIDTH-1:0] cache [0:4];
    reg [2:0] req_cnt;     // Count requests sent
    reg fifo_ren_d;        // Delayed Read Enable (to align with data)

    reg [2:0] load_ptr;    // 0..4
    reg [4:0] emit_ptr;    // 0..15

    // 状态机
    localparam S_FILL = 0, S_EMIT = 1;
    reg state;

    // 展平缓存以方便切片
    reg [2559:0] flattened_cache;
    integer i;
    always @(*) begin
        for(i=0; i<5; i=i+1) flattened_cache[i*512 +: 512] = cache[i];
    end

    // 控制逻辑
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_FILL;
            load_ptr <= 0;
            req_cnt <= 0;
            emit_ptr <= 0;
            fifo_ren <= 0;
            fifo_ren_d <= 0;
            parser_valid <= 0;
        end else begin
            case (state)
                S_FILL: begin
                    parser_valid <= 0;
                    
                    // 1. Request Logic
                    if (req_cnt < 5 && !fifo_empty && !fifo_ren) begin
                         fifo_ren <= 1;
                         req_cnt <= req_cnt + 1;
                    end else begin
                         fifo_ren <= 0;
                    end
                    
                    // 2. Data Capture Logic (Delayed)
                    fifo_ren_d <= fifo_ren; // 1 cycle delay

                    if (fifo_ren_d) begin
                        cache[load_ptr] <= fifo_dout;
                        if (load_ptr == 4) begin
                            state <= S_EMIT;
                            load_ptr <= 0;
                            req_cnt <= 0;
                            emit_ptr <= 0;
                            fifo_ren <= 0;
                            fifo_ren_d <= 0;
                        end else begin
                            load_ptr <= load_ptr + 1;
                        end
                    end
                end

                S_EMIT: begin
                    fifo_ren <= 0;
                    parser_valid <= 1; // 数据准备好了
                    
                    if (next_cycle_req) begin
                        // 外部消耗了一拍数据
                        if (emit_ptr == 15) begin
                            state <= S_FILL; // 发完了16拍，回去读新的元数据
                            parser_valid <= 0;
                        end else begin
                            emit_ptr <= emit_ptr + 1;
                        end
                    end
                end
            endcase
        end
    end

    // --- Bit Slicing Logic (Metadata Expansion) ---
    // 需求: RowBase(16b) + 8 * RowDelta(16b) + Colbase(16 b)= 160 bits
    // 16次计算 * 160 bits = 2560 bits ( < 2560 bits, 5行足够)
    
    reg [159:0] current_slice;
    always @(*) begin
        // 动态切片：根据 emit_ptr 选择 160 bits
        current_slice = flattened_cache[emit_ptr*160 +: 160];
        
        // 解析 Slice (New Format: Base + 8xDelta)
        // 假设布局：{RowDelta7, ..., RowDelta0, RowBase}
        // Base 在低位 [15:0]
        out_row_base = current_slice[15:0];

        // Deltas 在高位 [159:32]
        for (i=0; i<PARALLELISM; i=i+1) begin
            // 每个 Delta 16 bits
            out_row_delta[i*16 +: 16] = current_slice[32 + i*16 +: 16];
        end

        // ColBase 在最高位 [31:16]
        out_col_base = current_slice[31:16];
    end

endmodule
