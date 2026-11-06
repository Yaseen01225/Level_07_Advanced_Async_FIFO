//==============================================================================
// Project      : Asynchronous FIFO with Error Monitoring
// Design Level : Level 7 - Testbench for the monitoring wrapper
// Module       : tb_async_fifo_monitor
// File Name    : tb_async_fifo_monitor.v
// Developer    : Ghulam Yaseen Nangraj
// Date         : 06-Nov-2026
// Country      : Pakistan
// HDL Standard : Verilog-2001 (IEEE 1364-2001)
// Tool         : Xilinx Vivado (XSim)
// Target       : Simulation only
//
// Description  : Self-checking testbench for async_fifo_monitor. Uses two
//                unrelated clocks, a data scoreboard, and an independent
//                reference model of both saturating error counters.
//
// Key Parameters:
//   DATA_WIDTH       - Width of each FIFO word in bits
//   ADDR_WIDTH       - Pointer address width (FIFO depth = 2**ADDR_WIDTH)
//   ERROR_WIDTH      - Width of each error counter in bits
//   WR_PERIOD        - Write clock period in ns
//   RD_PERIOD        - Read clock period in ns
//   READ_REGISTERED  - 0: data_out is valid in the cycle rd_en is accepted
//                      1: data_out is valid one read clock after acceptance
//   RANDOM_CYCLES    - Write clock cycles per random traffic run
//
// Operation    :
//   Test 1 - Reset state (empty, not full, counters cleared)
//   Test 2 - Reads while empty increment rejected_reads
//   Test 3 - Fill to full, then writes while full increment rejected_writes
//   Test 4 - Drain in order (data checked), then reads while empty counted
//   Test 5 - Both counters saturate at their maximum value
//   Test 6 - Reset clears both counters
//   Test 7 - Random concurrent traffic with scoreboard and counter checks
//
// Flags        : PASSED / FAILED summary printed at the end of simulation
//
// Reset        : Active-low resets for both clock domains, released on the
//                falling clock edge to avoid races with the DUT
//
// Applications : Regression of the Level 7 FIFO monitor
//
// Note         : Compile together with async_fifo.v (Level 6) and
//                async_fifo_monitor.v.
//==============================================================================

`timescale 1ns / 1ps

module tb_async_fifo_monitor;

    //==========================================================================
    // Section 1 : Parameters
    //==========================================================================
    parameter DATA_WIDTH      = 8;                  // Width of each FIFO word
    parameter ADDR_WIDTH      = 3;                  // Pointer address width
    parameter DEPTH           = (1 << ADDR_WIDTH);  // Number of FIFO entries
    parameter ERROR_WIDTH     = 8;                  // Width of each error counter
    parameter WR_PERIOD       = 10;                 // Write clock period (ns)
    parameter RD_PERIOD       = 14;                 // Read clock period (ns)
    parameter READ_REGISTERED = 1;                  // 1 = registered data_out (Level 6 FIFO)
    parameter SCB_SIZE        = 4096;               // Scoreboard memory size
    parameter RANDOM_CYCLES   = 1500;               // Cycles per random run

    localparam [ERROR_WIDTH-1:0] ERR_MAX = {ERROR_WIDTH{1'b1}};

    //==========================================================================
    // Section 2 : Signal Declarations
    //==========================================================================
    reg                    wr_clk;
    reg                    rd_clk;
    reg                    wr_rst_n;
    reg                    rd_rst_n;
    reg                    wr_en;
    reg  [DATA_WIDTH-1:0]  data_in;
    reg                    rd_en;

    wire [DATA_WIDTH-1:0]  data_out;
    wire                   full;
    wire                   empty;
    wire [ERROR_WIDTH-1:0] rejected_writes;
    wire [ERROR_WIDTH-1:0] rejected_reads;

    // Random traffic control
    reg                    rand_en;
    integer                wr_prob;     // Write request probability (percent)
    integer                rd_prob;     // Read request probability (percent)

    // Scoreboard
    reg  [DATA_WIDTH-1:0]  scb_mem [0:SCB_SIZE-1];
    integer                scb_wr_idx;
    integer                scb_rd_idx;
    reg                    rd_check_pend;
    reg  [DATA_WIDTH-1:0]  rd_check_exp;

    // Reference model of the error counters
    reg  [ERROR_WIDTH-1:0] exp_rej_wr;
    reg  [ERROR_WIDTH-1:0] exp_rej_rd;

    // Result tracking
    integer                error_count;
    integer                check_count;

    //==========================================================================
    // Section 3 : Device Under Test
    //==========================================================================
    async_fifo_monitor #(
        .DATA_WIDTH  (DATA_WIDTH),
        .ADDR_WIDTH  (ADDR_WIDTH),
        .DEPTH       (DEPTH),
        .ERROR_WIDTH (ERROR_WIDTH)
    ) dut (
        .wr_clk          (wr_clk),
        .rd_clk          (rd_clk),
        .wr_rst_n        (wr_rst_n),
        .rd_rst_n        (rd_rst_n),
        .wr_en           (wr_en),
        .data_in         (data_in),
        .rd_en           (rd_en),
        .data_out        (data_out),
        .full            (full),
        .empty           (empty),
        .rejected_writes (rejected_writes),
        .rejected_reads  (rejected_reads)
    );

    //==========================================================================
    // Section 4 : Clock Generation
    //==========================================================================
    initial begin
        wr_clk = 1'b0;
    end

    initial begin
        rd_clk = 1'b0;
    end

    always #(WR_PERIOD/2.0) wr_clk = ~wr_clk;

    always #(RD_PERIOD/2.0) rd_clk = ~rd_clk;

    //==========================================================================
    // Section 5 : Reference Model of the Error Counters
    //==========================================================================
    // Independent re-implementation of the expected counter behavior.
    //--------------------------------------------------------------------------
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            exp_rej_wr <= {ERROR_WIDTH{1'b0}};
        end
        else begin
            if (wr_en && full && (exp_rej_wr != ERR_MAX)) begin
                exp_rej_wr <= exp_rej_wr + 1'b1;
            end
        end
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            exp_rej_rd <= {ERROR_WIDTH{1'b0}};
        end
        else begin
            if (rd_en && empty && (exp_rej_rd != ERR_MAX)) begin
                exp_rej_rd <= exp_rej_rd + 1'b1;
            end
        end
    end

    //==========================================================================
    // Section 6 : Scoreboard
    //==========================================================================

    //--------------------------------------------------------------------------
    // Write side: store every accepted write
    //--------------------------------------------------------------------------
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            scb_wr_idx <= 0;
        end
        else begin
            if (wr_en && !full) begin
                scb_mem[scb_wr_idx % SCB_SIZE] <= data_in;
                scb_wr_idx                     <= scb_wr_idx + 1;
            end
        end
    end

    //--------------------------------------------------------------------------
    // Read side: compare every accepted read against the stored data
    //--------------------------------------------------------------------------
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            scb_rd_idx    <= 0;
            rd_check_pend <= 1'b0;
            rd_check_exp  <= {DATA_WIDTH{1'b0}};
        end
        else begin
            // Registered-read mode: data_out is checked one clock after accept
            if (READ_REGISTERED && rd_check_pend) begin
                check_count = check_count + 1;
                if (data_out !== rd_check_exp) begin
                    error_count = error_count + 1;
                    $display("[%0t] ERROR: data mismatch, got %h expected %h",
                             $time, data_out, rd_check_exp);
                end
            end
            rd_check_pend <= 1'b0;

            if (rd_en && !empty) begin
                if (scb_rd_idx >= scb_wr_idx) begin
                    error_count = error_count + 1;
                    $display("[%0t] ERROR: read accepted with no data written",
                             $time);
                end
                else begin
                    if (READ_REGISTERED) begin
                        rd_check_exp  <= scb_mem[scb_rd_idx % SCB_SIZE];
                        rd_check_pend <= 1'b1;
                    end
                    else begin
                        check_count = check_count + 1;
                        if (data_out !== scb_mem[scb_rd_idx % SCB_SIZE]) begin
                            error_count = error_count + 1;
                            $display("[%0t] ERROR: data mismatch, got %h expected %h",
                                     $time, data_out,
                                     scb_mem[scb_rd_idx % SCB_SIZE]);
                        end
                    end
                end
                scb_rd_idx <= scb_rd_idx + 1;
            end
        end
    end

    //==========================================================================
    // Section 7 : Continuous Checkers
    //==========================================================================

    //--------------------------------------------------------------------------
    // Rejected write counter must match the reference model every cycle
    //--------------------------------------------------------------------------
    always @(negedge wr_clk) begin
        if (wr_rst_n) begin
            check_count = check_count + 1;
            if (rejected_writes !== exp_rej_wr) begin
                error_count = error_count + 1;
                $display("[%0t] ERROR: rejected_writes = %0d, expected %0d",
                         $time, rejected_writes, exp_rej_wr);
            end
        end
    end

    //--------------------------------------------------------------------------
    // Rejected read counter must match the reference model every cycle
    //--------------------------------------------------------------------------
    always @(negedge rd_clk) begin
        if (rd_rst_n) begin
            check_count = check_count + 1;
            if (rejected_reads !== exp_rej_rd) begin
                error_count = error_count + 1;
                $display("[%0t] ERROR: rejected_reads = %0d, expected %0d",
                         $time, rejected_reads, exp_rej_rd);
            end
        end
    end

    //--------------------------------------------------------------------------
    // full and empty must never be asserted together
    //--------------------------------------------------------------------------
    always @(negedge wr_clk) begin
        if (wr_rst_n && rd_rst_n) begin
            if ((full === 1'b1) && (empty === 1'b1)) begin
                error_count = error_count + 1;
                $display("[%0t] ERROR: full and empty asserted together", $time);
            end
        end
    end

    //==========================================================================
    // Section 8 : Random Traffic Drivers
    //==========================================================================
    always @(posedge wr_clk) begin
        if (rand_en) begin
            wr_en   <= (({$random} % 100) < wr_prob);
            data_in <= $random;
        end
    end

    always @(posedge rd_clk) begin
        if (rand_en) begin
            rd_en <= (({$random} % 100) < rd_prob);
        end
    end

    //==========================================================================
    // Section 9 : Helper Tasks
    //==========================================================================

    //--------------------------------------------------------------------------
    // Check a condition and report the result
    //--------------------------------------------------------------------------
    task check_cond;
        input              condition;
        input [8*40-1:0]   label;
        begin
            check_count = check_count + 1;
            if (!condition) begin
                error_count = error_count + 1;
                $display("[%0t] ERROR: %0s", $time, label);
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // Check a value against an expected value
    //--------------------------------------------------------------------------
    task check_value;
        input [31:0]       actual;
        input [31:0]       expected;
        input [8*40-1:0]   label;
        begin
            check_count = check_count + 1;
            if (actual !== expected) begin
                error_count = error_count + 1;
                $display("[%0t] ERROR: %0s = %0d, expected %0d",
                         $time, label, actual, expected);
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // Write burst: hold wr_en high for count write clock cycles
    //--------------------------------------------------------------------------
    task wr_burst;
        input integer count;
        integer i;
        begin
            for (i = 0; i < count; i = i + 1) begin
                @(posedge wr_clk);
                wr_en   <= 1'b1;
                data_in <= $random;
            end
            @(posedge wr_clk);
            wr_en <= 1'b0;
        end
    endtask

    //--------------------------------------------------------------------------
    // Read burst: hold rd_en high for count read clock cycles
    //--------------------------------------------------------------------------
    task rd_burst;
        input integer count;
        integer i;
        begin
            for (i = 0; i < count; i = i + 1) begin
                @(posedge rd_clk);
                rd_en <= 1'b1;
            end
            @(posedge rd_clk);
            rd_en <= 1'b0;
        end
    endtask

    //--------------------------------------------------------------------------
    // Wait for pointer synchronizers to settle in both domains
    //--------------------------------------------------------------------------
    task settle;
        begin
            repeat (6) @(posedge wr_clk);
            repeat (6) @(posedge rd_clk);
        end
    endtask

    //--------------------------------------------------------------------------
    // Apply reset to both clock domains
    //--------------------------------------------------------------------------
    task apply_reset;
        begin
            @(posedge wr_clk);
            wr_en <= 1'b0;
            @(posedge rd_clk);
            rd_en <= 1'b0;

            @(negedge wr_clk);
            wr_rst_n = 1'b0;
            @(negedge rd_clk);
            rd_rst_n = 1'b0;

            repeat (4) @(posedge wr_clk);
            repeat (4) @(posedge rd_clk);

            @(negedge wr_clk);
            wr_rst_n = 1'b1;
            @(negedge rd_clk);
            rd_rst_n = 1'b1;

            settle;
        end
    endtask

    //--------------------------------------------------------------------------
    // Random traffic run with given request probabilities
    //--------------------------------------------------------------------------
    task random_run;
        input integer write_percent;
        input integer read_percent;
        input integer cycles;
        begin
            wr_prob = write_percent;
            rd_prob = read_percent;
            @(negedge wr_clk);
            rand_en = 1'b1;
            repeat (cycles) @(posedge wr_clk);
            @(negedge wr_clk);
            rand_en = 1'b0;
            @(posedge wr_clk);
            wr_en <= 1'b0;
            @(posedge rd_clk);
            rd_en <= 1'b0;
            settle;
        end
    endtask

    //--------------------------------------------------------------------------
    // Drain the FIFO completely
    //--------------------------------------------------------------------------
    task drain_fifo;
        begin
            settle;
            while (empty !== 1'b1) begin
                rd_burst(DEPTH);
                settle;
            end
        end
    endtask

    //==========================================================================
    // Section 10 : Main Test Sequence
    //==========================================================================
    initial begin
        // Initial values
        wr_rst_n    = 1'b1;
        rd_rst_n    = 1'b1;
        wr_en       = 1'b0;
        rd_en       = 1'b0;
        data_in     = {DATA_WIDTH{1'b0}};
        rand_en     = 1'b0;
        wr_prob     = 50;
        rd_prob     = 50;
        error_count = 0;
        check_count = 0;

        $display("==================================================");
        $display(" tb_async_fifo_monitor : simulation started");
        $display("==================================================");

        apply_reset;

        //----------------------------------------------------------------------
        // Test 1 : Reset state
        //----------------------------------------------------------------------
        $display("[%0t] Test 1: reset state", $time);
        check_cond(empty === 1'b1,           "empty after reset");
        check_cond(full  === 1'b0,           "full cleared after reset");
        check_value(rejected_writes, 0,      "rejected_writes after reset");
        check_value(rejected_reads,  0,      "rejected_reads after reset");

        //----------------------------------------------------------------------
        // Test 2 : Reads while empty
        //----------------------------------------------------------------------
        $display("[%0t] Test 2: reads while empty", $time);
        rd_burst(5);
        settle;
        check_value(rejected_reads,  5,      "rejected_reads after 5 empty reads");
        check_value(rejected_writes, 0,      "rejected_writes unchanged");

        //----------------------------------------------------------------------
        // Test 3 : Fill to full, then writes while full
        //----------------------------------------------------------------------
        $display("[%0t] Test 3: fill and overflow attempts", $time);
        wr_burst(DEPTH);
        settle;
        check_cond(full  === 1'b1,           "full after DEPTH writes");
        check_cond(empty === 1'b0,           "empty cleared after writes");
        wr_burst(4);
        settle;
        check_value(rejected_writes, 4,      "rejected_writes after 4 full writes");

        //----------------------------------------------------------------------
        // Test 4 : Drain in order, then reads while empty
        //----------------------------------------------------------------------
        $display("[%0t] Test 4: drain and underflow attempts", $time);
        rd_burst(DEPTH);
        settle;
        check_cond(empty === 1'b1,           "empty after draining");
        check_cond(full  === 1'b0,           "full cleared after draining");
        check_value(scb_rd_idx, scb_wr_idx,  "scoreboard read/write count");
        rd_burst(3);
        settle;
        check_value(rejected_reads,  8,      "rejected_reads after 3 more reads");
        check_value(rejected_writes, 4,      "rejected_writes unchanged");

        //----------------------------------------------------------------------
        // Test 5 : Counter saturation
        //----------------------------------------------------------------------
        $display("[%0t] Test 5: counter saturation", $time);
        wr_burst(DEPTH);
        settle;
        wr_burst(ERR_MAX + 10);
        settle;
        check_value(rejected_writes, ERR_MAX, "rejected_writes saturated");
        drain_fifo;
        rd_burst(ERR_MAX + 10);
        settle;
        check_value(rejected_reads,  ERR_MAX, "rejected_reads saturated");
        check_value(scb_rd_idx, scb_wr_idx,   "scoreboard after saturation");

        //----------------------------------------------------------------------
        // Test 6 : Reset clears both counters
        //----------------------------------------------------------------------
        $display("[%0t] Test 6: reset clears counters", $time);
        apply_reset;
        check_value(rejected_writes, 0,      "rejected_writes after 2nd reset");
        check_value(rejected_reads,  0,      "rejected_reads after 2nd reset");
        check_cond(empty === 1'b1,           "empty after 2nd reset");
        check_cond(full  === 1'b0,           "full cleared after 2nd reset");

        //----------------------------------------------------------------------
        // Test 7 : Random concurrent traffic
        //----------------------------------------------------------------------
        $display("[%0t] Test 7: random traffic", $time);
        random_run(50, 50, RANDOM_CYCLES);   // Balanced
        random_run(90, 20, RANDOM_CYCLES);   // Write heavy (hits full)
        random_run(20, 90, RANDOM_CYCLES);   // Read heavy (hits empty)
        random_run(70, 70, RANDOM_CYCLES);   // High utilization
        drain_fifo;
        check_cond(empty === 1'b1,           "empty after random traffic");
        check_value(scb_rd_idx, scb_wr_idx,  "scoreboard after random traffic");

        //----------------------------------------------------------------------
        // Summary
        //----------------------------------------------------------------------
        $display("==================================================");
        $display(" Checks performed : %0d", check_count);
        $display(" Errors found     : %0d", error_count);
        if (error_count == 0) begin
            $display(" RESULT           : PASSED");
        end
        else begin
            $display(" RESULT           : FAILED");
        end
        $display("==================================================");
        $finish;
    end

    //==========================================================================
    // Section 11 : Watchdog Timer
    //==========================================================================
    initial begin
        #20_000_000;
        $display("[%0t] ERROR: watchdog timeout", $time);
        $display(" RESULT           : FAILED");
        $finish;
    end

endmodule
