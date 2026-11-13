"""Slow, obviously correct models, used only to check the fast ones. Shares no code with ntt.py on purpose."""

from pqc_golden.params import Scheme, bitrev


def schoolbook_mul(f: list[int], g: list[int], q: int) -> list[int]:
    """f * g the long way: every coefficient times every coefficient, folded with x^n = -1."""
    n = len(f)
    h = [0] * n
    for i in range(n):
        for j in range(n):
            if i + j < n:
                h[i + j] += f[i] * g[j]
            else:
                h[i + j - n] -= f[i] * g[j]  # x^n = -1
    return [c % q for c in h]


def ntt_by_definition(f: list[int], s: Scheme) -> list[int]:
    """The NTT from its meaning: f reduced modulo each factor x^m - gamma of x^n + 1, in bit-reversed order.

    ML-DSA: m = 1, so each entry is f evaluated at one point gamma.
    ML-KEM: m = 2 (one level short), so each pair of entries is f folded down to a degree-1 piece.
    """
    n = len(f)
    m = n >> s.layers
    out = []
    for i in range(2**s.layers):
        gamma = pow(s.zeta, 2 * bitrev(i, s.layers) + 1, s.q)
        piece = [0] * m
        for j, c in enumerate(f):
            piece[j % m] += c * pow(gamma, j // m, s.q)  # x^m = gamma, so x^j = gamma^(j//m) * x^(j%m)
        out += [c % s.q for c in piece]
    return out
