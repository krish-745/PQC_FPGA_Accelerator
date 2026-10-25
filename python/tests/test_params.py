import pytest

from pqc_golden.params import DILITHIUM, KYBER, bitrev


def test_bitrev():
    assert bitrev(0b0000001, 7) == 0b1000000
    assert bitrev(0b0000110, 7) == 0b0110000


def test_kyber_zetas_match_fips_203():
    # First entries of the table in FIPS 203, Appendix A.
    assert KYBER.zetas[:8] == [1, 1729, 2580, 3289, 2642, 630, 1897, 848]


def test_dilithium_zetas_match_fips_204():
    # First entries of the table in FIPS 204, Appendix B. FIPS prints zetas[0] as 0 because it is never used.
    assert DILITHIUM.zetas[1:8] == [4808194, 3765607, 3761513, 5178923, 5496691, 5234739, 5178987]


@pytest.mark.parametrize("s", [KYBER, DILITHIUM], ids=lambda s: s.name)
def test_zeta_to_the_2_layers_is_minus_one(s):
    # The same property as 2^4 = -1 on the 17-clock: it is what makes the points split into +/- pairs.
    assert pow(s.zeta, 2**s.layers, s.q) == s.q - 1


def test_n_inv_matches_fips():
    assert KYBER.n_inv == 3303
    assert DILITHIUM.n_inv == 8347681
