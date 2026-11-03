// Scoreboard: keeps a reference copy of main memory and checks
// that every read returns the latest value written to that address.
class scoreboard;

    mailbox #(transaction) mon2scb;

    bit [31:0] ref_mem [bit [31:0]];   // word address -> data (only written words)

    int num_checked;
    int num_errors;
    int num_reads, num_writes, num_hits;

    function new(mailbox #(transaction) mon2scb);
        this.mon2scb = mon2scb;
    endfunction

    // Must match the initial contents of mem_model (mem[i] = i * 100)
    function bit [31:0] expected(bit [31:0] addr);
        if (ref_mem.exists(addr)) return ref_mem[addr];
        return (addr >> 2) * 100;
    endfunction

    task run();
        transaction tr;
        bit [31:0]  exp;
        forever begin
            mon2scb.get(tr);

            if (tr.we) begin
                ref_mem[tr.addr] = tr.wdata;
                num_writes++;
            end else begin
                num_reads++;
                if (tr.cycles == 1) num_hits++;   // 1-cycle response = cache hit

                exp = expected(tr.addr);
                if (tr.rdata !== exp) begin
                    num_errors++;
                    $error("[SCB] MISMATCH addr=0x%08h expected=%0d got=%0d",
                           tr.addr, exp, tr.rdata);
                end
            end

            num_checked++;
        end
    endtask

    function void report();
        $display("--------------------------------------------");
        $display(" Transactions : %0d", num_checked);
        $display(" Reads        : %0d (hits %0d, misses %0d)",
                 num_reads, num_hits, num_reads - num_hits);
        $display(" Writes       : %0d", num_writes);
        $display(" Errors       : %0d", num_errors);
        $display(" RESULT       : %s", (num_errors == 0) ? "PASS" : "FAIL");
        $display("--------------------------------------------");
    endfunction

endclass
