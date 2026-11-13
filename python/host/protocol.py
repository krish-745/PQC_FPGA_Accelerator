"""Host side of the UART protocol (rtl/cmd_ctrl.v, docs/architecture.md "Host protocol").

Request : A5 | CMD | LEN lo | LEN hi | PAYLOAD | CHK      CHK = XOR of every byte after A5
Response: 5A | STATUS | LEN lo | LEN hi | PAYLOAD | CHK
Coefficients travel as 3 bytes each, little-endian, 256 per polynomial.
"""

from functools import reduce

SYNC_REQ, SYNC_RSP = 0xA5, 0x5A
PING, LOAD, READ, RUN, HASH = 0x01, 0x10, 0x11, 0x20, 0x30
OK, ERR_RANGE, ERR_CMD, ERR_LEN, ERR_CHK, ERR_TIMEOUT, ERR_ARG, ERR_STATE = range(8)
STATUS_NAMES = ["OK", "ERR_RANGE", "ERR_CMD", "ERR_LEN", "ERR_CHK", "ERR_TIMEOUT", "ERR_ARG", "ERR_STATE"]
KYBER_ID, DILITHIUM_ID = 0, 1
BUF = {"A": 0, "B": 1, "C": 2}
OP = {"NTT": 0, "INTT": 1, "PWM": 2, "MUL": 3}
HASH_MODE = {"sha3_256": 0, "sha3_512": 1, "shake_128": 2, "shake_256": 3}


def xor(data: bytes) -> int:
    return reduce(lambda a, b: a ^ b, data, 0)


def frame(cmd: int, payload: bytes = b"", bad_checksum: bool = False) -> bytes:
    body = bytes([cmd, len(payload) & 0xFF, len(payload) >> 8]) + payload
    return bytes([SYNC_REQ]) + body + bytes([xor(body) ^ (0x55 if bad_checksum else 0)])


def response(status: int, payload: bytes = b"") -> bytes:
    body = bytes([status, len(payload) & 0xFF, len(payload) >> 8]) + payload
    return bytes([SYNC_RSP]) + body + bytes([xor(body)])


def pack_poly(coeffs: list[int]) -> bytes:
    assert len(coeffs) == 256
    return b"".join(c.to_bytes(3, "little") for c in coeffs)


def unpack_poly(data: bytes) -> list[int]:
    assert len(data) == 768
    return [int.from_bytes(data[3 * i : 3 * i + 3], "little") for i in range(256)]


def load(scheme: int, buf: int, coeffs: list[int], **kw) -> bytes:
    return frame(LOAD, bytes([scheme, buf]) + pack_poly(coeffs), **kw)


def read(buf: int) -> bytes:
    return frame(READ, bytes([buf]))


def run(scheme: int, op: int, buf: int = 0) -> bytes:
    return frame(RUN, bytes([scheme, op, buf]))


def hash_req(mode: int, msg: bytes, outlen: int) -> bytes:
    return frame(HASH, bytes([mode, outlen & 0xFF, outlen >> 8]) + msg)


def parse_response(data: bytes) -> tuple[int, bytes]:
    """(status, payload) of one complete response; raises ValueError if it is malformed."""
    if len(data) < 5 or data[0] != SYNC_RSP:
        raise ValueError(f"bad response start: {data[:8].hex()}")
    n = data[2] | data[3] << 8
    if len(data) != 5 + n:
        raise ValueError(f"response length {len(data)} != {5 + n}")
    if xor(data[1:-1]) != data[-1]:
        raise ValueError("response checksum mismatch")
    return data[1], data[4:-1]
