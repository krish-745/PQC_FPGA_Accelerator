"""Cycle-accurate model of the NTT core (rtl/ntt_core.v, rtl/ntt_ctrl.v) for P = 1, 2, 4 butterflies.

It is the reference the RTL is checked against, cycle by cycle (see tb/tb_ntt_core.v): which butterfly
operations are issued in which cycle, which bank/address every result is written to and when, when
each pass finishes, and the total cycle count. It also proves the schedule safe: no bank is read or
written twice in one cycle, nothing is read while a write to it is still in flight, and the memory
after every pass equals the golden model.

Timing (all counts in clock cycles, cycle 0 = the cycle the start command is accepted):
  - an operation's first issue is in cycle FIRST_ISSUE = 2 (cycle 1 decodes the first group);
  - a group issued in cycle t presents its read addresses in t; the synchronous RAM / ROM data
    arrives in t + 1 and is routed to the butterflies and registered, so the butterfly inputs are
    valid in t + READ_LAT (= t + 2); the result appears BF_LAT cycles later; it is written in
    cycle t + D, D = READ_LAT + BF_LAT = 8;
  - passes run back to back: the first issue of a pass follows the last issue of the previous pass
    in the next cycle (GAP = 1). Every pass walks its indices in increasing order, so a word the next
    pass reads early was written early in the previous pass; run() proves for every configuration
    that no read ever overtakes its write (the check depends only on the schedule, not on the data);
  - done = (last issue of the final pass) + D + 1, the first cycle in which every write is visible;
    that is also the reported cycle count.

Memory: buffers A, B, C, each split into 2P banks of 128/P words. Coefficient i lives in
bank(i) = XOR of the b-bit chunks of i (b = log2(2P)) at address i >> b.
"""

from dataclasses import dataclass, field

from pqc_golden.modmul import MUL_LATENCY, butterfly, mod_add, modmul
from pqc_golden.ntt import intt_layers, ntt_layers
from pqc_golden.params import DILITHIUM, KYBER, N, Scheme
from pqc_golden.poly import kyber_gammas, pointwise

READ_LAT = 2  # synchronous RAM/ROM read, then a register after the bank-routing multiplexers
BF_LAT = 1 + MUL_LATENCY + 1  # pre-add stage, multiplier, post-add stage
D = READ_LAT + BF_LAT  # issue -> write
GAP = 1  # last issue of a pass -> first issue of the next pass
FIRST_ISSUE = 2  # start accepted in cycle 0, first group decoded in 1, issued in 2
BUFS = "ABC"


def log2(x: int) -> int:
    assert x > 0 and x & (x - 1) == 0
    return x.bit_length() - 1


def bank_of(i: int, P: int) -> int:
    b = log2(2 * P)
    mask, bank = (1 << b) - 1, 0
    for shift in range(0, 8, b):
        bank ^= (i >> shift) & mask
    return bank


def addr_of(i: int, P: int) -> int:
    return i >> log2(2 * P)


def deposit(lane: int, lane_pos: list[int], c: int, fixed_pos: list[int], extra: int = 0) -> int:
    """Build an index: lane bits go to lane_pos, counter bits to fixed_pos (both LSB first)."""
    i = extra
    for j, p in enumerate(lane_pos):
        i |= ((lane >> j) & 1) << p
    for j, p in enumerate(fixed_pos):
        i |= ((c >> j) & 1) << p
    return i


def ntt_lane_positions(k: int, P: int) -> list[int]:
    """Index bits that tell the P butterflies of one cycle apart, for butterfly bit k.

    With b = log2(2P), {k} plus these b-1 positions hit every residue mod b once, so the 2P
    indices of a cycle land in 2P different banks (each varying bit flips a different bank bit).
    """
    b = log2(2 * P)
    return [r for r in range(b) if r != k % b]


@dataclass
class Pass:
    kind: str  # FWD, INV, SCALE, PWD, K1..K5
    buf: str = "A"  # buffer for FWD/INV/SCALE
    level: int = 0  # FWD layer 1..L or INV level L..1


def op_passes(op: str, s: Scheme, buf: str = "A") -> list[Pass]:
    L = s.layers
    ntt = lambda x: [Pass("FWD", x, lv) for lv in range(1, L + 1)]  # noqa: E731
    intt = lambda x: [Pass("INV", x, lv) for lv in range(L, 0, -1)] + [Pass("SCALE", x)]  # noqa: E731
    pwm = [Pass("PWD")] if s is DILITHIUM else [Pass(f"K{j}") for j in range(1, 6)]
    if op == "NTT":
        return ntt(buf)
    if op == "INTT":
        return intt(buf)
    if op == "PWM":
        return pwm
    if op == "MUL":
        return ntt("A") + ntt("B") + pwm + intt("C")
    raise ValueError(op)


@dataclass
class Issue:
    """One butterfly operation: what lane `lane` starts in this cycle."""

    lane: int
    kind: str  # CT, GS, MAC
    u: tuple[str, int] | None  # (buffer, index) read for the u input, None = 0
    v: tuple[str, int]
    z: tuple[str, int]  # ("B", i) data operand, ("ZETA", k), ("GAMMA", p), ("NINV", 0)
    w: list[tuple[str, int]]  # destinations: [out0, out1] for CT/GS, [out0] for MAC


def pass_issues(p: Pass, s: Scheme, P: int) -> list[list[Issue]]:
    """The issue groups of a pass, one list of P Issues per cycle, in issue order."""
    b = log2(2 * P)
    groups = []
    if p.kind in ("FWD", "INV"):
        k = 8 - p.level  # butterfly partners are 2^k apart
        lane_pos = ntt_lane_positions(k, P)
        fixed = [x for x in range(8) if x != k and x not in lane_pos]
        for c in range(128 // P):
            g = []
            for lane in range(P):
                u = deposit(lane, lane_pos, c, fixed)
                v = u | 1 << k
                block = u >> (k + 1)
                zi = (1 << (p.level - 1)) + block if p.kind == "FWD" else (1 << p.level) - 1 - block
                kind = "CT" if p.kind == "FWD" else "GS"
                g.append(Issue(lane, kind, (p.buf, u), (p.buf, v), ("ZETA", zi), [(p.buf, u), (p.buf, v)]))
            groups.append(g)
    elif p.kind in ("SCALE", "PWD"):
        lane_pos = list(range(b - 1))
        fixed = list(range(b - 1, 8))
        for c in range(256 // P):
            g = []
            for lane in range(P):
                i = deposit(lane, lane_pos, c, fixed)
                if p.kind == "SCALE":
                    g.append(Issue(lane, "MAC", None, (p.buf, i), ("NINV", 0), [(p.buf, i)]))
                else:
                    g.append(Issue(lane, "MAC", None, ("A", i), ("B", i), [("C", i)]))
            groups.append(g)
    else:  # Kyber base-case multiply, pair p_ = 0..127 holds indices 2p_, 2p_+1
        lane_pos = list(range(b - 1))
        fixed = list(range(b - 1, 7))
        for c in range(128 // P):
            g = []
            for lane in range(P):
                pr = deposit(lane, lane_pos, c, fixed)
                e, o = 2 * pr, 2 * pr + 1
                g.append(
                    {
                        "K1": Issue(lane, "MAC", None, ("A", o), ("B", o), [("C", e)]),  # a1*b1
                        "K2": Issue(lane, "MAC", None, ("C", e), ("GAMMA", pr), [("C", e)]),  # *gamma
                        "K3": Issue(lane, "MAC", ("C", e), ("A", e), ("B", e), [("C", e)]),  # + a0*b0
                        "K4": Issue(lane, "MAC", None, ("A", o), ("B", e), [("C", o)]),  # a1*b0
                        "K5": Issue(lane, "MAC", ("C", o), ("A", e), ("B", o), [("C", o)]),  # + a0*b1
                    }[p.kind]
                )
            groups.append(g)
    return groups


@dataclass
class Trace:
    issues: list[tuple[int, int, str, int, int]] = field(default_factory=list)  # cycle, lane, kind, u_idx, v_idx
    writes: list[tuple[int, str, int, int, int]] = field(default_factory=list)  # cycle, buf, bank, addr, data
    pass_done: list[int] = field(default_factory=list)  # cycle of each pass's last write
    total: int = 0
    snapshots: list[list[int]] = field(default_factory=list)  # buffer of each pass after its last write

    def lines(self) -> list[str]:
        """The text form shared with the RTL testbench (one record per line)."""
        out = [f"I {c} {ln} {k} {u} {v}" for c, ln, k, u, v in self.issues]
        out += [f"W {c} {b} {bk} {a} {d}" for c, b, bk, a, d in self.writes]
        out += [f"S {j} {c}" for j, c in enumerate(self.pass_done)]
        out.append(f"T {self.total}")
        return out


KIND_CODE = {"CT": 0, "GS": 1, "MAC": 2}


def run(
    op: str, s: Scheme, P: int, mem: dict[str, list[int]], buf: str = "A", dil_special: bool = False, gap: int = GAP
) -> Trace:
    """Simulate one operation cycle by cycle on `mem` (modified in place). `gap` = cycles from a pass's
    last issue to the next pass's first issue; the hardware uses GAP.

    Checks, every cycle: at most one read and one write per bank, no read and write of the same
    bank+address in one cycle, no read of a word whose write is still in flight, no double write.
    """
    zetas, gammas = s.zetas, kyber_gammas()
    tr = Trace()
    pending: dict[int, list[tuple[str, int, int]]] = {}  # write cycle -> [(buf, index, value)]
    in_flight: set[tuple[str, int]] = set()
    reads_at: dict[int, set[tuple[str, int]]] = {}  # cycle -> {(buf, index)} read in that cycle
    snap_due: list[tuple[int, str]] = []  # (cycle of a pass's last write, buffer it wrote)

    def commit_through(cycle: int) -> None:
        for w in sorted(c for c in pending if c <= cycle):
            used = set()
            for bname, i, val in pending.pop(w):
                key = (bname, bank_of(i, P))
                assert key not in used, f"bank write conflict {key} in cycle {w}"
                used.add(key)
                assert (bname, i) not in reads_at.get(w, set()), f"same-cycle read/write {bname}[{i}] in cycle {w}"
                mem[bname][i] = val
                in_flight.discard((bname, i))
                tr.writes.append((w, bname, bank_of(i, P), addr_of(i, P), val))
            while snap_due and snap_due[0][0] == w:  # a pass's last write just landed
                tr.snapshots.append(list(mem[snap_due.pop(0)[1]]))

    def value(x: tuple[str, int] | None) -> int:
        if x is None:
            return 0
        src, i = x
        if src in BUFS:
            return mem[src][i]
        return {"ZETA": lambda: zetas[i], "GAMMA": lambda: gammas[i], "NINV": lambda: s.n_inv}[src]()

    t = t_last = FIRST_ISSUE
    for p in op_passes(op, s, buf):
        for g in pass_issues(p, s, P):
            commit_through(t - 1)  # writes of cycles < t are visible to reads issued in t
            used = set()
            for iss in g:
                for x in (iss.u, iss.v, iss.z):
                    if x is None or x[0] not in BUFS:
                        continue
                    assert x not in in_flight, f"RAW hazard: {x[0]}[{x[1]}] read in cycle {t} before its write"
                    key = (x[0], bank_of(x[1], P))
                    assert key not in used, f"bank read conflict {key} in cycle {t}"
                    used.add(key)
                    reads_at.setdefault(t, set()).add(x)
                u, v, z = value(iss.u), value(iss.v), value(iss.z)
                if iss.kind == "MAC":
                    outs = [mod_add(u, modmul(z, v, s, dil_special), s.q)]
                else:
                    outs = list(butterfly(u, v, z, s, inverse=iss.kind == "GS", dil_special=dil_special))
                for x, o in zip(iss.w, outs):
                    assert x not in in_flight, f"double write {x}"
                    in_flight.add(x)
                    pending.setdefault(t + D, []).append((x[0], x[1], o))
                tr.issues.append((t, iss.lane, KIND_CODE[iss.kind], -1 if iss.u is None else iss.u[1], iss.v[1]))
            t_last = t
            t += 1
        tr.pass_done.append(t_last + D)
        snap_due.append((t_last + D, p.buf if p.kind in ("FWD", "INV", "SCALE") else "C"))
        t = t_last + gap
    commit_through(t_last + D)
    tr.total = t_last + D + 1
    tr.writes.sort()
    return tr


def expected_snapshots(op: str, s: Scheme, mem: dict[str, list[int]], buf: str = "A") -> list[list[int]]:
    """Golden buffer contents after every pass, from ntt.py / poly.py (not from the scheduler)."""
    q = s.q
    snaps = []

    def do_ntt(x):
        snaps.extend(ntt_layers(mem[x], s))
        mem[x] = snaps[-1]

    def do_intt(x):
        snaps.extend(intt_layers(mem[x], s))
        mem[x] = [c * s.n_inv % q for c in snaps[-1]]
        snaps.append(mem[x])

    def do_pwm():
        a, b = mem["A"], mem["B"]
        if s is DILITHIUM:
            mem["C"] = pointwise(a, b, s)
            snaps.append(mem["C"])
            return
        c = list(mem["C"])
        g = kyber_gammas()
        for pr in range(128):
            c[2 * pr] = a[2 * pr + 1] * b[2 * pr + 1] % q
        snaps.append(list(c))
        for pr in range(128):
            c[2 * pr] = c[2 * pr] * g[pr] % q
        snaps.append(list(c))
        for pr in range(128):
            c[2 * pr] = (c[2 * pr] + a[2 * pr] * b[2 * pr]) % q
        snaps.append(list(c))
        for pr in range(128):
            c[2 * pr + 1] = a[2 * pr + 1] * b[2 * pr] % q
        snaps.append(list(c))
        for pr in range(128):
            c[2 * pr + 1] = (c[2 * pr + 1] + a[2 * pr] * b[2 * pr + 1]) % q
        snaps.append(list(c))
        assert c == pointwise(a, b, s)
        mem["C"] = c

    {"NTT": lambda: do_ntt(buf), "INTT": lambda: do_intt(buf), "PWM": do_pwm}.get(
        op, lambda: (do_ntt("A"), do_ntt("B"), do_pwm(), do_intt("C"))
    )()
    return snaps


def ideal_issue_cycles(s: Scheme, P: int) -> int:
    """Butterfly operations / P for one NTT: an ideal count, not a latency (no drains, no pipeline fill)."""
    return s.layers * (N // 2) // P


__all__ = ["run", "expected_snapshots", "op_passes", "bank_of", "addr_of", "D", "KYBER", "DILITHIUM"]
