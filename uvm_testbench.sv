// UVM testbench for direct_mapped_cache (compile direct_mapped_cache.v alongside)
// Order: config package -> interface -> memory model -> white-box checker -> UVM package -> top
//
// Every SVA failure is reported through uvm_report_error, so it counts towards the
// UVM error total and turns "TEST PASSED" into "TEST FAILED".
// Run cache_directed_test for coverage closure; cache_base_test is random traffic only.
`timescale 1ns/1ps

// Concurrent assertion that reports through UVM. Uses the default clocking and
// default disable iff of the enclosing scope.
`define SVA(name, prop) \
    name: assert property (prop) else uvm_pkg::uvm_report_error("SVA", `"name failed`");

// ============================================================
// cache_cfg_pkg.sv : one source of truth for sizes and timing
// ============================================================
package cache_cfg_pkg;
    localparam int        INDEX_BITS    = 4;
    localparam int        NUM_LINES     = 1 << INDEX_BITS;
    localparam int        TAG_BITS      = 32 - INDEX_BITS - 2;
    localparam int        MEM_LATENCY   = 3;
    localparam int        MISS_LAT      = MEM_LATENCY + 2;  // request -> cpu_ready for a read miss or a write
    localparam int        MAX_LAT       = 2 * MISS_LAT;     // hang bound for the protocol checks
    localparam int        CLK_PERIOD_NS = 10;
    localparam bit [31:0] NEAR_LIMIT    = 32'h80;           // addresses below this are "near"
endpackage

// ============================================================
// cache_if.sv
// ============================================================
interface cache_if (input logic clk);
    import cache_cfg_pkg::*;

    logic        rst;
    // CPU side (driven by the testbench)
    logic        cpu_req, cpu_we;
    logic [31:0] cpu_addr, cpu_wdata, cpu_rdata;
    logic        cpu_ready;
    // Memory side (driven by mem_model)
    logic        mem_req, mem_we;
    logic [31:0] mem_addr, mem_wdata, mem_rdata;
    logic        mem_ready;

    // Helpers: a request is pending from the cycle after cpu_req until cpu_ready is seen,
    // and is latched so the checks can compare against it.
    logic        pending = 1'b0;
    logic        req_we;
    logic [31:0] req_addr, req_wdata;

    always @(posedge clk) begin
        if (rst !== 1'b0)   pending <= 1'b0;
        else if (cpu_req)   pending <= 1'b1;
        else if (cpu_ready) pending <= 1'b0;
        if (cpu_req) {req_we, req_addr, req_wdata} <= {cpu_we, cpu_addr, cpu_wdata};
    end

    default clocking @(posedge clk); endclocking
    default disable iff (rst !== 1'b0);     // checks are off while rst is 1 or still X

    // ---------- Stimulus rules (these check the testbench, not the DUT) ----------
    // One request at a time; this also makes cpu_req a 1-cycle pulse
    `SVA(a_tb_one_outstanding, cpu_req |-> !pending)
    `SVA(a_tb_req_clean,       cpu_req |-> !$isunknown({cpu_we, cpu_addr, cpu_wdata}) && cpu_addr[1:0] == 2'b00)
    `SVA(a_tb_no_req_in_reset, disable iff (1'b0) rst === 1'b1 |-> !cpu_req)

    // ---------- Reset and X ----------
    `SVA(a_reset_idle, disable iff (1'b0) rst === 1'b1 |=> !cpu_ready && !mem_req && !mem_we)
    `SVA(a_no_x_ctrl,  !$isunknown({cpu_ready, mem_req, mem_we}))
    `SVA(a_no_x_rdata, cpu_ready && !req_we |-> !$isunknown(cpu_rdata))
    `SVA(a_no_x_mem,   mem_req |-> !$isunknown(mem_addr) && (!mem_we || !$isunknown(mem_wdata)))

    // ---------- CPU side ----------
    // Only an outstanding request is answered (this also makes cpu_ready a 1-cycle pulse)
    `SVA(a_ready_needs_req, cpu_ready |-> pending)
    `SVA(a_ready_bounded,   cpu_req |-> ##[1:MAX_LAT] cpu_ready)
    // The cycle after a request: writes always start a memory write (write-through);
    // reads either hit (answered at once, no memory access) or start a memory read
    `SVA(a_write_through,      cpu_req && cpu_we  |=> mem_req && mem_we && !cpu_ready)
    `SVA(a_read_hit_or_fetch,  cpu_req && !cpu_we |=> cpu_ready ^ (mem_req && !mem_we))

    // ---------- Memory side ----------
    // The memory command belongs to the pending request and matches it for its whole duration
    `SVA(a_mem_cmd_match, mem_req |-> pending && mem_we == req_we && mem_addr == req_addr &&
                                      (!mem_we || mem_wdata == req_wdata))
    // One access per request, started straight away
    `SVA(a_mem_start,     $rose(mem_req) |-> $past(cpu_req))
    // mem_req is held until mem_ready (no abandoned transfer)
    `SVA(a_mem_hold,      mem_req && !mem_ready |=> mem_req)
    // The CPU is answered the cycle after memory completes, and never while memory is busy
    `SVA(a_mem_done,      mem_req && mem_ready |=> cpu_ready)
    `SVA(a_ready_no_mem,  cpu_ready |-> !mem_req)
    // A read miss returns exactly the word memory supplied
    `SVA(a_miss_data,     mem_req && mem_ready && !mem_we |=> cpu_rdata == $past(mem_rdata))

endinterface

// ============================================================
// mem_model.sv
// ============================================================
// Main memory with a fixed latency. Sparse, so the full 32-bit address space works
// without aliasing. Initial contents: word w holds w * 100 (the scoreboard assumes the same).
// Reset clears the handshake only; memory contents survive a reset.
module mem_model #(
    parameter int LATENCY = 3
)(
    input  logic        clk,
    input  logic        rst,
    input  logic        req,
    input  logic        we,
    input  logic [31:0] addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    output logic        ready
);

    initial if (LATENCY < 1) $fatal(1, "mem_model: LATENCY must be >= 1");

    logic [31:0] mem [logic [29:0]];   // word address -> data (only written words)
    int          count;

    wire [29:0] waddr = addr[31:2];

    always @(posedge clk) begin
        if (rst) begin
            ready <= 1'b0;
            rdata <= '0;
            count <= 0;
        end else begin
            ready <= 1'b0;
            if (req && !ready) begin
                if (count == LATENCY - 1) begin
                    count <= 0;
                    ready <= 1'b1;
                    if (we) mem[waddr] = wdata;
                    else    rdata <= mem.exists(waddr) ? mem[waddr] : waddr * 100;
                end else begin
                    count <= count + 1;
                end
            end
        end
    end

    // Self-checks of the model (the scoreboard's latency expectations rely on them)
    default clocking @(posedge clk); endclocking
    default disable iff (rst !== 1'b0);

    `SVA(a_mem_latency,     req && !ready && count == 0 |-> ##LATENCY ready)
    `SVA(a_mem_ready_pulse, ready |-> req ##1 !ready)

endmodule

// ============================================================
// cache_fsm_checker.sv : white-box checks, bound into the DUT
// ============================================================
module cache_fsm_checker (
    input logic       clk, rst, cpu_req, mem_req, mem_we,
    input logic [1:0] state
);
    localparam logic [1:0] IDLE = 2'd0, READ = 2'd1, WRITE = 2'd2;   // must match direct_mapped_cache

    default clocking @(posedge clk); endclocking
    default disable iff (rst !== 1'b0);

    `SVA(a_fsm_legal,  (state inside {IDLE, READ, WRITE}))
    `SVA(a_fsm_reset,  disable iff (1'b0) rst === 1'b1 |=> state == IDLE)
    // The memory port is a direct image of the FSM state
    `SVA(a_fsm_mem_req, mem_req == (state != IDLE))
    `SVA(a_fsm_mem_we,  mem_we  == (state == WRITE))
    // The DUT silently drops a request that arrives while it is busy
    `SVA(a_fsm_accept,  cpu_req |-> state == IDLE)
endmodule

// ============================================================
// cache_uvm_pkg.sv
// ============================================================
package cache_uvm_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import cache_cfg_pkg::*;

    typedef enum bit       {KIND_REQ, KIND_RESET}        kind_e;
    typedef enum bit [1:0] {HIT, MISS_COLD, MISS_CONFLICT} outcome_e;

// ------------------------------------------------------------
// cache_item
// ------------------------------------------------------------
class cache_item extends uvm_sequence_item;

    // Stimulus
    kind_e            kind = KIND_REQ;    // KIND_RESET: pulse reset instead of issuing a request
    rand bit          we;             // 1 = write, 0 = read
    rand bit [31:0]   addr;
    rand bit [31:0]   wdata;
    rand int unsigned delay;          // idle cycles before the request
    int unsigned      abort_after;    // > 0: reset the DUT this many cycles into the request

    // Filled in by the monitor
    bit [31:0] rdata;
    int        cycles;                // request-to-ready latency
    int        gap;                   // idle cycles since the previous response
    int        mem_reads, mem_writes; // memory accesses completed during the request
    bit [31:0] mem_addr, mem_wdata;   // last memory access
    bit        aborted;               // cut short by reset, no cpu_ready

    // Filled in by the scoreboard (reference model)
    outcome_e  outcome;
    bit [29:0] line_waddr;            // word the line held before this access

    constraint c_addr {
        addr[1:0] == 2'b00;
        addr dist {[0 : NEAR_LIMIT - 1] :/ 7, [NEAR_LIMIT : 32'hFFFF_FFFF] :/ 1};
    }
    constraint c_we    { we dist {0 := 7, 1 := 3}; }
    constraint c_delay { delay dist {0 := 6, [1:3] :/ 4}; }

    `uvm_object_utils(cache_item)

    function new(string name = "cache_item");
        super.new(name);
    endfunction

    function string convert2string();
        if (kind == KIND_RESET) return "RESET";
        return $sformatf("%s addr=0x%08h wdata=%0d rdata=%0d cycles=%0d mem_rd=%0d mem_wr=%0d%s",
                         we ? "WRITE" : "READ ", addr, wdata, rdata, cycles,
                         mem_reads, mem_writes, aborted ? " ABORTED" : "");
    endfunction

endclass

// ------------------------------------------------------------
// Sequences
// ------------------------------------------------------------
class cache_base_seq extends uvm_sequence #(cache_item);

    `uvm_object_utils(cache_base_seq)

    localparam bit [31:0] STRIDE = NUM_LINES * 4;   // next address with the same index

    function new(string name = "cache_base_seq");
        super.new(name);
    endfunction

    task send(kind_e kind, bit we = 0, bit [31:0] addr = 0, bit [31:0] wdata = 0,
              int unsigned delay = 0, int unsigned abort_after = 0);
        cache_item item = cache_item::type_id::create("item");
        start_item(item);
        item.kind        = kind;
        item.we          = we;
        item.addr        = addr;
        item.wdata       = wdata;
        item.delay       = delay;
        item.abort_after = abort_after;
        finish_item(item);
    endtask

    task rd(bit [31:0] addr, int unsigned delay = 0, int unsigned abort_after = 0);
        send(KIND_REQ, 1'b0, addr, 0, delay, abort_after);
    endtask

    task wr(bit [31:0] addr, bit [31:0] data, int unsigned delay = 0, int unsigned abort_after = 0);
        send(KIND_REQ, 1'b1, addr, data, delay, abort_after);
    endtask

    task reset_dut();
        send(KIND_RESET);
    endtask

endclass


// Random traffic. A quarter of the requests re-use one of the last four addresses,
// which produces hits (also on far addresses) and read-after-write sequences.
class cache_rand_seq extends cache_base_seq;

    `uvm_object_utils(cache_rand_seq)

    int unsigned num_txns;            // set by the test

    function new(string name = "cache_rand_seq");
        super.new(name);
    endfunction

    task body();
        bit [31:0] recent[$];
        repeat (num_txns) begin
            bit reuse = recent.size() > 0 && $urandom_range(3) == 0;
            req = cache_item::type_id::create("req");
            start_item(req);
            if (!req.randomize() with { local::reuse -> addr inside {local::recent}; })
                `uvm_fatal("SEQ", "randomization failed")
            finish_item(req);
            recent.push_front(req.addr);
            if (recent.size() > 4) void'(recent.pop_back());
        end
    endtask

endclass


// Every line: cold miss, hit, conflict miss on upper tag bits, hit, eviction
class cache_sweep_seq extends cache_base_seq;

    `uvm_object_utils(cache_sweep_seq)

    function new(string name = "cache_sweep_seq");
        super.new(name);
    endfunction

    task body();
        bit [31:0] far_base = 32'hA000_0000;
        reset_dut();
        for (int i = 0; i < NUM_LINES; i++) rd(i * 4, i % 3);           // cold misses, with gaps
        for (int i = 0; i < NUM_LINES; i++) rd(i * 4);                  // hits
        for (int i = 0; i < NUM_LINES; i++) rd(far_base + i * 4);       // conflict misses
        for (int i = 0; i < NUM_LINES; i++) rd(far_base + i * 4);       // hits
        for (int i = 0; i < NUM_LINES; i++) rd(i * 4);                  // evicted again
    endtask

endclass


// Tag compare: thrash one line between two addresses whose tags differ in a single bit,
// for every tag bit. A comparator that ignores any bit returns a false hit.
class cache_tag_walk_seq extends cache_base_seq;

    `uvm_object_utils(cache_tag_walk_seq)

    function new(string name = "cache_tag_walk_seq");
        super.new(name);
    endfunction

    task body();
        bit [31:0] base = 32'h10;                               // line 4
        reset_dut();
        rd(base); rd(base);                                     // cold miss, hit
        for (int k = 0; k < TAG_BITS; k++) begin
            bit [31:0] other = base ^ (32'd1 << (2 + INDEX_BITS + k));
            rd(other);                                          // conflict miss
            rd(base);                                           // conflict miss back
        end
        rd(base); rd(base);                                     // hit, hit
    endtask

endclass


// Write-through / no-write-allocate, starting from an empty cache
class cache_write_seq extends cache_base_seq;

    `uvm_object_utils(cache_write_seq)

    function new(string name = "cache_write_seq");
        super.new(name);
    endfunction

    task body();
        bit [31:0] x = 32'h20;                 // line 8
        bit [31:0] y = x + STRIDE;             // line 8, other tag
        bit [31:0] w = x + 32'h1000_0000;      // line 8, far tag
        bit [31:0] z = 32'h24;                 // line 9

        reset_dut();
        wr(x, 111);                            // write miss on an empty line: memory only
        rd(x);                                 // cold miss (no allocate), returns 111
        wr(x, 222);                            // write hit: line and memory updated
        rd(x);                                 // hit, returns 222
        wr(y, 333);                            // write miss while x is cached
        rd(x);                                 // still a hit (no evict on write miss), 222
        wr(y, 444, 2);                         // write miss after an idle gap
        rd(y);                                 // conflict miss, returns 444; line now holds y
        wr(x, 9);                              // write miss, line holds y
        rd(w);                                 // conflict miss: line still holds y
        wr(z, 7);                              // write miss on another empty line
        rd(z + STRIDE);                        // cold miss: the write did not allocate line 9
        wr(x, 1); wr(x, 2); wr(x, 3);          // back-to-back write misses
        rd(x);                                 // conflict miss, returns 3
        wr(x, 4); wr(x, 5, 1);                 // back-to-back write hits
        rd(x);                                 // hit, returns 5
    endtask

endclass


// Reset while idle and in the middle of a request. The cache must come back empty,
// memory keeps its contents, and a write cut short counts only if memory completed it.
class cache_reset_seq extends cache_base_seq;

    `uvm_object_utils(cache_reset_seq)

    function new(string name = "cache_reset_seq");
        super.new(name);
    endfunction

    task body();
        bit [31:0] a = 32'hF000_0030;                       // line 12, far tag
        rd(a); wr(a, 55);                                   // fill the line, write hit
        reset_dut();                                        // idle reset
        rd(a);                                              // cold miss, returns 55
        rd(a + STRIDE, .abort_after(2));                    // read miss cut short
        wr(a, 66, .abort_after(2));                         // cut short before memory writes
        rd(a);                                              // cold miss, still 55
        wr(a, 77, .abort_after(MEM_LATENCY + 1));           // reset as memory completes, no cpu_ready
        rd(a);                                              // cold miss, returns 77
    endtask

endclass

// ------------------------------------------------------------
// cache_driver
// ------------------------------------------------------------
class cache_driver extends uvm_driver #(cache_item);

    `uvm_component_utils(cache_driver)

    virtual cache_if vif;
    int unsigned     num_driven;       // requests issued (resets not counted)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual cache_if)::get(this, "", "vif", vif))
            `uvm_fatal("DRV", "virtual interface 'vif' not set")
    endfunction

    task reset_phase(uvm_phase phase);
        phase.raise_objection(this);
        reset_dut();
        phase.drop_objection(this);
    endtask

    task main_phase(uvm_phase phase);
        forever begin
            seq_item_port.get_next_item(req);
            if (req.kind == KIND_RESET) reset_dut();
            else begin
                drive(req);
                num_driven++;            // before item_done, so the test never sees a stale count
            end
            seq_item_port.item_done();
        end
    endtask

    // Two cycles of reset, then one idle cycle
    task reset_dut();
        vif.rst       <= 1'b1;
        vif.cpu_req   <= 1'b0;
        vif.cpu_we    <= 1'b0;
        vif.cpu_addr  <= '0;
        vif.cpu_wdata <= '0;
        repeat (2) @(posedge vif.clk);
        vif.rst       <= 1'b0;
        @(posedge vif.clk);
    endtask

    task drive(cache_item tr);
        repeat (tr.delay) @(posedge vif.clk);
        vif.cpu_req   <= 1'b1;
        vif.cpu_we    <= tr.we;
        vif.cpu_addr  <= tr.addr;
        vif.cpu_wdata <= tr.wdata;
        @(posedge vif.clk);
        vif.cpu_req   <= 1'b0;
        for (int n = 1; !vif.cpu_ready; n++) begin
            if (n == tr.abort_after) begin
                reset_dut();
                return;
            end
            @(posedge vif.clk);
        end
    endtask

endclass

// ------------------------------------------------------------
// cache_monitor
// ------------------------------------------------------------
// Publishes one item per request (completed or cut short by reset) and one RESET
// item each time a reset starts (the power-on reset is not published).
class cache_monitor extends uvm_monitor;

    `uvm_component_utils(cache_monitor)

    virtual cache_if vif;
    uvm_analysis_port #(cache_item) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap = new("ap", this);
        if (!uvm_config_db #(virtual cache_if)::get(this, "", "vif", vif))
            `uvm_fatal("MON", "virtual interface 'vif' not set")
    endfunction

    task run_phase(uvm_phase phase);
        cache_item tr;                 // request in flight, null when idle
        int        idle     = 0;       // idle cycles since the last response
        bit        in_reset = 1'b1;

        forever begin
            @(posedge vif.clk);

            if (tr != null) begin
                tr.cycles++;
                if (vif.mem_req && vif.mem_ready) begin
                    if (vif.mem_we) tr.mem_writes++;
                    else            tr.mem_reads++;
                    tr.mem_addr  = vif.mem_addr;
                    tr.mem_wdata = vif.mem_wdata;
                end
                if (vif.cpu_ready || vif.rst === 1'b1) begin
                    tr.aborted = !vif.cpu_ready;
                    tr.rdata   = vif.cpu_rdata;
                    `uvm_info("MON", tr.convert2string(), UVM_HIGH)
                    ap.write(tr);
                    tr   = null;
                    idle = 0;
                end
            end else if (vif.cpu_req && vif.rst === 1'b0) begin
                tr       = cache_item::type_id::create("mon_tr");
                tr.we    = vif.cpu_we;
                tr.addr  = vif.cpu_addr;
                tr.wdata = vif.cpu_wdata;
                tr.gap   = idle;
            end else begin
                idle++;
            end

            if (vif.rst !== 1'b0) begin
                if (!in_reset) begin
                    cache_item r = cache_item::type_id::create("mon_rst");
                    r.kind = KIND_RESET;
                    ap.write(r);
                end
                in_reset = 1'b1;
                idle     = 0;
            end else begin
                in_reset = 1'b0;
            end
        end
    endtask

endclass

// ------------------------------------------------------------
// cache_scoreboard
// ------------------------------------------------------------
class cache_scoreboard extends uvm_scoreboard;

    `uvm_component_utils(cache_scoreboard)

    uvm_analysis_imp  #(cache_item, cache_scoreboard) imp;
    uvm_analysis_port #(cache_item)                   ap_checked;

    bit [31:0] ref_mem [bit [29:0]];   // words written so far (others hold waddr * 100)
    bit        line_valid [NUM_LINES];
    bit [29:0] line_waddr [NUM_LINES];

    int num_reqs, num_reads, num_writes, num_hits, num_aborted, num_resets, num_errors;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        imp        = new("imp", this);
        ap_checked = new("ap_checked", this);
    endfunction

    function bit [31:0] mem_value(bit [29:0] waddr);
        return ref_mem.exists(waddr) ? ref_mem[waddr] : waddr * 100;
    endfunction

    function void expect_ok(bit ok, string what, cache_item tr);
        if (ok) return;
        num_errors++;
        `uvm_error("SCB", {what, " | ", tr.convert2string()})
    endfunction

    function void write(cache_item tr);
        bit [29:0] waddr = tr.addr[31:2];
        int        idx   = tr.addr[2 +: INDEX_BITS];
        bit        hit   = line_valid[idx] && line_waddr[idx] == waddr;

        if (tr.kind == KIND_RESET) begin
            // The DUT clears its valid bits; memory keeps its contents
            line_valid = '{default: 1'b0};
            num_resets++;
        end else if (tr.aborted) begin
            // Cut short by reset: only a memory write that completed has an effect
            if (tr.we && tr.mem_writes > 0) ref_mem[waddr] = tr.wdata;
            num_reqs++;
            num_aborted++;
        end else begin
            num_reqs++;
            tr.outcome    = hit ? HIT : line_valid[idx] ? MISS_CONFLICT : MISS_COLD;
            tr.line_waddr = line_waddr[idx];

            if (tr.we) begin
                num_writes++;
                expect_ok(tr.mem_writes == 1 && tr.mem_reads == 0,
                      "write did not do exactly one memory write", tr);
                expect_ok(tr.mem_addr == tr.addr && tr.mem_wdata == tr.wdata,
                      "memory write has the wrong address or data", tr);
                expect_ok(tr.cycles == MISS_LAT, $sformatf("write latency is not %0d", MISS_LAT), tr);
                ref_mem[waddr] = tr.wdata;       // write-through, no-write-allocate: lines unchanged
            end else begin
                num_reads++;
                if (hit) begin
                    num_hits++;
                    expect_ok(tr.mem_reads == 0 && tr.mem_writes == 0, "read hit accessed memory", tr);
                    expect_ok(tr.cycles == 1, "read hit latency is not 1", tr);
                end else begin
                    expect_ok(tr.mem_reads == 1 && tr.mem_writes == 0 && tr.mem_addr == tr.addr,
                          "read miss did not fetch its word exactly once", tr);
                    expect_ok(tr.cycles == MISS_LAT, $sformatf("read miss latency is not %0d", MISS_LAT), tr);
                    line_valid[idx] = 1'b1;
                    line_waddr[idx] = waddr;
                end
                expect_ok(tr.rdata == mem_value(waddr),
                      $sformatf("read data mismatch, expected %0d", mem_value(waddr)), tr);
            end
        end
        ap_checked.write(tr);
    endfunction

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info("SCB", $sformatf({"\n--------------------------------------------\n",
                  " Requests     : %0d (%0d aborted by reset)\n",
                  " Reads        : %0d (hits %0d, misses %0d)\n",
                  " Writes       : %0d\n",
                  " Resets       : %0d\n",
                  " Mismatches   : %0d\n",
                  "--------------------------------------------"},
                  num_reqs, num_aborted, num_reads, num_hits, num_reads - num_hits,
                  num_writes, num_resets, num_errors), UVM_NONE)
    endfunction

endclass

// ------------------------------------------------------------
// cache_coverage
// ------------------------------------------------------------
class cache_coverage extends uvm_subscriber #(cache_item);

    `uvm_component_utils(cache_coverage)

    typedef enum {P_RD_HIT, P_RD_MISS, P_WRITE}  prev_e;   // previous request
    typedef enum {SAME_ADDR, SAME_LINE, OTHER}   rel_e;    // relation to the previous request
    typedef enum {RST_IDLE, RST_ABORT_READ, RST_ABORT_WRITE, RST_ABORT_WRITE_DONE} reset_e;

    cache_item prev;          // previous request, null after a reset
    bit        has_prev;
    prev_e     prev_kind;
    rel_e      rel;

    // One sample per completed request
    covergroup cg_req with function sample(cache_item t);
        option.per_instance = 1;
        cp_op:      coverpoint t.we { bins read = {0}; bins write = {1}; }
        cp_outcome: coverpoint t.outcome;
        cp_index:   coverpoint t.addr[2 +: INDEX_BITS];
        cp_far:     coverpoint (t.addr >= NEAR_LIMIT) { bins near = {0}; bins far = {1}; }
        cp_gap:     coverpoint t.gap { bins zero = {0}; bins one = {1}; bins more = {[2:$]}; }
        cp_prev:    coverpoint prev_kind iff (has_prev);
        cp_rel:     coverpoint rel iff (has_prev) { bins same_addr = {SAME_ADDR}; bins same_line = {SAME_LINE}; }

        // Read and write hit, cold miss and conflict miss
        x_op_outcome:    cross cp_op, cp_outcome;
        // Every line hits, fills and gets evicted
        x_index_outcome: cross cp_index, cp_outcome;
        // Upper tag bits take part in hits and misses
        x_far_outcome:   cross cp_far, cp_outcome;
        // Back-to-back and spaced requests after every kind of response
        x_gap_prev:      cross cp_gap, cp_prev;
        // Write-through / no-allocate: what follows a write to the same word or line.
        // After a read the line holds that word, so only hit / conflict can follow.
        x_history:       cross cp_prev, cp_rel, cp_outcome {
            ignore_bins rd_same_addr = binsof(cp_prev) intersect {P_RD_HIT, P_RD_MISS} &&
                                       binsof(cp_rel.same_addr) &&
                                       binsof(cp_outcome) intersect {MISS_COLD, MISS_CONFLICT};
            ignore_bins rd_same_line = binsof(cp_prev) intersect {P_RD_HIT, P_RD_MISS} &&
                                       binsof(cp_rel.same_line) &&
                                       binsof(cp_outcome) intersect {HIT, MISS_COLD};
        }
    endgroup

    // Conflict misses whose tags differ in exactly one bit: every comparator bit exercised
    covergroup cg_tag with function sample(int unsigned pos);
        option.per_instance = 1;
        cp_bit: coverpoint pos { bins tag_bit[] = {[0 : TAG_BITS - 1]}; }
    endgroup

    // Reset while idle, or in the middle of each kind of request
    covergroup cg_reset with function sample(reset_e ctx);
        option.per_instance = 1;
        cp_ctx: coverpoint ctx;
    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        cg_req   = new();
        cg_tag   = new();
        cg_reset = new();
    endfunction

    function void write(cache_item t);
        if (t.kind == KIND_RESET) begin
            if (prev == null || !prev.aborted) cg_reset.sample(RST_IDLE);
            else if (!prev.we)                 cg_reset.sample(RST_ABORT_READ);
            else if (prev.mem_writes == 0)     cg_reset.sample(RST_ABORT_WRITE);
            else                               cg_reset.sample(RST_ABORT_WRITE_DONE);
            prev = null;
            return;
        end

        if (!t.aborted) begin
            has_prev = (prev != null);
            if (has_prev) begin
                prev_kind = prev.we ? P_WRITE : (prev.outcome == HIT) ? P_RD_HIT : P_RD_MISS;
                rel       = (prev.addr == t.addr)                                   ? SAME_ADDR :
                            (prev.addr[2 +: INDEX_BITS] == t.addr[2 +: INDEX_BITS]) ? SAME_LINE : OTHER;
            end
            cg_req.sample(t);

            if (t.outcome == MISS_CONFLICT) begin
                bit [TAG_BITS-1:0] diff = t.addr[31 -: TAG_BITS] ^ t.line_waddr[29 -: TAG_BITS];
                if ($onehot(diff)) cg_tag.sample($clog2(diff));
            end
        end
        prev = t;
    endfunction

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info("COV", $sformatf("coverage: requests %0.2f%%, tag bits %0.2f%%, resets %0.2f%%",
                  cg_req.get_inst_coverage(), cg_tag.get_inst_coverage(),
                  cg_reset.get_inst_coverage()), UVM_NONE)
    endfunction

endclass

// ------------------------------------------------------------
// cache_agent / cache_env
// ------------------------------------------------------------
typedef uvm_sequencer #(cache_item) cache_sequencer;

class cache_agent extends uvm_agent;

    `uvm_component_utils(cache_agent)

    cache_sequencer sqr;
    cache_driver    drv;
    cache_monitor   mon;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        mon = cache_monitor::type_id::create("mon", this);
        if (get_is_active() == UVM_ACTIVE) begin
            sqr = cache_sequencer::type_id::create("sqr", this);
            drv = cache_driver::type_id::create("drv", this);
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (get_is_active() == UVM_ACTIVE)
            drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction

endclass


class cache_env extends uvm_env;

    `uvm_component_utils(cache_env)

    cache_agent      agent;
    cache_scoreboard scb;
    cache_coverage   cov;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        agent = cache_agent::type_id::create("agent", this);
        scb   = cache_scoreboard::type_id::create("scb", this);
        cov   = cache_coverage::type_id::create("cov", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        agent.mon.ap.connect(scb.imp);
        scb.ap_checked.connect(cov.analysis_export);
    endfunction

endclass

// ------------------------------------------------------------
// Tests
// ------------------------------------------------------------
class cache_base_test extends uvm_test;

    `uvm_component_utils(cache_base_test)

    cache_env    env;
    int unsigned num_txns = 500;      // random requests, +NUM_TXNS=<n> to change

    function new(string name = "cache_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        void'($value$plusargs("NUM_TXNS=%d", num_txns));
        env = cache_env::type_id::create("env", this);
    endfunction

    // Watchdog: every request finishes well within 2 * MAX_LAT cycles; the 1000 covers
    // the directed sequences and resets.
    function void start_of_simulation_phase(uvm_phase phase);
        super.start_of_simulation_phase(phase);
        uvm_root::get().set_timeout((num_txns + 1000) * 2 * MAX_LAT * CLK_PERIOD_NS * 1ns, 0);
    endfunction

    task start_seq(cache_base_seq seq);
        seq.start(env.agent.sqr);
    endtask

    virtual task run_sequences();
        cache_rand_seq seq = cache_rand_seq::type_id::create("rand");
        seq.num_txns = num_txns;
        start_seq(seq);
    endtask

    task main_phase(uvm_phase phase);
        phase.raise_objection(this);
        run_sequences();
        wait (env.scb.num_reqs >= env.agent.drv.num_driven);
        phase.drop_objection(this);
    endtask

    function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        if (env.scb.num_reqs == 0)
            `uvm_error("TEST", "no transactions were checked")
        if (env.scb.num_reqs != env.agent.drv.num_driven)
            `uvm_error("TEST", $sformatf("driver sent %0d requests but the scoreboard saw %0d",
                                         env.agent.drv.num_driven, env.scb.num_reqs))
    endfunction

    function void report_phase(uvm_phase phase);
        uvm_report_server svr = uvm_report_server::get_server();
        super.report_phase(phase);
        if (svr.get_severity_count(UVM_ERROR) + svr.get_severity_count(UVM_FATAL) == 0)
            `uvm_info("TEST", "*** TEST PASSED ***", UVM_NONE)
        else
            `uvm_info("TEST", "*** TEST FAILED ***", UVM_NONE)
    endfunction

endclass


// Directed sequences for closure, then random traffic
class cache_directed_test extends cache_base_test;

    `uvm_component_utils(cache_directed_test)

    function new(string name = "cache_directed_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_sequences();
        start_seq(cache_sweep_seq   ::type_id::create("sweep"));
        start_seq(cache_tag_walk_seq::type_id::create("tag_walk"));
        start_seq(cache_write_seq   ::type_id::create("writes"));
        start_seq(cache_reset_seq   ::type_id::create("resets"));
        super.run_sequences();
    endtask

endclass

endpackage

// ============================================================
// tb_top.sv
// ============================================================
// The UVM test is chosen with +UVM_TESTNAME (default below).
module tb_top;

    import uvm_pkg::*;
    import cache_cfg_pkg::*;
    import cache_uvm_pkg::*;

    logic clk = 0;
    always #(CLK_PERIOD_NS / 2.0) clk = ~clk;

    cache_if intf (clk);

    direct_mapped_cache #(.INDEX_BITS(INDEX_BITS)) dut (
        .clk       (intf.clk),
        .rst       (intf.rst),
        .cpu_req   (intf.cpu_req),
        .cpu_we    (intf.cpu_we),
        .cpu_addr  (intf.cpu_addr),
        .cpu_wdata (intf.cpu_wdata),
        .cpu_rdata (intf.cpu_rdata),
        .cpu_ready (intf.cpu_ready),
        .mem_req   (intf.mem_req),
        .mem_we    (intf.mem_we),
        .mem_addr  (intf.mem_addr),
        .mem_wdata (intf.mem_wdata),
        .mem_rdata (intf.mem_rdata),
        .mem_ready (intf.mem_ready)
    );

    mem_model #(.LATENCY(MEM_LATENCY)) mem (
        .clk   (intf.clk),
        .rst   (intf.rst),
        .req   (intf.mem_req),
        .we    (intf.mem_we),
        .addr  (intf.mem_addr),
        .wdata (intf.mem_wdata),
        .rdata (intf.mem_rdata),
        .ready (intf.mem_ready)
    );

    bind direct_mapped_cache cache_fsm_checker u_fsm_chk (.clk, .rst, .cpu_req, .mem_req, .mem_we, .state);

    initial begin
        uvm_config_db #(virtual cache_if)::set(null, "*", "vif", intf);
        run_test("cache_base_test");     // overridden by +UVM_TESTNAME=<test>
    end

endmodule
