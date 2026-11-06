# Level 7 Asynchronous FIFO with Error Monitoring

## 1. Project Overview

This project implements a **dual-clock asynchronous FIFO** and extends
it with independent overflow/underflow monitoring counters. It is
intended as an educational and verification project for learning
clock-domain crossing (CDC), Gray-coded pointers, FIFO status
generation, and self-checking RTL verification.

The design is organized into three Verilog files:

  ------------------------------------------------------------------------------
  File                                        Design level Purpose
  --------------------------- ---------------------------- ---------------------
  `async_fifo.v`                                   Level 6 Core dual-clock
                                                           asynchronous FIFO

  `async_fifo_monitor.v`                           Level 7 Monitoring wrapper
                                                           with saturating
                                                           rejected-operation
                                                           counters

  `tb_async_fifo_monitor.v`           Level 7 verification Self-checking
                                                           testbench with
                                                           unrelated clocks,
                                                           scoreboard, reference
                                                           counters, directed
                                                           tests, and random
                                                           traffic
  ------------------------------------------------------------------------------

**Developer:** Ghulam Yaseen Nangraj\
**HDL:** Verilog-2001 (IEEE 1364-2001)\
**Target tool:** Xilinx Vivado 2025.2.1 / XSim\
**Target:** Xilinx FPGA (synthesis suitability depends on the selected
device and implementation constraints)\
**Simulation timescale:** `1ns / 1ps`

The testbench is simulation-only and is not part of the synthesized
hardware.

------------------------------------------------------------------------

## 2. What Is an Asynchronous FIFO?

A FIFO (First-In, First-Out) is a storage structure in which data is
read in the same order in which it was written.

An **asynchronous FIFO** has separate write and read clock domains:

-   `wr_clk` controls incoming data, the write pointer, and write-side
    storage operations.
-   `rd_clk` controls outgoing data, the read pointer, and read-side
    output registration.
-   The two clocks may have different frequencies and are not required
    to have a fixed phase relationship.

This makes an asynchronous FIFO useful when data must safely pass
between two independently clocked parts of a digital system.

### Conceptual data flow

``` text
                 WRITE CLOCK DOMAIN
              wr_clk / wr_rst_n / wr_en
                         |
                         v
                  +-------------+
 data_in -------->|             |
                  | FIFO MEMORY |-------> data_out
                  |             |
                  +-------------+
                         ^
                         |
                 READ CLOCK DOMAIN
              rd_clk / rd_rst_n / rd_en

        Gray-coded read pointer ---- synchronizer ----> write domain
        Gray-coded write pointer --- synchronizer ----> read domain
```

The memory is shared storage, but each pointer is updated only in its
own clock domain. The opposite pointer is transferred through a
two-stage synchronizer in Gray-coded form.

------------------------------------------------------------------------

## 3. Level 6 Core: `async_fifo.v`

The Level 6 module provides the actual asynchronous FIFO storage and
control.

### 3.1 FIFO architecture

The implementation uses:

1.  A dual-clock memory array.
2.  A binary write pointer and a binary read pointer.
3.  Gray-coded versions of both pointers.
4.  Two flip-flops to synchronize each Gray-coded pointer into the
    opposite clock domain.
5.  A wrap bit in each pointer to distinguish different trips around the
    circular buffer.
6.  A registered read-data output.

### 3.2 Why binary and Gray-coded pointers are both used

Binary pointers are convenient for addressing the memory and
incrementing the FIFO position. However, multiple bits can change during
a binary increment. If such a pointer is sampled asynchronously, the
receiving clock domain could observe an incoherent intermediate value.

A Gray-code conversion changes only one bit between successive pointer
values:

\[ Gray = Binary `\oplus `{=tex}(Binary \>\> 1) \]

The design therefore:

-   Uses binary pointers locally for memory addressing and pointer
    arithmetic.
-   Converts the next binary pointer to Gray code.
-   Sends the Gray-coded pointer through a two-flip-flop synchronizer.
-   Uses the synchronized pointer to determine the remote side's
    progress.

Gray coding reduces the risk of incoherent multi-bit transitions at the
CDC boundary. It does not eliminate the need for proper synchronizer
placement and timing constraints.

### 3.3 Pointer width and FIFO depth

The core defines:

\[ PTR_WIDTH = ADDR_WIDTH + 1 \]

The extra most-significant bit is the wrap bit. The lower `ADDR_WIDTH`
bits address the memory.

For the default configuration:

-   `ADDR_WIDTH = 3`
-   `DEPTH = 2**3 = 8`
-   `PTR_WIDTH = 4`
-   Memory locations are addressed from 0 through 7.

### 3.4 Full and empty detection

-   **Empty:** the local read Gray pointer equals the synchronized write
    Gray pointer.
-   **Full:** the write Gray pointer equals the synchronized read Gray
    pointer with its two most-significant bits inverted.

The full comparison is the standard Gray-pointer comparison for a
power-of-two asynchronous FIFO. The implementation requires
`ADDR_WIDTH >= 2`, because the comparison uses the top two pointer bits.

The flags are generated in the RTL from the local pointer and
synchronized remote pointer. Due to synchronization latency, a flag can
take a number of destination-clock edges to reflect a change made in the
other domain. This conservative delay is normal for asynchronous FIFO
designs.

### 3.5 Core module interface

  Signal       Direction            Width Description
  ------------ ----------- -------------- --------------------------------------------
  `wr_clk`     Input                    1 Write clock
  `rd_clk`     Input                    1 Read clock
  `wr_rst_n`   Input                    1 Active-low asynchronous write-domain reset
  `rd_rst_n`   Input                    1 Active-low asynchronous read-domain reset
  `wr_en`      Input                    1 Write request
  `data_in`    Input         `DATA_WIDTH` Input data word
  `rd_en`      Input                    1 Read request
  `data_out`   Output        `DATA_WIDTH` Registered read data
  `full`       Output                   1 FIFO full status
  `empty`      Output                   1 FIFO empty status

A write is accepted on a rising edge of `wr_clk` when `wr_en=1` and
`full=0`. A read is accepted on a rising edge of `rd_clk` when `rd_en=1`
and `empty=0`.

Requests made while the corresponding flag blocks the operation do not
advance that side's pointer.

------------------------------------------------------------------------

## 4. Level 7 Monitoring Wrapper: `async_fifo_monitor.v`

The Level 7 module instantiates the Level 6 FIFO and adds two
independent error counters. It does not replace the FIFO's pointer,
memory, or CDC architecture.

### 4.1 Added monitoring features

  Counter             Clock domain   Increment condition   Reset condition
  ------------------- -------------- --------------------- ---------------------
  `rejected_writes`   `wr_clk`       `wr_en && full`       `wr_rst_n` asserted
  `rejected_reads`    `rd_clk`       `rd_en && empty`      `rd_rst_n` asserted

The counters are **saturating counters**. They stop at their maximum
representable value instead of wrapping back to zero.

For an `ERROR_WIDTH`-bit counter:

\[ Maximum = 2\^{ERROR_WIDTH} - 1 \]

With the default `ERROR_WIDTH = 8`, the range is 0 through 255.

### 4.2 Why are the counters in separate clock domains?

A rejected write is detected using write-side signals and is counted by
`wr_clk`. A rejected read is detected using read-side signals and is
counted by `rd_clk`.

This keeps each counter local to the clock domain in which its event
occurs. The design does not combine the two counters into a single clock
domain or directly synchronize the counter buses.

If a future system needs to read these counters from a third clock
domain, add a suitable CDC-safe snapshot or handshake mechanism rather
than sampling a changing multi-bit counter directly.

### 4.3 Monitoring wrapper interface

The wrapper exposes all core FIFO signals and adds:

  ---------------------------------------------------------------------------
  Signal              Direction                        Width Description
  ------------------- ---------------- --------------------- ----------------
  `rejected_writes`   Output                   `ERROR_WIDTH` Number of write
                                                             requests
                                                             observed while
                                                             full

  `rejected_reads`    Output                   `ERROR_WIDTH` Number of read
                                                             requests
                                                             observed while
                                                             empty
  ---------------------------------------------------------------------------

The wrapper's other ports are the same as the core FIFO interface.

### 4.4 Wrapper parameters

  ------------------------------------------------------------------------
  Parameter                                  Default Description
  --------------------- ---------------------------- ---------------------
  `DATA_WIDTH`                                     8 Number of bits in
                                                     each FIFO word

  `ADDR_WIDTH`                                     3 Address width; FIFO
                                                     depth is normally
                                                     `2**ADDR_WIDTH`

  `DEPTH`                          `1 << ADDR_WIDTH` Number of storage
                                                     entries

  `ERROR_WIDTH`                                    8 Width of each
                                                     saturating error
                                                     counter
  ------------------------------------------------------------------------

Keep `DEPTH` equal to `2**ADDR_WIDTH`. The Gray-pointer full/empty
scheme in this project is intended for a power-of-two FIFO depth.

------------------------------------------------------------------------

## 5. Verification: `tb_async_fifo_monitor.v`

The testbench verifies both data integrity and monitoring behavior. It
generates two unrelated clocks, drives directed and randomized traffic,
and checks the design against independent reference models.

### 5.1 Default testbench configuration

  ------------------------------------------------------------------------
  Parameter                                  Default Description
  --------------------- ---------------------------- ---------------------
  `DATA_WIDTH`                                     8 FIFO word width

  `ADDR_WIDTH`                                     3 Pointer address width

  `DEPTH`                                          8 FIFO entries

  `ERROR_WIDTH`                                    8 Error-counter width

  `WR_PERIOD`                                  10 ns Write clock period

  `RD_PERIOD`                                  14 ns Read clock period

  `READ_REGISTERED`                                1 Selects the
                                                     testbench's
                                                     registered-output
                                                     checking path

  `SCB_SIZE`                                    4096 Scoreboard array size

  `RANDOM_CYCLES`                               1500 Write-clock cycles in
                                                     each random run
  ------------------------------------------------------------------------

The default clock periods are different (10 ns and 14 ns), so the
testbench exercises the design with unrelated clock edges.

### 5.2 Scoreboard operation

The scoreboard records each accepted write in order. For each accepted
read, it obtains the corresponding expected word and compares it with
`data_out`.

The testbench detects:

-   Data corruption.
-   Data-order errors.
-   A read being accepted when the scoreboard has no corresponding
    written word.
-   Mismatches in the rejected-write counter.
-   Mismatches in the rejected-read counter.
-   An illegal condition in which `full` and `empty` are asserted
    together.

The testbench uses case inequality (`!==`) for comparisons so that
unknown (`X`) or high-impedance (`Z`) values are treated as failures
rather than silently passing.

### 5.3 Independent error-counter reference models

The testbench separately models the expected rejected-write and
rejected-read counters. It checks the DUT counters on the falling edge
of their respective clocks, after the rising-edge sequential updates
have settled.

This checks both the increment conditions and saturation behavior.

### 5.4 Directed and random test plan

The main test sequence contains seven test groups:

  ------------------------------------------------------------------------
                          Test Description           Expected behavior
  ---------------------------- --------------------- ---------------------
                             1 Reset state           `empty=1`, `full=0`,
                                                     both counters are
                                                     zero

                             2 Read while empty      Each rejected read
                                                     increments
                                                     `rejected_reads`

                             3 Fill FIFO and write   FIFO becomes full;
                               while full            each blocked write
                                                     increments
                                                     `rejected_writes`

                             4 Drain FIFO and read   Data is returned in
                               while empty           FIFO order;
                                                     additional empty
                                                     reads are counted

                             5 Counter saturation    Both counters stop at
                                                     all ones and do not
                                                     wrap

                             6 Reset after activity  Both counters clear
                                                     and FIFO status
                                                     returns to empty

                             7 Random concurrent     Scoreboard and
                               traffic               counter reference
                                                     models check mixed
                                                     traffic
  ------------------------------------------------------------------------

The random test group runs four traffic profiles:

-   50% write requests and 50% read requests (balanced).
-   90% write requests and 20% read requests (write-heavy).
-   20% write requests and 90% read requests (read-heavy).
-   70% write requests and 70% read requests (high utilization).

The percentages are request probabilities, not guaranteed
accepted-operation percentages. Full and empty conditions can reject
requests.

### 5.5 Testbench result

At the end of simulation, the testbench prints:

-   Total number of checks.
-   Total number of errors.
-   `RESULT : PASSED` when no errors were detected.
-   `RESULT : FAILED` when one or more errors were detected.

A watchdog timer also terminates the simulation if the test sequence
does not finish within the configured timeout.

------------------------------------------------------------------------

## 6. Reset Behavior

The design uses independent active-low asynchronous resets:

-   `wr_rst_n` resets the write pointer, write-side synchronizer, and
    rejected-write counter.
-   `rd_rst_n` resets the read pointer, read-side synchronizer, output
    register, and rejected-read counter.

For normal system operation, reset assertion and release must be planned
carefully across both clock domains. Although the RTL uses asynchronous
assertion, reset deassertion should be synchronized to each local clock
domain in a production CDC design.

The testbench releases each reset on the falling edge of its
corresponding clock to avoid driving reset at the same active edge used
by the DUT.

**Important:** Resetting one side independently while the other side is
actively operating can invalidate the FIFO's shared logical state. Treat
reset as a coordinated FIFO reset unless the system-level architecture
explicitly handles independent-domain reset recovery.

------------------------------------------------------------------------

## 7. How to Run the Project in Vivado 2025.2.1

### 7.1 Create a project

1.  Open **Xilinx Vivado 2025.2.1**.
2.  Select **Create Project**.
3.  Choose an RTL project.
4.  Add the three Verilog files:
    -   `async_fifo.v`
    -   `async_fifo_monitor.v`
    -   `tb_async_fifo_monitor.v`
5.  Set `tb_async_fifo_monitor` as the simulation top.
6.  Select the intended FPGA part if creating a device-specific project.
    The testbench itself does not require an FPGA board.

### 7.2 Run behavioral simulation

1.  Open **Flow Navigator → Simulation**.
2.  Select **Run Simulation → Run Behavioral Simulation**.
3.  Allow the simulation to run until the testbench calls `$finish`.
4.  Inspect the Tcl Console for the final check count and result.
5.  Inspect the wave window for the clocks, resets, enables, flags,
    data, and monitoring counters.

### 7.3 Suggested waveform signals

Add these signals to the waveform window:

``` text
wr_clk
rd_clk
wr_rst_n
rd_rst_n
wr_en
rd_en
data_in
data_out
full
empty
rejected_writes
rejected_reads
```

For deeper debugging, also inspect internal pointers and synchronizer
stages:

``` text
u_fifo.wr_bin
u_fifo.rd_bin
u_fifo.wr_gray
u_fifo.rd_gray
u_fifo.rd_gray_w1
u_fifo.rd_gray_w2
u_fifo.wr_gray_r1
u_fifo.wr_gray_r2
```

Internal hierarchical names may vary if the instance name or RTL
structure is changed.

### 7.4 Compile order

The core module must be available when compiling the wrapper, and the
wrapper and core must both be available when compiling the testbench.
Vivado normally resolves module dependencies automatically when all
files are included in the project.

For command-line or scripted simulation, compile all three files and
select `tb_async_fifo_monitor` as the simulation top.

------------------------------------------------------------------------

## 8. Synthesis and FPGA Implementation Notes

The synthesizable design hierarchy is:

``` text
async_fifo_monitor
    |
    +---- async_fifo
    |       +---- FIFO memory
    |       +---- binary pointers
    |       +---- Gray-code pointers
    |       +---- pointer synchronizers
    |       +---- full / empty logic
    |
    +---- rejected_writes counter
    |
    +---- rejected_reads counter
```

The testbench is not instantiated in the hardware hierarchy.

### 8.1 Memory inference

The core declares a memory array and writes it in the write-clock
process while reading it in the read-clock process. Whether Vivado maps
this structure into block RAM, distributed RAM, or another
implementation depends on the FPGA family, coding pattern, and synthesis
results.

Check the synthesis report and inferred-memory report. Do not assume
block RAM inference without verifying the result.

### 8.2 CDC constraints and implementation review

For a real FPGA implementation:

-   Review the CDC report in Vivado.
-   Ensure the two-stage pointer synchronizer registers are recognized
    and placed appropriately.
-   Apply suitable `ASYNC_REG` attributes to synchronizer registers
    where required by the project methodology.
-   Review timing constraints for the asynchronous clock relationship
    and synchronizer paths.
-   Do not apply broad false paths that hide unrelated timing problems.
-   Confirm reset synchronization and reset-release behavior.
-   Review placement, routing, and timing after implementation.

The RTL's two-flop synchronizers are an educational baseline; a
production design should include device- and project-appropriate CDC
attributes, constraints, and review.

### 8.3 Parameter restrictions

The core's Gray-pointer full comparison uses the two most-significant
pointer bits. Therefore:

-   `ADDR_WIDTH` must be at least 2.
-   `DEPTH` must be a power of two.
-   `DEPTH` must equal `2**ADDR_WIDTH`.

The supplied defaults satisfy these requirements.

------------------------------------------------------------------------

## 9. Important Design and Verification Notes

1.  **Registered read output:** `async_fifo.v` updates `data_out` in the
    read-clocked sequential process. The supplied testbench default
    `READ_REGISTERED=1` matches this behavior.
2.  **Do not select `READ_REGISTERED=0` without changing the RTL or
    checker:** the testbench contains a non-registered checking branch,
    but the supplied FIFO itself always uses a registered output. The
    default value of 1 is the supported configuration for these files.
3.  **Counter meaning:** the counters count requests observed while
    `full` or `empty` is asserted. They do not count successful
    operations.
4.  **Saturation:** once a counter reaches all ones, further rejected
    requests leave it unchanged until reset.
5.  **Clock-domain visibility:** `full` and `empty` are used in their
    respective local operation paths, but the testbench observes both
    for checking. In a larger design, consume each status signal
    according to its documented clock-domain meaning.
6.  **Random stimulus:** random traffic is useful for broad simulation
    coverage but is not a substitute for directed corner-case tests,
    formal verification, or hardware CDC analysis.
7.  **Scoreboard capacity:** `SCB_SIZE` must be large enough for the
    cumulative accepted writes between scoreboard resets. Increase it if
    the traffic duration or test plan is expanded significantly.

------------------------------------------------------------------------

## 10. Example Parameter Configuration

The default configuration creates an 8-entry FIFO with 8-bit data and
8-bit monitoring counters.

For example, a 16-entry FIFO with 16-bit data and 12-bit counters can be
configured by setting:

``` verilog
async_fifo_monitor #(
    .DATA_WIDTH  (16),
    .ADDR_WIDTH  (4),
    .DEPTH       (16),
    .ERROR_WIDTH (12)
) u_async_fifo_monitor (
    // Connect clocks, resets, data, enables, flags, and counters.
);
```

The matching testbench parameters must also be updated to use the same
FIFO and counter widths.

------------------------------------------------------------------------

## 11. Applications

This design pattern is useful in systems that transfer data between
unrelated clock domains, including:

-   FPGA data acquisition and processing pipelines.
-   Communication interfaces with independent transmit and receive
    clocks.
-   Sensor interfaces and digital signal-processing blocks.
-   Packet and streaming-data buffers.
-   Clock-domain boundaries between peripheral and system logic.
-   Debug and diagnostic systems that need overflow/underflow attempt
    counts.

The monitoring wrapper is especially useful during system integration
because it makes rejected write and read requests observable without
changing the FIFO's basic data interface.

------------------------------------------------------------------------

## 12. Future Improvements

Possible extensions for a more advanced FIFO project include:

-   `almost_full` and `almost_empty` status flags.
-   Programmable thresholds.
-   Sticky overflow and underflow event flags.
-   A memory-mapped register interface for software access to status
    counters.
-   A CDC-safe snapshot mechanism for reading counters from another
    clock domain.
-   Parameter and configuration checks for unsupported FIFO depths.
-   `ASYNC_REG` attributes and project-specific CDC constraints.
-   Assertions or formal properties for pointer, flag, and data-order
    invariants.
-   More directed tests for simultaneous read/write activity and reset
    sequencing.
-   Coverage metrics and reproducible random seeds.

------------------------------------------------------------------------

## 13. Project Summary

This project demonstrates the progression from a basic asynchronous FIFO
(Level 6) to a monitored asynchronous FIFO (Level 7).

-   **Level 6** provides dual-clock FIFO storage, Gray-coded pointers,
    synchronizers, and full/empty detection.
-   **Level 7** adds independent saturating counters for rejected write
    and read requests.
-   **The testbench** verifies reset behavior, overflow and underflow
    attempts, counter saturation, FIFO data ordering, and randomized
    concurrent traffic.

The key learning outcome is understanding how FIFO data movement,
clock-domain crossing, status generation, monitoring, and self-checking
verification work together in a practical Verilog design.

------------------------------------------------------------------------

## License

No license terms are specified in the supplied RTL files. Add an
explicit license before redistributing the project if you want to define
reuse, modification, and attribution conditions.
