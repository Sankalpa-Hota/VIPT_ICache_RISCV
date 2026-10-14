`timescale 1ns / 1ps
// Miss Status Holding Registers.
// Each entry tracks one outstanding line fill and up to TARGETS fetches waiting on that line.
//   IDLE  -> ISSUE : primary miss allocates the entry
//   ISSUE -> WAIT  : line request accepted by memory
//   WAIT  -> DRAIN : line returns, installed into tag/data arrays (refill_*), kept in a fill buffer
//   DRAIN -> IDLE  : every waiting target got its word back (one per cycle)
// A secondary miss to a line already in ISSUE/WAIT merges into that entry instead of
// sending a second memory request.
module icache_mshr
  import icache_pkg::*;
#(
  parameter int ENTRIES = 2,
  parameter int TARGETS = 4,
  localparam int MID_W  = $clog2(ENTRIES),
  localparam int CNT_W  = $clog2(TARGETS + 1),
  localparam int TPTR_W = $clog2(TARGETS)
)(
  input  logic                   clk,
  input  logic                   rst,

  // Lookup from the tag-compare stage (combinational)
  input  logic [LINE_ADDR_W-1:0] lookup_line_i,
  output logic                   match_o,
  output logic                   match_full_o,
  output logic                   free_o,
  output logic                   empty_o,

  // Primary miss / secondary miss
  input  logic                   alloc_i,
  input  logic                   merge_i,
  input  logic [WAY_W-1:0]       alloc_way_i,
  input  logic [ID_W-1:0]        tgt_id_i,
  input  logic [WOFF_W-1:0]      tgt_woff_i,

  // Memory request / response (whole line in one beat)
  output logic                   mem_req_valid_o,
  output logic [PA_W-1:0]        mem_req_addr_o,
  output logic [MID_W-1:0]       mem_req_id_o,
  input  logic                   mem_req_ready_i,
  input  logic                   mem_resp_valid_i,
  input  logic [MID_W-1:0]       mem_resp_id_i,
  input  logic [LINE_W-1:0]      mem_resp_data_i,

  // Refill write into the arrays (same cycle as the memory response)
  output logic                   refill_we_o,
  output logic [IDX_W-1:0]       refill_idx_o,
  output logic [WAY_W-1:0]       refill_way_o,
  output logic [TAG_W-1:0]       refill_tag_o,
  output logic [LINE_W-1:0]      refill_line_o,

  // Responses for waiting fetches
  output logic                   tgt_valid_o,
  output logic [ID_W-1:0]        tgt_id_o,
  output logic [31:0]            tgt_word_o,
  input  logic                   tgt_ready_i
);

  typedef enum logic [1:0] {
    M_IDLE  = 2'd0,
    M_ISSUE = 2'd1,
    M_WAIT  = 2'd2,
    M_DRAIN = 2'd3
  } mshr_state_t;

  mshr_state_t            state_q   [ENTRIES];
  logic [LINE_ADDR_W-1:0] line_q    [ENTRIES];
  logic [WAY_W-1:0]       way_q     [ENTRIES];
  logic [CNT_W-1:0]       cnt_q     [ENTRIES];
  logic [TPTR_W-1:0]      head_q    [ENTRIES];
  logic [ID_W-1:0]        tid_q     [ENTRIES][TARGETS];
  logic [WOFF_W-1:0]      twoff_q   [ENTRIES][TARGETS];
  logic [LINE_W-1:0]      fbuf_q    [ENTRIES];

  logic [MID_W-1:0] match_slot, free_slot, issue_slot, drain_slot;
  logic             issue_any, drain_any;
  logic             tgt_pop;
  logic [WOFF_W-1:0] drain_woff;

  // --------------------------------------------------------
  // Lookup, free slot, issue and drain pickers (lowest slot wins)
  // --------------------------------------------------------
  always_comb begin
    match_o    = 1'b0;
    match_slot = '0;
    free_o     = 1'b0;
    free_slot  = '0;
    issue_any  = 1'b0;
    issue_slot = '0;
    drain_any  = 1'b0;
    drain_slot = '0;
    empty_o    = 1'b1;
    for (int e = ENTRIES - 1; e >= 0; e--) begin
      if ((state_q[e] == M_ISSUE || state_q[e] == M_WAIT) && line_q[e] == lookup_line_i) begin
        match_o    = 1'b1;
        match_slot = e[MID_W-1:0];
      end
      if (state_q[e] == M_IDLE) begin
        free_o    = 1'b1;
        free_slot = e[MID_W-1:0];
      end else begin
        empty_o = 1'b0;
      end
      if (state_q[e] == M_ISSUE) begin
        issue_any  = 1'b1;
        issue_slot = e[MID_W-1:0];
      end
      if (state_q[e] == M_DRAIN) begin
        drain_any  = 1'b1;
        drain_slot = e[MID_W-1:0];
      end
    end
  end

  assign match_full_o = match_o & (cnt_q[match_slot] == CNT_W'(TARGETS));

  // --------------------------------------------------------
  // Memory request
  // --------------------------------------------------------
  assign mem_req_valid_o = issue_any;
  assign mem_req_addr_o  = {line_q[issue_slot], {OFF_W{1'b0}}};
  assign mem_req_id_o    = issue_slot;

  // --------------------------------------------------------
  // Refill: install the returning line right away
  // --------------------------------------------------------
  assign refill_we_o   = mem_resp_valid_i;
  assign refill_idx_o  = line_q[mem_resp_id_i][IDX_W-1:0];
  assign refill_tag_o  = line_q[mem_resp_id_i][LINE_ADDR_W-1:IDX_W];
  assign refill_way_o  = way_q[mem_resp_id_i];
  assign refill_line_o = mem_resp_data_i;

  // --------------------------------------------------------
  // Target drain: critical word from the fill buffer
  // --------------------------------------------------------
  assign drain_woff  = twoff_q[drain_slot][head_q[drain_slot]];
  assign tgt_valid_o = drain_any;
  assign tgt_id_o    = tid_q[drain_slot][head_q[drain_slot]];
  assign tgt_word_o  = fbuf_q[drain_slot][drain_woff * 32 +: 32];
  assign tgt_pop     = drain_any & tgt_ready_i;

  // --------------------------------------------------------
  // Entry state
  // --------------------------------------------------------
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      for (int e = 0; e < ENTRIES; e++) begin
        state_q[e] <= M_IDLE;
        cnt_q[e]   <= '0;
        head_q[e]  <= '0;
      end
    end else begin
      for (int e = 0; e < ENTRIES; e++) begin
        case (state_q[e])
          M_IDLE: begin
            if (alloc_i && free_slot == e[MID_W-1:0]) begin
              state_q[e]      <= M_ISSUE;
              line_q[e]       <= lookup_line_i;
              way_q[e]        <= alloc_way_i;
              cnt_q[e]        <= CNT_W'(1);
              head_q[e]       <= '0;
              tid_q[e][0]     <= tgt_id_i;
              twoff_q[e][0]   <= tgt_woff_i;
            end
          end
          M_ISSUE, M_WAIT: begin
            if (state_q[e] == M_ISSUE && issue_slot == e[MID_W-1:0] && mem_req_ready_i)
              state_q[e] <= M_WAIT;
            if (state_q[e] == M_WAIT && mem_resp_valid_i && mem_resp_id_i == e[MID_W-1:0]) begin
              state_q[e] <= M_DRAIN;
              fbuf_q[e]  <= mem_resp_data_i;
            end
            if (merge_i && match_slot == e[MID_W-1:0]) begin
              tid_q[e][cnt_q[e][TPTR_W-1:0]]   <= tgt_id_i;
              twoff_q[e][cnt_q[e][TPTR_W-1:0]] <= tgt_woff_i;
              cnt_q[e]                         <= cnt_q[e] + 1'b1;
            end
          end
          M_DRAIN: begin
            if (tgt_pop && drain_slot == e[MID_W-1:0]) begin
              if (CNT_W'(head_q[e]) + 1'b1 == cnt_q[e]) begin
                state_q[e] <= M_IDLE;
                cnt_q[e]   <= '0;
                head_q[e]  <= '0;
              end else begin
                head_q[e]  <= head_q[e] + 1'b1;
              end
            end
          end
          default: state_q[e] <= M_IDLE;
        endcase
      end
    end
  end

endmodule
