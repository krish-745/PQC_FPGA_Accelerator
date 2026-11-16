# Architecture

```
 PC (python/host) ── USB-UART 115200 8N1 ──┐
                                           │  rtl/top.v  (Nexys 4 DDR, 100 MHz)
              ┌─────────┐   ┌──────────┐   │
              │ uart_rx │──▶│          │   │   ┌──────────────────────────────────────┐
              └─────────┘   │ cmd_ctrl │──────▶│ ntt_core  (P butterflies)            │
              ┌─────────┐   │ staging  │◀──────│  A, B, C buffers, 2P banks each      │
              │ uart_tx │◀──│ buffer,  │   │   │  twiddle ROM per lane, controller    │
              └─────────┘   │ tags     │   │   └──────────────────────────────────────┘
                            │          │──────▶┌──────────────────────────────────────┐
                            └──────────┘◀──────│ keccak_core (SHA3-256/512, SHAKE128/256)│
                                               └──────────────────────────────────────┘
```

Build-time parameters:
- `P ∈ {1, 2, 4}`: number of butterflies;
- `DIL_SPECIAL ∈ {0, 1}`: ML-DSA multiplier, Barrett or special form.

Arithmetic details are in `docs/arithmetic.md`.

## 1. NTT core (`rtl/ntt_core.v`)

### Operations

| op | Name | Effect |
|---|---|---|
| 0 | NTT(buf) | buf ← NTT(buf), in place, bit-reversed output |
| 1 | INTT(buf) | buf ← NTT⁻¹(buf), in place, including the n⁻¹ scale |
| 2 | PWM | C ← A ∘ B (pointwise; ML-KEM base-case multiply) |
| 3 | MUL | A ← NTT(A), B ← NTT(B), C ← INTT(A ∘ B) = A·B mod (X²⁵⁶ + 1) |

`op`, `scheme` and `buf` are **captured in the cycle `start` is accepted** (`start && !busy`).
Changing the inputs later has no effect on the running operation.

**Overwrite policy.** NTT and INTT work in place. MUL leaves the NTT-domain operands in A and B. It
does not keep the originals; the host reloads them if it needs them.

### Memory

There are three buffers, A, B and C. Each holds 256 coefficients of 23 bits, split into
`2P` simple dual-port banks of `128/P` words (one read and one write port each).
- Coefficient i lives in bank `bank(i)` = XOR of the `b`-bit chunks of i (`b = log2(2P)`), at address `i >> b`.
- The mapping is a bijection (`test_bank_mapping_is_a_bijection`).

| P | banks per buffer | words per bank | index bits that pick the bank |
|---|---|---|---|
| 1 | 2 | 128 | parity of all 8 bits |
| 2 | 4 | 64 | 2-bit chunks XOR-ed |
| 4 | 8 | 32 | 3-bit chunks XOR-ed |

In one cycle, P butterflies read 2P coefficients and write 2P results. For butterfly bit k, the
lanes of a cycle differ in index bits at the residues `{0 … b−1} \ {k mod b}`. So the 2P indices of
a cycle flip 2P different bank bits and land in 2P different banks. The writes D cycles later go to
the same banks. PWM and SCALE read P coefficients per buffer per cycle, in lanes that differ in
index bits `0 … b−2` (ML-KEM pairs: bits `1 … b−1`).

**Same-address read/write policy.** A read and a write of the same bank and address in the same
cycle never happen. `schedule.py` checks this for every configuration. The RAM model is read-first,
but no correct schedule depends on that.

### Schedule and timing

The schedule is `python/pqc_golden/schedule.py`. The RTL replays it, and `tb_ntt_core` checks every
record. Cycle 0 is the cycle in which `start` is accepted.

1. Cycle 1: the first group is decoded (`active`).
2. Cycle 2: the first group is issued.
3. A group issued in cycle t:
   - presents its RAM read addresses and ROM addresses in t;
   - gets its data in t+1, where it is routed to its lane and registered (routing register);
   - enters the butterfly in t+2;
   - is written back in **t + D, with D = 8**.
4. Passes are issued back to back (GAP = 1). Every pass walks its indices in increasing order, so
   the words the next pass reads first were written early in the previous pass. `schedule.py`
   proves for every scheme, P and operation that no read overtakes its write. A negative control
   in the tests reverses the group order and shows the check firing.
5. `done` is high for one cycle at (last issue) + D + 1, and `cycles` holds that cycle's number.
   The host may read the result in that cycle.

Pass list:
- NTT: L forward passes.
- INTT: L inverse passes, then SCALE.
- PWM: one pass (ML-DSA) or K1 … K5 (ML-KEM).
- MUL: NTT(A), NTT(B), PWM, INTT(C).

Each FWD/INV/K pass has 128/P issue cycles; SCALE and the ML-DSA PWM pass have 256/P.

**Measured cycle counts** (`schedule.py`, identical in RTL simulation; `cycles` includes the decode
cycle and the final pipeline drain):

| Scheme | P | NTT | INTT | PWM | MUL | ideal NTT issue count* |
|---|---|---|---|---|---|---|
| ML-KEM | 1 | 906 | 1162 | 650 | 3594 | 896 |
| ML-KEM | 2 | 458 | 586 | 330 | 1802 | 448 |
| ML-KEM | 4 | 234 | 298 | 170 | 906 | 224 |
| ML-DSA | 1 | 1034 | 1290 | 266 | 3594 | 1024 |
| ML-DSA | 2 | 522 | 650 | 138 | 1802 | 512 |
| ML-DSA | 4 | 266 | 330 | 74 | 906 | 256 |

\* Butterfly operations ÷ P, assuming one operation per butterfly per cycle. This is an ideal count,
not a latency.

### Datapath pipeline per lane

| Cycle (rel. to issue t) | What happens |
|---|---|
| t − 1 | decode (combinational, from `pass_no` and the group counter), registered into the issue stage |
| t | issue: RAM addresses = flat AND-OR of one-hot bank selects; ROM address |
| t + 1 | RAM/ROM data, routed to the lane, registered |
| t + 2 … t + 7 | butterfly (pre-add, 4-stage multiplier, post-add) |
| t + 8 | write: one-hot bank selects (registered at t + 7), flat AND-OR into each bank's write port |

The z operand of a lane comes from its own copy of the twiddle ROM, from a B bank (pointwise
multiply), or from the n⁻¹ constant (SCALE).

### Host port (owned by the core only while `busy`)

While `!busy`:
- `h_we` writes `h_wdata` into `h_buf[h_idx]`;
- `h_re` reads, with the data on `h_rdata` in the next cycle.

While `busy`, the host port is ignored. `cmd_ctrl` never uses it then, because it runs one command at
a time.

### Reset

`rst` clears `busy`, the controller and every valid bit in the pipelines. Buffer contents are not
cleared. The command layer also clears its operand tags, so after a reset the host has to reload
before RUN.

## 2. Command controller and host protocol (`rtl/cmd_ctrl.v`, `python/host/protocol.py`)

The UART runs at 115200 baud, 8N1 (`CLKS_PER_BIT = 868` at 100 MHz). Bytes are little-endian, and a
coefficient is 3 bytes LE.

```
Request : A5 | CMD | LEN_lo | LEN_hi | PAYLOAD[LEN] | CHK       CHK = XOR of all bytes after A5
Response: 5A | STATUS | LEN_lo | LEN_hi | PAYLOAD[LEN] | CHK
```

| CMD | Name | LEN | Payload | Response payload |
|---|---|---|---|---|
| 01 | PING | 0 | none | `50 51 P DIL_SPECIAL` |
| 10 | LOAD | 770 | scheme (0 = ML-KEM, 1 = ML-DSA), buffer (0 A, 1 B, 2 C), 256 × 3-byte coefficients | none |
| 11 | READ | 1 | buffer | 768 bytes (256 coefficients) |
| 20 | RUN | 3 | scheme, op (0 NTT, 1 INTT, 2 PWM, 3 MUL), buffer (NTT/INTT only) | 4-byte LE cycle count (from the core) |
| 30 | HASH | 3 + n | mode (0 SHA3-256, 1 SHA3-512, 2 SHAKE128, 3 SHAKE256), outlen (LE16), n message bytes | outlen bytes |

| STATUS | Name | When |
|---|---|---|
| 00 | OK | |
| 01 | ERR_RANGE | a LOAD coefficient is ≥ q of the given scheme (the 24-bit value is checked) |
| 02 | ERR_CMD | unknown CMD |
| 03 | ERR_LEN | LEN differs from the table (HASH: LEN < 3) |
| 04 | ERR_CHK | checksum mismatch |
| 05 | ERR_TIMEOUT | inside a request, no byte for `TIMEOUT` cycles (default 1,000,000 = 10 ms) |
| 06 | ERR_ARG | scheme > 1, buffer > 2, op > 3, mode > 3; SHA3-256 outlen ≠ 32, SHA3-512 ≠ 64, SHAKE outlen = 0 |
| 07 | ERR_STATE | RUN on operands not loaded, or loaded for the other scheme |

Rules:

- **One command at a time.** The response comes after the whole request (including CHK) has
  arrived and the command has finished. Bytes before an A5 are ignored.
- **Complete consumption.** A request is always consumed to its end (LEN payload bytes + CHK)
  before its error response, so the next request starts cleanly. The first error found is reported.
- **Atomic LOAD.** Coefficients go into a 256-word staging buffer. Only if the whole request is valid
  (length, scheme, buffer, every coefficient, checksum) is the staging buffer copied into the core,
  in 256 cycles. Otherwise the A, B and C buffers and the tags are untouched. `tb_top` checks
  invalid coefficients at positions 0, 128 and 255, a 2²⁴ − 1 coefficient, a bad checksum and an
  interrupted transfer, each followed by a READ showing the buffer unchanged. `pqc_host.py selftest`
  runs the same checks on the board (passed on all six bitstreams; see `docs/board/`).
- **Timeout and resync.** After `ERR_TIMEOUT` the controller hunts for the next A5. If the first bytes
  of a request are lost on the wire, the controller never sees its A5, so it answers nothing; a host
  then has to time out and resend. `pqc_host.py` raises an error in that case, it does not retry.
- **Operand tags.** Each buffer carries {loaded, scheme}:
  - LOAD sets the tag;
  - RUN PWM/MUL sets C's tag;
  - RUN NTT/INTT requires the target buffer's tag to match;
  - PWM/MUL require A's and B's tags to match;
  - reset clears all tags.
- **HASH streams.** Message bytes go to the Keccak core as they arrive, so there is no length limit
  besides LEN. A failed checksum gives ERR_CHK and no output. No persistent state is affected,
  because the next HASH re-initializes the core.
- **Cycle counts** in RUN responses are the core's own counter. Host transfer time is measured
  separately by `python/host/pqc_host.py`.

## 3. Keccak core (`rtl/keccak_core.v`, `rtl/keccak_f1600.v`)

- One Keccak-f[1600] round per cycle, so a permutation takes 24 cycles. State: 1600 flip-flops.
- Byte-serial absorb and squeeze. The XOR position is a byte index into the rate.
- Rates: SHA3-256 136, SHA3-512 72, SHAKE128 168, SHAKE256 136 bytes. Domain and padding bytes:
  SHA3 `06 … 80`, SHAKE `1F … 80`. When the suffix and the final bit fall in the same byte, they
  combine.
- Interface: `init` with `mode`; `in_valid`/`in_byte` while `in_ready`; `finish`; `out_req`/`out_valid`/`out_byte`.
  Squeezing past the rate runs another permutation automatically.
- `tb_keccak` checks every mode at its own rate boundaries (empty, 1, r−1, r, r+1, 2r, 2r+1,
  3r+7 bytes) and SHAKE outputs across squeeze blocks (1, 32, r−1, r, r+1, 2r+5 bytes). It uses random
  input gaps and random output backpressure, against Python's `hashlib`, which is itself checked
  against FIPS 202 known answers in `tests/test_protocol_and_hash.py`.

## 4. Clocking, reset and I/O

- One clock domain, the 100 MHz board oscillator.
- `CPU_RESETN` and the UART receive line pass through two-flop synchronizers (`reset_sync`, `uart_rx`).
- The constraints (`constraints/nexys4ddr.xdc`):
  - put a 10 ns clock on `CLK100MHZ`;
  - declare the asynchronous inputs and the slow outputs (UART TX, LEDs) false paths.
- LEDs: 0 heartbeat, 1 core busy, 2 last response was an error, 3 in reset.
