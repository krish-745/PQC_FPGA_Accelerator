# Test vectors

Hex files for the Verilog testbenches, written by `python/pqc_golden/vectors.py`. To regenerate them, run this from the `python/` folder:

```
python -m pqc_golden.vectors
```

The output is deterministic, so regenerating only changes the files if the golden model changes.

## Format

Every file loads with `$readmemh`. Each line is one memory word, with no comments or address markers. Every field is 24 bits (6 hex digits). When a line packs several fields, the first one sits in the most significant bits, so a 3-field line loads into `reg [71:0] mem [...]` and splits as `{a, b, p} = mem[i]`.

ML-KEM values only use the low 12 bits of each field. File names start with `kyber_` or `dilithium_`.

## Files

| File | Lines | Fields per line |
|---|---|---|
| `*_zetas.hex` | 128 (ML-KEM) or 256 (ML-DSA) | zeta^bitrev(k): the twiddle ROM contents |
| `*_modmul.hex` | 1009 | a, b, a·b mod q |
| `*_ct.hex` | 1027 | a, b, w, a + w·b, a − w·b |
| `*_gs.hex` | 1027 | a, b, w, a + b, w·(b − a) |
| `*_ntt_in.hex`, `*_ntt_out.hex` | 4 × 256 | one coefficient |
| `*_ntt_l1.hex` ... `*_ntt_lL.hex` | 4 × 256 | the polynomial after layer 1 ... L |
| `*_intt_in.hex`, `*_intt_out.hex` | 4 × 256 | one coefficient; the output includes the 1/2^L scale |
| `*_intt_l1.hex` ... `*_intt_lL.hex` | 4 × 256 | after each layer, before the scale |
| `*_pwm_a.hex`, `*_pwm_b.hex`, `*_pwm_out.hex` | 4 × 256 | NTT-domain inputs and their pointwise product |
| `*_polymul_a.hex`, `*_polymul_b.hex`, `*_polymul_out.hex` | 4 × 256 | a, b and a·b mod (X²⁵⁶ + 1) |

L is 7 for ML-KEM and 8 for ML-DSA. All arithmetic is mod q, and every value is fully reduced into [0, q).

The scalar files start with every combination of 0, 1 and q − 1 (9 lines for modmul, 27 for the butterflies), then 1000 random lines.

Polynomial files hold 4 test cases back to back, and case c is lines 256·c to 256·c + 255. Inside a case, line i is coefficient i, which is also the memory address the hardware uses. In the `ntt`, `intt`, `pwm_a` and `polymul_a` files, case 0 is the constant polynomial 1 and case 1 is all q − 1. The other cases are random. The `b` files hold the same set rotated by one case, so case 0 there is all q − 1.

The NTT of 1 is all ones for ML-DSA and 1, 0, 1, 0, ... for ML-KEM. That's an easy first check in a waveform.

The ML-KEM base-case multiply needs no separate gamma ROM: gamma for pair 2j is zetas[64 + j], and for pair 2j + 1 it is q − zetas[64 + j].
