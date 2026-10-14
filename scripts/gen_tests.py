#!/usr/bin/env python3
"""Generate the .txt stimulus/expected files used by the testbenches in tb/.

Usage: python3 scripts/gen_tests.py [seed]
"""
import os
import random
import sys

SEED = int(sys.argv[1]) if len(sys.argv) > 1 else 1
random.seed(SEED)
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests")
os.makedirs(OUT, exist_ok=True)

SETS, WAYS = 128, 4


def write(name, lines):
    with open(os.path.join(OUT, name), "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{name}: {len(lines)} lines")


# ---------------------------------------------------------------- sram_1rw
def gen_sram():
    depth, mem, lines = 64, {}, []
    for _ in range(400):
        a = random.randrange(depth)
        if random.random() < 0.5 or a not in mem:
            d = random.getrandbits(32)
            mem[a] = d
            lines.append(f"W {a:x} {d:08x}")
        else:
            lines.append(f"R {a:x} {mem[a]:08x}")
    write("sram_ops.txt", lines)


# ---------------------------------------------------------------- tag array
def gen_tag_array():
    valid = [[0] * WAYS for _ in range(SETS)]
    tags = [[0] * WAYS for _ in range(SETS)]
    lines = []
    for i in range(600):
        r = random.random()
        s = random.randrange(16)  # small set range to get re-reads
        if i == 300:
            lines.append("F")
            valid = [[0] * WAYS for _ in range(SETS)]
        elif r < 0.45:
            w, t = random.randrange(WAYS), random.getrandbits(20)
            valid[s][w], tags[s][w] = 1, t
            lines.append(f"W {s:x} {w} {t:05x}")
        else:
            vmask = sum(valid[s][w] << w for w in range(WAYS))
            ts = " ".join(f"{tags[s][w] if valid[s][w] else 0:05x}" for w in range(WAYS))
            lines.append(f"R {s:x} {vmask:x} {ts}")
    write("tag_array_ops.txt", lines)


# ---------------------------------------------------------------- data array
def gen_data_array():
    mem, lines = {}, []
    for _ in range(300):
        w, s = random.randrange(WAYS), random.randrange(8)
        if random.random() < 0.5 or (w, s) not in mem:
            d = random.getrandbits(256)
            mem[(w, s)] = d
            lines.append(f"W {w} {s:x} {d:064x}")
        else:
            lines.append(f"R {w} {s:x} {mem[(w, s)]:064x}")
    write("data_array_ops.txt", lines)


# ---------------------------------------------------------------- PLRU
def plru_victim(b):
    return (2 | b[2]) if b[0] else b[1]


def plru_touch(b, w):
    if w < 2:
        b[0], b[1] = 1, 0 if w == 1 else 1
    else:
        b[0], b[2] = 0, 0 if w == 3 else 1


def gen_plru():
    state = [[0, 0, 0] for _ in range(SETS)]
    lines = []
    for _ in range(800):
        s = random.randrange(8)
        if random.random() < 0.6:
            w = random.randrange(WAYS)
            plru_touch(state[s], w)
            lines.append(f"T {s:x} {w}")
        else:
            lines.append(f"V {s:x} {plru_victim(state[s])}")
    # property: the victim is never the most recently used way
    for _ in range(50):
        s = random.randrange(SETS)
        order = random.sample(range(WAYS), WAYS)
        for w in order:
            plru_touch(state[s], w)
            lines.append(f"T {s:x} {w}")
        assert plru_victim(state[s]) != order[-1]
        lines.append(f"V {s:x} {plru_victim(state[s])}")
    write("plru_ops.txt", lines)


# ---------------------------------------------------------------- ITLB
def gen_itlb():
    n = 8
    valid, vpn, ppn, rr = [0] * n, [0] * n, [0] * n, 0
    lines, pool = [], [random.getrandbits(20) for _ in range(14)]
    table = {v: random.getrandbits(20) for v in pool}
    for i in range(500):
        v = random.choice(pool)
        if i in (200, 400):
            valid = [0] * n
            lines.append("X")
            continue
        hit = [e for e in range(n) if valid[e] and vpn[e] == v]
        if hit:
            lines.append(f"L {v:05x} 1 {ppn[hit[0]]:05x}")
        else:
            lines.append(f"L {v:05x} 0 00000")
            free = [e for e in range(n) if not valid[e]]
            slot = free[0] if free else rr
            if not free:
                rr = (rr + 1) % n
            valid[slot], vpn[slot], ppn[slot] = 1, v, table[v]
            lines.append(f"F {v:05x} {table[v]:05x}")
    write("itlb_ops.txt", lines)


# ---------------------------------------------------------------- MSHR
def gen_mshr():
    # each line: <line_addr hex> <id> <woff>; lines repeat to create secondary misses
    pool = [random.getrandbits(27) for _ in range(6)]
    lines = []
    for i in range(200):
        line = random.choice(pool[:3]) if random.random() < 0.6 else random.choice(pool)
        lines.append(f"{line:07x} {i % 16:x} {random.randrange(8)}")
    write("mshr_misses.txt", lines)


# ---------------------------------------------------------------- full cache
def gen_top():
    # code lives in VPN 0x10..0x19 ; VPN 0x40 is unmapped (fetch fault)
    vpns = list(range(0x10, 0x1A))
    ppns = random.sample(range(0x100, 0x400), len(vpns))
    pt = dict(zip(vpns, ppns))
    write("page_table.txt", [f"{v:05x} {p:05x}" for v, p in pt.items()])

    lines = []
    funcs = [((random.choice(vpns) << 12) | (random.randrange(0, 0x1000) & ~3)) for _ in range(12)]

    def run(start, n):
        pc = start
        for _ in range(n):
            if (pc >> 12) not in pt and (pc >> 12) != 0x40:
                pc = funcs[0]
            lines.append(f"F {pc:08x}")
            pc += 4

    pc = 0x10000
    for it in range(220):
        r = random.random()
        if r < 0.45:                       # tight loop: same lines -> hits
            body = random.randint(4, 24)
            for _ in range(random.randint(2, 6)):
                run(pc, body)
        elif r < 0.85:                     # call into a function (other page / conflicting set)
            run(random.choice(funcs), random.randint(6, 30))
        else:                              # straight-line code -> sequential misses
            run(pc, random.randint(16, 64))
            pc = (pc + 0x40) & ~3
            if (pc >> 12) not in pt:
                pc = 0x10000
        if it == 90:
            lines.append("FLUSH")
        if it == 150:
            lines.append("SFENCE")
        if it in (60, 180):
            lines.append(f"F {0x40000 | 0x10:08x}")   # page fault
    write("fetch_trace.txt", lines)


if __name__ == "__main__":
    gen_sram()
    gen_tag_array()
    gen_data_array()
    gen_plru()
    gen_itlb()
    gen_mshr()
    gen_top()
