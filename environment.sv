// Environment: builds the components, connects them with mailboxes
// and runs them in parallel.
class environment;

    generator  gen;
    driver     drv;
    monitor    mon;
    scoreboard scb;

    mailbox #(transaction) gen2drv;
    mailbox #(transaction) mon2scb;

    virtual cache_if vif;

    function new(virtual cache_if vif);
        this.vif = vif;
        gen2drv  = new();
        mon2scb  = new();
        gen      = new(gen2drv);
        drv      = new(vif, gen2drv);
        mon      = new(vif, mon2scb);
        scb      = new(mon2scb);
    endfunction

    task run(int num_txns);
        gen.num_txns = num_txns;

        drv.reset();

        fork
            gen.run();
            drv.run();
            mon.run();
            scb.run();
        join_none

        // Done once the scoreboard has checked every transaction
        wait (scb.num_checked == num_txns);
        scb.report();
    endtask

endclass
