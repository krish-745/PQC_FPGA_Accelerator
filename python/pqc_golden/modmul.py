"""Bit-exact models of the hardware modular arithmetic (rtl/mod_*.v), stage by stage.

Contract for every multiplier: for 0 <= a, b < q, return a*b mod q with 0 <= out < q.
Every intermediate is checked against the width its RTL register has, because Python's
unlimited integers would otherwise hide an overflow the hardware would have.
Widths and bounds are derived in docs/arithmetic.md.
"""

from pqc_golden.params import DILITHIUM, KYBER, Scheme

MUL_LATENCY = 4  # pipeline stages in every multiplier build (rtl/mod_mul.v)

# Barrett constants (HAC 14.42 with base 2): k = bit length of q, mu = floor(2^(2k) / q).
BARRETT = {
    "ML-KEM": dict(k=12, mu=2**24 // KYBER.q),  # mu = 5039 (13 bits)
    "ML-DSA": dict(k=23, mu=2**46 // DILITHIUM.q),  # mu = 8396807 (24 bits)
}


def fits(x: int, bits: int, name: str) -> int:
    """Assert 0 <= x < 2^bits: the value fits the unsigned register of that width."""
    assert 0 <= x < 1 << bits, f"{name} = {x} does not fit {bits} bits"
    return x


def barrett_reduce(c: int, s: Scheme) -> int:
    """c < q^2 to c mod q. Register widths are the shared ML-DSA ones (ML-KEM values fit inside)."""
    q, k, mu = s.q, BARRETT[s.name]["k"], BARRETT[s.name]["mu"]
    fits(c, 46, "c")
    assert c < q * q
    q1 = fits(c >> (k - 1), 24, "q1")  # < 2^(k+1)
    q2 = fits(q1 * mu, 48, "q2")  # 24 x 24 product
    q3 = fits(q2 >> (k + 1), 24, "q3")
    # The true difference c - q3*q lies in [0, 3q) (derived in docs/arithmetic.md 6.2), so 25 low bits are enough.
    r = (c - q3 * q) & ((1 << 25) - 1)
    assert r == c - q3 * q and r < 3 * q, "Barrett error bound broken"
    if r >= 2 * q:
        r -= 2 * q
    elif r >= q:
        r -= q
    return r


def dilithium_special_reduce(c: int) -> int:
    """c < q^2 to c mod q for q = 2^23 - 2^13 + 1, using 2^23 = 2^13 - 1 (mod q). Exact: no scale factor."""
    q = DILITHIUM.q
    fits(c, 46, "c")
    assert c < q * q

    def fold(x: int, xbits: int, out_bits: int, name: str) -> int:
        fits(x, xbits, name + "_in")
        hi, lo = x >> 23, x & ((1 << 23) - 1)
        return fits(lo + (hi << 13) - hi, out_bits, name)  # hi*2^23 -> hi*(2^13 - 1)

    r1 = fold(c, 46, 37, "r1")  # hi < 2^23, so r1 < 2^23 + 2^36
    r2 = fold(r1, 37, 28, "r2")  # hi < 2^14, so r2 < 2^23 + 2^27
    r3 = fold(r2, 28, 24, "r3")  # hi < 2^5,  so r3 < 2^23 + 2^18 < 2q
    assert r3 < 2 * q
    return r3 - q if r3 >= q else r3


def modmul(a: int, b: int, s: Scheme, dil_special: bool = False) -> int:
    """The multiplier as built: Kyber always Barrett; Dilithium Barrett or special-form (build option)."""
    assert 0 <= a < s.q and 0 <= b < s.q, "multiplier input outside [0, q)"
    c = fits(a * b, 46, "c")  # 23 x 23 product
    if s is DILITHIUM and dil_special:
        return dilithium_special_reduce(c)
    return barrett_reduce(c, s)


def mod_add(a: int, b: int, q: int) -> int:
    assert 0 <= a < q and 0 <= b < q
    t = fits(a + b, 24, "sum")
    return t - q if t >= q else t


def mod_sub(a: int, b: int, q: int) -> int:
    assert 0 <= a < q and 0 <= b < q
    t = a - b  # 24-bit two's complement in RTL; negative means add q back
    return t + q if t < 0 else t


def butterfly(u: int, v: int, z: int, s: Scheme, inverse: bool, dil_special: bool = False) -> tuple[int, int]:
    """One butterfly as rtl/butterfly.v computes it.

    forward (Cooley-Tukey, FIPS 203 Alg. 9 / FIPS 204 Alg. 41):  (u + z*v, u - z*v)
    inverse (Gentleman-Sande, as python/pqc_golden/ntt.py intt):  (u + v, z*(v - u))
    """
    q = s.q
    if inverse:
        return mod_add(u, v, q), modmul(z, mod_sub(v, u, q), s, dil_special)
    t = modmul(z, v, s, dil_special)
    return mod_add(u, t, q), mod_sub(u, t, q)
