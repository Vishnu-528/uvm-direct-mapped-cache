// Simple main memory model with a fixed latency.
// Initial contents: mem[i] = i * 100 (the scoreboard assumes the same).
module mem_model #(
    parameter LATENCY = 3,
    parameter DEPTH   = 1024
)(
    input  logic        clk,
    input  logic        req,
    input  logic        we,
    input  logic [31:0] addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    output logic        ready
);

    logic [31:0] mem [0:DEPTH-1];
    int          count;

    initial begin
        for (int i = 0; i < DEPTH; i++) mem[i] = i * 100;
        ready = 1'b0;
        rdata = '0;
        count = 0;
    end

    always @(posedge clk) begin
        ready <= 1'b0;
        if (req && !ready) begin
            if (count == LATENCY - 1) begin
                count <= 0;
                ready <= 1'b1;
                if (we) mem[addr[11:2]] <= wdata;
                else    rdata           <= mem[addr[11:2]];
            end else begin
                count <= count + 1;
            end
        end
    end

endmodule
