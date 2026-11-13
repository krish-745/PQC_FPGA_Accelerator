# Report: a configurable ML-KEM / ML-DSA NTT coprocessor on Artix-7

All numbers below come from runs on the final RTL, made on 2026-11-12:
- **Tools:** Vivado 2024.2, default synthesis and implementation strategies; part XC7A100T-1CSG324C (Nexys 4 DDR).
- **Raw reports:** `build/<target>_<options>/`. `uv run python scripts/flow.py summarize` regenerates the build table.
- **Not available:** board measurements are **pending** (no board was connected; see `docs/status.md`).

## 1. What was built

- **NTT core** (`rtl/ntt_core.v`). It serves both schemes and supports:
  - NTT, inverse NTT, pointwise multiply, and full multiplication mod X²⁵⁶ + 1;
  - P = 1, 2 or 4 butterflies;
  - ML-KEM always multiplied by Barrett reduction; ML-DSA by Barrett or by the exact special-form reduction (`DIL_SPECIAL`).
- **Keccak core**: SHA3-256/512 and SHAKE128/256.
- **UART command controller**: atomic loads, range, length, checksum and timeout errors, operand scheme tags.
- **Python golden model, cycle-accurate scheduler and host tools.**

Design details: `docs/arithmetic.md` and `docs/architecture.md`.

## 2. Method

### Verification (summary; full list in `docs/status.md`)

- **Golden model** against independent references: NTT by definition, schoolbook negacyclic
  multiplication, FIPS 203/204 table entries, and FIPS 202 known answers for hashlib.
- **Multipliers**, against `a·b mod q`:
  - ML-KEM exhaustively (3329² pairs), in Python and in RTL simulation, for both builds;
  - ML-DSA with edge and random operands, plus derived intermediate bounds.
- **NTT core** in all six configurations (P = 1, 2, 4 × two ML-DSA multipliers):
  - 23 cases cover every operation and both schemes, including zero, one × X²⁵⁵, an alternating
    0/q−1 polynomial and edge values;
  - the final memory is compared with the golden model;
  - a full cycle trace (129,385 records) must be identical to `schedule.py`.

  While the core is busy, its inputs are driven with random values, and one case is reset in the
  middle of a MUL. Mutation checks confirmed that the trace comparison catches a one-cycle timing
  change, and that the scrambling catches a host write accepted while busy.
- **Full system** (`tb_top`), over the UART pins: a 97-record host transcript including every error
  path, in five configurations.

### Builds

- **Board targets** (`echo`, `sys`) use the board constraint file: a 10 ns clock and asynchronous
  I/O declared as false paths.
- **Standalone units** (`mul`, `core`) are built out of context inside a wrapper that registers every
  port, so all timed paths are register to register. The clock constraint is read **before**
  synthesis.
- **Timing and utilization claims are post-route only.** Synthesis estimates (`synth_util.rpt`) were
  used only to inspect resource inference.
- **Resource numbers.** LUT, FF, LUTRAM, RAMB18 and DSP are taken for the unit's own instance
  (`route_util_hier.rpt`). Registers that Vivado packs into DSP48 blocks are counted inside the DSP,
  not as FFs. "Slices" is the slice count of the whole out-of-context design, so it includes the
  wrapper's port registers.
- **Fmax method.** Each unit was built at a decreasing series of clock periods. One run per period
  was made, stopping at the first period that failed post-route timing. The result is reported as a
  bound: *passes at T_pass, fails at T_fail*. A single passing run is never reported as Fmax.

  WNS is not monotonic in the period (e.g. P = 1 special-form: +0.150 ns at 9.0 ns but +0.252 ns at
  8.5 ns). Placement varies from run to run, so the bounds are approximate to about one sweep step.
- **Latency** is cycles × 10 ns, the clock the board design runs at. Figures at the out-of-context
  sweep period are labelled as such.

## 3. Results

### 3.1 Standalone modular multipliers (both schemes in one unit, post-route, out of context)

| Build | ML-KEM | ML-DSA | LUT | FF | DSP | Slices | Passes | Fails | Fmax bound |
|---|---|---|---|---|---|---|---|---|---|
| `DIL_SPECIAL=0` | Barrett | Barrett | 172 | 97 | 4 | 52 | 8.0 ns | 7.5 ns | 125–133 MHz |
| `DIL_SPECIAL=1` | Barrett (narrow) | special form | 197 | 130 | 3 | 75 | 5.0 ns | 4.5 ns | 200–222 MHz |

Resources are from the 10 ns build.

- **Limiting path.** In the Barrett build it is the second Barrett multiply: the mode-selected
  q1·μ into the DSP cascade. In the special-form build it is the narrow ML-KEM Barrett multiply.
- **Caution in reading the difference.** The special-form build changes two things at once: ML-DSA
  uses the special-form reduction, *and* the ML-KEM Barrett path shrinks to ML-KEM width, because it
  no longer shares the ML-DSA Barrett datapath. The difference is therefore that of the build as a
  whole, not of the ML-DSA reduction alone. The next table separates the two effects.

**ML-DSA reduction alone.** Here the bench wrapper ties `mode` to ML-DSA (`FIXED_MODE=1`), so
synthesis removes all ML-KEM logic. The table compares only the two ML-DSA multiply-and-reduce
datapaths (post-route, out of context; resources from the 10 ns build):

| ML-DSA reduction | LUT | FF | DSP | Slices | Passes | Fails | Fmax bound |
|---|---|---|---|---|---|---|---|
| Barrett | 121 | 90 | 4 | 41 | 7.0 ns | 6.5 ns | 143–154 MHz |
| special form | 132 | 101 | 2 | 41 | 5.0 ns | 4.5 ns | 200–222 MHz |

The exact special-form reduction removes Barrett's quotient-estimate multiplication q1·μ, the only
multiplier Barrett needs after the product (q3·q is already shift-and-add in both builds). That gives
2 fewer DSP blocks, for 11 more LUTs and 11 more FFs. It also raises the Fmax bound from
143–154 to 200–222 MHz, because no multiplier is left after the product.

### 3.2 NTT core (post-route, out of context)

| Config | LUT | LUTRAM | FF | RAMB18 | DSP | Slices | Passes | Fails | Fmax bound |
|---|---|---|---|---|---|---|---|---|---|
| P = 1, ML-DSA Barrett | 1319 | 0 | 473 | 7 | 4 | 420 | 8.0 ns | 7.5 ns | 125–133 MHz |
| P = 1, ML-DSA special form | 1344 | 0 | 505 | 7 | 3 | 428 | 8.0 ns | 7.5 ns | 125–133 MHz |
| P = 2, ML-DSA Barrett | 2871 | 0 | 838 | 14 | 8 | 871 | 8.0 ns (WNS +0.000) | 7.5 ns | 125–133 MHz |
| P = 2, ML-DSA special form | 2912 | 0 | 905 | 14 | 6 | 895 | 7.5 ns | 7.0 ns | 133–143 MHz |
| P = 4, ML-DSA Barrett | 8236 | 384 | 2253 | 4 | 16 | 2452 | 9.0 ns | 8.5 ns (also with `ExtraTimingOpt`) | 111–117 MHz |
| P = 4, ML-DSA special form | 8243 | 384 | 2384 | 4 | 12 | 2496 | 8.0 ns | 7.5 ns | 125–133 MHz |

Resources are from the 10 ns build. ML-KEM uses Barrett in every configuration.

How the memory and DSPs are used:
- **RAMB18.** At P = 1 and P = 2 the bank RAMs (128 or 64 words) map to RAMB18, plus one ROM per lane.
- **P = 4.** The 32-word banks map to LUTRAM, so the 4 RAMB18 are the four lane ROMs.
- **DSP** is 4 per lane with Barrett and 3 with the special-form build.

Limiting paths at the first failing period:
- the Barrett multiply (P = 4) or the butterfly input into the multiplier (P = 1) in the Barrett builds;
- the controller decode from `pass_no` to the twiddle-ROM address in the special-form builds.

**Measured cycles.** These are identical in RTL simulation and `schedule.py`. `cycles` runs from
start acceptance to the first cycle the result is readable. The NTT column also gives the latency
at 100 MHz:

| Scheme | P | NTT (latency at 100 MHz) | INTT | PWM | MUL | Ideal NTT issue count* |
|---|---|---|---|---|---|---|
| ML-KEM | 1 | 906 (9.06 µs) | 1162 | 650 | 3594 (35.9 µs) | 896 |
| ML-KEM | 2 | 458 (4.58 µs) | 586 | 330 | 1802 | 448 |
| ML-KEM | 4 | 234 (2.34 µs) | 298 | 170 | 906 (9.06 µs) | 224 |
| ML-DSA | 1 | 1034 (10.34 µs) | 1290 | 266 | 3594 (35.9 µs) | 1024 |
| ML-DSA | 2 | 522 (5.22 µs) | 650 | 138 | 1802 | 512 |
| ML-DSA | 4 | 266 (2.66 µs) | 330 | 74 | 906 (9.06 µs) | 256 |

\* Butterfly operations ÷ P: an ideal issue count, not a latency. The measured NTT overhead over
the ideal count is a constant 10 cycles: one decode cycle, the 8-cycle pipeline, and the done
cycle. Passes run back to back with no drain, which `schedule.py` proves hazard-free.

At the out-of-context sweep periods (not the board clock), the ML-KEM NTT at P = 4 would take:
- 234 × 8.0 ns = 1.87 µs (special-form build);
- 234 × 9.0 ns = 2.11 µs (Barrett build).

**P = 1 → P = 4 trade-off.**
- **Speed:** cycles drop 3.9× for the NTT and 4.0× for MUL.
- **Area:** LUTs grow 6.2×, mostly from the bank-to-lane routing multiplexers and the write-port
  AND-OR. DSPs grow 4×; FFs grow 4.8×.

### 3.3 Full system on the board clock (post-route, with pins, bitstream written)

| Config | LUT | LUTRAM | FF | RAMB18 | DSP | Slices | WNS at 10 ns | WHS |
|---|---|---|---|---|---|---|---|---|
| P = 1, Barrett | 8867 | 0 | 2503 | 8 | 4 | 2541 | +0.168 ns | +0.119 ns |
| P = 1, special form | 8901 | 0 | 2550 | 8 | 3 | 2510 | +0.693 ns | +0.103 ns |
| P = 2, Barrett | 10391 | 0 | 2868 | 15 | 8 | 2938 | +0.318 ns | +0.131 ns |
| P = 2, special form | 10442 | 0 | 2935 | 15 | 6 | 2997 | +0.153 ns | +0.039 ns |
| P = 4, Barrett | 15820 | 384 | 4267 | 5 | 16 | 4411 | +0.318 ns | +0.050 ns |
| P = 4, special form | 15836 | 384 | 4400 | 5 | 12 | 4481 | +0.092 ns | +0.039 ns |

All six meet 100 MHz with positive setup and hold slack. The build logs show no critical warnings,
no latches and no multiply-driven nets. The ordinary synthesis warnings are all removals of unused
or constant register bits (for example, the upper Barrett quotient bits that ML-KEM never sets).

The system adds about 7,550 LUTs over the core. The P = 1 Barrett system breaks down as:

| Instance | LUT | FF |
|---|---|---|
| `keccak_core` | 7107 | 1640 |
| `cmd_ctrl` | 352 | 287 |
| `uart_rx` | 57 | 40 |
| `uart_tx` | 39 | 31 |
| `ntt_core` | 1310 | 473 |

Keccak dominates: a 1600-bit state with a full combinational round, plus byte-wise XOR and select
across the 200-byte state. `cmd_ctrl` also holds the 256-word staging RAM (1 RAMB18).

The UART echo bring-up design meets 10 ns with WNS +5.036 ns (95 LUT, 116 FF).

### 3.4 Comparison with the literature (convention of Ahmad et al., TCSI 2026)

The paper (Tables I and II) uses the weighted area `A = Slices + 100·DSP + 200·BRAM` for Artix-7,
with `ATP = A × latency (µs)`. For our numbers in that convention:
- a RAMB18 counts as half a BRAM;
- LUTRAM counts only through its slices;
- slices are those of the whole out-of-context design.

This is a literature convention shown next to the raw counts above, not a replacement for them.

**Multiplier (q = 3329 in the paper; our units serve both moduli):**

| Design | Moduli | Freq | LUT | FF | DSP | Slices | A |
|---|---|---|---|---|---|---|---|
| Ahmad et al. (square form) | 3329 | 236 MHz | 328 | 192 | 0 | 106 | 106 |
| Barrett [29] in their Table I | 3329 | 265 MHz | 81 | 112 | 1 | 35 | 135 |
| ours, `DIL_SPECIAL=0` | 3329 and 8380417 | 125–133 MHz | 172 | 97 | 4 | 52 | 452 |
| ours, `DIL_SPECIAL=1` | 3329 and 8380417 | 200–222 MHz | 197 | 130 | 3 | 75 | 375 |

**NTT core:**

| Design | Schemes | NTT cycles | Freq | Latency | LUT | FF | BRAM | DSP | Slices | A | ATP |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Ahmad et al. (4 BU, hybrid radix-2/4) | ML-KEM | 224 | 222 MHz | 1.01 µs | 3470 | 1849 | 0 | 0 | 1098 | 1098 | 1109 |
| ours, P = 4, special form | ML-KEM + ML-DSA | 234 (ML-KEM) | 100 MHz* | 2.34 µs | 8243 | 2384 | 2 | 12 | 2496 | 4096 | 9585 |
| ours, P = 4, Barrett | ML-KEM + ML-DSA | 234 (ML-KEM) | 100 MHz* | 2.34 µs | 8236 | 2253 | 2 | 16 | 2452 | 4452 | 10418 |
| ours, P = 1, special form | ML-KEM + ML-DSA | 906 (ML-KEM) | 100 MHz* | 9.06 µs | 1344 | 505 | 3.5 | 3 | 428 | 1428 | 12938 |

\* The board clock. The out-of-context bounds are in §3.2.

**Reading this honestly.** The cycle counts are close: 234 against 224, the difference being our
10-cycle decode, pipeline and done overhead. On the area-time product the paper's design is about
9× better. The main reasons:
- **Scope.** Our datapath is 23 bits wide and serves both moduli. Its multipliers use DSP blocks,
  which the convention weights at 100 slices each.
- **Memory.** Our three operand buffers are RAM banks with general bank-to-lane routing. The paper
  uses ML-KEM-only, register-based streaming memory with a hand-made schedule.
- **Clock.** We report latency at the 100 MHz board clock. The paper derives 222 MHz "from the
  critical path's logic delay" (its Section IV-B), while our frequencies come from a post-route
  sweep. These are different methods.

The comparison supports these conclusions:
- the parallel schedule reaches near-ideal cycle counts for both schemes;
- the exact special-form ML-DSA reduction halves the DSPs of the ML-DSA datapath (4 → 2) and lifts
  its standalone Fmax bound from 143–154 to 200–222 MHz. In the cores it saves one DSP per lane.
  The P = 4 special-form core passed at 8.0 ns, while the Barrett core failed at 8.5 ns in both
  placements tried (default: WNS −0.042 ns; `ExtraTimingOpt`: −0.093 ns). This is a small margin
  measured on two placements, not a general speed claim;
- a dual-scheme, RAM-based design pays substantially in area-time compared with a
  single-scheme, DSP-free, register-streaming one.

## 4. Limitations

- **No board measurements.** The board was not available. The echo test, the full self-test and the
  host-side transfer timing are pending. The bitstreams exist but have not been run.
- **No security claims.** The design has no side-channel countermeasures, and no leakage evaluation
  was performed.
- **Fmax precision.** Bounds come from one placement per period. Different seeds or strategies could
  move them by about one sweep step.
- **UART speed.** At 115200 baud, moving one polynomial (768 bytes) takes about 67 ms. That dwarfs
  the microsecond compute time, so end-to-end board throughput is limited by the UART, not by P.
- **Untested platforms.** The Linux and macOS paths in `scripts/flow.py` have not been tested.

## 5. Future work

These items are out of the project scope and were not implemented:
- complete ML-KEM / ML-DSA cryptosystems (sampling, compression, encoding, key generation, encapsulation, signing);
- masking and leakage evaluation;
- Kyber's K-RED special-form reduction. It returns 13·a·b, so it needs twiddles pre-scaled by 13⁻¹
  and a compensated inverse-NTT constant;
- the square-form DSP-free multiplier of Ahmad et al.;
- a faster host link (higher UART baud rate or a DMA interface);
- pipelining the controller decode, which limits the special-form builds.

## 6. Related work and attribution

- S. Ahmad, S. Reddy B. R., Hemanth Kumar C, J. Singh, "A Leakage-Aware DSP-Free Square-Form
  Modular Multiplier for ML-KEM", *IEEE Trans. Circuits Syst. I*, 2026, doi:10.1109/TCSI.2026.3731998.
  Used for:
  - the four-butterfly target and its cycle count (224);
  - the idea of reusing one twiddle table for both transform directions, which this project also
    uses, in the FIPS form: read backwards with the subtraction swapped;
  - the Artix-7 area and ATP convention;
  - the comparison figures quoted in §3.4 (their Tables I and II, including the Barrett design [29]
    they cite).
- NIST FIPS 203 (ML-KEM), FIPS 204 (ML-DSA), FIPS 202 (SHA-3): the algorithms, constants and test values.
- A. Menezes, P. van Oorschot, S. Vanstone, *Handbook of Applied Cryptography*, Algorithm 14.42
  (Barrett reduction); the base-2 error bound used here is derived in `docs/arithmetic.md` §6.2.
- Digilent Nexys 4 DDR master XDC: pin assignments.
