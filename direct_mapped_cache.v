`timescale 1ns/1ps
// Simple direct-mapped cache
//  - One 32-bit word per line
//  - Write-through, no-write-allocate
//  - CPU side: cpu_req is a 1-cycle pulse; wait for cpu_ready before the next request
//  - Memory side: simple req/ready handshake (hold mem_req until mem_ready)
//
// Address layout: [ tag | index | byte offset (2 bits) ]

module direct_mapped_cache #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter INDEX_BITS = 4                        // 2^4 = 16 lines
)(
    input  wire                  clk,
    input  wire                  rst,

    // CPU interface
    input  wire                  cpu_req,
    input  wire                  cpu_we,
    input  wire [ADDR_WIDTH-1:0] cpu_addr,
    input  wire [DATA_WIDTH-1:0] cpu_wdata,
    output reg  [DATA_WIDTH-1:0] cpu_rdata,
    output reg                   cpu_ready,

    // Memory interface
    output reg                   mem_req,
    output reg                   mem_we,
    output reg  [ADDR_WIDTH-1:0] mem_addr,
    output reg  [DATA_WIDTH-1:0] mem_wdata,
    input  wire [DATA_WIDTH-1:0] mem_rdata,
    input  wire                  mem_ready
);

    localparam OFFSET_BITS = 2;
    localparam TAG_BITS    = ADDR_WIDTH - INDEX_BITS - OFFSET_BITS;
    localparam NUM_LINES   = 1 << INDEX_BITS;

    // Cache storage
    reg                  valid [0:NUM_LINES-1];
    reg [TAG_BITS-1:0]   tags  [0:NUM_LINES-1];
    reg [DATA_WIDTH-1:0] data  [0:NUM_LINES-1];

    // Address decode
    wire [INDEX_BITS-1:0] index = cpu_addr[OFFSET_BITS +: INDEX_BITS];
    wire [TAG_BITS-1:0]   tag   = cpu_addr[ADDR_WIDTH-1 -: TAG_BITS];
    wire                  hit   = valid[index] && (tags[index] == tag);

    // Saved request info for the miss / write states
    reg [INDEX_BITS-1:0] req_index;
    reg [TAG_BITS-1:0]   req_tag;

    // FSM
    localparam IDLE  = 2'd0,
               READ  = 2'd1,   // waiting for memory on a read miss
               WRITE = 2'd2;   // waiting for memory on a write-through

    reg [1:0] state;
    integer i;

    always @(posedge clk) begin
        if (rst) begin
            state     <= IDLE;
            cpu_ready <= 1'b0;
            cpu_rdata <= 0;
            mem_req   <= 1'b0;
            mem_we    <= 1'b0;
            mem_addr  <= 0;
            mem_wdata <= 0;
            for (i = 0; i < NUM_LINES; i = i + 1)
                valid[i] <= 1'b0;
        end else begin
            cpu_ready <= 1'b0;                      // default: 1-cycle pulse

            case (state)
                IDLE: if (cpu_req) begin
                    req_index <= index;
                    req_tag   <= tag;

                    if (cpu_we) begin
                        // Write-through: update the line on a hit, always write memory
                        if (hit) data[index] <= cpu_wdata;
                        mem_req   <= 1'b1;
                        mem_we    <= 1'b1;
                        mem_addr  <= cpu_addr;
                        mem_wdata <= cpu_wdata;
                        state     <= WRITE;
                    end else if (hit) begin
                        // Read hit
                        cpu_rdata <= data[index];
                        cpu_ready <= 1'b1;
                    end else begin
                        // Read miss: fetch from memory
                        mem_req  <= 1'b1;
                        mem_we   <= 1'b0;
                        mem_addr <= cpu_addr;
                        state    <= READ;
                    end
                end

                READ: if (mem_ready) begin
                    valid[req_index] <= 1'b1;
                    tags [req_index] <= req_tag;
                    data [req_index] <= mem_rdata;
                    cpu_rdata        <= mem_rdata;
                    cpu_ready        <= 1'b1;
                    mem_req          <= 1'b0;
                    state            <= IDLE;
                end

                WRITE: if (mem_ready) begin
                    cpu_ready <= 1'b1;
                    mem_req   <= 1'b0;
                    mem_we    <= 1'b0;
                    state     <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
