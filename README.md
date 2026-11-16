# PQC FPGA Accelerator

A verified, configurable NTT coprocessor for **ML-KEM (Kyber, FIPS 203)** and **ML-DSA (Dilithium,
FIPS 204)** on the Digilent **Nexys 4 DDR** (Artix-7 XC7A100T-1CSG324C), written in Verilog and
built with Vivado. It provides:

- forward and inverse NTT for both schemes, and full polynomial multiplication mod X²⁵⁶ + 1;
- P = 1, 2 or 4 parallel butterflies (build parameter);
- ML-KEM multiplication by Barrett reduction; ML-DSA by Barrett or the exact special-form reduction
  (build parameter);
- Keccak-f[1600] with SHA3-256, SHA3-512, SHAKE128 and SHAKE256;
- a UART host protocol with atomic loads and error recovery, and Python host tools.

What is verified, synthesized, timing-checked or board-tested is listed in [docs/status.md](docs/status.md).
Measured results are in [docs/report.md](docs/report.md).

## Documents

| File | Contents |
|---|---|
| [docs/plan.md](docs/plan.md) | project plan and scope |
| [docs/arithmetic.md](docs/arithmetic.md) | butterfly equations, twiddles, multiplier contract, widths, latencies |
| [docs/architecture.md](docs/architecture.md) | core memory/schedule, UART protocol, Keccak, reset |
| [docs/learning-guide.md](docs/learning-guide.md) | the whole design explained step by step |
| [docs/report.md](docs/report.md) | results, comparison method, limitations, related work |
| [docs/status.md](docs/status.md) | what is implemented / simulated / synthesized / timing-verified / board-verified |

## Requirements

- [uv](https://docs.astral.sh/uv/). It installs Python 3.12+ and the dependencies (`pytest`, `pyserial`).
- Vivado ML Standard (free edition) with 7-series support, for simulation, builds and programming.
  Tested with **Vivado 2024.2** on Windows 11.
- A Nexys 4 DDR, for the board tests only.

`scripts/flow.py` finds Vivado through `VIVADO_BIN`, then `PATH`, then the default install folders of
the running OS:
- Windows: `C:\Xilinx\Vivado\*\bin`, `C:\AMDDesignTools\*\Vivado\bin`;
- Linux: `/tools/Xilinx/Vivado/*/bin`, `/opt/Xilinx/Vivado/*/bin`.

Check what it found with:

```
uv run python scripts/flow.py tools
```

## Quick start

Run everything from the repository root. The commands were tested in PowerShell and Git Bash on Windows 11; the Linux paths in `flow.py` have not been tried.

1. Install the Python dependencies (first time only):
   ```
   uv sync
   ```
2. Run the golden-model tests: the fast suite, then the exhaustive 3329² Kyber multiplier check (~15 s):
   ```
   uv run pytest -m "not slow"
   uv run pytest -m slow
   ```
3. Generate the RTL twiddle ROM and all testbench vectors into `build/vectors/`:
   ```
   uv run python python/gen_vectors.py
   ```
4. Run every testbench in every configuration. `--slow` adds the exhaustive RTL multiplier runs:
   ```
   uv run python scripts/flow.py regress
   uv run python scripts/flow.py regress --slow
   ```
5. Run a single testbench, for example:
   ```
   uv run python scripts/flow.py sim tb_ntt_core -g P=4 -g DIL_SPECIAL=1
   ```
6. Build: synthesis, place and route, reports, and the bitstream for board targets:
   ```
   uv run python scripts/flow.py build echo                          # UART echo bring-up design
   uv run python scripts/flow.py build sys P=1 DIL_SPECIAL=0         # full system
   uv run python scripts/flow.py build core P=4 DIL_SPECIAL=1 period=8.0   # NTT core alone (out of context)
   uv run python scripts/flow.py build mul DIL_SPECIAL=1             # multiplier alone (out of context)
   ```
   Reports land in `build/<target>_<options>/`: `synth_util.rpt`, `route_util.rpt`,
   `route_util_hier.rpt`, `route_timing.rpt` and `summary.txt`.
7. Program the board and test it (plug it in and switch it on first):
   ```
   uv run python scripts/flow.py program echo
   uv run python python/host/pqc_host.py ports
   uv run python python/host/pqc_host.py echo --port COM5
   uv run python scripts/flow.py program sys P=1 DIL_SPECIAL=0
   uv run python python/host/pqc_host.py selftest --port COM5
   ```
   Use the port that `ports` lists for the board's USB serial converter, e.g. `/dev/ttyUSB1` on Linux.

## Running on another machine

Vivado does not run on macOS. On a Mac:
1. Run steps 1–3 locally; they need only Python.
2. On a Windows or Linux machine with Vivado, clone the repository and run:
   ```
   uv sync
   uv run python python/gen_vectors.py
   uv run python scripts/flow.py regress
   uv run python scripts/flow.py build sys P=1 DIL_SPECIAL=0
   ```
   If Vivado is not in a default folder, set `VIVADO_BIN` to `<install>/Vivado/<version>/bin` first.
3. Copy `build/sys_P1_DIL_SPECIAL0/sys.bit` back if the board is attached to the Mac. The host
   scripts run anywhere `pyserial` does; programming itself needs Vivado's hardware manager.

## Layout

```
python/pqc_golden/   golden model: params, ntt, reference (slow, independent), poly, modmul (bit-exact),
                     schedule (cycle-accurate model of the core)
python/host/         protocol.py (framing), pqc_host.py (board tests), opcycles.py (per-op board check), fake_board.py (protocol model for tests)
python/tests/        pytest suites (slow suite: -m slow)
python/gen_vectors.py  writes rtl/twiddle_rom.v and build/vectors/*
rtl/                 Verilog: mod_mul, butterfly, ntt_core, keccak_*, uart_*, cmd_ctrl, top, bench wrappers
docs/board/          board test logs (2026-11-16)
tb/                  self-checking testbenches (print TEST PASSED / TEST FAILED)
constraints/         Nexys 4 DDR pins and clock
scripts/             flow.py (sim/regress/build/program), build.tcl, program.tcl
```
