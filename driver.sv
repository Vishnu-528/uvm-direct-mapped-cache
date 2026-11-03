// Driver: turns transactions into pin activity on the CPU interface.
class driver;

    virtual cache_if       vif;
    mailbox #(transaction) gen2drv;

    function new(virtual cache_if vif, mailbox #(transaction) gen2drv);
        this.vif     = vif;
        this.gen2drv = gen2drv;
    endfunction

    task reset();
        vif.rst       <= 1'b1;
        vif.cpu_req   <= 1'b0;
        vif.cpu_we    <= 1'b0;
        vif.cpu_addr  <= '0;
        vif.cpu_wdata <= '0;
        repeat (2) @(posedge vif.clk);
        vif.rst       <= 1'b0;
        @(posedge vif.clk);
    endtask

    task run();
        transaction tr;
        forever begin
            gen2drv.get(tr);
            drive(tr);
        end
    endtask

    // One-cycle request pulse, then wait for the DUT to answer
    task drive(transaction tr);
        @(posedge vif.clk);
        vif.cpu_req   <= 1'b1;
        vif.cpu_we    <= tr.we;
        vif.cpu_addr  <= tr.addr;
        vif.cpu_wdata <= tr.wdata;
        @(posedge vif.clk);
        vif.cpu_req   <= 1'b0;
        while (!vif.cpu_ready) @(posedge vif.clk);
    endtask

endclass
