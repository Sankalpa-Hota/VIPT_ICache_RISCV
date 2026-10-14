`timescale 1ns / 1ps
// 16 KB, 4-way, VIPT, non-blocking instruction cache.
//
// Pipeline
//   S0 (index)   : VA[11:5] reads all 4 tag ways. Index bits sit inside the page offset,
//                  so no translation is needed yet and there is no synonym/alias problem.
//   S1 (compare) : ITLB translates VA[31:12] -> PPN in parallel with the tag SRAM output,
//                  4 tags compared against the PPN.
//                    hit           -> read only the hit way from the data SRAM, touch PLRU
//                    miss          -> allocate an MSHR (or merge into one) and retire,
//                                     so later fetches can still hit (hit-under-miss)
//                    TLB miss      -> stall, walk via PTW, retry
//                    no resources  -> stall in S1
//   S2 (data)    : pick the 32-bit word from the line, respond with the request id.
//
// Port priority on the arrays: refill write > S1 re-read > new S0 read.
// Any S1 request that was in flight while a refill wrote the arrays re-reads its tags,
// so it never compares against stale tags (prevents installing a line twice).
module icache_top
  import icache_pkg::*;
#(
  parameter int TLB_ENTRIES  = 8,
  parameter int MSHR_ENTRIES = 2,
  parameter int MSHR_TARGETS = 4,
  localparam int MID_W       = $clog2(MSHR_ENTRIES)
)(
  input  logic              clk,
  input  logic              rst,

  // Fetch request
  input  logic              req_valid_i,
  output logic              req_ready_o,
  input  logic [VA_W-1:0]   req_va_i,
  input  logic [ID_W-1:0]   req_id_i,

  // Fetch response (may return out of order, match by id)
  output logic              resp_valid_o,
  output logic [ID_W-1:0]   resp_id_o,
  output logic [31:0]       resp_data_o,
  output logic              resp_fault_o,

  // Maintenance (only when idle_o is high)
  input  logic              icache_flush_i,
  input  logic              tlb_flush_i,
  output logic              idle_o,

  // Page-table walker
  output logic              ptw_req_valid_o,
  output logic [VPN_W-1:0]  ptw_req_vpn_o,
  input  logic              ptw_req_ready_i,
  input  logic              ptw_resp_valid_i,
  input  logic [PPN_W-1:0]  ptw_resp_ppn_i,
  input  logic              ptw_resp_fault_i,

  // Next-level memory
  output logic              mem_req_valid_o,
  output logic [PA_W-1:0]   mem_req_addr_o,
  output logic [MID_W-1:0]  mem_req_id_o,
  input  logic              mem_req_ready_i,
  input  logic              mem_resp_valid_i,
  input  logic [MID_W-1:0]  mem_resp_id_i,
  input  logic [LINE_W-1:0] mem_resp_data_i,

  // Performance counters
  output logic [31:0]       perf_hit_o,
  output logic [31:0]       perf_miss_o,
  output logic [31:0]       perf_merge_o,
  output logic [31:0]       perf_tlb_miss_o
);

  // VIPT legality: index + offset must fit in the page offset
  initial begin
    if (IDX_W + OFF_W > PAGE_OFF_W) $fatal(1, "VIPT alias: index bits exceed page offset");
  end

  // --------------------------------------------------------
  // Pipeline registers
  // --------------------------------------------------------
  logic              s1_valid_q, s1_reread_q;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [VA_W-1:0]   s1_va_q;      // [1:0] unused, fetches are word aligned
  /* verilator lint_on UNUSEDSIGNAL */
  logic [ID_W-1:0]   s1_id_q;

  logic              s2_valid_q, s2_fault_q;
  logic [ID_W-1:0]   s2_id_q;
  logic [WOFF_W-1:0] s2_woff_q;

  // --------------------------------------------------------
  // Internal signals
  // --------------------------------------------------------
  logic [IDX_W-1:0]  s0_idx, s1_idx;
  logic [WOFF_W-1:0] s1_woff;
  logic [VPN_W-1:0]  s1_vpn;

  logic                       tag_rd_en;
  logic [IDX_W-1:0]           tag_rd_idx;
  logic [WAYS-1:0][TAG_W-1:0] tag_rd;
  logic [WAYS-1:0]            tag_vld;
  logic [LINE_W-1:0]          data_line;

  logic              tlb_hit, tlb_fill;
  logic [PPN_W-1:0]  tlb_ppn;

  logic [WAYS-1:0]   hit_vec;
  logic              s1_hit;
  logic [WAY_W-1:0]  hit_way, plru_way, victim_way;
  logic [LINE_ADDR_W-1:0] s1_line;

  logic mshr_match, mshr_match_full, mshr_free, mshr_empty;
  logic refill_we;
  logic [IDX_W-1:0]  refill_idx;
  logic [WAY_W-1:0]  refill_way;
  logic [TAG_W-1:0]  refill_tag;
  logic [LINE_W-1:0] refill_line;
  logic              tgt_valid;
  logic [ID_W-1:0]   tgt_id;
  logic [31:0]       tgt_word;

  logic s0_fire, s1_eval, s1_reread_rd, s1_tlb_miss, s1_fault;
  logic s1_do_hit, s1_do_merge, s1_do_alloc, s1_retire;

  typedef enum logic [1:0] { PTW_IDLE, PTW_REQ, PTW_WAIT } ptw_state_t;
  ptw_state_t       ptw_state_q;
  logic [VPN_W-1:0] ptw_vpn_q;
  logic             ptw_fault_q;

  assign s0_idx  = req_va_i[OFF_W +: IDX_W];
  assign s1_idx  = s1_va_q[OFF_W +: IDX_W];
  assign s1_woff = s1_va_q[2 +: WOFF_W];
  assign s1_vpn  = s1_va_q[VA_W-1:PAGE_OFF_W];

  // --------------------------------------------------------
  // S1: translation + tag compare
  // --------------------------------------------------------
  itlb #(.ENTRIES(TLB_ENTRIES)) u_itlb (
    .clk          (clk),
    .rst          (rst),
    .lookup_vpn_i (s1_vpn),
    .hit_o        (tlb_hit),
    .ppn_o        (tlb_ppn),
    .fill_en_i    (tlb_fill),
    .fill_vpn_i   (ptw_vpn_q),
    .fill_ppn_i   (ptw_resp_ppn_i),
    .flush_i      (tlb_flush_i)
  );

  always_comb begin
    hit_way    = '0;
    victim_way = plru_way;
    for (int w = WAYS - 1; w >= 0; w--) begin
      hit_vec[w] = tag_vld[w] & (tag_rd[w] == tlb_ppn);
      if (hit_vec[w]) hit_way = w[WAY_W-1:0];
      if (!tag_vld[w]) victim_way = w[WAY_W-1:0];
    end
  end
  assign s1_hit  = |hit_vec;
  assign s1_line = {tlb_ppn, s1_idx};

  assign s1_eval      = s1_valid_q & ~s1_reread_q & ~refill_we;
  assign s1_reread_rd = s1_valid_q &  s1_reread_q & ~refill_we;
  assign s1_tlb_miss  = s1_eval & ~tlb_hit;
  assign s1_fault     = s1_tlb_miss & ptw_fault_q;
  assign s1_do_hit    = s1_eval & tlb_hit &  s1_hit;
  assign s1_do_merge  = s1_eval & tlb_hit & ~s1_hit &  mshr_match & ~mshr_match_full;
  assign s1_do_alloc  = s1_eval & tlb_hit & ~s1_hit & ~mshr_match &  mshr_free;
  assign s1_retire    = s1_fault | s1_do_hit | s1_do_merge | s1_do_alloc;

  // --------------------------------------------------------
  // S0: accept a new fetch when S1 frees up and the arrays are free
  // --------------------------------------------------------
  assign req_ready_o = ~refill_we & ~s1_reread_rd & (~s1_valid_q | s1_retire) &
                       ~icache_flush_i & ~tlb_flush_i;
  assign s0_fire     = req_valid_i & req_ready_o;

  assign tag_rd_en   = s0_fire | s1_reread_rd;
  assign tag_rd_idx  = s1_reread_rd ? s1_idx : s0_idx;

  // --------------------------------------------------------
  // Arrays
  // --------------------------------------------------------
  icache_tag_array u_tag_array (
    .clk        (clk),
    .rst        (rst),
    .rd_en_i    (tag_rd_en),
    .rd_idx_i   (tag_rd_idx),
    .rd_tag_o   (tag_rd),
    .rd_valid_o (tag_vld),
    .wr_en_i    (refill_we),
    .wr_idx_i   (refill_idx),
    .wr_way_i   (refill_way),
    .wr_tag_i   (refill_tag),
    .flush_i    (icache_flush_i)
  );

  icache_data_array u_data_array (
    .clk       (clk),
    .rd_en_i   (s1_do_hit),
    .rd_way_i  (hit_way),
    .rd_idx_i  (s1_idx),
    .rd_line_o (data_line),
    .wr_en_i   (refill_we),
    .wr_way_i  (refill_way),
    .wr_idx_i  (refill_idx),
    .wr_line_i (refill_line)
  );

  plru_tree u_plru (
    .clk         (clk),
    .rst         (rst),
    .rd_idx_i    (s1_idx),
    .victim_o    (plru_way),
    .touch_en_i  (s1_do_hit | s1_do_alloc),
    .touch_idx_i (s1_idx),
    .touch_way_i (s1_do_hit ? hit_way : victim_way)
  );

  icache_mshr #(.ENTRIES(MSHR_ENTRIES), .TARGETS(MSHR_TARGETS)) u_mshr (
    .clk              (clk),
    .rst              (rst),
    .lookup_line_i    (s1_line),
    .match_o          (mshr_match),
    .match_full_o     (mshr_match_full),
    .free_o           (mshr_free),
    .empty_o          (mshr_empty),
    .alloc_i          (s1_do_alloc),
    .merge_i          (s1_do_merge),
    .alloc_way_i      (victim_way),
    .tgt_id_i         (s1_id_q),
    .tgt_woff_i       (s1_woff),
    .mem_req_valid_o  (mem_req_valid_o),
    .mem_req_addr_o   (mem_req_addr_o),
    .mem_req_id_o     (mem_req_id_o),
    .mem_req_ready_i  (mem_req_ready_i),
    .mem_resp_valid_i (mem_resp_valid_i),
    .mem_resp_id_i    (mem_resp_id_i),
    .mem_resp_data_i  (mem_resp_data_i),
    .refill_we_o      (refill_we),
    .refill_idx_o     (refill_idx),
    .refill_way_o     (refill_way),
    .refill_tag_o     (refill_tag),
    .refill_line_o    (refill_line),
    .tgt_valid_o      (tgt_valid),
    .tgt_id_o         (tgt_id),
    .tgt_word_o       (tgt_word),
    .tgt_ready_i      (~s2_valid_q)
  );

  // --------------------------------------------------------
  // S1 / S2 registers
  // --------------------------------------------------------
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      s1_valid_q  <= 1'b0;
      s1_reread_q <= 1'b0;
      s1_va_q     <= '0;
      s1_id_q     <= '0;
    end else if (s0_fire) begin
      s1_valid_q  <= 1'b1;
      s1_reread_q <= 1'b0;
      s1_va_q     <= req_va_i;
      s1_id_q     <= req_id_i;
    end else begin
      if (s1_retire)                  s1_valid_q  <= 1'b0;
      if (refill_we && s1_valid_q)    s1_reread_q <= 1'b1;
      else if (s1_reread_rd)          s1_reread_q <= 1'b0;
    end
  end

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      s2_valid_q <= 1'b0;
      s2_fault_q <= 1'b0;
      s2_id_q    <= '0;
      s2_woff_q  <= '0;
    end else begin
      s2_valid_q <= s1_do_hit | s1_fault;
      s2_fault_q <= s1_fault;
      s2_id_q    <= s1_id_q;
      s2_woff_q  <= s1_woff;
    end
  end

  // --------------------------------------------------------
  // Response mux: S2 hit/fault first, then MSHR targets
  // --------------------------------------------------------
  assign resp_valid_o = s2_valid_q | tgt_valid;
  assign resp_id_o    = s2_valid_q ? s2_id_q : tgt_id;
  assign resp_fault_o = s2_valid_q & s2_fault_q;
  assign resp_data_o  = s2_valid_q ? (s2_fault_q ? 32'h0 : data_line[s2_woff_q * 32 +: 32]) : tgt_word;

  // --------------------------------------------------------
  // Page-table walk on ITLB miss
  // --------------------------------------------------------
  assign ptw_req_valid_o = (ptw_state_q == PTW_REQ);
  assign ptw_req_vpn_o   = ptw_vpn_q;
  assign tlb_fill        = (ptw_state_q == PTW_WAIT) & ptw_resp_valid_i & ~ptw_resp_fault_i;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      ptw_state_q <= PTW_IDLE;
      ptw_vpn_q   <= '0;
      ptw_fault_q <= 1'b0;
    end else begin
      case (ptw_state_q)
        PTW_IDLE: if (s1_tlb_miss && !ptw_fault_q) begin
          ptw_state_q <= PTW_REQ;
          ptw_vpn_q   <= s1_vpn;
        end
        PTW_REQ:  if (ptw_req_ready_i) ptw_state_q <= PTW_WAIT;
        PTW_WAIT: if (ptw_resp_valid_i) begin
          ptw_state_q <= PTW_IDLE;
          ptw_fault_q <= ptw_resp_fault_i;
        end
        default:  ptw_state_q <= PTW_IDLE;
      endcase
      if (s1_fault) ptw_fault_q <= 1'b0;
    end
  end

  assign idle_o = ~s1_valid_q & ~s2_valid_q & mshr_empty & (ptw_state_q == PTW_IDLE);

  // --------------------------------------------------------
  // Performance counters
  // --------------------------------------------------------
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      perf_hit_o      <= '0;
      perf_miss_o     <= '0;
      perf_merge_o    <= '0;
      perf_tlb_miss_o <= '0;
    end else begin
      if (s1_do_hit)   perf_hit_o   <= perf_hit_o + 1;
      if (s1_do_alloc) perf_miss_o  <= perf_miss_o + 1;
      if (s1_do_merge) perf_merge_o <= perf_merge_o + 1;
      if (ptw_state_q == PTW_IDLE && s1_tlb_miss && !ptw_fault_q) perf_tlb_miss_o <= perf_tlb_miss_o + 1;
    end
  end

endmodule
