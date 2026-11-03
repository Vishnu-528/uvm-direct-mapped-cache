// Test: picks the configuration and starts the environment.
class test;

    environment env;
    int         num_txns = 500;

    function new(virtual cache_if vif);
        env = new(vif);
    endfunction

    task run();
        env.run(num_txns);
    endtask

endclass
