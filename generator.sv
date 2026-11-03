// Generator: creates randomized transactions and sends them to the driver.
class generator;

    mailbox #(transaction) gen2drv;
    int                    num_txns;

    function new(mailbox #(transaction) gen2drv);
        this.gen2drv = gen2drv;
    endfunction

    task run();
        transaction tr;
        repeat (num_txns) begin
            tr = new();
            if (!tr.randomize()) $fatal(1, "[GEN] randomization failed");
            gen2drv.put(tr);
        end
    endtask

endclass
