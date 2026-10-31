"""Bit-exact model of the hardware modular arithmetic. The RTL has to match these step for step.

The multiplier reduces a product x = a*b < q^2 with Barrett reduction (HAC Algorithm 14.42, base 2).
For a k-bit q (k = 12 for ML-KEM, 23 for ML-DSA):

    mu   = floor(2^(2k) / q)                     constant, picked by the mode bit
    qhat = ((x >> (k - 1)) * mu) >> (k + 1)      estimate of x // q, low by at most 2
    r    = x - qhat * q                          so r < 3q, and only its low k + 2 bits are needed
    two conditional subtractions of q

Both multiplies are at most 24 x 24 bits.
"""

from functools import cache

from pqc_golden.params import Scheme


@cache
def barrett_constants(s: Scheme) -> tuple[int, int]:
    """(k, mu) for the scheme: the bit width of q and the Barrett multiplier."""
    k = s.q.bit_length()
    return k, (1 << (2 * k)) // s.q


def barrett_estimate(x: int, s: Scheme) -> int:
    """x minus the estimated multiple of q, before the corrections. Always in [0, 3q)."""
    k, mu = barrett_constants(s)
    qhat = ((x >> (k - 1)) * mu) >> (k + 1)
    return (x - qhat * s.q) & ((1 << (k + 2)) - 1)


def barrett_reduce(x: int, s: Scheme) -> int:
    """x mod q for 0 <= x < q^2, the way the hardware does it."""
    r = barrett_estimate(x, s)
    if r >= s.q:
        r -= s.q
    if r >= s.q:
        r -= s.q
    return r


def mod_mul(a: int, b: int, s: Scheme) -> int:
    return barrett_reduce(a * b, s)


def mod_add(a: int, b: int, s: Scheme) -> int:
    """a + b mod q for a, b in [0, q): one add, one compare, one conditional subtract."""
    t = a + b
    return t - s.q if t >= s.q else t


def mod_sub(a: int, b: int, s: Scheme) -> int:
    """a - b mod q for a, b in [0, q): one subtract, add q back if it went negative."""
    t = a - b
    return t + s.q if t < 0 else t
