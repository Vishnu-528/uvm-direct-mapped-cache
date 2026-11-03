// Monitor: watches the CPU interface and rebuilds each completed
// transaction (request + response) for the scoreboard.
class monitor;

    virtual cache_if       vif;
    mailbox #(transaction) mon2scb;

    function new(virtual cache_if vif, mailbox #(transaction) mon2scb);
        this.vif     = vif;
        this.mon2scb = mon2scb;
    endfunction

    task run();
        transaction tr;
        forever begin
            @(posedge vif.clk);
            if (vif.cpu_req) begin
                // Capture the request
                tr        = new();
                tr.we     = vif.cpu_we;
                tr.addr   = vif.cpu_addr;
                tr.wdata  = vif.cpu_wdata;
                tr.cycles = 0;

                // Wait for the response
                do begin
                    @(posedge vif.clk);
                    tr.cycles++;
                end while (!vif.cpu_ready);

                tr.rdata = vif.cpu_rdata;
                mon2scb.put(tr);
            end
        end
    endtask

endclass
