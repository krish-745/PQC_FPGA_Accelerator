# Status checklist

State on 2026-11-12, final RTL. **Pending** means not run, because the tool or hardware was not
available. Nothing marked done is an estimate.

Column meanings:
- **Implemented:** RTL or code exists.
- **Simulated:** a self-checking testbench passes (xsim, Vivado 2024.2).
- **Synthesized:** synthesized and placed/routed without errors.
- **Timing-verified:** post-route WNS ≥ 0 and WHS ≥ 0 at the stated clock.
- **Board-verified:** run on a Nexys 4 DDR.

| Capability | Implemented | Simulated | Synthesized | Timing-verified | Board-verified |
|---|---|---|---|---|---|
| Golden model: NTT, INTT, pointwise, full multiply (both schemes) | yes | 102 pytest tests pass (`-m "not slow"`) | n/a | n/a | n/a |
| Exhaustive ML-KEM multiplier check, Python (3329² pairs) | yes | `pytest -m slow` passes | n/a | n/a | n/a |
| Cycle-accurate schedule, P = 1, 2, 4 (hazard/port proof) | yes | pytest passes, incl. negative control | n/a | n/a | n/a |
| `mod_mul`, Barrett (`DIL_SPECIAL=0`) | yes | `tb_mod_mul` 200,511 products + exhaustive 3329² | yes (out of context) | yes, at 8.0 ns (fails at 7.5 ns) | pending |
| `mod_mul`, special form (`DIL_SPECIAL=1`) | yes | same, incl. exhaustive ML-KEM | yes (out of context) | yes, at 5.0 ns (fails at 4.5 ns) | pending |
| ML-DSA-only multipliers (`FIXED_MODE=1`, both reductions) | yes (bench option) | covered by the `mod_mul` runs above (same RTL) | yes (out of context) | Barrett: 7.0 ns (fails 6.5); special: 5.0 ns (fails 4.5) | n/a |
| `butterfly`, CT/GS/MAC, both builds | yes | `tb_butterfly` 61,292 operations | inside core | inside core | pending |
| NTT core P = 1, both builds | yes | `tb_ntt_core`: 23 cases, memory + 129,385-record trace identical, scrambled inputs, mid-MUL reset | yes (out of context) | yes, at 8.0 ns (fails at 7.5 ns) | pending |
| NTT core P = 2, both builds | yes | same | yes (out of context) | Barrett: 8.0 ns (fails 7.5); special: 7.5 ns (fails 7.0) | pending |
| NTT core P = 4, both builds | yes | same | yes (out of context) | Barrett: 9.0 ns (fails 8.5); special: 8.0 ns (fails 7.5) | pending |
| Keccak: SHA3-256, SHA3-512, SHAKE128, SHAKE256 | yes | `tb_keccak`: 54 cases, 4,440 bytes vs hashlib; every mode at empty, 1, r−1, r, r+1, 2r, 2r+1, 3r+7 bytes, SHAKE squeeze boundaries, gaps, backpressure, mid-hash reset | inside system | inside system | pending |
| UART RX/TX | yes | `tb_uart`: 256 values, framing error, glitch | inside echo/system | inside echo/system | pending |
| UART echo bring-up design | yes | `tb_top_uart_echo`: 40-byte burst, reset | yes, bitstream `build/echo/echo.bit` | yes, 10 ns, WNS +5.036 | **pending** (`pqc_host.py echo`) |
| Command protocol: PING/LOAD/READ/RUN/HASH, all error codes, atomic LOAD, timeout recovery, tags | yes | `tb_top`: 97-record transcript, 8,263 response bytes, P = 1/2/4 | inside system | inside system | **pending** (`pqc_host.py selftest`) |
| Full system P = 1, Barrett | yes | `tb_top` passes | yes, bitstream | yes, 10 ns, WNS +0.168, WHS +0.119 | **pending** |
| Full system P = 1, special form | yes | `tb_top` passes | yes, bitstream | yes, 10 ns, WNS +0.693, WHS +0.103 | **pending** |
| Full system P = 2, Barrett | yes | `tb_top` passes | yes, bitstream | yes, 10 ns, WNS +0.318, WHS +0.131 | **pending** |
| Full system P = 2, special form | yes | `tb_top` passes | yes, bitstream | yes, 10 ns, WNS +0.153, WHS +0.039 | **pending** |
| Full system P = 4, Barrett | yes | `tb_top` passes | yes, bitstream | yes, 10 ns, WNS +0.318, WHS +0.050 | **pending** |
| Full system P = 4, special form | yes | `tb_top` passes | yes, bitstream | yes, 10 ns, WNS +0.092, WHS +0.039 | **pending** |
| Host scripts `pqc_host.py echo / selftest` | yes | `selftest` executed end to end in pytest against `host/fake_board.py` (a protocol model that also reproduces the `tb_top` transcript byte for byte); `echo` and a missing port tested to fail cleanly | n/a | n/a | **pending** |
| FPGA cycle count separate from host transfer time | yes (RUN returns the core's counter; selftest times transfers) | cycle counts checked in `tb_ntt_core` and `tb_top` | n/a | n/a | **pending** |
| Tool discovery and programming without a board | yes (`flow.py tools`, `flow.py program`) | run on Windows 11: Vivado found; `program` exits 1 with "no JTAG target" | n/a | n/a | n/a |
| Linux / macOS tool discovery and handoff | yes (`flow.py`, README) | not tested (Windows only) | n/a | n/a | n/a |

## Reproducibility

A clean copy of only the files git would track (`git ls-files -co --exclude-standard`) was set up
from scratch on 2026-11-12, and these were run in it:
- `uv sync`;
- both pytest suites: 102 passed, and 1 slow test passed;
- `gen_vectors.py`;
- `flow.py regress`: 18/18 passed;
- `flow.py build mul DIL_SPECIAL=1` and `build echo`.

Both builds reproduced the same WNS as in the working tree (+3.667 ns and +5.036 ns).

## Open items

**Needs you:**
- Board tests (echo and self-test) on the bitstreams. Steps are below.
- Approval of the proposed commits. Nothing is committed yet.

**Not done (stated plainly):**
- Linux and macOS: the `flow.py` paths for them are untested; everything ran on Windows 11.
- The specification documents (`arithmetic.md`, `architecture.md`) were written after the RTL, not before.

**Out of scope, by decision:** masking, leakage tests, Kyber K-RED, the square-form multiplier,
complete ML-KEM/ML-DSA cryptosystems.

**Decisions made during autonomous implementation**, which you will need to explain (all in
`docs/plan.md` "Implementation notes"):
- Passes run back to back with no drain. `schedule.py` proves this is hazard-free (`learning-guide.md` §4).
- Pipeline depth D = 8, with a routing register added for 100 MHz timing (`architecture.md` §1).
- The bank mapping is our own XOR fold, not taken from a paper (`architecture.md` §1).
- Keccak is about 80% of the system's LUTs, because it does one full round per cycle (`report.md` §3.3).

## Blocked checks and how to finish them

No Nexys 4 DDR was connected: the only serial ports were Bluetooth COM3 and COM4. With the board
plugged in and switched on:

1. Find the board's serial port:
   ```
   uv run python python/host/pqc_host.py ports
   ```
2. Program the echo design and run the echo test:
   ```
   uv run python scripts/flow.py program echo
   uv run python python/host/pqc_host.py echo --port COMx
   ```
3. Program the full system and run the self-test:
   ```
   uv run python scripts/flow.py program sys P=1 DIL_SPECIAL=0
   uv run python python/host/pqc_host.py selftest --port COMx
   ```
4. Repeat step 3 for `sys P=4 DIL_SPECIAL=1`, and for the other two system bitstreams if wanted.

## Commands that reproduce every "done" entry

```
uv run pytest -m "not slow"
uv run pytest -m slow
uv run python scripts/flow.py regress --slow
uv run python scripts/flow.py sweep core P=1 DIL_SPECIAL=0
uv run python scripts/flow.py sweep core P=4 DIL_SPECIAL=1
uv run python scripts/flow.py sweep mul DIL_SPECIAL=1 --periods 10,8,7,6.5,6,5.5,5,4.5,4
uv run python scripts/flow.py build sys P=4 DIL_SPECIAL=1
uv run python scripts/flow.py summarize
```
