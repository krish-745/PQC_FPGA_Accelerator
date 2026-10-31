import random

import pytest

from pqc_golden.ntt import ct_butterfly, gs_butterfly
from pqc_golden.params import DILITHIUM, KYBER
from pqc_golden.reduce import barrett_constants, barrett_estimate, barrett_reduce, mod_add, mod_mul, mod_sub

SCHEMES = pytest.mark.parametrize("s", [KYBER, DILITHIUM], ids=lambda s: s.name)


def test_barrett_constants():
    assert barrett_constants(KYBER) == (12, 5039)
    assert barrett_constants(DILITHIUM) == (23, 8396807)


def test_kyber_barrett_exhaustive():
    # Every possible product of two ML-KEM coefficients: 0 .. (q-1)^2, about 11 million values.
    q = KYBER.q
    worst = 0
    for x in range((q - 1) ** 2 + 1):
        r = barrett_estimate(x, KYBER)
        assert r % q == x % q
        worst = max(worst, r // q)
    assert worst <= 2  # never more than two corrections


def dilithium_products(rng, n):
    q = DILITHIUM.q
    xs = [0, 1, q - 1, q, q + 1, (q - 1) ** 2]
    for _ in range(n):
        m = rng.randrange(q - 1)
        xs += [m * q, m * q - 1, m * q + q - 1]  # right next to multiples of q, where the estimate is most likely off
    xs += [rng.randrange(q) * rng.randrange(q) for _ in range(n)]
    return [x for x in xs if 0 <= x <= (q - 1) ** 2]


def test_dilithium_barrett_random():
    rng = random.Random(5)
    q = DILITHIUM.q
    for x in dilithium_products(rng, 200_000):
        r = barrett_estimate(x, DILITHIUM)
        assert r < 3 * q and r % q == x % q
        assert barrett_reduce(x, DILITHIUM) == x % q


@SCHEMES
def test_mod_add_sub_exhaustive_edges(s):
    rng = random.Random(6)
    vals = [0, 1, s.q - 2, s.q - 1] + [rng.randrange(s.q) for _ in range(200)]
    for a in vals:
        for b in vals:
            assert mod_add(a, b, s) == (a + b) % s.q
            assert mod_sub(a, b, s) == (a - b) % s.q


@SCHEMES
def test_hardware_butterflies_match_golden(s):
    # The RTL builds the butterflies from mod_add, mod_sub and mod_mul; they must equal the golden ones.
    rng = random.Random(7)
    for _ in range(20_000):
        a, b, w = (rng.randrange(s.q) for _ in range(3))
        t = mod_mul(w, b, s)
        assert (mod_add(a, t, s), mod_sub(a, t, s)) == ct_butterfly(a, b, w, s.q)
        assert (mod_add(a, b, s), mod_mul(w, mod_sub(b, a, s), s)) == gs_butterfly(a, b, w, s.q)
