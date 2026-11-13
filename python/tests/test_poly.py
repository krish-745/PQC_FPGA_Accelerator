"""Full polynomial multiply and the inverse NTT, checked against the independent slow references."""

import random

import pytest

from pqc_golden.ntt import intt, ntt
from pqc_golden.params import DILITHIUM, KYBER, N, Scheme
from pqc_golden.poly import kyber_gammas, multiply
from pqc_golden.reference import ntt_by_definition, schoolbook_mul

SCHEMES = pytest.mark.parametrize("s", [KYBER, DILITHIUM], ids=lambda s: s.name)
rng = random.Random(203204)


def edge_polys(s: Scheme) -> dict[str, list[int]]:
    q = s.q
    basis = lambda k: [1 if i == k else 0 for i in range(N)]  # noqa: E731
    return {
        "zero": [0] * N,
        "one": basis(0),
        "x": basis(1),
        "x^255": basis(255),
        "all_q-1": [q - 1] * N,
        "alternating": [q - 1 if i % 2 else 0 for i in range(N)],
        "ramp": [i % q for i in range(N)],
        "sparse": [(q - 1 if i in (3, 77, 200) else 0) for i in range(N)],
        "random": [rng.randrange(q) for _ in range(N)],
    }


def test_kyber_gammas_match_fips_203():
    # FIPS 203 Appendix A, gamma table: 17, -17, 2761, -2761, 583, -583, 2649, -2649, ...
    assert kyber_gammas()[:8] == [17, 3312, 2761, 568, 583, 2746, 2649, 680]


@SCHEMES
def test_ntt_edge_inputs_match_definition(s):
    for name, f in edge_polys(s).items():
        assert ntt(f, s) == ntt_by_definition(f, s), name


@SCHEMES
def test_intt_matches_definition_independently(s):
    # f_hat comes from the slow definition, not from ntt(), so this checks intt() on its own:
    # it also proves the "forward table read backwards" inverse against the reference.
    for name, f in edge_polys(s).items():
        assert intt(ntt_by_definition(f, s), s) == f, name


@SCHEMES
def test_multiply_matches_schoolbook(s):
    polys = list(edge_polys(s).values())
    pairs = [(polys[i], polys[j]) for i in range(len(polys)) for j in (0, 1, 4, 8)]
    pairs += [([rng.randrange(s.q) for _ in range(N)], [rng.randrange(s.q) for _ in range(N)]) for _ in range(3)]
    for f, g in pairs:
        assert multiply(f, g, s) == schoolbook_mul(f, g, s.q)


@SCHEMES
def test_backwards_twiddle_is_minus_inverse_of_forward_partner(s):
    """Why the inverse NTT can read the forward table backwards: the entry it reads at level l, block b
    equals -1 / (the forward twiddle of the same butterfly), and the swapped subtraction (v - u)
    supplies the minus sign. See docs/arithmetic.md."""
    z = s.zetas
    for lv in range(1, s.layers + 1):
        for b in range(2 ** (lv - 1)):
            assert z[2**lv - 1 - b] * z[2 ** (lv - 1) + b] % s.q == s.q - 1
