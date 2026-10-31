import random

import pytest

from pqc_golden.ntt import intt, kyber_gammas, ntt, pointwise, polymul, schoolbook
from pqc_golden.params import DILITHIUM, KYBER, N

SCHEMES = pytest.mark.parametrize("s", [KYBER, DILITHIUM], ids=lambda s: s.name)


def rand_poly(s, rng):
    return [rng.randrange(s.q) for _ in range(N)]


def test_kyber_gammas_match_fips_203():
    # First entries of the gamma table in FIPS 203, Appendix A: 17, -17, 2761, -2761, 583, -583, ...
    assert kyber_gammas()[:8] == [17, 3312, 2761, 568, 583, 2746, 2649, 680]


def test_kyber_gammas_come_from_the_twiddle_table():
    g, z = kyber_gammas(), KYBER.zetas
    for j in range(64):
        assert g[2 * j] == z[64 + j]
        assert g[2 * j + 1] == KYBER.q - z[64 + j]


def test_ntt_of_one():
    assert ntt([1] + [0] * (N - 1), DILITHIUM) == [1] * N
    assert ntt([1] + [0] * (N - 1), KYBER) == [1, 0] * 128


@SCHEMES
def test_intt_undoes_ntt(s):
    rng = random.Random(1)
    for _ in range(20):
        f = rand_poly(s, rng)
        assert intt(ntt(f, s), s) == f
        assert ntt(intt(f, s), s) == f


@SCHEMES
def test_polymul_matches_schoolbook(s):
    rng = random.Random(2)
    for _ in range(10):
        f, g = rand_poly(s, rng), rand_poly(s, rng)
        assert polymul(f, g, s) == schoolbook(f, g, s.q)


@SCHEMES
def test_x_times_x255_is_minus_one(s):
    # The negacyclic wrap: X * X^255 = X^256 = -1 mod (X^256 + 1).
    x, x255 = [0] * N, [0] * N
    x[1], x255[255] = 1, 1
    assert polymul(x, x255, s) == [s.q - 1] + [0] * (N - 1)


@SCHEMES
def test_pointwise_is_commutative(s):
    rng = random.Random(3)
    f, g = rand_poly(s, rng), rand_poly(s, rng)
    assert pointwise(f, g, s) == pointwise(g, f, s)


@SCHEMES
def test_trace_has_one_entry_per_layer(s):
    rng = random.Random(4)
    f = rand_poly(s, rng)
    fwd, inv = [], []
    fwd_out = ntt(f, s, fwd)
    assert len(fwd) == s.layers and fwd[-1] == fwd_out
    inv_out = intt(f, s, inv)
    assert len(inv) == s.layers
    assert [x * s.n_inv % s.q for x in inv[-1]] == inv_out
