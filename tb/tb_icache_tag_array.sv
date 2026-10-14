`timescale 1ns / 1ps
// Reads tests/tag_array_ops.txt:
//   W <set> <way> <tag>               install
//   R <set> <valid_mask> <t0..t3>     read and compare (tags only checked for valid ways)
//   F                                 flush
module tb_icache_tag_array;
  import icache_pkg::*;

  logic clk = 0, rst;
  logic rd_en_i, wr_en_i, flush_i;
  logic [IDX_W-1:0] rd_idx_i, wr_idx_i;
  logic [WAY_W-1:0] wr_way_i;
  logic [TAG_W-1:0] wr_tag_i;
  logic [WAYS-1:0][TAG_W-1:0] rd_tag_o;
  logic [WAYS-1:0] rd_valid_o;

  icache_tag_array dut (.*);

  always #5 clk = ~clk;

  int fd, n, errors, reads;
  string op;
  logic [31:0] s, w_or_mask, t [4];

  initial begin
    rst = 1; rd_en_i = 0; wr_en_i = 0; flush_i = 0;
    rd_idx_i = '0; wr_idx_i = '0; wr_way_i = '0; wr_tag_i = '0;
    repeat (2) @(negedge clk);
    rst = 0;
    fd = $fopen("tests/tag_array_ops.txt", "r");
    if (fd == 0) $fatal(1, "cannot open tests/tag_array_ops.txt");
    while (!$feof(fd)) begin
      n = $fscanf(fd, "%s", op);
      if (n != 1) continue;
      @(negedge clk);
      if (op == "F") begin
        flush_i = 1;
        @(negedge clk);
        flush_i = 0;
      end else if (op == "W") begin
        n = $fscanf(fd, "%h %h %h\n", s, w_or_mask, t[0]);
        wr_en_i = 1; wr_idx_i = s[IDX_W-1:0]; wr_way_i = w_or_mask[WAY_W-1:0]; wr_tag_i = t[0][TAG_W-1:0];
        @(negedge clk);
        wr_en_i = 0;
      end else begin
        n = $fscanf(fd, "%h %h %h %h %h %h\n", s, w_or_mask, t[0], t[1], t[2], t[3]);
        rd_en_i = 1; rd_idx_i = s[IDX_W-1:0];
        @(negedge clk);
        rd_en_i = 0;
        reads++;
        if (rd_valid_o !== w_or_mask[WAYS-1:0]) begin
          $error("set %0h: valid %b expected %b", s, rd_valid_o, w_or_mask[WAYS-1:0]);
          errors++;
        end
        for (int w = 0; w < WAYS; w++) begin
          if (w_or_mask[w] && rd_tag_o[w] !== t[w][TAG_W-1:0]) begin
            $error("set %0h way %0d: tag %h expected %h", s, w, rd_tag_o[w], t[w][TAG_W-1:0]);
            errors++;
          end
        end
      end
    end
    $fclose(fd);
    if (errors == 0) $display("PASS tb_icache_tag_array (%0d reads checked)", reads);
    else $display("FAIL tb_icache_tag_array (%0d errors)", errors);
    $finish;
  end
endmodule
