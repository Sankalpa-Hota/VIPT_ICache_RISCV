`timescale 1ns / 1ps
// 4-way tree pseudo-LRU, 3 bits per set.
//   b[0] : 0 -> victim in ways {0,1}, 1 -> victim in ways {2,3}
//   b[1] : victim inside {0,1}     b[2] : victim inside {2,3}
// Touching a way flips the bits on its path to point away from it.
module plru_tree
  import icache_pkg::*;
(
  input  logic             clk,
  input  logic             rst,

  input  logic [IDX_W-1:0] rd_idx_i,
  output logic [WAY_W-1:0] victim_o,

  input  logic             touch_en_i,
  input  logic [IDX_W-1:0] touch_idx_i,
  input  logic [WAY_W-1:0] touch_way_i
);

  logic [2:0] tree_q [SETS];
  logic [2:0] rd_bits;

  assign rd_bits  = tree_q[rd_idx_i];
  assign victim_o = rd_bits[0] ? {1'b1, rd_bits[2]} : {1'b0, rd_bits[1]};

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      for (int s = 0; s < SETS; s++) tree_q[s] <= '0;
    end else if (touch_en_i) begin
      if (touch_way_i[1] == 1'b0) begin
        tree_q[touch_idx_i][0] <= 1'b1;
        tree_q[touch_idx_i][1] <= ~touch_way_i[0];
      end else begin
        tree_q[touch_idx_i][0] <= 1'b0;
        tree_q[touch_idx_i][2] <= ~touch_way_i[0];
      end
    end
  end

endmodule
