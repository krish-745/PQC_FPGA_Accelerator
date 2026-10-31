"""NTT, inverse NTT and pointwise multiply for ML-KEM (FIPS 203) and ML-DSA (FIPS 204).

Both schemes run the same in-place loops; only q, the twiddle table and the number of layers change.
The hardware follows the same loop order, so the per-layer traces are what each RTL pass should write.
"""

from pqc_golden.params import KYBER, N, Scheme, bitrev


def ct_butterfly(a: int, b: int, w: int, q: int) -> tuple[int, int]:
    """Cooley-Tukey butterfly, used by the forward NTT: (a, b) -> (a + w*b, a - w*b)."""
    t = w * b % q
    return (a + t) % q, (a - t) % q


def gs_butterfly(a: int, b: int, w: int, q: int) -> tuple[int, int]:
    """Gentleman-Sande butterfly, used by the inverse NTT: (a, b) -> (a + b, w*(b - a))."""
    return (a + b) % q, w * (b - a) % q


def ntt(f: list[int], s: Scheme, trace: list | None = None) -> list[int]:
    """Forward NTT. FIPS 203 Algorithm 9, FIPS 204 Algorithm 41.

    Pairs are (j, j + len) with len = 128, 64, ... and one twiddle per block, read from zetas[1] upwards.
    If `trace` is a list, a copy of the polynomial after each layer is appended to it.
    """
    q, zetas = s.q, s.zetas
    f = list(f)
    k = 1
    for layer in range(s.layers):
        length = 128 >> layer
        for start in range(0, N, 2 * length):
            w = zetas[k]
            k += 1
            for j in range(start, start + length):
                f[j], f[j + length] = ct_butterfly(f[j], f[j + length], w, q)
        if trace is not None:
            trace.append(list(f))
    return f


def intt(f: list[int], s: Scheme, trace: list | None = None) -> list[int]:
    """Inverse NTT, then scale by 1/2^layers. FIPS 203 Algorithm 10, FIPS 204 Algorithm 42.

    The forward loops run backwards: len grows from 2 (ML-KEM) or 1 (ML-DSA) up to 128, and the twiddles
    are read from the top of the same table down. FIPS 204 writes the second output as -w*(a - b), which is
    the same number. `trace` gets the polynomial after each layer, before the final scale.
    """
    q, zetas = s.q, s.zetas
    f = list(f)
    k = 2**s.layers - 1
    for layer in range(s.layers):
        length = (N >> s.layers) << layer
        for start in range(0, N, 2 * length):
            w = zetas[k]
            k -= 1
            for j in range(start, start + length):
                f[j], f[j + length] = gs_butterfly(f[j], f[j + length], w, q)
        if trace is not None:
            trace.append(list(f))
    return [x * s.n_inv % q for x in f]


def kyber_gammas() -> list[int]:
    """gammas[i] = 17^(2*bitrev7(i) + 1): pair i of an ML-KEM NTT is a polynomial mod X^2 - gammas[i].

    The table in FIPS 203 Appendix A. gammas[2j] = zetas[64 + j] and gammas[2j + 1] = -zetas[64 + j],
    so the hardware reads them from the twiddle ROM and needs no second table.
    """
    return [pow(KYBER.zeta, 2 * bitrev(i, 7) + 1, KYBER.q) for i in range(128)]


def basemul(a0: int, a1: int, b0: int, b1: int, gamma: int, q: int) -> tuple[int, int]:
    """(a0 + a1*X) * (b0 + b1*X) mod (X^2 - gamma). FIPS 203 Algorithm 12."""
    return (a0 * b0 + a1 * b1 % q * gamma) % q, (a0 * b1 + a1 * b0) % q


def pointwise(f: list[int], g: list[int], s: Scheme) -> list[int]:
    """Multiply two polynomials in the NTT domain.

    ML-DSA: coefficient by coefficient. ML-KEM: basemul on each pair (FIPS 203 Algorithm 11), since its
    7-layer NTT stops at 128 degree-1 pieces.
    """
    q = s.q
    if s != KYBER:
        return [a * b % q for a, b in zip(f, g)]
    h = [0] * N
    for i, gamma in enumerate(kyber_gammas()):
        h[2 * i], h[2 * i + 1] = basemul(f[2 * i], f[2 * i + 1], g[2 * i], g[2 * i + 1], gamma, q)
    return h


def polymul(f: list[int], g: list[int], s: Scheme) -> list[int]:
    """f * g mod (X^256 + 1) the fast way: NTT both, pointwise multiply, inverse NTT. What the accelerator computes."""
    return intt(pointwise(ntt(f, s), ntt(g, s), s), s)


def schoolbook(f: list[int], g: list[int], q: int) -> list[int]:
    """f * g mod (X^256 + 1) the slow O(n^2) way. Only used to check that polymul is right."""
    c = [0] * N
    for i in range(N):
        for j in range(N):
            if i + j < N:
                c[i + j] += f[i] * g[j]
            else:
                c[i + j - N] -= f[i] * g[j]  # X^256 = -1 wraps with a sign flip
    return [x % q for x in c]
