"""A serial-port stand-in that answers like the FPGA, for testing the host tools without a board.

It models rtl/cmd_ctrl.v's documented behaviour (docs/architecture.md "Host protocol") on top of
the golden model: framing, the first-error-wins status rules, atomic LOAD, operand tags, RUN cycle
counts from schedule.py, HASH via hashlib, and the inter-byte timeout (triggered by silence()).
It is a protocol reference, not a copy of the RTL: tb_top checks the RTL against transcripts made
from python/host/protocol.py and the golden model.
"""

import hashlib

from host import protocol as pr
from pqc_golden.ntt import intt, ntt
from pqc_golden.params import DILITHIUM, KYBER, N
from pqc_golden.poly import pointwise
from pqc_golden.schedule import run as schedule_run

SCHEMES = {0: KYBER, 1: DILITHIUM}
HASH_NAMES = ["sha3_256", "sha3_512", "shake_128", "shake_256"]
EXPECT_LEN = {pr.PING: 0, pr.LOAD: 770, pr.READ: 1, pr.RUN: 3}


class FakeBoard:
    def __init__(self, P: int = 1, dil_special: int = 0):
        self.P, self.special = P, dil_special
        self.mem = {b: [0] * N for b in range(3)}
        self.tags: dict[int, int | None] = {0: None, 1: None, 2: None}  # scheme each buffer was loaded for
        self.rx = bytearray()  # bytes received, not yet a complete request
        self.tx = bytearray()  # response bytes waiting to be read

    # ---- serial.Serial subset used by pqc_host ----
    def write(self, data: bytes) -> None:
        self.rx += data
        self._process()

    def read(self, n: int) -> bytes:
        out, self.tx = bytes(self.tx[:n]), self.tx[n:]
        return out

    def reset_input_buffer(self) -> None:
        self.tx.clear()

    def silence(self) -> None:
        """The host stays quiet longer than the timeout: an unfinished request is aborted."""
        if self.rx:
            self.rx.clear()
            self.tx += pr.response(pr.ERR_TIMEOUT)

    # ---- request handling ----
    def _process(self) -> None:
        while True:
            while self.rx and self.rx[0] != pr.SYNC_REQ:  # bytes before A5 are ignored
                del self.rx[0]
            if len(self.rx) < 4:
                return
            n = self.rx[2] | self.rx[3] << 8
            if len(self.rx) < 5 + n:
                return  # wait for the rest (or a timeout)
            req, self.rx = bytes(self.rx[: 5 + n]), self.rx[5 + n :]
            self.tx += self._answer(req[1], req[4:-1], pr.xor(req[1:-1]) == req[-1])

    def _answer(self, cmd: int, pl: bytes, chk_ok: bool) -> bytes:
        status = pr.OK
        if cmd not in (pr.PING, pr.LOAD, pr.READ, pr.RUN, pr.HASH):
            status = pr.ERR_CMD
        elif (len(pl) < 3) if cmd == pr.HASH else (len(pl) != EXPECT_LEN[cmd]):
            status = pr.ERR_LEN
        else:
            status = self._check_args(cmd, pl)
        if status == pr.OK and not chk_ok:
            status = pr.ERR_CHK
        if status != pr.OK:
            return pr.response(status)
        return self._execute(cmd, pl)

    def _check_args(self, cmd: int, pl: bytes) -> int:
        """Argument errors in payload byte order; the first one wins, as in cmd_ctrl."""
        if cmd == pr.LOAD:
            if pl[0] > 1 or pl[1] > 2:
                return pr.ERR_ARG
            q = SCHEMES[pl[0]].q
            if any(c >= q for c in pr.unpack_poly(pl[2:])):
                return pr.ERR_RANGE
        elif cmd == pr.READ:
            if pl[0] > 2:
                return pr.ERR_ARG
        elif cmd == pr.RUN:
            if pl[0] > 1 or pl[1] > 3 or pl[2] > 2:
                return pr.ERR_ARG
        elif cmd == pr.HASH:
            mode, outlen = pl[0], pl[1] | pl[2] << 8
            if mode > 3 or (mode == 0 and outlen != 32) or (mode == 1 and outlen != 64) or outlen == 0:
                return pr.ERR_ARG
        return pr.OK

    def _execute(self, cmd: int, pl: bytes) -> bytes:
        if cmd == pr.PING:
            return pr.response(pr.OK, bytes([0x50, 0x51, self.P, self.special]))
        if cmd == pr.LOAD:
            self.mem[pl[1]] = pr.unpack_poly(pl[2:])
            self.tags[pl[1]] = pl[0]
            return pr.response(pr.OK)
        if cmd == pr.READ:
            return pr.response(pr.OK, pr.pack_poly(self.mem[pl[0]]))
        if cmd == pr.HASH:
            h = hashlib.new(HASH_NAMES[pl[0]], pl[3:])
            outlen = pl[1] | pl[2] << 8
            return pr.response(pr.OK, h.digest(outlen) if pl[0] >= 2 else h.digest())
        sid, op, buf = pl
        s = SCHEMES[sid]
        need = (0, 1) if op >= 2 else (buf,)
        if any(self.tags[b] != sid for b in need):
            return pr.response(pr.ERR_STATE)
        name = ["NTT", "INTT", "PWM", "MUL"][op]
        cycles = schedule_run(name, s, self.P, {b: [0] * N for b in "ABC"}, "ABC"[buf]).total
        m = self.mem
        if op == 0:
            m[buf] = ntt(m[buf], s)
        elif op == 1:
            m[buf] = intt(m[buf], s)
        else:
            if op == 3:
                m[0], m[1] = ntt(m[0], s), ntt(m[1], s)
            m[2] = pointwise(m[0], m[1], s)
            if op == 3:
                m[2] = intt(m[2], s)
            self.tags[2] = sid
        return pr.response(pr.OK, cycles.to_bytes(4, "little"))
