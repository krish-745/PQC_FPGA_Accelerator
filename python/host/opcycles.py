"""Run NTT, INTT, PWM and MUL on the board, check every result against pqc_golden, print cycle counts.

Usage: uv run python python/host/opcycles.py COMx
"""
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from pqc_host import Board, open_port  # noqa: E402
from host import protocol as pr  # noqa: E402
from pqc_golden.ntt import intt, ntt  # noqa: E402
from pqc_golden.params import DILITHIUM, KYBER, N  # noqa: E402
from pqc_golden.poly import multiply, pointwise  # noqa: E402


def run_and_check(ser) -> int:
    b = Board(ser)
    info = b.expect(pr.frame(pr.PING), pr.OK, "PING")
    print(f"P = {info[2]}, special = {info[3]}")
    rng = random.Random(5)
    for sid, s in ((pr.KYBER_ID, KYBER), (pr.DILITHIUM_ID, DILITHIUM)):
        inputs = {
            "random": ([rng.randrange(s.q) for _ in range(N)], [rng.randrange(s.q) for _ in range(N)]),
            "zeros": ([0] * N, [0] * N),
            "q-1": ([s.q - 1] * N, [s.q - 1] * N),
        }
        cycles = {}
        for kind, (f, g) in inputs.items():

            def op(name, buf, want_buf, want):
                cyc = b.expect(pr.run(sid, pr.OP[name], buf), pr.OK, f"{s.name} {kind} RUN {name}")
                cycles.setdefault(name, set()).add(int.from_bytes(cyc, "little"))
                got = pr.unpack_poly(b.expect(pr.read(want_buf), pr.OK, f"READ {want_buf}"))
                assert got == want, f"{s.name} {kind} {name} on buffer {buf}: result mismatch"

            b.expect(pr.load(sid, 0, f), pr.OK, "LOAD A")
            b.expect(pr.load(sid, 1, g), pr.OK, "LOAD B")
            op("NTT", 0, 0, ntt(f, s))
            op("INTT", 0, 0, f)
            op("NTT", 1, 1, ntt(g, s))
            op("INTT", 1, 1, g)
            op("PWM", 0, 2, pointwise(f, g, s))
            op("NTT", 2, 2, ntt(pointwise(f, g, s), s))
            op("INTT", 2, 2, pointwise(f, g, s))
            op("MUL", 0, 2, multiply(f, g, s))
        assert all(len(v) == 1 for v in cycles.values()), f"{s.name} cycle count depends on data: {cycles}"
        print(s.name, " ".join(f"{k}={v.pop()}" for k, v in cycles.items()), "results OK")
    return 0


if __name__ == "__main__":
    sys.exit(run_and_check(open_port(sys.argv[1], 115200)))
