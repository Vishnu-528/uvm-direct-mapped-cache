`timescale 1ns/1ps

// Top: clock, interface, DUT, memory model and test.
module tb_top;

    import cache_tb_pkg::*;

    logic clk = 0;
    always #5 clk = ~clk;

    cache_if intf (clk);

    direct_mapped_cache dut (
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
        .req   (intf.mem_req),
        .we    (intf.mem_we),
        .addr  (intf.mem_addr),
        .wdata (intf.mem_wdata),
        .rdata (intf.mem_rdata),
        .ready (intf.mem_ready)
    );

    test t;

    initial begin
        t = new(intf);
        t.run();
        $finish;
    end

endmodule
