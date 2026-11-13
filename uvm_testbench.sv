// Combined UVM testbench for direct_mapped_cache (DUT NOT included: compile your direct_mapped_cache.v alongside)
// Order: interface -> memory model -> UVM package -> top
`timescale 1ns/1ps
// ============================================================
// cache_if.sv
// ============================================================
// Interface: bundles every DUT signal so the classes can reach them
// through a single virtual interface handle.
interface cache_if (input logic clk);

    logic        rst;

    // CPU side (driven by the testbench)
    logic        cpu_req;
    logic        cpu_we;
    logic [31:0] cpu_addr;
    logic [31:0] cpu_wdata;
    logic [31:0] cpu_rdata;
    logic        cpu_ready;

    // Memory side (driven by mem_model)
    logic        mem_req;
    logic        mem_we;
    logic [31:0] mem_addr;
    logic [31:0] mem_wdata;
    logic [31:0] mem_rdata;
    logic        mem_ready;

    // Protocol checks on the DUT outputs
    // cpu_ready is a single-cycle pulse
    a_ready_pulse: assert property (@(posedge clk) disable iff (rst)
        cpu_ready |=> !cpu_ready);

    // Once raised, mem_req and its command must hold until mem_ready
    a_mem_hold: assert property (@(posedge clk) disable iff (rst)
        mem_req && !mem_ready |=> mem_req && $stable(mem_we) &&
                                  $stable(mem_addr) && $stable(mem_wdata));

endinterface
`timescale 1ns/1ps
// ============================================================
// mem_model.sv
// ============================================================
// Simple main memory model with a fixed latency.
// Sparse, so the full 32-bit address space works without aliasing.
// Initial contents: word w holds w * 100 (the scoreboard assumes the same).
module mem_model #(
    parameter LATENCY = 3
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

endmodule

package cache_uvm_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    localparam int INDEX_BITS = 4;
    localparam int NUM_LINES  = 1 << INDEX_BITS;

// ============================================================
// cache_item.sv
// ============================================================
// Sequence item: one CPU read or write request, plus the response and memory
// traffic the monitor / scoreboard fill in.

// What the cache did with a request (set by the scoreboard's reference model)
typedef enum bit [1:0] {HIT, MISS_COLD, MISS_CONFLICT} cache_outcome_e;

class cache_item extends uvm_sequence_item;

    rand bit          we;      // 1 = write, 0 = read
    rand bit [31:0]   addr;
    rand bit [31:0]   wdata;
    rand int unsigned delay;   // idle cycles before the request
    rand bit [2:0]    region;  // 0 = far address (about 1 in 8), else near

    // Filled in by the monitor
    bit [31:0] rdata;
    int        cycles;         // request-to-ready latency
    int        mem_reads;      // memory reads completed during this request
    int        mem_writes;     // memory writes completed during this request
    bit [31:0] mem_addr;       // address of the last memory access
    bit [31:0] mem_wdata;      // data of the last memory write

    // Filled in by the scoreboard (reference model), used by coverage
    cache_outcome_e outcome;

    // Word-aligned. Mostly a small range (32 words = 2 tags per line) so hits,
    // misses and evictions happen often; far addresses exercise the upper tag bits.
    constraint c_addr {
        addr[1:0] == 2'b00;
        if (region == 0) addr >= 32'h80;
        else             addr <  32'h80;
    }

    // Mostly reads
    constraint c_we    { we dist {0 := 7, 1 := 3}; }

    // Mostly back-to-back requests, sometimes a short gap
    constraint c_delay { delay dist {0 := 6, [1:3] :/ 4}; }

    `uvm_object_utils(cache_item)

    function new(string name = "cache_item");
        super.new(name);
    endfunction

    function void do_copy(uvm_object rhs);
        cache_item r;
        super.do_copy(rhs);
        if (!$cast(r, rhs)) `uvm_fatal("ITEM", "do_copy: type mismatch")
        we = r.we;  addr = r.addr;  wdata = r.wdata;  delay = r.delay;  region = r.region;
        rdata = r.rdata;  cycles = r.cycles;
        mem_reads = r.mem_reads;  mem_writes = r.mem_writes;
        mem_addr = r.mem_addr;  mem_wdata = r.mem_wdata;
        outcome = r.outcome;
    endfunction

    function string convert2string();
        return $sformatf("%s addr=0x%08h wdata=%0d rdata=%0d cycles=%0d mem_rd=%0d mem_wr=%0d",
                         we ? "WRITE" : "READ ", addr, wdata, rdata, cycles,
                         mem_reads, mem_writes);
    endfunction

endclass

// ============================================================
// cache_sequences.sv
// ============================================================

// Base sequence: helpers for sending one directed request.
class cache_base_seq extends uvm_sequence #(cache_item);

    `uvm_object_utils(cache_base_seq)

    // Byte distance between two addresses that map to the same line (different tag)
    localparam bit [31:0] STRIDE = NUM_LINES * 4;

    function new(string name = "cache_base_seq");
        super.new(name);
    endfunction

    task send(bit we, bit [31:0] addr, bit [31:0] wdata = 0, int unsigned delay = 0);
        cache_item item = cache_item::type_id::create("item");
        start_item(item);
        item.we    = we;
        item.addr  = addr;
        item.wdata = wdata;
        item.delay = delay;
        finish_item(item);
    endtask

    task rd(bit [31:0] addr);
        send(1'b0, addr);
    endtask

    task wr(bit [31:0] addr, bit [31:0] data);
        send(1'b1, addr, data);
    endtask

endclass


// Constrained-random traffic (the original generator).
class cache_rand_seq extends cache_base_seq;

    `uvm_object_utils(cache_rand_seq)

    int unsigned num_txns = 500;

    function new(string name = "cache_rand_seq");
        super.new(name);
    endfunction

    task body();
        repeat (num_txns) begin
            req = cache_item::type_id::create("req");
            start_item(req);
            if (!req.randomize()) `uvm_fatal("SEQ", "randomization failed")
            finish_item(req);
        end
    endtask

endclass


// Touch every line: cold miss, then hit, then evict with a far tag, then hit again.
class cache_sweep_seq extends cache_base_seq;

    `uvm_object_utils(cache_sweep_seq)

    function new(string name = "cache_sweep_seq");
        super.new(name);
    endfunction

    task body();
        bit [31:0] far_base = 32'hA000_0000;
        for (int i = 0; i < NUM_LINES; i++) rd(i * 4);              // cold misses
        for (int i = 0; i < NUM_LINES; i++) rd(i * 4);              // all hits
        for (int i = 0; i < NUM_LINES; i++) rd(far_base + i * 4);   // conflict misses (upper tag bits)
        for (int i = 0; i < NUM_LINES; i++) rd(far_base + i * 4);   // all hits
        for (int i = 0; i < NUM_LINES; i++) rd(i * 4);              // evicted again
    endtask

endclass


// Ping-pong between addresses that share a line.
class cache_conflict_seq extends cache_base_seq;

    `uvm_object_utils(cache_conflict_seq)

    function new(string name = "cache_conflict_seq");
        super.new(name);
    endfunction

    task body();
        bit [31:0] a = 32'h10;                 // line 4
        bit [31:0] b = a + STRIDE;             // line 4, different tag
        bit [31:0] c = a + 32'h1000_0000;      // line 4, far tag
        rd(a); rd(a);                          // miss, hit
        rd(b);                                 // evicts a
        rd(a);                                 // miss again
        rd(c); rd(b); rd(c); rd(a);            // keep thrashing
        rd(a);                                 // hit
    endtask

endclass


// Write-through / no-write-allocate behaviour.
class cache_write_seq extends cache_base_seq;

    `uvm_object_utils(cache_write_seq)

    function new(string name = "cache_write_seq");
        super.new(name);
    endfunction

    task body();
        bit [31:0] x = 32'h20;                 // line 8
        bit [31:0] y = x + STRIDE;             // line 8, different tag
        bit [31:0] z = 32'h24;                 // line 9

        wr(x, 111);                            // write miss: memory only, no allocate
        rd(x);                                 // still a read miss, returns 111 from memory
        rd(x);                                 // hit
        wr(x, 222);                            // write hit: line and memory updated
        rd(x);                                 // hit, returns 222

        rd(z);                                 // fill line 9
        wr(y, 333);                            // write to a conflicting address
        rd(x);                                 // must still hit (no evict on write miss), 222
        rd(y);                                 // miss, returns 333
        rd(x);                                 // miss (y just replaced x)

        wr(x, 1); wr(x, 2); wr(x, 3);          // back-to-back writes, same address
        rd(x);                                 // returns 3
    endtask

endclass

// ============================================================
// cache_driver.sv
// ============================================================
// Driver: turns items into pin activity on the CPU interface.
class cache_driver extends uvm_driver #(cache_item);

    `uvm_component_utils(cache_driver)

    virtual cache_if vif;
    int unsigned     num_driven;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual cache_if)::get(this, "", "vif", vif))
            `uvm_fatal("DRV", "virtual interface 'vif' not set")
    endfunction

    // Reset runs in its own phase so the main phase only starts afterwards.
    task reset_phase(uvm_phase phase);
        phase.raise_objection(this);
        vif.rst       <= 1'b1;
        vif.cpu_req   <= 1'b0;
        vif.cpu_we    <= 1'b0;
        vif.cpu_addr  <= '0;
        vif.cpu_wdata <= '0;
        repeat (2) @(posedge vif.clk);
        vif.rst       <= 1'b0;
        @(posedge vif.clk);
        phase.drop_objection(this);
    endtask

    task main_phase(uvm_phase phase);
        forever begin
            seq_item_port.get_next_item(req);
            drive(req);
            num_driven++;                // before item_done, so the test never sees a stale count
            seq_item_port.item_done();
        end
    endtask

    // Optional idle gap, one-cycle request pulse, then wait for the DUT to answer.
    // Called on a clock edge; returns on the edge where cpu_ready is seen.
    task drive(cache_item tr);
        repeat (tr.delay) @(posedge vif.clk);
        vif.cpu_req   <= 1'b1;
        vif.cpu_we    <= tr.we;
        vif.cpu_addr  <= tr.addr;
        vif.cpu_wdata <= tr.wdata;
        @(posedge vif.clk);
        vif.cpu_req   <= 1'b0;
        while (!vif.cpu_ready) @(posedge vif.clk);
    endtask

endclass

// ============================================================
// cache_monitor.sv
// ============================================================
// Monitor: watches the CPU and memory interfaces and rebuilds each completed
// transaction (request, response and the memory traffic it caused).
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
        cache_item tr;
        forever begin
            @(posedge vif.clk);
            if (vif.cpu_req) begin
                // Capture the request
                tr       = cache_item::type_id::create("mon_tr");
                tr.we    = vif.cpu_we;
                tr.addr  = vif.cpu_addr;
                tr.wdata = vif.cpu_wdata;

                // Wait for the response, recording completed memory accesses
                do begin
                    @(posedge vif.clk);
                    tr.cycles++;
                    if (vif.mem_req && vif.mem_ready) begin
                        if (vif.mem_we) tr.mem_writes++;
                        else            tr.mem_reads++;
                        tr.mem_addr  = vif.mem_addr;
                        tr.mem_wdata = vif.mem_wdata;
                    end
                end while (!vif.cpu_ready);

                tr.rdata = vif.cpu_rdata;
                `uvm_info("MON", tr.convert2string(), UVM_HIGH)
                ap.write(tr);
            end
        end
    endtask

endclass

// ============================================================
// cache_scoreboard.sv
// ============================================================
// Scoreboard: keeps a reference model of main memory and of the cache
// contents, and checks every transaction for:
//  - read data (latest value written to that address)
//  - hit/miss behaviour (a hit answers in 1 cycle with no memory access,
//    a miss does exactly one memory read)
//  - write-through (every write does exactly one memory write, no allocate)
// Checked items (with .outcome filled in) are forwarded on ap_checked for coverage.
class cache_scoreboard extends uvm_scoreboard;

    `uvm_component_utils(cache_scoreboard)

    uvm_analysis_imp #(cache_item, cache_scoreboard) imp;
    uvm_analysis_port #(cache_item)                  ap_checked;

    // Reference main memory: word address -> data (only written words)
    bit [31:0] ref_mem [bit [29:0]];

    // Reference cache: which word address each line holds
    bit        line_valid [NUM_LINES];
    bit [29:0] line_waddr [NUM_LINES];

    int num_checked;
    int num_errors;
    int num_reads, num_writes, num_hits;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        imp        = new("imp", this);
        ap_checked = new("ap_checked", this);
    endfunction

    // Must match the initial contents of mem_model (word w holds w * 100)
    function bit [31:0] mem_value(bit [29:0] waddr);
        return ref_mem.exists(waddr) ? ref_mem[waddr] : waddr * 100;
    endfunction

    function void check_cond(bit ok, string what, cache_item tr);
        if (ok) return;
        num_errors++;
        `uvm_error("SCB", {what, " | ", tr.convert2string()})
    endfunction

    // Called by the monitor's analysis port, once per completed transaction
    function void write(cache_item tr);
        bit [29:0] waddr = tr.addr[31:2];
        int        idx   = tr.addr[2 +: INDEX_BITS];
        bit        hit   = line_valid[idx] && (line_waddr[idx] == waddr);

        if (hit)                     tr.outcome = HIT;
        else if (!line_valid[idx])   tr.outcome = MISS_COLD;
        else                         tr.outcome = MISS_CONFLICT;

        if (tr.we) begin
            num_writes++;
            check_cond(tr.mem_writes == 1 && tr.mem_reads == 0,
                  "write did not do exactly one memory write", tr);
            check_cond(tr.mem_addr == tr.addr && tr.mem_wdata == tr.wdata,
                  "memory write has the wrong address or data", tr);
            ref_mem[waddr] = tr.wdata;           // no-write-allocate: cache state unchanged
        end else begin
            num_reads++;
            if (hit) begin
                num_hits++;
                check_cond(tr.mem_reads == 0 && tr.mem_writes == 0,
                      "read hit accessed memory", tr);
                check_cond(tr.cycles == 1, "read hit took more than 1 cycle", tr);
            end else begin
                check_cond(tr.mem_reads == 1 && tr.mem_writes == 0,
                      "read miss did not do exactly one memory read", tr);
                check_cond(tr.mem_addr == tr.addr, "read miss fetched the wrong address", tr);
                line_valid[idx] = 1'b1;           // the line now holds this word
                line_waddr[idx] = waddr;
            end
            check_cond(tr.rdata == mem_value(waddr),
                  $sformatf("read data mismatch, expected %0d", mem_value(waddr)), tr);
        end

        num_checked++;
        ap_checked.write(tr);
    endfunction

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info("SCB", $sformatf({"\n--------------------------------------------\n",
                  " Transactions : %0d\n",
                  " Reads        : %0d (hits %0d, misses %0d)\n",
                  " Writes       : %0d\n",
                  " Errors       : %0d\n",
                  " RESULT       : %s\n",
                  "--------------------------------------------"},
                  num_checked, num_reads, num_hits, num_reads - num_hits,
                  num_writes, num_errors, (num_errors == 0) ? "PASS" : "FAIL"), UVM_NONE)
    endfunction

endclass

// ============================================================
// cache_coverage.sv
// ============================================================
// Functional coverage, sampled on every transaction the scoreboard has checked.
class cache_coverage extends uvm_subscriber #(cache_item);

    `uvm_component_utils(cache_coverage)

    // Sampled values
    bit                    is_write;
    cache_outcome_e        outcome;
    bit [INDEX_BITS-1:0]   index;
    bit                    is_far;

    covergroup cg;
        option.per_instance = 1;

        cp_op: coverpoint is_write {
            bins read  = {0};
            bins write = {1};
        }
        cp_outcome: coverpoint outcome {
            bins hit           = {HIT};
            bins miss_cold     = {MISS_COLD};
            bins miss_conflict = {MISS_CONFLICT};
        }
        cp_index: coverpoint index;
        cp_far: coverpoint is_far {
            bins near = {0};
            bins far  = {1};
        }

        x_op_outcome: cross cp_op, cp_outcome;
        x_far_outcome: cross cp_far, cp_outcome;
    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        cg = new();
    endfunction

    function void write(cache_item t);
        is_write = t.we;
        outcome  = t.outcome;
        index    = t.addr[2 +: INDEX_BITS];
        is_far   = (t.addr >= 32'h80);
        cg.sample();
    endfunction

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info("COV", $sformatf("functional coverage = %0.2f%%", cg.get_inst_coverage()), UVM_NONE)
    endfunction

endclass

// ============================================================
// cache_agent.sv
// ============================================================
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


// ============================================================
// cache_env.sv
// ============================================================
// Environment: agent -> scoreboard -> coverage.
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

// ============================================================
// cache_tests.sv
// ============================================================

// Base test: builds the env, runs run_sequences(), waits for the scoreboard to
// catch up, and guards against a hung DUT with a global timeout.
class cache_base_test extends uvm_test;

    `uvm_component_utils(cache_base_test)

    cache_env    env;
    int unsigned num_txns   = 500;
    int unsigned max_cycles = 200_000;      // watchdog, in clock cycles (10 ns each)

    function new(string name = "cache_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        void'($value$plusargs("NUM_TXNS=%d", num_txns));
        env = cache_env::type_id::create("env", this);
    endfunction

    function void start_of_simulation_phase(uvm_phase phase);
        super.start_of_simulation_phase(phase);
        uvm_root::get().set_timeout(max_cycles * 10ns, 0);
    endfunction

    // Override in derived tests to pick the stimulus
    virtual task run_sequences(uvm_phase phase);
        cache_rand_seq seq = cache_rand_seq::type_id::create("seq");
        seq.num_txns = num_txns;
        seq.start(env.agent.sqr);
    endtask

    task main_phase(uvm_phase phase);
        phase.raise_objection(this);
        run_sequences(phase);
        // The last response reaches the scoreboard around the same time the sequence ends
        wait (env.scb.num_checked >= env.agent.drv.num_driven);
        phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
        uvm_report_server svr = uvm_report_server::get_server();
        super.report_phase(phase);
        if (svr.get_severity_count(UVM_ERROR) + svr.get_severity_count(UVM_FATAL) == 0)
            `uvm_info("TEST", "*** TEST PASSED ***", UVM_NONE)
        else
            `uvm_info("TEST", "*** TEST FAILED ***", UVM_NONE)
    endfunction

endclass


// Directed corner cases first, then some random traffic.
class cache_directed_test extends cache_base_test;

    `uvm_component_utils(cache_directed_test)

    function new(string name = "cache_directed_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_sequences(uvm_phase phase);
        cache_sweep_seq    sweep    = cache_sweep_seq::type_id::create("sweep");
        cache_conflict_seq conflict = cache_conflict_seq::type_id::create("conflict");
        cache_write_seq    wrs      = cache_write_seq::type_id::create("wrs");

        sweep.start(env.agent.sqr);
        conflict.start(env.agent.sqr);
        wrs.start(env.agent.sqr);
        super.run_sequences(phase);          // random traffic (num_txns)
    endtask

endclass

endpackage

`timescale 1ns/1ps

// Top: clock, interface, DUT and memory model. The UVM test is chosen with
// +UVM_TESTNAME (default below).
module tb_top;

    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import cache_uvm_pkg::*;

    logic clk = 0;
    always #5 clk = ~clk;

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

    mem_model #(.LATENCY(3)) mem (
        .clk   (intf.clk),
        .rst   (intf.rst),
        .req   (intf.mem_req),
        .we    (intf.mem_we),
        .addr  (intf.mem_addr),
        .wdata (intf.mem_wdata),
        .rdata (intf.mem_rdata),
        .ready (intf.mem_ready)
    );

    initial begin
        uvm_config_db #(virtual cache_if)::set(null, "*", "vif", intf);
        run_test("cache_base_test");     // overridden by +UVM_TESTNAME=<test>
    end

endmodule
