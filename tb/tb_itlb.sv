`timescale 1ns / 1ps
// Reads tests/itlb_ops.txt:
//   L <vpn> <exp_hit> <exp_ppn>   lookup and check
//   F <vpn> <ppn>                 refill
//   X                             flush (sfence.vma)
module tb_itlb;
  import icache_pkg::*;

  logic clk = 0, rst;
  logic [VPN_W-1:0] lookup_vpn_i, fill_vpn_i;
  logic [PPN_W-1:0] ppn_o, fill_ppn_i;
  logic hit_o, fill_en_i, flush_i;

  itlb #(.ENTRIES(8)) dut (.*);

  always #5 clk = ~clk;

  int fd, n, errors, lookups, hits;
  string op;
  logic [31:0] v, a, b;

  initial begin
    rst = 1; fill_en_i = 0; flush_i = 0; lookup_vpn_i = '0; fill_vpn_i = '0; fill_ppn_i = '0;
    repeat (2) @(negedge clk);
    rst = 0;
    fd = $fopen("tests/itlb_ops.txt", "r");
    if (fd == 0) $fatal(1, "cannot open tests/itlb_ops.txt");
    while (!$feof(fd)) begin
      n = $fscanf(fd, "%s", op);
      if (n != 1) continue;
      @(negedge clk);
      if (op == "X") begin
        flush_i = 1;
        @(negedge clk);
        flush_i = 0;
      end else if (op == "F") begin
        n = $fscanf(fd, "%h %h\n", v, a);
        fill_en_i = 1; fill_vpn_i = v[VPN_W-1:0]; fill_ppn_i = a[PPN_W-1:0];
        @(negedge clk);
        fill_en_i = 0;
      end else begin
        n = $fscanf(fd, "%h %h %h\n", v, a, b);
        lookup_vpn_i = v[VPN_W-1:0];
        #1;
        lookups++;
        if (hit_o) hits++;
        if (hit_o !== a[0] || (a[0] && ppn_o !== b[PPN_W-1:0])) begin
          $error("vpn %h: hit=%b ppn=%h expected hit=%0d ppn=%h", v, hit_o, ppn_o, a[0], b);
          errors++;
        end
      end
    end
    $fclose(fd);
    if (errors == 0) $display("PASS tb_itlb (%0d lookups, %0d hits)", lookups, hits);
    else $display("FAIL tb_itlb (%0d errors)", errors);
    $finish;
  end
endmodule
