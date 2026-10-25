"""Constants for ML-KEM (FIPS 203) and ML-DSA (FIPS 204).

Twiddles are stored as plain integers (not Montgomery form), so they match the FIPS tables.
"""

from dataclasses import dataclass

N = 256  # coefficients per polynomial, both schemes


def bitrev(x: int, bits: int) -> int:
    """Reverse the lowest `bits` bits of x, e.g. bitrev(0b0000001, 7) == 0b1000000."""
    return int(format(x, f"0{bits}b")[::-1], 2)


@dataclass(frozen=True)
class Scheme:
    name: str
    q: int  # modulus: the "clock size"
    zeta: int  # root of unity: every twiddle is a power of it
    layers: int  # NTT levels: 7 for ML-KEM, 8 for ML-DSA

    @property
    def zetas(self) -> list[int]:
        """Twiddle table, zetas[k] = zeta^bitrev(k): the twiddles in the order the NTT loop uses them."""
        return [pow(self.zeta, bitrev(k, self.layers), self.q) for k in range(2**self.layers)]

    @property
    def n_inv(self) -> int:
        """Inverse NTT scale factor: 1 / 2^layers on the q-clock."""
        return pow(2**self.layers, -1, self.q)


KYBER = Scheme("ML-KEM", q=3329, zeta=17, layers=7)
DILITHIUM = Scheme("ML-DSA", q=8380417, zeta=1753, layers=8)
