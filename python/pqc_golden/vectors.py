"""Write the hex test vectors the Verilog testbenches read with $readmemh.

Run from the python/ folder:  python -m pqc_golden.vectors [output_dir]
The default output is the vectors/ folder at the repo root. vectors/README.md describes every file.
"""

import random
import sys
from pathlib import Path

from pqc_golden.ntt import ct_butterfly, gs_butterfly, intt, ntt, pointwise, polymul
from pqc_golden.params import DILITHIUM, KYBER, N, Scheme

WIDTH = 24  # every field is one 24-bit coefficient, 6 hex digits
TAGS = {KYBER: "kyber", DILITHIUM: "dilithium"}
SEED = 2026
POLY_CASES = 4  # polynomials per file, 256 lines each
SCALAR_CASES = 1000  # random lines in the modmul and butterfly files, after the edge cases


def pack(*fields: int) -> str:
    """One $readmemh line: the fields side by side, first field in the most significant bits."""
    return "".join(f"{x:06x}" for x in fields)


def write(path: Path, lines: list[str]) -> None:
    path.write_text("\n".join(lines) + "\n")


def poly_lines(polys: list[list[int]]) -> list[str]:
    return [pack(x) for p in polys for x in p]


def sample_polys(s: Scheme, rng: random.Random) -> list[list[int]]:
    """Case 0 is the constant 1, case 1 is all q - 1, the rest random.

    The NTT of 1 is all ones for ML-DSA and 1, 0, 1, 0, ... for ML-KEM, which is easy to spot in a waveform.
    """
    polys = [[1] + [0] * (N - 1), [s.q - 1] * N]
    polys += [[rng.randrange(s.q) for _ in range(N)] for _ in range(POLY_CASES - 2)]
    return polys


def scalar_inputs(s: Scheme, rng: random.Random, n: int) -> list[tuple[int, ...]]:
    """Every combination of 0, 1 and q - 1 first, then random values."""
    edges = (0, 1, s.q - 1)
    if n == 2:
        cases = [(a, b) for a in edges for b in edges]
    else:
        cases = [(a, b, w) for a in edges for b in edges for w in edges]
    cases += [tuple(rng.randrange(s.q) for _ in range(n)) for _ in range(SCALAR_CASES)]
    return cases


def write_scheme(s: Scheme, out: Path) -> None:
    tag, q = TAGS[s], s.q
    rng = random.Random(f"{SEED}-{tag}")

    write(out / f"{tag}_zetas.hex", [pack(z) for z in s.zetas])

    write(out / f"{tag}_modmul.hex", [pack(a, b, a * b % q) for a, b in scalar_inputs(s, rng, 2)])
    write(out / f"{tag}_ct.hex", [pack(a, b, w, *ct_butterfly(a, b, w, q)) for a, b, w in scalar_inputs(s, rng, 3)])
    write(out / f"{tag}_gs.hex", [pack(a, b, w, *gs_butterfly(a, b, w, q)) for a, b, w in scalar_inputs(s, rng, 3)])

    for name, transform in (("ntt", ntt), ("intt", intt)):
        inputs = sample_polys(s, rng)
        traces = [[] for _ in inputs]
        outputs = [transform(p, s, t) for p, t in zip(inputs, traces)]
        write(out / f"{tag}_{name}_in.hex", poly_lines(inputs))
        for layer in range(s.layers):
            write(out / f"{tag}_{name}_l{layer + 1}.hex", poly_lines([t[layer] for t in traces]))
        write(out / f"{tag}_{name}_out.hex", poly_lines(outputs))

    for name, op in (("pwm", pointwise), ("polymul", polymul)):
        a, b = sample_polys(s, rng), sample_polys(s, rng)
        b = b[1:] + b[:1]  # so case 0 is not 1 * 1
        write(out / f"{tag}_{name}_a.hex", poly_lines(a))
        write(out / f"{tag}_{name}_b.hex", poly_lines(b))
        write(out / f"{tag}_{name}_out.hex", poly_lines([op(x, y, s) for x, y in zip(a, b)]))


def main(out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    for s in TAGS:
        write_scheme(s, out)


if __name__ == "__main__":
    default = Path(__file__).resolve().parents[2] / "vectors"
    main(Path(sys.argv[1]) if len(sys.argv) > 1 else default)
