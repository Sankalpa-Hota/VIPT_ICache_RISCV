# VIPT Instruction Cache: Design Document

## 1. Spec at a glance

| Item | Value |
|---|---|
| Capacity | 16 KB |
| Associativity | 4-way set associative |
| Line size | 32 B (8 × 32-bit words) |
| Sets | 128 |
| Addressing | Virtually Indexed, Physically Tagged |
| Page size | 4 KB |
| Pipeline | 3 stages: index → tag compare → data |
| Replacement | Tree pseudo-LRU (3 bits/set), invalid way first |
| Translation | 8-entry fully associative ITLB + page-table-walker port |
| Non-blocking | 2 MSHRs × 4 targets (hit-under-miss, miss merging) |
| Memory side | Line request / line response, tagged by MSHR id |
| Throughput | 1 fetch/cycle on hits |

## 2. Why VIPT works here

```
 VA  31                     12 11        5 4    2 1 0
     +-------------------------+-----------+------+---+
     |          VPN            |  index    | woff |00 |
     +-------------------------+-----------+------+---+
                 |                 |
           ITLB (S1)         tag SRAM read (S0)
                 v
 PA  |          PPN  = tag     |  same bits ...    |
```

- Each way is 4 KB = one page. Index (7 bits) + offset (5 bits) = 12 bits = page offset.
- So the index is identical in the VA and the PA. The cache can start the SRAM read before translation finishes, and synonyms/aliases can't happen.
- The tag is the full PPN (20 bits). The compare happens after the TLB returns.
- `icache_top` has an elaboration check that fails if someone grows the cache so `IDX_W + OFF_W > PAGE_OFF_W`.

## 3. Block diagram

```
              req_va / req_id
                    |
        +-----------v-----------+                      +-----------+
   S0   | index = VA[11:5]      |--- rd 4 ways ------->| TAG ARRAY |  4 × (128 × 20b) SRAM
        +-----------+-----------+                      | + valid   |  valid bits in flops
                    |                                  +-----+-----+
        +-----------v-----------+   VPN   +------+           |
   S1   | tag compare (4 ways)  |<--------| ITLB |<--- PTW   | tags, valid
        | hit / miss / tlb miss |   PPN   +------+           |
        +--+--------+--------+--+                            |
           | hit    | miss   | lookup                        |
           |        v        v                               |
           |    +-------------------+  line req   +--------+ |
           |    |  MSHR (2 × 4 tgt) |------------>| MEMORY | |
           |    |  fill buffer      |<------------|        | |
           |    +----+---------+----+  line resp  +--------+ |
           |  refill |   target words                        |
           v  write  v         |                             |
        +---------------+      |  (to tag array, data array) |
   S2   |  DATA ARRAY   |      |                             |
        | 512 × 256b    |      |       +-------+             |
        +-------+-------+      |       | PLRU  | <- touch on hit / alloc
                |              |       +-------+
                v              v
             word mux ----> resp mux ----> resp_data / resp_id / resp_fault
```

## 4. Submodules

### `icache_pkg.sv`: parameters
All widths in one place: VA/PA 32b, 4 KB pages, 4 ways, 128 sets, 32 B lines, 4-bit request id.

### `sram_1rw.sv`: SRAM macro model
- Single port: one read or one write per cycle (this is what a foundry 1RW macro gives you).
- Read data comes out one cycle later and **holds** until the next read. The pipeline relies on this so a stalled S1 can keep using the tags it already read.
- Storage is uninitialized like real SRAM. Valid bits live outside it.

### `icache_tag_array.sv`: tag store
- 4 tag SRAMs (one per way), 128 × 20b each. All 4 are read in parallel for a lookup.
- Valid bits are a 128 × 4 flop array. That makes reset and `fence.i` a 1-cycle bulk clear; you can't do that with SRAM.
- A refill writes only the target way's SRAM and sets its valid bit. A write wins over a read in the same cycle.

### `icache_data_array.sv`: data store
- One 512 × 256b SRAM addressed by `{way, set}`.
- The **phased** access saves power: tags are checked in S1 and only the hit way is read in S2, instead of reading 4 × 256b every fetch. The cost is one extra stage of latency, which a fetch pipeline can hide.

### `plru_tree.sv`: replacement
- 3 bits per set: root picks a half, the two leaves pick a way.
- On a hit or a new allocation, the bits on that way's path flip to point away from it.
- Guarantee: the victim is never the most-recently-used way. It approximates true LRU (it's not exact), at 3 bits/set instead of 5.
- `icache_top` takes an invalid way first, and only uses the PLRU victim when the set is full.

### `itlb.sv`: instruction TLB
- 8 entries, fully associative CAM on VPN → PPN.
- The lookup is combinational in S1, so it runs in parallel with the tag SRAM output. This is the "VI" half of VIPT paying off.
- Refill comes from the PTW port. Replacement takes the first invalid entry, else round-robin.
- `tlb_flush_i` (sfence.vma) clears all valid bits.

### `icache_mshr.sv`: miss handling (non-blocking)
- 2 entries. Each tracks one line in flight plus up to 4 fetches waiting on it ("targets": id + word offset).
- State per entry: `IDLE → ISSUE → WAIT → DRAIN → IDLE`.
  - **ISSUE**: send line address to memory (`mem_req_id` = entry index).
  - **WAIT**: line returns. It is installed in the tag and data arrays the same cycle and copied into the entry's fill buffer.
  - **DRAIN**: returns one waiting word per cycle from the fill buffer. This is critical-word forwarding: no second array read is needed.
- **Primary miss**: a free entry is allocated with the victim way chosen in S1.
- **Secondary miss**: a fetch to a line already in ISSUE/WAIT merges in as another target, with no duplicate memory request.
- `match_full_o` (targets full) and `free_o` (no free entry) tell S1 to stall.

### `icache_top.sv`: pipeline and control
| Stage | Work |
|---|---|
| S0 | Accept the fetch, read 4 tag ways at `VA[11:5]` |
| S1 | ITLB lookup, 4-way tag compare, MSHR lookup, decide hit / merge / alloc / stall |
| S2 | Data SRAM output → 32-bit word mux → response |

S1 decision table:

| TLB | Cache | MSHR | Action |
|---|---|---|---|
| miss | — | — | stall, start PTW walk, retry (page fault → respond with `resp_fault`) |
| hit | hit | — | read hit way, touch PLRU, respond in S2 |
| hit | miss | line pending, room | merge as target, retire |
| hit | miss | no match, free entry | allocate, pick victim, touch PLRU, retire |
| hit | miss | full | stall |

Hazards and how they're handled:
- **Array port conflict.** Priority is refill write > S1 re-read > new S0 read. `req_ready_o` drops during a refill.
- **Stale tags.** If a refill writes the arrays while a request sits in S1, that request re-reads its set before deciding. Without this, S1 could compare against old tags, miss, and install the same line in a second way (a multi-hit).
- **Response port.** S2 hits/faults take priority and MSHR targets wait. Since responses can come back out of order, every response carries the request id.
- `idle_o` = nothing in S1/S2, all MSHRs idle, PTW idle. Flushes are only legal when idle.

Performance counters: hits, primary misses, merged misses, ITLB walks.

## 5. Interfaces

| Port group | Signals | Notes |
|---|---|---|
| Fetch req | `req_valid/ready, req_va[31:0], req_id[3:0]` | valid/ready handshake |
| Fetch resp | `resp_valid, resp_id, resp_data[31:0], resp_fault` | no backpressure, match by id |
| PTW | `ptw_req_valid/ready, ptw_req_vpn`, `ptw_resp_valid, ppn, fault` | one walk at a time |
| Memory | `mem_req_valid/ready, addr, id`, `mem_resp_valid, id, data[255:0]` | whole line in one beat |
| Control | `icache_flush` (fence.i), `tlb_flush` (sfence.vma), `idle` | flush only when idle |

## 6. Verification

Each module has a self-checking SV testbench driven by a `.txt` vector file in `tests/`. The files come from `scripts/gen_tests.py`, which includes a Python reference model where one is needed.

| Testbench | Input | Checks |
|---|---|---|
| `tb_sram_1rw` | `sram_ops.txt` | read-after-write data, read latency |
| `tb_icache_tag_array` | `tag_array_ops.txt` | per-way tags, valid mask, flush |
| `tb_icache_data_array` | `data_array_ops.txt` | 256-bit line read/write by {way,set} |
| `tb_plru_tree` | `plru_ops.txt` | victim vs. reference model, victim ≠ MRU |
| `tb_itlb` | `itlb_ops.txt` | hit/miss, PPN, round-robin replacement, flush |
| `tb_icache_mshr` | `mshr_misses.txt` | 1 memory request per line, merge, refill fields, every target word |
| `tb_icache_top` | `page_table.txt`, `fetch_trace.txt` | every fetch (data or fault) by id, with random memory latency, fence.i, sfence.vma |

The top-level trace has loops (hits), calls across 10 pages (set conflicts plus ITLB walks), straight-line code (sequential misses that merge), two fetches to an unmapped page (faults), one `fence.i` and one `sfence.vma`.

Result (Verilator 5.052 and Icarus 13, seed 1):

```
fetches 8662 | hits 8067 | primary misses 163 | merged misses 430 | itlb walks 28 | faults 2
hit rate 93.13% | ~10.2k cycles (0.85 fetch/cycle)
PASS tb_icache_top
```

## 7. Known limits / next steps
- Memory returns a whole line in one beat. A real bus would need a beat counter in the MSHR.
- One PTW walk at a time; the ITLB doesn't track ASIDs.
- No prefetcher. A next-line prefetch could reuse the free MSHR entry.
- Tag/data SRAM parity is not modeled.
