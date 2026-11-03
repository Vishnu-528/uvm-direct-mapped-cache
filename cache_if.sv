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

endinterface
