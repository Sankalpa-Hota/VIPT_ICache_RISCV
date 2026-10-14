`timescale 1ns / 1ps
// Reads tests/sram_ops.txt:  W <addr> <data>  |  R <addr> <expected>
module tb_sram_1rw;
  localparam int DEPTH = 64;
  localparam int WIDTH = 32;

  logic clk = 0;
  logic ce_i, we_i;
  logic [$clog2(DEPTH)-1:0] addr_i;
  logic [WIDTH-1:0] wdata_i, rdata_o;

  sram_1rw #(.DEPTH(DEPTH), .WIDTH(WIDTH)) dut (.*);

  always #5 clk = ~clk;

  int fd, n, errors, ops;
  string op;
  logic [31:0] a, d;

  initial begin
    ce_i = 0; we_i = 0; addr_i = '0; wdata_i = '0;
    fd = $fopen("tests/sram_ops.txt", "r");
    if (fd == 0) $fatal(1, "cannot open tests/sram_ops.txt");
    while (!$feof(fd)) begin
      n = $fscanf(fd, "%s %h %h\n", op, a, d);
      if (n != 3) continue;
      @(negedge clk);
      ce_i = 1; addr_i = a[$clog2(DEPTH)-1:0];
      we_i = (op == "W"); wdata_i = d;
      @(negedge clk);
      ce_i = 0; we_i = 0;
      if (op == "R") begin
        ops++;
        if (rdata_o !== d) begin
          $error("R addr %0h: got %h expected %h", a, rdata_o, d);
          errors++;
        end
      end
    end
    $fclose(fd);
    if (errors == 0) $display("PASS tb_sram_1rw (%0d reads checked)", ops);
    else $display("FAIL tb_sram_1rw (%0d errors)", errors);
    $finish;
  end
endmodule
