`timescale 1ns / 1ps
// ============================================================================
// Level 6: Educational dual-clock asynchronous FIFO.
// Requires DEPTH=2**ADDR_WIDTH and ADDR_WIDTH >= 2.
// Each clock domain owns its binary pointer and synchronizes the opposite
// Gray-coded pointer through two flip-flops.
// ============================================================================
module async_fifo #(
    parameter DATA_WIDTH=8,
    parameter ADDR_WIDTH=3,                 // Depth is 2**ADDR_WIDTH.
    parameter DEPTH=(1 << ADDR_WIDTH)
)(
    input wire wr_clk, input wire rd_clk,
    input wire wr_rst_n, input wire rd_rst_n, // Active-low local resets.
    input wire wr_en, input wire [DATA_WIDTH-1:0] data_in,
    input wire rd_en, output reg [DATA_WIDTH-1:0] data_out,
    output wire full, output wire empty
);
    localparam PTR_WIDTH = ADDR_WIDTH + 1;   // Extra wrap bit distinguishes laps.
    reg [DATA_WIDTH-1:0] memory [0:DEPTH-1];

    reg [PTR_WIDTH-1:0] wr_bin, wr_gray;     // Write-domain pointers.
    reg [PTR_WIDTH-1:0] rd_bin, rd_gray;     // Read-domain pointers.
    reg [PTR_WIDTH-1:0] rd_gray_w1, rd_gray_w2; // Read pointer into write domain.
    reg [PTR_WIDTH-1:0] wr_gray_r1, wr_gray_r2; // Write pointer into read domain.

    wire [PTR_WIDTH-1:0] wr_bin_next = wr_bin + (wr_en && !full);
    wire [PTR_WIDTH-1:0] rd_bin_next = rd_bin + (rd_en && !empty);
    wire [PTR_WIDTH-1:0] wr_gray_next = (wr_bin_next >> 1) ^ wr_bin_next;
    wire [PTR_WIDTH-1:0] rd_gray_next = (rd_bin_next >> 1) ^ rd_bin_next;

    // Full when next write Gray pointer equals synchronized read Gray pointer
    // with its two most-significant bits inverted (classic power-of-two FIFO).
    assign full = (wr_gray ==
        {~rd_gray_w2[PTR_WIDTH-1:PTR_WIDTH-2], rd_gray_w2[PTR_WIDTH-3:0]});
    assign empty = (rd_gray == wr_gray_r2);

    // Synchronize Gray-coded read pointer into write-clock domain.
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin rd_gray_w1 <= 0; rd_gray_w2 <= 0; end
        else begin rd_gray_w1 <= rd_gray; rd_gray_w2 <= rd_gray_w1; end
    end

    // Synchronize Gray-coded write pointer into read-clock domain.
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin wr_gray_r1 <= 0; wr_gray_r2 <= 0; end
        else begin wr_gray_r1 <= wr_gray; wr_gray_r2 <= wr_gray_r1; end
    end

    // Write pointer and storage are controlled only by wr_clk.
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin wr_bin <= 0; wr_gray <= 0; end
        else if (wr_en && !full) begin
            memory[wr_bin[ADDR_WIDTH-1:0]] <= data_in;
            wr_bin <= wr_bin_next;
            wr_gray <= wr_gray_next;
        end
    end

    // Read pointer and output register are controlled only by rd_clk.
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin rd_bin <= 0; rd_gray <= 0; data_out <= 0; end
        else if (rd_en && !empty) begin
            data_out <= memory[rd_bin[ADDR_WIDTH-1:0]];
            rd_bin <= rd_bin_next;
            rd_gray <= rd_gray_next;
        end
    end
endmodule
