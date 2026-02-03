//////////////////////////////////////////////////////////////////////////////////
//simple_sync_fifo.v
// 简单同步 FIFO 模块
//////////////////////////////////////////////////////////////////////////////////
module simple_sync_fifo #(parameter WIDTH=512, DEPTH=512)(
    input clk, rst_n, wen, ren, input [WIDTH-1:0] din,
    output reg [WIDTH-1:0] dout, output full, empty
);
    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [$clog2(DEPTH):0] wptr=0, rptr=0, cnt=0;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin wptr<=0; rptr<=0; cnt<=0; end
        else begin
            if(wen && !full) begin mem[wptr[$clog2(DEPTH)-1:0]] <= din; wptr <= wptr+1; end
            if(ren && !empty) begin dout <= mem[rptr[$clog2(DEPTH)-1:0]]; rptr <= rptr+1; end
            if(wen && !full && !(ren && !empty)) cnt <= cnt + 1;
            else if(!(wen && !full) && (ren && !empty)) cnt <= cnt - 1;
        end
    end
    assign full = (cnt == DEPTH);
    assign empty = (cnt == 0);
endmodule
