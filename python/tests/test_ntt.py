import random

import pytest

from pqc_golden.ntt import intt, ntt, ntt_layers
from pqc_golden.params import DILITHIUM, KYBER, N, Scheme
from pqc_golden.reference import ntt_by_definition, schoolbook_mul

TOY = Scheme("toy", q=17, zeta=2, layers=2)  # the 4-point example worked by hand
SCHEMES = pytest.mark.parametrize("s", [KYBER, DILITHIUM], ids=lambda s: s.name)
rng = random.Random(2026)  # fixed seed, so a failure reproduces exactly


def random_poly(s: Scheme) -> list[int]:
    return [rng.randrange(s.q) for _ in range(N)]


def test_toy_matches_hand_example():
    f, g = [1, 2, 3, 4], [2, 1, 0, 5]
    assert ntt_layers(f, TOY) == [[13, 1, 6, 3], [15, 11, 13, 16]]
    assert ntt_by_definition(f, TOY) == [15, 11, 13, 16]
    assert ntt(g, TOY) == [10, 11, 3, 1]
    h_hat = [a * b % TOY.q for a, b in zip(ntt(f, TOY), ntt(g, TOY))]
    assert intt(h_hat, TOY) == [5, 7, 5, 16] == schoolbook_mul(f, g, TOY.q)


@SCHEMES
def test_ntt_matches_definition(s):
    for _ in range(3):
        f = random_poly(s)
        assert ntt(f, s) == ntt_by_definition(f, s)


@SCHEMES
def test_intt_undoes_ntt(s):
    for _ in range(10):
        f = random_poly(s)
        assert intt(ntt(f, s), s) == f


def test_dilithium_multiply_matches_schoolbook():
    # Kyber's multiply needs the base-case multiply from Part C.
    s = DILITHIUM
    for _ in range(3):
        f, g = random_poly(s), random_poly(s)
        h_hat = [a * b % s.q for a, b in zip(ntt(f, s), ntt(g, s))]
        assert intt(h_hat, s) == schoolbook_mul(f, g, s.q)
