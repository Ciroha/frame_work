`timescale 1ns / 1ps

// ============================================================================
// Sub-module: Value LUT Decode (8xID -> 8xFP64)
// ============================================================================
module value_lut_decode #(
    parameter PARALLELISM = 8,
    parameter ID_WIDTH = 8,
    parameter DATA_WIDTH = 64,
    parameter LUT_INIT_FILE = ""
)(
    input  wire [PARALLELISM*ID_WIDTH-1:0] id_vec,
    output wire [PARALLELISM*DATA_WIDTH-1:0] fp_vec
);
    localparam LUT_SIZE = (1 << ID_WIDTH);

    (* rom_style = "distributed" *) reg [DATA_WIDTH-1:0] lut_mem [0:LUT_SIZE-1];

    integer i;
    initial begin
        for (i = 0; i < LUT_SIZE; i = i + 1) begin
            lut_mem[i] = {DATA_WIDTH{1'b0}};
        end
        if (LUT_INIT_FILE != "") begin
            $readmemh(LUT_INIT_FILE, lut_mem);
            $display("Loaded LUT from %s", LUT_INIT_FILE);
        end else begin
            $display("LUT_INIT_FILE is empty; LUT initialized to zeros.");
        end
    end

    genvar k;
    generate
        for (k = 0; k < PARALLELISM; k = k + 1) begin : gen_lut
            wire [ID_WIDTH-1:0] id = id_vec[k*ID_WIDTH +: ID_WIDTH];
            assign fp_vec[k*DATA_WIDTH +: DATA_WIDTH] = lut_mem[id];
        end
    endgenerate

endmodule

