`timescale 1ns / 1ps
// MSHR testbench. Plays the role of the S1 stage:
//   reads tests/mshr_misses.txt (<line> <id> <woff>), allocates on a new line,
//   merges on a line already pending, waits when out of entries/targets.
// A memory model answers line requests in order after a random latency.
// Checks: one memory request per line, refill fields, every target gets the right word.
module tb_icache_mshr;
  import icache_pkg::*;

  localparam int ENTRIES = 2;
  localparam int TARGETS = 4;
  localparam int MID_W   = $clog2(ENTRIES);

  logic clk = 0, rst;
  logic [LINE_ADDR_W-1:0] lookup_line_i;
  logic match_o, match_full_o, free_o, empty_o;
  logic alloc_i, merge_i;
  logic [WAY_W-1:0] alloc_way_i;
  logic [ID_W-1:0] tgt_id_i;
  logic [WOFF_W-1:0] tgt_woff_i;
  logic mem_req_valid_o, mem_req_ready_i;
  logic [PA_W-1:0] mem_req_addr_o;
  logic [MID_W-1:0] mem_req_id_o, mem_resp_id_i;
  logic mem_resp_valid_i;
  logic [LINE_W-1:0] mem_resp_data_i;
  logic refill_we_o;
  logic [IDX_W-1:0] refill_idx_o;
  logic [WAY_W-1:0] refill_way_o;
  logic [TAG_W-1:0] refill_tag_o;
  logic [LINE_W-1:0] refill_line_o;
  logic tgt_valid_o, tgt_ready_i;
  logic [ID_W-1:0] tgt_id_o;
  logic [31:0] tgt_word_o;

  icache_mshr #(.ENTRIES(ENTRIES), .TARGETS(TARGETS)) dut (.*);

  always #5 clk = ~clk;

  function automatic logic [31:0] mem_word(input logic [LINE_ADDR_W-1:0] line, input int k);
    return ({line, 5'b0} + 32'(4 * k)) ^ 32'h1234_5678;
  endfunction

  function automatic logic [LINE_W-1:0] mem_line(input logic [LINE_ADDR_W-1:0] line);
    logic [LINE_W-1:0] l;
    for (int k = 0; k < 8; k++) l[k*32 +: 32] = mem_word(line, k);
    return l;
  endfunction

  // ---------------- scoreboard ----------------
  logic                   busy_id  [16];
  logic [LINE_ADDR_W-1:0] exp_line [16];
  logic [WOFF_W-1:0]      exp_woff [16];
  logic [LINE_ADDR_W-1:0] slot_line [ENTRIES];
  logic [WAY_W-1:0]       slot_way  [ENTRIES];
  int errors, n_alloc, n_merge, n_mem_req, n_resp;

  // ---------------- memory model (in order) ----------------
  logic [LINE_ADDR_W-1:0] q_line [8];
  logic [MID_W-1:0]       q_id   [8];
  int                     q_due  [8];
  int q_head, q_tail, now;

  always @(posedge clk) now <= now + 1;

  always @(negedge clk) begin
    mem_req_ready_i  <= ($urandom % 4) != 0;
    mem_resp_valid_i <= 1'b0;
    if (q_head != q_tail && q_due[q_head % 8] <= now) begin
      mem_resp_valid_i <= 1'b1;
      mem_resp_id_i    <= q_id[q_head % 8];
      mem_resp_data_i  <= mem_line(q_line[q_head % 8]);
      q_head <= q_head + 1;
    end
  end

  always @(posedge clk) begin
    if (!rst && mem_req_valid_o && mem_req_ready_i) begin
      q_line[q_tail % 8] <= mem_req_addr_o[PA_W-1:OFF_W];
      q_id[q_tail % 8]   <= mem_req_id_o;
      q_due[q_tail % 8]  <= now + 3 + ($urandom % 8);
      q_tail <= q_tail + 1;
      n_mem_req++;
      if (mem_req_addr_o[PA_W-1:OFF_W] !== slot_line[mem_req_id_o]) begin
        $error("mem req addr %h does not match slot %0d line", mem_req_addr_o, mem_req_id_o);
        errors++;
      end
    end
    if (!rst && refill_we_o) begin
      if ({refill_tag_o, refill_idx_o} !== slot_line[mem_resp_id_i] || refill_way_o !== slot_way[mem_resp_id_i]) begin
        $error("refill fields wrong for slot %0d", mem_resp_id_i);
        errors++;
      end
    end
    if (!rst && tgt_valid_o && tgt_ready_i) begin
      n_resp++;
      if (!busy_id[tgt_id_o]) begin
        $error("response for id %0d that is not outstanding", tgt_id_o);
        errors++;
      end else if (tgt_word_o !== mem_word(exp_line[tgt_id_o], int'(exp_woff[tgt_id_o]))) begin
        $error("id %0d: word %h expected %h", tgt_id_o, tgt_word_o, mem_word(exp_line[tgt_id_o], int'(exp_woff[tgt_id_o])));
        errors++;
      end
      busy_id[tgt_id_o] <= 1'b0;
    end
  end

  // ---------------- S1 driver ----------------
  int fd, n;
  logic [31:0] f_line, f_id, f_woff;
  bit done;

  initial begin
    rst = 1; alloc_i = 0; merge_i = 0; tgt_ready_i = 1;
    lookup_line_i = '0; alloc_way_i = '0; tgt_id_i = '0; tgt_woff_i = '0;
    mem_req_ready_i = 0; mem_resp_valid_i = 0; mem_resp_id_i = '0; mem_resp_data_i = '0;
    for (int i = 0; i < 16; i++) busy_id[i] = 0;
    repeat (3) @(negedge clk);
    rst = 0;

    fd = $fopen("tests/mshr_misses.txt", "r");
    if (fd == 0) $fatal(1, "cannot open tests/mshr_misses.txt");
    while (!$feof(fd)) begin
      n = $fscanf(fd, "%h %h %h\n", f_line, f_id, f_woff);
      if (n != 3) continue;
      done = 0;
      while (!done) begin
        @(negedge clk);
        alloc_i = 0; merge_i = 0;
        tgt_ready_i = ($urandom % 3) != 0;
        lookup_line_i = f_line[LINE_ADDR_W-1:0];
        #1;
        // same rule as icache_top: no alloc/merge in a refill cycle, id must be free
        if (!refill_we_o && !busy_id[f_id[3:0]]) begin
          if (match_o && !match_full_o) begin
            merge_i = 1; n_merge++; done = 1;
          end else if (!match_o && free_o) begin
            alloc_i = 1; n_alloc++; done = 1;
            alloc_way_i = WAY_W'($urandom);
            for (int e = ENTRIES - 1; e >= 0; e--)
              if (dut.state_q[e] == 2'd0) begin
                slot_line[e] = f_line[LINE_ADDR_W-1:0];
                slot_way[e]  = alloc_way_i;
              end
          end
          if (done) begin
            tgt_id_i = f_id[ID_W-1:0];
            tgt_woff_i = f_woff[WOFF_W-1:0];
            busy_id[f_id[3:0]] = 1;
            exp_line[f_id[3:0]] = f_line[LINE_ADDR_W-1:0];
            exp_woff[f_id[3:0]] = f_woff[WOFF_W-1:0];
          end
        end
      end
    end
    $fclose(fd);
    @(negedge clk);
    alloc_i = 0; merge_i = 0; tgt_ready_i = 1;
    repeat (200) @(negedge clk);

    if (!empty_o) begin $error("MSHR not empty at end"); errors++; end
    if (n_mem_req != n_alloc) begin
      $error("memory requests %0d != primary misses %0d", n_mem_req, n_alloc); errors++;
    end
    if (n_resp != n_alloc + n_merge) begin
      $error("responses %0d != targets %0d", n_resp, n_alloc + n_merge); errors++;
    end
    if (errors == 0) $display("PASS tb_icache_mshr (%0d primary, %0d merged, %0d responses)", n_alloc, n_merge, n_resp);
    else $display("FAIL tb_icache_mshr (%0d errors)", errors);
    $finish;
  end
endmodule
