"""Board tests over the USB-UART. Run from the repo root with the board programmed:

    uv run python python/host/pqc_host.py ports                       # list serial ports
    uv run python python/host/pqc_host.py echo --port COM5            # bring-up bitstream (build/echo)
    uv run python python/host/pqc_host.py selftest --port COM5        # full system bitstream (build/sys_*)
    uv run python python/host/pqc_host.py selftest --port /dev/ttyUSB1 --repeat 20

selftest checks, against the Python golden model:
  - PING and the build configuration (P, Dilithium multiplier) the board reports;
  - complete polynomial multiplication for ML-KEM and ML-DSA (LOAD A, LOAD B, RUN MUL, READ C),
    plus the NTT(A) left in A, INTT on B;
  - SHA3-256, SHA3-512, SHAKE128, SHAKE256 including rate and squeeze-block boundaries;
  - protocol recovery: ERR_RANGE (first/middle/last coefficient), ERR_CHK, an interrupted transfer
    (ERR_TIMEOUT), unknown command, wrong length, bad argument, operand-state error, each followed by
    a check that the buffers did not change and that the next command works;
  - repeated commands (--repeat).
It reports the FPGA's own cycle count for each RUN separately from the host-side transfer time.
"""

import argparse
import hashlib
import random
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from host import protocol as pr  # noqa: E402
from pqc_golden.ntt import ntt  # noqa: E402
from pqc_golden.params import DILITHIUM, KYBER, N  # noqa: E402
from pqc_golden.poly import multiply  # noqa: E402

CLOCK_HZ = 100e6


def open_port(port: str, baud: int):
    import serial

    return serial.Serial(port, baud, timeout=2)


class Board:
    def __init__(self, ser):
        self.ser = ser

    def xact(self, req: bytes) -> tuple[int, bytes, float]:
        """Send one request, read one response. Returns (status, payload, seconds on the wire)."""
        self.ser.reset_input_buffer()
        t0 = time.perf_counter()
        self.ser.write(req)
        head = self.ser.read(4)
        if len(head) < 4:
            raise TimeoutError(f"no response header (got {head.hex()})")
        n = head[2] | head[3] << 8
        rest = self.ser.read(n + 1)
        dt = time.perf_counter() - t0
        status, payload = pr.parse_response(head + rest)
        return status, payload, dt

    def wait_timeout(self) -> None:
        """Stay silent longer than the board's 10 ms inter-byte timeout."""
        if hasattr(self.ser, "silence"):
            self.ser.silence()  # fake board (tests): no real time passes
        else:
            time.sleep(0.05)

    def expect(self, req: bytes, status: int, what: str) -> bytes:
        got, payload, _ = self.xact(req)
        if got != status:
            raise AssertionError(f"{what}: expected {pr.STATUS_NAMES[status]}, got {pr.STATUS_NAMES[got]}")
        return payload


def cmd_echo(a) -> int:
    ser = open_port(a.port, a.baud)
    rng = random.Random(1)
    data = bytes(rng.randrange(256) for _ in range(1000))
    ser.reset_input_buffer()
    t0 = time.perf_counter()
    for i in range(0, len(data), 16):  # the echo FIFO holds 16 bytes
        ser.write(data[i : i + 16])
        back = ser.read(len(data[i : i + 16]))
        if back != data[i : i + 16]:
            print(f"FAIL: echo mismatch at byte {i}: sent {data[i:i+16].hex()} got {back.hex()}")
            return 1
    print(f"PASS: 1000 bytes echoed in {time.perf_counter() - t0:.2f} s")
    return 0


def cmd_selftest(a, ser=None) -> int:
    b = Board(ser if ser is not None else open_port(a.port, a.baud))
    rng = random.Random(a.seed)
    info = b.expect(pr.frame(pr.PING), pr.OK, "PING")
    if info[:2] != b"PQ":
        raise AssertionError(f"unexpected PING payload {info.hex()}")
    P, special = info[2], info[3]
    print(f"board: P = {P}, Dilithium multiplier = {'special-form' if special else 'Barrett'}")
    results = []
    for rep in range(a.repeat):
        for sid, s in ((pr.KYBER_ID, KYBER), (pr.DILITHIUM_ID, DILITHIUM)):
            f = [rng.randrange(s.q) for _ in range(N)]
            g = [rng.randrange(s.q) for _ in range(N)]
            _, _, t_load = b.xact(pr.load(sid, 0, f))
            b.expect(pr.load(sid, 1, g), pr.OK, "LOAD B")
            st, cyc, t_run = b.xact(pr.run(sid, pr.OP["MUL"]))
            assert st == pr.OK, f"RUN MUL: {pr.STATUS_NAMES[st]}"
            cycles = int.from_bytes(cyc, "little")
            st, c_bytes, t_read = b.xact(pr.read(2))
            assert pr.unpack_poly(c_bytes) == multiply(f, g, s), f"{s.name} product mismatch"
            assert pr.unpack_poly(b.expect(pr.read(0), pr.OK, "READ A")) == ntt(f, s), f"{s.name} NTT(A) mismatch"
            b.expect(pr.run(sid, pr.OP["INTT"], 1), pr.OK, "RUN INTT B")
            assert pr.unpack_poly(b.expect(pr.read(1), pr.OK, "READ B")) == g, f"{s.name} INTT(NTT(B)) mismatch"
            results.append((s.name, cycles, t_load, t_run, t_read))
            if rep == 0:
                # protocol recovery: none of these may change A
                a_now = ntt(f, s)
                for pos in (0, 128, 255):
                    bad = list(f)
                    bad[pos] = s.q
                    b.expect(pr.load(sid, 0, bad), pr.ERR_RANGE, f"out-of-range coefficient at {pos}")
                bad = list(f)
                bad[7] = (1 << 24) - 1  # largest value the 3-byte field can carry
                b.expect(pr.load(sid, 0, bad), pr.ERR_RANGE, "coefficient 2^24 - 1")
                b.expect(pr.load(sid, 0, f, bad_checksum=True), pr.ERR_CHK, "bad checksum")
                req = pr.load(sid, 0, g)
                b.ser.write(req[: len(req) // 2])
                b.wait_timeout()  # > 10 ms inter-byte timeout
                head = b.ser.read(5)
                assert pr.parse_response(head) == (pr.ERR_TIMEOUT, b""), f"interrupted LOAD: {head.hex()}"
                assert pr.unpack_poly(b.expect(pr.read(0), pr.OK, "READ A after errors")) == a_now, "A changed"
    b.expect(pr.frame(0x77), pr.ERR_CMD, "unknown command")
    b.expect(pr.frame(pr.READ, bytes([0, 0])), pr.ERR_LEN, "wrong length")
    b.expect(pr.frame(pr.RUN, bytes([0, 4, 0])), pr.ERR_ARG, "bad op")
    b.expect(pr.run(pr.KYBER_ID, pr.OP["NTT"], 0), pr.ERR_STATE, "scheme mismatch")
    for name, mode in pr.HASH_MODE.items():
        r = {"sha3_256": 136, "sha3_512": 72, "shake_128": 168, "shake_256": 136}[name]
        for n in (0, 1, r - 1, r, r + 1, 3 * r + 7):
            msg = bytes(rng.randrange(256) for _ in range(n))
            for outlen in ([32] if mode == 0 else [64] if mode == 1 else [1, r, r + 1, 2 * r + 5]):
                h = hashlib.new(name, msg)
                want = h.digest(outlen) if name.startswith("shake") else h.digest()
                got = b.expect(pr.hash_req(mode, msg, outlen), pr.OK, f"{name} {n} bytes")
                assert got == want, f"{name}({n} bytes, {outlen} out) mismatch"
    print(f"{'scheme':8} {'FPGA cycles':>12} {'FPGA time':>10} {'LOAD (host)':>12} {'RUN (host)':>11} {'READ (host)':>12}")
    for name, cyc, tl, tr, td in results[:2]:
        print(f"{name:8} {cyc:12d} {cyc / CLOCK_HZ * 1e6:8.2f} us {tl * 1e3:9.1f} ms {tr * 1e3:8.1f} ms {td * 1e3:9.1f} ms")
    print(f"PASS: selftest, {a.repeat} round(s), P = {P}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("ports")
    for name in ("echo", "selftest"):
        p = sub.add_parser(name)
        p.add_argument("--port", required=True)
        p.add_argument("--baud", type=int, default=115200)
        p.add_argument("--repeat", type=int, default=3)
        p.add_argument("--seed", type=int, default=2026)
    a = ap.parse_args()
    if a.cmd == "ports":
        from serial.tools import list_ports

        for p in list_ports.comports():
            print(f"{p.device}\t{p.description}")
        return 0
    import serial

    try:
        return {"echo": cmd_echo, "selftest": cmd_selftest}[a.cmd](a)
    except serial.SerialException as e:
        print(f"FAIL: cannot use serial port {a.port}: {e}")
        return 1
    except (AssertionError, TimeoutError, ValueError) as e:
        print(f"FAIL: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
