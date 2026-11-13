"""Fast NTT model: the loops of FIPS 203 (Algorithms 9, 10) and FIPS 204 (Algorithms 41, 42).

Butterflies run in the order the hardware will run them, so ntt_layers() gives the expected
RAM contents after every level.
"""

from pqc_golden.params import Scheme


def ntt_layers(f: list[int], s: Scheme) -> list[list[int]]:
    """Forward NTT. Returns the coefficients after each level; the last entry is the NTT (bit-reversed order)."""
    f = list(f)
    n, q = len(f), s.q
    k = 1  # position in the twiddle table
    layers = []
    for level in range(1, s.layers + 1):
        length = n >> level  # distance between the two inputs of a butterfly
        for start in range(0, n, 2 * length):  # one block per twiddle
            z = s.zetas[k]
            k += 1
            for j in range(start, start + length):
                t = z * f[j + length] % q
                f[j], f[j + length] = (f[j] + t) % q, (f[j] - t) % q
        layers.append(list(f))
    return layers


def ntt(f: list[int], s: Scheme) -> list[int]:
    return ntt_layers(f, s)[-1]


def intt(f_hat: list[int], s: Scheme) -> list[int]:
    """Inverse NTT: the forward loops run backwards, then the 1/2^layers scale."""
    return [c * s.n_inv % s.q for c in intt_layers(f_hat, s)[-1]]


def intt_layers(f_hat: list[int], s: Scheme) -> list[list[int]]:
    """Inverse NTT without the final scale. Returns the coefficients after each level (level = layers first)."""
    f = list(f_hat)
    n, q = len(f), s.q
    layers = []
    k = 2**s.layers - 1  # read the forward twiddle table backwards
    for level in range(s.layers, 0, -1):
        length = n >> level
        for start in range(0, n, 2 * length):
            z = s.zetas[k]
            k -= 1
            for j in range(start, start + length):
                t = f[j]
                f[j] = (t + f[j + length]) % q
                # Needs (u - v) / z_partner; the table read backwards holds -1/z_partner, hence (v - u) * z.
                f[j + length] = z * (f[j + length] - t) % q
        layers.append(list(f))
    return layers
