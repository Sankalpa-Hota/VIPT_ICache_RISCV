`timescale 1ns / 1ps
// Data store: one SRAM of WAYS*SETS lines, addressed by {way, set}.
// Only the hit way is read (tag lookup happens one stage earlier), which saves read power.
module icache_data_array
  import icache_pkg::*;
(
  input  logic              clk,

  input  logic              rd_en_i,
  input  logic [WAY_W-1:0]  rd_way_i,
  input  logic [IDX_W-1:0]  rd_idx_i,
  output logic [LINE_W-1:0] rd_line_o,

  input  logic              wr_en_i,
  input  logic [WAY_W-1:0]  wr_way_i,
  input  logic [IDX_W-1:0]  wr_idx_i,
  input  logic [LINE_W-1:0] wr_line_i
);

  sram_1rw #(.DEPTH(WAYS * SETS), .WIDTH(LINE_W)) u_data_sram (
    .clk     (clk),
    .ce_i    (rd_en_i | wr_en_i),
    .we_i    (wr_en_i),
    .addr_i  (wr_en_i ? {wr_way_i, wr_idx_i} : {rd_way_i, rd_idx_i}),
    .wdata_i (wr_line_i),
    .rdata_o (rd_line_o)
  );

endmodule
