`timescale 1ns / 1ps
// Tag store: one tag SRAM per way + valid bits in flops.
// Valid bits live in flops so reset and fence.i can clear the whole cache in one cycle.
module icache_tag_array
  import icache_pkg::*;
(
  input  logic                        clk,
  input  logic                        rst,

  // Read all ways of one set (data valid next cycle)
  input  logic                        rd_en_i,
  input  logic [IDX_W-1:0]            rd_idx_i,
  output logic [WAYS-1:0][TAG_W-1:0]  rd_tag_o,
  output logic [WAYS-1:0]             rd_valid_o,

  // Install one way (refill)
  input  logic                        wr_en_i,
  input  logic [IDX_W-1:0]            wr_idx_i,
  input  logic [WAY_W-1:0]            wr_way_i,
  input  logic [TAG_W-1:0]            wr_tag_i,

  // Invalidate everything (fence.i)
  input  logic                        flush_i
);

  logic [WAYS-1:0] valid_q [SETS];

  // --------------------------------------------------------
  // Tag SRAMs, write has priority over read
  // --------------------------------------------------------
  for (genvar w = 0; w < WAYS; w++) begin : g_way
    logic way_wr;
    assign way_wr = wr_en_i & (wr_way_i == w[WAY_W-1:0]);

    sram_1rw #(.DEPTH(SETS), .WIDTH(TAG_W)) u_tag_sram (
      .clk     (clk),
      .ce_i    ((rd_en_i & ~wr_en_i) | way_wr),
      .we_i    (way_wr),
      .addr_i  (wr_en_i ? wr_idx_i : rd_idx_i),
      .wdata_i (wr_tag_i),
      .rdata_o (rd_tag_o[w])
    );
  end

  // --------------------------------------------------------
  // Valid bits
  // --------------------------------------------------------
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      for (int s = 0; s < SETS; s++) valid_q[s] <= '0;
    end else if (flush_i) begin
      for (int s = 0; s < SETS; s++) valid_q[s] <= '0;
    end else if (wr_en_i) begin
      valid_q[wr_idx_i][wr_way_i] <= 1'b1;
    end
  end

  always_ff @(posedge clk or posedge rst) begin
    if (rst)                       rd_valid_o <= '0;
    else if (rd_en_i & ~wr_en_i)   rd_valid_o <= valid_q[rd_idx_i];
  end

endmodule
