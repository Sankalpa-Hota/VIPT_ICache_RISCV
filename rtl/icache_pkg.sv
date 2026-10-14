`timescale 1ns / 1ps
package icache_pkg;

  // Address map
  localparam int VA_W        = 32;
  localparam int PA_W        = 32;
  localparam int PAGE_OFF_W  = 12;                 // 4 KB pages
  localparam int VPN_W       = VA_W - PAGE_OFF_W;  // 20
  localparam int PPN_W       = PA_W - PAGE_OFF_W;  // 20

  // Cache geometry: 16 KB, 4-way, 32 B lines -> 4 KB per way
  localparam int WAYS        = 4;
  localparam int WAY_W       = 2;
  localparam int LINE_BYTES  = 32;
  localparam int OFF_W       = 5;
  localparam int SETS        = 128;
  localparam int IDX_W       = 7;
  localparam int LINE_W      = LINE_BYTES * 8;     // 256
  localparam int WOFF_W      = 3;
  localparam int TAG_W       = PPN_W;              // physical tag = PA[31:12]
  localparam int LINE_ADDR_W = PA_W - OFF_W;       // 27

  // Fetch request id (lets responses come back out of order)
  localparam int ID_W        = 4;

endpackage
