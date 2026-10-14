`timescale 1ns / 1ps
// Reads tests/plru_ops.txt:  T <set> <way>  (touch)  |  V <set> <expected_victim>
module tb_plru_tree;
  import icache_pkg::*;

  logic clk = 0, rst;
  logic [IDX_W-1:0] rd_idx_i, touch_idx_i;
  logic [WAY_W-1:0] victim_o, touch_way_i;
  logic touch_en_i;

  plru_tree dut (.*);

  always #5 clk = ~clk;

  int fd, n, errors, checks;
  string op;
  logic [31:0] s, w;

  initial begin
    rst = 1; touch_en_i = 0; rd_idx_i = '0; touch_idx_i = '0; touch_way_i = '0;
    repeat (2) @(negedge clk);
    rst = 0;
    fd = $fopen("tests/plru_ops.txt", "r");
    if (fd == 0) $fatal(1, "cannot open tests/plru_ops.txt");
    while (!$feof(fd)) begin
      n = $fscanf(fd, "%s %h %h\n", op, s, w);
      if (n != 3) continue;
      @(negedge clk);
      if (op == "T") begin
        touch_en_i = 1; touch_idx_i = s[IDX_W-1:0]; touch_way_i = w[WAY_W-1:0];
        @(negedge clk);
        touch_en_i = 0;
      end else begin
        rd_idx_i = s[IDX_W-1:0];
        #1;
        checks++;
        if (victim_o !== w[WAY_W-1:0]) begin
          $error("set %0h: victim %0d expected %0d", s, victim_o, w);
          errors++;
        end
      end
    end
    $fclose(fd);
    if (errors == 0) $display("PASS tb_plru_tree (%0d victims checked)", checks);
    else $display("FAIL tb_plru_tree (%0d errors)", errors);
    $finish;
  end
endmodule
