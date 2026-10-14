`timescale 1ns / 1ps
// Fully-associative instruction TLB (4 KB pages).
// Lookup is combinational so it runs in parallel with the cache index read (the "VI" in VIPT).
// Refill comes from the page-table walker. Replacement: first invalid entry, else round-robin.
module itlb
  import icache_pkg::*;
#(
  parameter int ENTRIES = 8
)(
  input  logic             clk,
  input  logic             rst,

  input  logic [VPN_W-1:0] lookup_vpn_i,
  output logic             hit_o,
  output logic [PPN_W-1:0] ppn_o,

  input  logic             fill_en_i,
  input  logic [VPN_W-1:0] fill_vpn_i,
  input  logic [PPN_W-1:0] fill_ppn_i,

  input  logic             flush_i
);

  localparam int EW = $clog2(ENTRIES);

  logic [ENTRIES-1:0] valid_q;
  logic [VPN_W-1:0]   vpn_q [ENTRIES];
  logic [PPN_W-1:0]   ppn_q [ENTRIES];
  logic [EW-1:0]      rr_q;

  logic [ENTRIES-1:0] match;
  logic [EW-1:0]      fill_slot;
  logic               any_free;

  // --------------------------------------------------------
  // CAM lookup
  // --------------------------------------------------------
  always_comb begin
    ppn_o = '0;
    for (int e = 0; e < ENTRIES; e++) begin
      match[e] = valid_q[e] & (vpn_q[e] == lookup_vpn_i);
      if (match[e]) ppn_o = ppn_o | ppn_q[e];
    end
  end
  assign hit_o = |match;

  // --------------------------------------------------------
  // Victim select
  // --------------------------------------------------------
  always_comb begin
    any_free  = 1'b0;
    fill_slot = rr_q;
    for (int e = ENTRIES - 1; e >= 0; e--) begin
      if (!valid_q[e]) begin
        any_free  = 1'b1;
        fill_slot = e[EW-1:0];
      end
    end
  end

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      valid_q <= '0;
      rr_q    <= '0;
    end else if (flush_i) begin
      valid_q <= '0;
    end else if (fill_en_i) begin
      valid_q[fill_slot] <= 1'b1;
      vpn_q[fill_slot]   <= fill_vpn_i;
      ppn_q[fill_slot]   <= fill_ppn_i;
      if (!any_free) rr_q <= rr_q + 1'b1;
    end
  end

endmodule
