"""Bit-exact multiplier models against the contract a*b mod q. The exhaustive Kyber check is marked slow."""

import random

import pytest

from pqc_golden.modmul import (
    barrett_reduce,
    butterfly,
    dilithium_special_reduce,
    mod_add,
    mod_sub,
    modmul,
)
from pqc_golden.params import DILITHIUM, KYBER

rng = random.Random(46)
QD, QK = DILITHIUM.q, KYBER.q


def edge_operands(q: int) -> list[int]:
    vals = {0, 1, 2, 3, q - 1, q - 2, q // 2, q // 2 + 1}
    for e in range(1, q.bit_length()):
        vals |= {(1 << e) - 1, 1 << e, (1 << e) + 1}
    return sorted(v for v in vals if 0 <= v < q)


def edge_products(q: int) -> list[int]:
    """Reduction inputs c in [0, q^2): multiples of q +- 1, powers of two +- 1, the maximum."""
    vals = {0, 1, q - 1, q, q + 1, (q - 1) ** 2, q * q - 1}
    for m in [2, 3, 1000, q // 2, q - 2, q - 1]:
        vals |= {m * q - 1, m * q, m * q + 1}
    for e in range(1, 46):
        vals |= {(1 << e) - 1, 1 << e, (1 << e) + 1}
    vals |= {rng.randrange(q * q) for _ in range(20000)}
    return sorted(v for v in vals if 0 <= v < q * q)


@pytest.mark.parametrize("dil_special", [False, True], ids=["barrett", "special"])
def test_dilithium_reductions_on_edge_products(dil_special):
    reduce = dilithium_special_reduce if dil_special else lambda c: barrett_reduce(c, DILITHIUM)
    for c in edge_products(QD):
        assert reduce(c) == c % QD, c


@pytest.mark.parametrize("dil_special", [False, True], ids=["barrett", "special"])
def test_dilithium_multiplier_contract(dil_special):
    ops = edge_operands(QD)
    pairs = [(a, b) for a in ops for b in ops] + [(rng.randrange(QD), rng.randrange(QD)) for _ in range(100000)]
    for a, b in pairs:
        assert modmul(a, b, DILITHIUM, dil_special) == a * b % QD, (a, b)


def test_kyber_multiplier_edge_and_random():
    ops = edge_operands(QK)
    pairs = [(a, b) for a in ops for b in ops] + [(rng.randrange(QK), rng.randrange(QK)) for _ in range(100000)]
    for a, b in pairs:
        for special in (False, True):  # special-form builds still use Barrett for Kyber
            assert modmul(a, b, KYBER, special) == a * b % QK


@pytest.mark.slow
def test_kyber_multiplier_exhaustive():
    """All 3329^2 = 11,082,241 input pairs."""
    for a in range(QK):
        for b in range(QK):
            assert barrett_reduce(a * b, KYBER) == a * b % QK, (a, b)


@pytest.mark.parametrize("s", [KYBER, DILITHIUM], ids=lambda s: s.name)
def test_add_sub_and_butterfly(s):
    q = s.q
    ops = edge_operands(q)
    for a in ops:
        for b in ops:
            assert mod_add(a, b, q) == (a + b) % q
            assert mod_sub(a, b, q) == (a - b) % q
    for _ in range(20000):
        u, v, z = (rng.randrange(q) for _ in range(3))
        assert butterfly(u, v, z, s, inverse=False) == ((u + z * v) % q, (u - z * v) % q)
        assert butterfly(u, v, z, s, inverse=True) == ((u + v) % q, z * (v - u) % q)
