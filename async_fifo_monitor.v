//==============================================================================
// Project      : Asynchronous FIFO with Error Monitoring
// Design Level : Level 7 - Monitoring wrapper around the Level 6 async FIFO
// Module       : async_fifo_monitor
// File Name    : async_fifo_monitor.v
// Developer    : Ghulam Yaseen Nangraj
// Date         : 06-Nov-2026
// Country      : Pakistan
// HDL Standard : Verilog-2001 (IEEE 1364-2001)
// Tool         : Xilinx Vivado v2025.2.1 
// Target       : Xilinx FPGA
//
// Description  : Wraps the Level 6 asynchronous FIFO (async_fifo) and adds
//                two saturating error counters. Each counter lives in the
//                clock domain of the request it observes, so no counter
//                crosses a clock domain boundary.
//
// Key Parameters:
//   DATA_WIDTH  - Width of each FIFO word in bits
//   ADDR_WIDTH  - Pointer address width (FIFO depth = 2**ADDR_WIDTH)
//   DEPTH       - Number of FIFO entries
//   ERROR_WIDTH - Width of each error counter in bits
//
// Operation    :
//   - Every write request seen while the FIFO is full increments
//     rejected_writes (write clock domain).
//   - Every read request seen while the FIFO is empty increments
//     rejected_reads (read clock domain).
//   - Both counters stop at their maximum value (saturate) instead of
//     wrapping around.
//
// Flags        : full, empty (driven by the underlying async_fifo)
//
// Reset        : Independent active-low asynchronous resets, one per clock
//                domain (wr_rst_n, rd_rst_n). Each reset clears the error
//                counter of its own domain.
//
// Applications : Clock domain crossing buffers, data streaming links, and
//                designs that need to detect overflow and underflow attempts.
//==============================================================================

`timescale 1ns / 1ps

module async_fifo_monitor #(
    parameter DATA_WIDTH  = 8,                  // Width of each FIFO word
    parameter ADDR_WIDTH  = 3,                  // Pointer address width
    parameter DEPTH       = (1 << ADDR_WIDTH),  // Number of FIFO entries
    parameter ERROR_WIDTH = 8                   // Width of each error counter
)(
    //--------------------------------------------------------------------------
    // Clock and Reset
    //--------------------------------------------------------------------------
    input  wire                   wr_clk,           // Write domain clock
    input  wire                   rd_clk,           // Read domain clock
    input  wire                   wr_rst_n,         // Write domain reset (active low)
    input  wire                   rd_rst_n,         // Read domain reset (active low)

    //--------------------------------------------------------------------------
    // Write Interface
    //--------------------------------------------------------------------------
    input  wire                   wr_en,            // Write request
    input  wire [DATA_WIDTH-1:0]  data_in,          // Write data

    //--------------------------------------------------------------------------
    // Read Interface
    //--------------------------------------------------------------------------
    input  wire                   rd_en,            // Read request
    output wire [DATA_WIDTH-1:0]  data_out,         // Read data

    //--------------------------------------------------------------------------
    // Status Flags
    //--------------------------------------------------------------------------
    output wire                   full,             // FIFO full flag
    output wire                   empty,            // FIFO empty flag

    //--------------------------------------------------------------------------
    // Monitoring
    //--------------------------------------------------------------------------
    output reg  [ERROR_WIDTH-1:0] rejected_writes,  // Writes attempted while full
    output reg  [ERROR_WIDTH-1:0] rejected_reads    // Reads attempted while empty
);

    //==========================================================================
    // Section 1 : Underlying Asynchronous FIFO
    //==========================================================================
    async_fifo #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH),
        .DEPTH      (DEPTH)
    ) u_fifo (
        .wr_clk     (wr_clk),
        .rd_clk     (rd_clk),
        .wr_rst_n   (wr_rst_n),
        .rd_rst_n   (rd_rst_n),
        .wr_en      (wr_en),
        .data_in    (data_in),
        .rd_en      (rd_en),
        .data_out   (data_out),
        .full       (full),
        .empty      (empty)
    );

    //==========================================================================
    // Section 2 : Rejected Write Counter (Write Clock Domain)
    //==========================================================================
    // Counts write requests observed while full. Saturates at all ones.
    //--------------------------------------------------------------------------
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rejected_writes <= {ERROR_WIDTH{1'b0}};
        end
        else begin
            if (wr_en && full && (rejected_writes != {ERROR_WIDTH{1'b1}})) begin
                rejected_writes <= rejected_writes + 1'b1;
            end
        end
    end

    //==========================================================================
    // Section 3 : Rejected Read Counter (Read Clock Domain)
    //==========================================================================
    // Counts read requests observed while empty. Saturates at all ones.
    //--------------------------------------------------------------------------
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rejected_reads <= {ERROR_WIDTH{1'b0}};
        end
        else begin
            if (rd_en && empty && (rejected_reads != {ERROR_WIDTH{1'b1}})) begin
                rejected_reads <= rejected_reads + 1'b1;
            end
        end
    end

endmodule