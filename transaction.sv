// Transaction: one CPU read or write request.
class transaction;

    rand bit        we;      // 1 = write, 0 = read
    rand bit [31:0] addr;
    rand bit [31:0] wdata;

    bit      [31:0] rdata;   // filled in by the monitor
    int             cycles;  // request-to-ready latency, filled in by the monitor

    // Word-aligned addresses in a small range (32 words = 2 tags per line)
    // so that hits, misses, evictions and write-then-read hits all happen often.
    constraint c_addr { addr[1:0] == 2'b00; addr < 32'h80; }

    // Mostly reads
    constraint c_we   { we dist {0 := 7, 1 := 3}; }

    function void display(string name);
        $display("[%s] %s addr=0x%08h wdata=%0d rdata=%0d cycles=%0d",
                 name, we ? "WRITE" : "READ ", addr, wdata, rdata, cycles);
    endfunction

endclass
