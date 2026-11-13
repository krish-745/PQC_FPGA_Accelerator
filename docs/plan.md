# Plan: unified ML-KEM / ML-DSA NTT coprocessor (P = 1, 2, 4), full implementation

## Context
This is a course project: a verified FPGA NTT coprocessor for the Nexys 4 DDR (Artix-7 XC7A100T-1CSG324C), revised using the TCSI 2026 paper (Ahmad et al.) and an external review.
`docs/plan.md` was lost in the restart. The repo holds:
- `params.py` + tests (committed, f98a5af);
- `ntt.py`, `reference.py`, `test_ntt.py` (uncommitted, 12 tests reported passing; to be re-verified).

The UART, scripts and RTL from the pre-restart repo are gone and must be rebuilt.

The user has authorized autonomous implementation of all core milestones:
- create files, run tests, fix failures, write docs, with no routine approval stops;
- no commits, pushes, paid tools or system configuration changes without explicit authorization;
- ask only when blocked or when an action is destructive.

**Target claim:** a verified, configurable dual-scheme NTT accelerator with measured arithmetic and parallelism trade-offs.

## Mandatory scope
- Kyber and Dilithium forward and inverse NTT.
- Complete polynomial multiplication mod `X²⁵⁶ + 1`.
- Butterfly count `P ∈ {1, 2, 4}`.
- Kyber Barrett in every build; Dilithium Barrett or exact special-form as a build option.
- UART host control.
- Keccak-f[1600] with SHA3-256, SHA3-512, SHAKE128, SHAKE256.
- Reproducible sim / synth / impl / board scripts.
- Measured comparisons.

Baseline clock 100 MHz; higher frequency only after correctness.

**Out of scope, recorded as future work:** full ML-KEM/ML-DSA cryptosystems, masking, leakage resistance or leakage tests, scaled Kyber K-RED, the paper's square-form multiplier.

## Fixed decisions
- Bit-reversed NTT output order (FIPS 203/204).
- Plain non-Montgomery twiddles.
- ROM sizes:
  - Kyber 128 × 12 bits (127 used).
  - Dilithium 256 × 23 bits (255 used).
- **Inverse ROM reuse is proven against the independent reference** in tests, not assumed from address reversal.
- **Multiplier contract:** `modmul(a, b) = a·b mod q`, `0 ≤ a, b < q`, `0 ≤ out < q`, for every build.
- The reduction comparison is Dilithium-only and documented as such.
- Kyber base-case pair ordering is documented explicitly: `(f̂[2i], f̂[2i+1])` with `γ = ζ^(2·bitrev7(i)+1)`, as in FIPS 203 Algorithms 11–12.
- Scheme and operation are captured when a command is accepted and stay stable for that operation.

## Specify before implementing
- **`docs/arithmetic.md`:**
  - exact forward/inverse butterfly equations, twiddle indexing, subtraction order, output ordering and inverse normalization, per scheme;
  - the multiplier contract;
  - width, signedness, bounds and correction steps of every intermediate (Barrett both schemes, Dilithium special-form);
  - derived Dilithium correction limits.
- **`docs/architecture.md`:**
  - multiplier/butterfly latency, initiation interval, valid/ready, reset behaviour;
  - A/B/result operand storage, overwrite policy, host/core ownership, pointwise access pattern;
  - bank/address mapping, synchronous read latency, same-address read/write policy, writeback timing, pipeline draining;
  - UART protocol: byte order, coefficient packing, command lengths, status/error codes, recovery from invalid or incomplete commands (timeout resync);
  - scheme/operation capture at command acceptance.

## Restated requirements (explicit)
- **Keccak:** Keccak-f[1600] supporting SHA3-256, SHA3-512, SHAKE128 and SHAKE256.
- **Multiplier contract:** for `0 ≤ a, b < q`, return `a·b mod q` with `0 ≤ output < q`.
- **Vivado flow:** complete synthesis, implementation, timing reports (`report_timing_summary`, `report_utilization`) and bitstream generation, all scripted.
- **Unavailable measurements** are explicitly marked **pending** in `docs/report.md` and `docs/status.md`.
- **Atomic polynomial loading:**
  - Coefficients are received into a staging buffer.
  - They are committed to the A/B operand buffer only after the whole command passes validation (length, range, framing).
  - On an invalid coefficient, a malformed command or an inter-byte timeout, the staged data is discarded and the existing operand and result buffers stay as they were.
  - Tests:
    - invalid coefficient at the first, a middle and the last position;
    - interrupted transfers (timeout mid-poly);
    - a successful command right after each failure, with buffers checked unchanged.
- **Synthesis vs post-route are reported separately:**
  - Early out-of-context synthesis is used only to inspect resource inference (DSP/BRAM use, widths); it is labelled "synthesis estimate".
  - Timing and utilization claims come only from place-and-route runs with documented clock and I/O constraints, labelled "post-route".
- **Host input check:** the core rejects any host-supplied coefficient outside `0 ≤ c < q` with a defined protocol error (`ERR_RANGE`). Nothing is stored, and the result buffer is untouched. This is tested in sim and on the board.

## Implementation order
0. **Platform-aware tool discovery.**
   - Detect the OS (`uname` / `$env:OS`); this machine reports win32, but check rather than assume.
   - Find Vivado: `VIVADO_BIN`, `PATH`, then OS-specific default install directories.
   - Look for Icarus/Verilator as fallback simulators.
   - Board serial port: `serial.tools.list_ports`, giving COMx on Windows and `/dev/ttyUSB*` on Linux.
   - If Vivado is only on another machine (e.g. a macOS dev box with a Windows/Linux Vivado host), document reproducible handoff commands in `README.md`.
1. **Inspect and verify existing work.** Run the test suites, read `ntt.py`/`reference.py`, and check that the reference is independent of the fast model.
2. **Early FPGA bring-up.** Before the arithmetic work:
   - UART rx/tx/fifo + echo top level, `constraints/nexys4ddr.xdc` (100 MHz clock, reset button, USB-UART pins).
   - Testbenches for clock/reset behaviour.
   - First full Vivado build: synth → impl → timing → bitstream.
   - Board echo test, or recorded as pending.
3. **Mathematical references.**
   - Schoolbook negacyclic multiplication.
   - NTT and inverse NTT each checked separately against the reference.
   - Full multiplication tests for both schemes.
   - Inputs: zero, one, q−1, sparse/basis, alternating, boundary values, seeded random.
4. **Bit-exact models and scheduler.**
   - `modmul.py`: Barrett for both schemes plus Dilithium special-form, with width asserts on every intermediate. The exhaustive 3329² Kyber test is a separate slow regression (pytest marker).
   - `schedule.py`, a cycle-accurate model of:
     - bank mapping and synchronous read latency;
     - ROM latency;
     - butterfly latency and initiation interval;
     - pending writes, port limits (1 read + 1 write per bank per cycle);
     - read-after-write dependencies and drains.

     Verify forward NTT, inverse NTT, normalization, pointwise/base-case multiply and the full operation for both schemes at P = 1, 2, 4. Compare memory only after writebacks complete.
   - `gen_vectors.py`: ROMs, per-layer vectors, multiplier vectors, schedules.
5. **Arithmetic RTL and butterfly.**
   - `mod_add_sub`, `mod_mul_barrett`, `mod_mul_dil_special`, `butterfly`.
   - Self-checking testbenches with back-to-back transactions, bubbles and reset; the exhaustive Kyber multiplier sim is a slow regression.
   - **Synthesize each standalone multiplier right away** (out-of-context, post-route numbers).
6. **P = 1, both schemes, Barrett.**
   - NTT, inverse NTT and pointwise in `ntt_core`; full multiplication testbench.
   - **RTL-vs-scheduler check:** the testbench logs every accepted butterfly operation (cycle, addresses), every writeback (cycle, bank, address, data), each stage-completion cycle and the total cycles. It diffs the log against the trace `schedule.py` exports. Matching outputs alone do not count as a pass.
   - Synthesize and implement the P = 1 core.
7. **Dilithium special-form build option**, re-running the same testbenches and trace checks.
8. **P = 2 and P = 4**, each verified independently, trace checks included.
9. **Command controller + host commands** (with `ERR_RANGE` and resync on bad or incomplete commands), then the **Keccak core** and its host commands.
10. **Vivado comparison runs:** the four benchmark configurations, the standalone multipliers and the full system, plus an Fmax constraint sweep.
11. **Docs and reproducibility check.**

Blocked checks (no tool, no board) are recorded in `docs/status.md`, and all unaffected work continues.

A working baseline is kept throughout: an unverified optimization never replaces a verified design.

## If tools are missing
If Vivado is missing:
- Simulate with whatever is available (Icarus if present).
- Mark synthesis, timing and board results **pending**.
- Never estimate or fabricate a number.

## Verification requirements
- Self-checking testbenches with actionable mismatch messages (index, expected, got) and a nonzero exit status on failure.
- Keccak:
  - Each mode tested at its own rate boundary (SHA3-256: 135/136/137 bytes; SHA3-512: 71/72/73; SHAKE128: 167/168/169; SHAKE256: 135/136/137), plus empty input and multi-block input.
  - SHAKE outputs tested across squeeze-block boundaries.
  - Checked against `hashlib`, plus NIST known-answer vectors where available.
- Board scripts in `python/host/`:
  - UART echo;
  - two-polynomial multiply for both schemes;
  - hash/XOF commands;
  - repeated commands and protocol recovery.

  They report FPGA compute cycles (from an on-chip cycle counter) separately from host transfer time.

## Benchmarks
- Main table, four configurations:
  - P = 1 with Dilithium Barrett;
  - P = 1 with Dilithium special-form;
  - P = 4 with Dilithium Barrett;
  - P = 4 with Dilithium special-form.

  Kyber is Barrett in all four. P = 2 is verified but may stay out of the table.
- Three separate boundaries: standalone multipliers, standalone NTT core, full system.
- Recorded per run: LUT, FF, DSP, BRAM, measured cycles, latency, WNS/timing.
  - Same part, tool version, settings and clock constraint in every run.
  - Fmax comes from a documented sweep of clock constraints, never from one passing run.
  - Post-route results only.
- "DSP-free" is claimed only if the utilization report shows 0 DSP.
- Ideal issue counts (Kyber 896/224, Dilithium 1,024/256) are labelled as ideal, never as latency.
- Weighted area `A = Slices + 100·DSP + 200·BRAM` and ATP are shown as a literature convention next to raw counts.
- Unavailable measurements are marked **pending**.

## Deliverables / files
- `docs/`:
  - `plan.md` (recreated from this plan);
  - `arithmetic.md`, `architecture.md`;
  - `learning-guide.md` (math, datapath, controller, memory schedule, UART, Keccak, verification, in plain language);
  - `report.md` (results, methodology, limitations, related work with the Ahmad et al. paper attributed);
  - `status.md` (checklist: implemented / simulated / synthesized / timing-verified / board-verified).
- `README.md`: quick start.
- Python:
  - `python/pqc_golden/` (`params`, `ntt`, `reference`, `poly`, `modmul`, `schedule`); the Keccak reference is Python `hashlib`, checked against FIPS 202 known answers;
  - `python/gen_vectors.py`;
  - `python/host/`;
  - `python/tests/`.
- RTL and scripts: `rtl/` (the twiddle ROM is generated as `rtl/twiddle_rom.v`), `tb/`, `constraints/nexys4ddr.xdc`, `scripts/flow.py` plus `build.tcl` and `program.tcl`.

Reuse:
- `Scheme`, `bitrev`, `KYBER`, `DILITHIUM`, `Scheme.zetas`, `Scheme.n_inv` from `python/pqc_golden/params.py`;
- `ntt_layers`, `ntt`, `intt` from `python/pqc_golden/ntt.py`.

## End-to-end verification
- `uv run pytest -m "not slow"` (fast suite) and `uv run pytest -m slow` (exhaustive Kyber multiplier), run as separate suites. The `slow` marker is registered in `pyproject.toml`; the default `uv run pytest` runs everything.
- `uv run python scripts/flow.py sim <tb>` for every testbench; `uv run python scripts/flow.py regress` runs them all.
- `uv run python scripts/flow.py build <target> [options]` and `sweep` for the four benchmark configurations plus the standalone multipliers, writing reports into `build/`.
- Board: `python/host/*.py` against the programmed board, or marked pending.

## Working rules
- Progress updates are short, with evidence and blockers.
- The final summary lists exact checks run and their results, output locations, and unresolved dependencies. The project is never called "verified" while required checks are unrun.
- No commits; at the end, propose subject-line-only commit messages.

## Implementation notes (deviations from the plan, and why)

- **Scripts.** A single cross-platform `scripts/flow.py` (run with `uv run python scripts/flow.py ...`)
  replaces the planned `scripts/run.ps1`. It does the platform-aware Vivado discovery that requirement 0
  asks for. It was run in PowerShell and Git Bash on Windows 11; the Linux paths are untested.
- **Pipeline depth.**
  - The first P = 1 build missed 100 MHz in the special-form build (WNS −0.224 ns) and passed only
    narrowly in the Barrett build. A routing register was added after the bank multiplexers, so D went from 7 to 8.
  - The first P = 4 build failed by 15 ns: the write ports were a priority chain over 8 sources. Bank
    selects are now one-hot and registered, the ports are flat AND-ORs, and a decode register stage
    moved the first issue to cycle 2.
  - `schedule.py` was changed in lock-step, and the RTL-vs-scheduler trace check was re-run.
- **No drain between passes.** `schedule.py` proved that passes can run back to back (GAP = 1)
  without any read-after-write hazard, for every scheme, P and operation. The planned full drain was
  therefore dropped. A negative-control test reverses the group order to show that the hazard check
  fires.
- **Keccak** is byte-streaming (one round per cycle) and is fed directly from the UART, so HASH has
  no message buffer and no length limit besides the 16-bit LEN field.
- **Bank mapping.** The conflict-free mapping is our own XOR fold of the index bits
  (`docs/architecture.md` §1), proven by `schedule.py`. The Guo & Li paper ([25] in Ahmad et al.),
  mentioned earlier in planning, was not read or used.
- **Order of work.** `docs/arithmetic.md` and `docs/architecture.md` were written after the
  arithmetic RTL and the core existed, not before. They describe the final design.
