"""Runs the board self-test (python/host/pqc_host.py) against the fake board, so the host script's own
logic is exercised before it ever meets real hardware; and checks the fake board against the tb_top
transcript, the same request/response pairs the RTL system passes."""

import argparse

import pytest

from host import pqc_host
from host.fake_board import FakeBoard


@pytest.mark.parametrize("P,special", [(1, 0), (4, 1)])
def test_selftest_runs_against_fake_board(P, special, capsys):
    a = argparse.Namespace(port="fake", baud=115200, repeat=1, seed=7)
    assert pqc_host.cmd_selftest(a, ser=FakeBoard(P, special)) == 0
    out = capsys.readouterr().out
    assert "PASS: selftest" in out and f"P = {P}" in out


@pytest.mark.parametrize("P,special", [(1, 0), (4, 1)])
def test_fake_board_reproduces_tb_top_transcript(P, special):
    from gen_vectors import top_transcript

    board = FakeBoard(P, special)
    for item in top_transcript(P, special, timeout_gap=3000):
        kind = item[0]
        if kind == "S":
            board.write(item[1])
        elif kind == "G":
            board.silence()
        elif kind == "R":
            board.__init__(P, special)  # reset: tags and protocol state cleared
        elif kind == "E":
            assert board.read(len(item[1])) == item[1]
    assert board.read(1) == b""
