# Learning guide

This guide walks through the whole project from the mathematics to the board, in the order you
would explain it to someone new. Each section ends with the file to open next.

## 1. Why polynomial multiplication?

ML-KEM (key exchange) and ML-DSA (signatures) do almost all of their heavy work on polynomials with
256 coefficients. Each coefficient is a number "on a clock" of size q:
- 3329 for ML-KEM;
- 8380417 for ML-DSA.

After 3328 comes 0 again: every result is taken mod q.

Multiplying two such polynomials is also done "on a clock", because x²⁵⁶ wraps around to −1. The
direct method multiplies every coefficient with every other one: 256 × 256 = 65,536
multiplications. That is `schoolbook_mul` in `python/pqc_golden/reference.py`.

**The NTT (number theoretic transform)** is the trick that makes this fast. It is the clock-arithmetic
cousin of the FFT:
1. Transform both polynomials. That costs about 256·log₂(256)/2 multiplications each.
2. Multiply the transforms entry by entry (256 products for ML-DSA).
3. Transform back.

Tiny example, done by hand in `python/tests/test_ntt.py`. With q = 17 and 4 coefficients, the NTT of
[1, 2, 3, 4] is [15, 11, 13, 16]. Multiplying transforms pointwise and transforming back gives
the same answer as the schoolbook product.

Next: `python/pqc_golden/params.py` (the constants), then `ntt.py`.

## 2. The butterfly: the one operation the NTT repeats

Every NTT step takes two coefficients u, v and one constant z (a "twiddle"), and returns:

```
forward (Cooley-Tukey):   u + z·v,   u − z·v
inverse (Gentleman-Sande): u + v,    z·(v − u)
```

It is called a butterfly because the diagram of two inputs crossing to two outputs looks like
wings. One NTT is 7 (ML-KEM) or 8 (ML-DSA) **layers** of 128 butterflies each:
- in layer 1 the partners are 128 positions apart;
- in layer 2 they are 64 apart;
- and so on, halving each time.

**Twiddles.** The twiddles are powers of a root of unity ζ (17 or 1753), stored in a table. The table
order is the order the loops use them, which is "bit-reversed". The inverse NTT reads the same table
backwards, with the subtraction swapped. `docs/arithmetic.md` §3 shows why that is exactly right,
and a test proves it for every entry.

**Bit-reversed output.** The NTT output comes out in "bit-reversed" order. FIPS 203/204 define the
NTT domain that way, so the hardware never reorders it.

**Why ML-KEM is different.** q = 3329 has no 512-th root of unity, so the ML-KEM NTT stops one layer
early. The result is 128 pairs, not 256 single values. Multiplying two transforms therefore means
multiplying pairs like small degree-1 polynomials: `(a0 + a1·X)(b0 + b1·X)` with X² = γ. That is the
"base-case multiply" in `poly.py`.

Next: `python/pqc_golden/poly.py`, then `rtl/butterfly.v`.

## 3. Modular multiplication in hardware

`a·b mod q` is the expensive part. The product of two 23-bit numbers is 46 bits, and dividing by q
in hardware is slow. Two ways around the division are used here.

**Barrett reduction** (both schemes). Precompute μ ≈ 2⁴⁶/q once. Then the quotient ⌊c/q⌋ is
estimated with one more multiplication and two shifts. The estimate is at most 2 too small, so the
remainder lands in [0, 3q) and at most two subtractions fix it. It works for any q, which is why
ML-KEM uses it in every build.

**Special-form reduction** (ML-DSA option). Because q = 2²³ − 2¹³ + 1, the number 2²³ "is worth"
2¹³ − 1 on the q-clock. So the top bits of c can be folded down:

```
c = hi·2²³ + lo   →   lo + hi·2¹³ − hi
```

That is only shifts and adds, no multiplier. Three folds shrink 46 bits to below 2q, and one
subtraction finishes. It is exact: there is no hidden scale factor.

ML-KEM's equivalent trick (K-RED, from 3329 = 13·2⁸ + 1) would return 13·a·b instead of a·b. That is
why it is left as future work.

Both multipliers obey one contract: return a·b mod q, fully reduced. The Python model in
`modmul.py` checks every intermediate against its RTL register width, and the ML-KEM multiplier is
tested on all 11,082,241 input pairs.

Next: `docs/arithmetic.md` §6, `rtl/mod_mul.v`.

## 4. The NTT core: P butterflies sharing memory

One butterfly per clock gives an ML-KEM NTT in ~900 cycles. **P butterflies** in parallel give
~900/P cycles. The hard part is feeding them: 2P reads and 2P writes per clock, while a block RAM has
only two ports.

**Banks.** Each polynomial is split across 2P small RAMs (banks). Think of it as checkout lanes,
where each bank can serve one number per clock. The rule for which coefficient lives in which bank
is an XOR of groups of its index bits. It is chosen so that the 2P numbers needed in the same cycle
are always in 2P different banks, in every layer, even though the partner distance changes from
layer to layer. `docs/architecture.md` §1 explains why.

**Schedule.** The controller walks through "passes":
- one per NTT layer;
- one for scaling at the end of the inverse NTT;
- one to five for pointwise multiplication.

In every cycle it starts a new group of P butterflies. A group's result comes back 8 cycles later
and is written to the same banks. Passes follow each other without pausing. The Python scheduler
proves that no pass ever reads a number before the previous pass has written it. That works because
every pass walks the indices in increasing order.

**The Python scheduler is the reference for the RTL.** `python/pqc_golden/schedule.py` simulates
the core cycle by cycle. For each cycle it records which butterfly starts, what it reads, and what is
written to which bank and address. `tb/tb_ntt_core.v` records the same events from the RTL, and
`scripts/flow.py` compares the two lists record by record. Getting the right final answer is not
enough: the timing must match too.

Next: `python/pqc_golden/schedule.py` (read `run()` and `pass_issues()`), then `rtl/ntt_core.v`.

## 5. Talking to the board: UART and the command protocol

The board's USB port includes a serial converter. The FPGA receives and sends bytes at 115200
bit/s (`uart_rx.v`, `uart_tx.v`). One byte takes 87 µs, so sending a polynomial (768 bytes) takes
~67 ms, while the multiplication itself takes ~36 µs at P = 1. The cycle counter in the RUN response
shows the FPGA's own time separately.

Every request is a small frame: `A5, command, length, payload, checksum`. The controller
(`cmd_ctrl.v`) is careful about bad input:
- **Loads are atomic.** A polynomial goes into a staging buffer first. It reaches the core only if
  every coefficient is in range and the checksum matches. A broken transfer never leaves half a
  polynomial behind.
- **Every request is read to its end** before an error is answered. A gap of more than 10 ms inside a
  request aborts it with ERR_TIMEOUT, and the controller then waits for the next `A5`.
- **Scheme tags.** Each buffer remembers which scheme it was loaded for. Running the wrong scheme on
  it gives ERR_STATE, never silent garbage.

Next: `docs/architecture.md` §2, `python/host/protocol.py`, `rtl/cmd_ctrl.v`.

## 6. Keccak / SHA-3

ML-KEM and ML-DSA use SHA-3 and SHAKE for hashing and for generating randomness from seeds. All of
them are built on one permutation, Keccak-f[1600]:
- 1600 bits of state, mixed by 24 rounds of five simple steps (θ, ρ, π, χ, ι);
- message bytes are XOR-ed into the first r bytes (the rate), then the state is permuted;
- output is read from the same r bytes.

The modes differ only in the rate and a few padding bits. The core does one round per clock and
handles one byte at a time, which suits the UART stream. SHAKE can produce any amount of output: it
permutes again whenever the r bytes are used up.

Next: `rtl/keccak_f1600.v`, `rtl/keccak_core.v`, `tb/tb_keccak.v`.

## 7. How everything is verified

There are layers of evidence, each independent of the one above:
1. **Mathematical reference** (`reference.py`): the NTT computed from its definition, and schoolbook
   multiplication. It shares no code with the fast model.
2. **Fast golden model** (`ntt.py`, `poly.py`), checked against the reference, including the inverse
   NTT on its own.
3. **Bit-exact arithmetic** (`modmul.py`). It matches the RTL register by register, with width
   checks, and is tested exhaustively for ML-KEM.
4. **Cycle-accurate schedule** (`schedule.py`), checked against the golden model after every pass and
   for port conflicts and hazards.
5. **RTL testbenches**, each comparing against something independent:

   | Testbench | Checked against |
   |---|---|
   | `tb_mod_mul`, `tb_butterfly` | Verilog 64-bit integer arithmetic |
   | `tb_ntt_core` | the schedule trace and the golden memory |
   | `tb_keccak` | Python `hashlib` |
   | `tb_top` | a full host transcript, including every error path |

6. **Builds**: synthesis estimates first, then place and route with real timing.
7. **Board tests** (`pqc_host.py selftest`): the same checks on the real chip.

`docs/status.md` says which of these have actually been run, and with what result.
