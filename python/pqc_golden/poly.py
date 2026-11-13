"""Pointwise (NTT-domain) multiply and full polynomial multiply mod x^256 + 1.

ML-DSA: the NTT is complete, so pointwise multiply is one product per coefficient.
ML-KEM: the NTT stops one level early, so f_hat holds 128 degree-1 pieces
(f_hat[2i], f_hat[2i+1]) and each pair is multiplied modulo x^2 - gamma_i
(FIPS 203 Algorithms 11-12), with gamma_i = zeta^(2*bitrev7(i) + 1).
"""

from pqc_golden.ntt import intt, ntt
from pqc_golden.params import DILITHIUM, KYBER, Scheme, bitrev


def kyber_gammas() -> list[int]:
    """gamma_i for pair i = 0..127, plain integers (FIPS 203 Appendix A, second table)."""
    s = KYBER
    return [pow(s.zeta, 2 * bitrev(i, 7) + 1, s.q) for i in range(128)]


def pointwise(f_hat: list[int], g_hat: list[int], s: Scheme) -> list[int]:
    q = s.q
    if s is DILITHIUM:
        return [a * b % q for a, b in zip(f_hat, g_hat)]
    if s is KYBER:
        h = [0] * 256
        for i, gamma in enumerate(kyber_gammas()):
            a0, a1 = f_hat[2 * i], f_hat[2 * i + 1]
            b0, b1 = g_hat[2 * i], g_hat[2 * i + 1]
            h[2 * i] = (a0 * b0 + a1 * b1 * gamma) % q
            h[2 * i + 1] = (a0 * b1 + a1 * b0) % q
        return h
    raise ValueError(s.name)


def multiply(f: list[int], g: list[int], s: Scheme) -> list[int]:
    """f * g mod (x^256 + 1, q) through the NTT: the operation the hardware MUL command runs."""
    return intt(pointwise(ntt(f, s), ntt(g, s), s), s)
