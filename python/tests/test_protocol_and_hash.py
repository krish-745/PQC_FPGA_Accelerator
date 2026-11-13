"""Host protocol framing and the hash reference (hashlib) against FIPS 202 known answers."""

import hashlib

import pytest

from host import protocol as pr


def test_frame_layout_and_checksum():
    f = pr.frame(pr.READ, bytes([2]))
    assert f == bytes([0xA5, 0x11, 1, 0, 2, 0x11 ^ 1 ^ 0 ^ 2])
    assert pr.frame(pr.PING, bad_checksum=True)[-1] != pr.frame(pr.PING)[-1]


def test_response_roundtrip():
    payload = bytes(range(10))
    assert pr.parse_response(pr.response(pr.OK, payload)) == (pr.OK, payload)
    bad = bytearray(pr.response(pr.OK, payload))
    bad[5] ^= 1
    with pytest.raises(ValueError):
        pr.parse_response(bytes(bad))


def test_poly_packing_is_little_endian_3_bytes():
    coeffs = [8380416] + [0] * 255
    data = pr.pack_poly(coeffs)
    assert data[:3] == bytes([0x00, 0xE0, 0x7F]) and pr.unpack_poly(data) == coeffs


def test_hashlib_matches_fips_202_known_answers():
    # Known-answer values from the NIST examples (FIPS 202 example files) for "" and "abc".
    assert hashlib.sha3_256(b"").hexdigest() == "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a"
    assert hashlib.sha3_256(b"abc").hexdigest() == "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532"
    assert hashlib.sha3_512(b"abc").hexdigest().startswith("b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e")
    assert hashlib.shake_128(b"").hexdigest(16) == "7f9c2ba4e88f827d616045507605853e"
    assert hashlib.shake_256(b"").hexdigest(16) == "46b9dd2b0ba88d13233b3feb743eeb24"
