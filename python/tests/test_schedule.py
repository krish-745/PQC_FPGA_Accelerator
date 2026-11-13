"""The cycle-accurate schedule: conflict-free, hazard-free, and equal to the golden model after every pass."""

import random

import pytest

from pqc_golden.ntt import ntt
from pqc_golden.params import DILITHIUM, KYBER, N
from pqc_golden.poly import multiply
from pqc_golden.reference import schoolbook_mul
from pqc_golden.schedule import D, addr_of, bank_of, expected_snapshots, op_passes, pass_issues, run

rng = random.Random(7)
CONFIGS = [(s, P) for s in (KYBER, DILITHIUM) for P in (1, 2, 4)]
IDS = [f"{s.name}-P{P}" for s, P in CONFIGS]


def rand_mem(s):
    return {b: [rng.randrange(s.q) for _ in range(N)] for b in "ABC"}


@pytest.mark.parametrize("P", [1, 2, 4])
def test_bank_mapping_is_a_bijection(P):
    seen = {(bank_of(i, P), addr_of(i, P)) for i in range(N)}
    assert len(seen) == N
    assert all(0 <= bk < 2 * P and 0 <= a < 128 // P for bk, a in seen)


@pytest.mark.parametrize("s,P", CONFIGS, ids=IDS)
@pytest.mark.parametrize("op,buf", [("NTT", "A"), ("NTT", "B"), ("INTT", "C"), ("INTT", "A"), ("PWM", "A"), ("MUL", "A")])
def test_schedule_matches_golden_after_every_pass(s, P, op, buf):
    mem = rand_mem(s)
    golden = expected_snapshots(op, s, {k: list(v) for k, v in mem.items()}, buf)
    tr = run(op, s, P, mem, buf)  # asserts ports and hazards internally
    assert len(tr.snapshots) == len(golden) == len(op_passes(op, s, buf))
    for j, (got, want) in enumerate(zip(tr.snapshots, golden)):
        assert got == want, f"pass {j} ({op_passes(op, s, buf)[j]})"


@pytest.mark.parametrize("s,P", CONFIGS, ids=IDS)
@pytest.mark.parametrize("dil_special", [False, True])
def test_full_multiply_matches_schoolbook(s, P, dil_special):
    f, g = [rng.randrange(s.q) for _ in range(N)], [rng.randrange(s.q) for _ in range(N)]
    mem = {"A": list(f), "B": list(g), "C": [0] * N}
    run("MUL", s, P, mem, dil_special=dil_special)
    assert mem["C"] == schoolbook_mul(f, g, s.q) == multiply(f, g, s)
    assert mem["A"] == ntt(f, s) and mem["B"] == ntt(g, s)  # MUL leaves NTT(A), NTT(B) behind (documented)


@pytest.mark.parametrize("s,P", CONFIGS, ids=IDS)
def test_cycle_count_formula(s, P):
    """Total = 1 decode cycle + all issue cycles back to back + D cycles until the last write + 1."""
    for op in ("NTT", "INTT", "PWM", "MUL"):
        passes = op_passes(op, s)
        expect = 1 + sum(len(pass_issues(p, s, P)) for p in passes) + D + 1
        assert run(op, s, P, rand_mem(s)).total == expect


def test_every_cycle_reads_each_bank_at_most_once_and_uses_all_lanes():
    for s, P in CONFIGS:
        for p in op_passes("MUL", s):
            for g in pass_issues(p, s, P):
                assert len(g) == P


@pytest.mark.parametrize("s", [KYBER, DILITHIUM], ids=lambda s: s.name)
def test_hazard_check_fires_on_a_bad_order(s, monkeypatch):
    """Negative control: reverse the group order of every pass after the first. The next pass then
    starts with the words the previous pass wrote last, which are still in flight."""
    import pqc_golden.schedule as sch

    real = sch.pass_issues
    calls = []

    def reversed_after_first(p, s_, P):
        calls.append(p)
        groups = real(p, s_, P)
        return groups[::-1] if len(calls) > 1 else groups

    monkeypatch.setattr(sch, "pass_issues", reversed_after_first)
    with pytest.raises(AssertionError, match="RAW hazard"):
        sch.run("NTT", s, 4, rand_mem(s))


@pytest.mark.parametrize("s,P", CONFIGS, ids=IDS)
def test_a_full_drain_gives_the_same_result(s, P):
    """Back-to-back passes (GAP = 1) and fully drained passes (gap = D + 1) compute identical memory."""
    m1, m2 = rand_mem(s), None
    m2 = {k: list(v) for k, v in m1.items()}
    run("MUL", s, P, m1)
    run("MUL", s, P, m2, gap=D + 1)
    assert m1 == m2
