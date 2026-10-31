import pytest

from pqc_golden import vectors
from pqc_golden.ntt import intt, ntt, polymul
from pqc_golden.params import DILITHIUM, KYBER, N

SCHEMES = pytest.mark.parametrize("s", [KYBER, DILITHIUM], ids=lambda s: s.name)


@pytest.fixture(scope="module")
def out(tmp_path_factory):
    d = tmp_path_factory.mktemp("vectors")
    vectors.main(d)
    return d


def read_polys(path):
    words = [int(line, 16) for line in path.read_text().split()]
    assert len(words) == vectors.POLY_CASES * N
    return [words[i : i + N] for i in range(0, len(words), N)]


def read_fields(path, n):
    lines = path.read_text().split()
    assert all(len(line) == 6 * n for line in lines)
    return [[int(line[6 * i : 6 * i + 6], 16) for i in range(n)] for line in lines]


@SCHEMES
def test_files_round_trip(out, s):
    tag = vectors.TAGS[s]
    assert [z for (z,) in read_fields(out / f"{tag}_zetas.hex", 1)] == s.zetas

    for a, b, p in read_fields(out / f"{tag}_modmul.hex", 3):
        assert p == a * b % s.q

    ins = read_polys(out / f"{tag}_ntt_in.hex")
    assert read_polys(out / f"{tag}_ntt_out.hex") == [ntt(f, s) for f in ins]
    assert read_polys(out / f"{tag}_ntt_l{s.layers}.hex") == [ntt(f, s) for f in ins]

    ins = read_polys(out / f"{tag}_intt_in.hex")
    assert read_polys(out / f"{tag}_intt_out.hex") == [intt(f, s) for f in ins]

    a, b = read_polys(out / f"{tag}_polymul_a.hex"), read_polys(out / f"{tag}_polymul_b.hex")
    assert read_polys(out / f"{tag}_polymul_out.hex") == [polymul(x, y, s) for x, y in zip(a, b)]


def test_output_is_deterministic(out, tmp_path):
    vectors.main(tmp_path)
    for f in out.iterdir():
        assert f.read_bytes() == (tmp_path / f.name).read_bytes()
