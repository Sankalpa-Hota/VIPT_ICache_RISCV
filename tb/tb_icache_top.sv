`timescale 1ns / 1ps
// Full I-cache testbench.
//   tests/page_table.txt  : <vpn> <ppn>   (unlisted VPN -> page fault)
//   tests/fetch_trace.txt : F <va> | FLUSH (fence.i) | SFENCE (sfence.vma)
// Models: page-table walker (fixed latency) and in-order memory (random latency).
// Every response is checked by id against the expected word or fault.
module tb_icache_top;
  import icache_pkg::*;

  localparam int MSHR_ENTRIES = 2;
  localparam int MID_W = $clog2(MSHR_ENTRIES);

  logic clk = 0, rst;
  logic req_valid_i, req_ready_o;
  logic [VA_W-1:0] req_va_i;
  logic [ID_W-1:0] req_id_i, resp_id_o;
  logic resp_valid_o, resp_fault_o;
  logic [31:0] resp_data_o;
  logic icache_flush_i, tlb_flush_i, idle_o;
  logic ptw_req_valid_o, ptw_req_ready_i, ptw_resp_valid_i, ptw_resp_fault_i;
  logic [VPN_W-1:0] ptw_req_vpn_o;
  logic [PPN_W-1:0] ptw_resp_ppn_i;
  logic mem_req_valid_o, mem_req_ready_i, mem_resp_valid_i;
  logic [PA_W-1:0] mem_req_addr_o;
  logic [MID_W-1:0] mem_req_id_o, mem_resp_id_i;
  logic [LINE_W-1:0] mem_resp_data_i;
  logic [31:0] perf_hit_o, perf_miss_o, perf_merge_o, perf_tlb_miss_o;

  icache_top #(.TLB_ENTRIES(8), .MSHR_ENTRIES(MSHR_ENTRIES), .MSHR_TARGETS(4)) dut (.*);

  always #5 clk = ~clk;

  function automatic logic [31:0] mem_word(input logic [PA_W-1:0] pa);
    return {pa[31:2], 2'b00} ^ 32'h1234_5678;
  endfunction

  // ---------------- page table ----------------
  logic [VPN_W-1:0] pt_vpn [64];
  logic [PPN_W-1:0] pt_ppn [64];
  int pt_n;

  function automatic bit pt_mapped(input logic [VPN_W-1:0] vpn);
    for (int i = 0; i < pt_n; i++) if (pt_vpn[i] == vpn) return 1;
    return 0;
  endfunction

  function automatic logic [PPN_W-1:0] pt_ppn_of(input logic [VPN_W-1:0] vpn);
    for (int i = 0; i < pt_n; i++) if (pt_vpn[i] == vpn) return pt_ppn[i];
    return '0;
  endfunction

  // ---------------- PTW model ----------------
  int ptw_cnt;
  logic [VPN_W-1:0] ptw_vpn;
  logic ptw_busy;

  assign ptw_req_ready_i = !ptw_busy;

  always @(posedge clk) begin
    ptw_resp_valid_i <= 1'b0;
    if (rst) begin
      ptw_busy <= 1'b0;
    end else if (ptw_busy) begin
      ptw_cnt <= ptw_cnt - 1;
      if (ptw_cnt == 0) begin
        ptw_busy         <= 1'b0;
        ptw_resp_valid_i <= 1'b1;
        ptw_resp_fault_i <= !pt_mapped(ptw_vpn);
        ptw_resp_ppn_i   <= pt_ppn_of(ptw_vpn);
      end
    end else if (ptw_req_valid_o) begin
      ptw_busy <= 1'b1;
      ptw_cnt  <= 4;
      ptw_vpn  <= ptw_req_vpn_o;
    end
  end

  // ---------------- memory model (in order, random latency) ----------------
  logic [PA_W-1:0]  q_addr [8];
  logic [MID_W-1:0] q_id   [8];
  int q_due [8];
  int q_head, q_tail, now;

  always @(posedge clk) now <= now + 1;

  always @(negedge clk) begin
    mem_req_ready_i  <= (q_tail - q_head) < 8;
    mem_resp_valid_i <= 1'b0;
    if (q_head != q_tail && q_due[q_head % 8] <= now) begin
      mem_resp_valid_i <= 1'b1;
      mem_resp_id_i    <= q_id[q_head % 8];
      for (int k = 0; k < 8; k++) mem_resp_data_i[k*32 +: 32] <= mem_word(q_addr[q_head % 8] + 32'(4 * k));
      q_head <= q_head + 1;
    end
  end
  always @(posedge clk) if (!rst && mem_req_valid_o && mem_req_ready_i) begin
    q_addr[q_tail % 8] <= mem_req_addr_o;
    q_id[q_tail % 8]   <= mem_req_id_o;
    q_due[q_tail % 8]  <= now + 6 + ($urandom % 10);
    q_tail <= q_tail + 1;
  end

  // ---------------- scoreboard ----------------
  logic        busy_id  [16];
  logic [31:0] exp_data [16];
  logic        exp_flt  [16];
  int errors, n_req, n_resp, n_fault;

  always @(posedge clk) if (!rst && resp_valid_o) begin
    n_resp++;
    if (!busy_id[resp_id_o]) begin
      $error("response id %0d not outstanding", resp_id_o);
      errors++;
    end else if (resp_fault_o !== exp_flt[resp_id_o] ||
                 (!exp_flt[resp_id_o] && resp_data_o !== exp_data[resp_id_o])) begin
      $error("id %0d: data=%h fault=%b expected data=%h fault=%b", resp_id_o, resp_data_o,
             resp_fault_o, exp_data[resp_id_o], exp_flt[resp_id_o]);
      errors++;
    end
    if (resp_fault_o) n_fault++;
    busy_id[resp_id_o] <= 1'b0;
  end

  function automatic bit any_busy();
    for (int i = 0; i < 16; i++) if (busy_id[i]) return 1;
    return 0;
  endfunction

  task automatic wait_idle();
    do @(negedge clk); while (any_busy() || !idle_o);
  endtask

  // ---------------- driver ----------------
  int fd, n, cycles;
  string op;
  logic [31:0] va, v, p;
  logic [ID_W-1:0] next_id;
  bit ok;
  logic [PPN_W-1:0] ppn;

  initial begin
    rst = 1; req_valid_i = 0; req_va_i = '0; req_id_i = '0; next_id = '0;
    icache_flush_i = 0; tlb_flush_i = 0;
    ptw_resp_valid_i = 0; ptw_resp_fault_i = 0; ptw_resp_ppn_i = '0;
    mem_req_ready_i = 0; mem_resp_valid_i = 0; mem_resp_id_i = '0; mem_resp_data_i = '0;
    for (int i = 0; i < 16; i++) busy_id[i] = 0;

    fd = $fopen("tests/page_table.txt", "r");
    if (fd == 0) $fatal(1, "cannot open tests/page_table.txt");
    while (!$feof(fd)) begin
      n = $fscanf(fd, "%h %h\n", v, p);
      if (n == 2) begin pt_vpn[pt_n] = v[VPN_W-1:0]; pt_ppn[pt_n] = p[PPN_W-1:0]; pt_n++; end
    end
    $fclose(fd);

    repeat (3) @(negedge clk);
    rst = 0;
    cycles = now;

    fd = $fopen("tests/fetch_trace.txt", "r");
    if (fd == 0) $fatal(1, "cannot open tests/fetch_trace.txt");
    while (!$feof(fd)) begin
      n = $fscanf(fd, "%s", op);
      if (n != 1) continue;
      if (op == "FLUSH" || op == "SFENCE") begin
        wait_idle();
        if (op == "FLUSH") icache_flush_i = 1; else tlb_flush_i = 1;
        @(negedge clk);
        icache_flush_i = 0; tlb_flush_i = 0;
        continue;
      end
      n = $fscanf(fd, "%h\n", va);
      while (busy_id[next_id]) @(negedge clk);
      req_valid_i = 1; req_va_i = va; req_id_i = next_id;
      ok = pt_mapped(va[VA_W-1:PAGE_OFF_W]);
      ppn = pt_ppn_of(va[VA_W-1:PAGE_OFF_W]);
      #1;
      while (!req_ready_o) begin @(negedge clk); #1; end
      @(posedge clk);
      busy_id[next_id]  = 1;
      exp_flt[next_id]  = !ok;
      exp_data[next_id] = mem_word({ppn, va[PAGE_OFF_W-1:0]});
      next_id = next_id + 1'b1;
      n_req++;
      @(negedge clk);
      req_valid_i = 0;
    end
    $fclose(fd);
    wait_idle();
    cycles = now - cycles;

    if (n_resp != n_req) begin $error("requests %0d responses %0d", n_req, n_resp); errors++; end
    $display("fetches %0d | hits %0d | primary misses %0d | merged misses %0d | itlb walks %0d | faults %0d",
             n_req, perf_hit_o, perf_miss_o, perf_merge_o, perf_tlb_miss_o, n_fault);
    $display("hit rate %0.2f%% | %0d cycles (%0.2f fetch/cycle)",
             100.0 * real'(perf_hit_o) / real'(n_req), cycles, real'(n_req) / real'(cycles));
    if (errors == 0) $display("PASS tb_icache_top");
    else $display("FAIL tb_icache_top (%0d errors)", errors);
    $finish;
  end
endmodule
