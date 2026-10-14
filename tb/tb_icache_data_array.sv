`timescale 1ns / 1ps
// Reads tests/data_array_ops.txt:  W <way> <set> <line256>  |  R <way> <set> <expected256>
module tb_icache_data_array;
  import icache_pkg::*;

  logic clk = 0;
  logic rd_en_i, wr_en_i;
  logic [WAY_W-1:0] rd_way_i, wr_way_i;
  logic [IDX_W-1:0] rd_idx_i, wr_idx_i;
  logic [LINE_W-1:0] rd_line_o, wr_line_i;

  icache_data_array dut (.*);

  always #5 clk = ~clk;

  int fd, n, errors, reads;
  string op;
  logic [31:0] w, s;
  logic [LINE_W-1:0] d;

  initial begin
    rd_en_i = 0; wr_en_i = 0; rd_way_i = '0; wr_way_i = '0;
    rd_idx_i = '0; wr_idx_i = '0; wr_line_i = '0;
    fd = $fopen("tests/data_array_ops.txt", "r");
    if (fd == 0) $fatal(1, "cannot open tests/data_array_ops.txt");
    while (!$feof(fd)) begin
      n = $fscanf(fd, "%s %h %h %h\n", op, w, s, d);
      if (n != 4) continue;
      @(negedge clk);
      if (op == "W") begin
        wr_en_i = 1; wr_way_i = w[WAY_W-1:0]; wr_idx_i = s[IDX_W-1:0]; wr_line_i = d;
      end else begin
        rd_en_i = 1; rd_way_i = w[WAY_W-1:0]; rd_idx_i = s[IDX_W-1:0];
      end
      @(negedge clk);
      wr_en_i = 0; rd_en_i = 0;
      if (op == "R") begin
        reads++;
        if (rd_line_o !== d) begin
          $error("way %0d set %0h: line mismatch", w, s);
          errors++;
        end
      end
    end
    $fclose(fd);
    if (errors == 0) $display("PASS tb_icache_data_array (%0d reads checked)", reads);
    else $display("FAIL tb_icache_data_array (%0d errors)", errors);
    $finish;
  end
endmodule
