`timescale 1ns / 1ps
// Single-port SRAM macro model: one read OR one write per cycle.
// Read data appears one cycle after the read and holds until the next read.
module sram_1rw #(
  parameter int DEPTH = 128,
  parameter int WIDTH = 32
)(
  input  logic                     clk,
  input  logic                     ce_i,
  input  logic                     we_i,
  input  logic [$clog2(DEPTH)-1:0] addr_i,
  input  logic [WIDTH-1:0]         wdata_i,
  output logic [WIDTH-1:0]         rdata_o
);

  logic [WIDTH-1:0] mem [DEPTH];

  always_ff @(posedge clk) begin
    if (ce_i) begin
      if (we_i) mem[addr_i] <= wdata_i;
      else      rdata_o     <= mem[addr_i];
    end
  end

endmodule
