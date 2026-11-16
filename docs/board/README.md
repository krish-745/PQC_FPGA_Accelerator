# Board test logs

Run on 2026-11-16 on a Nexys 4 DDR (XC7A100T), board serial port COM6, Windows 11, Vivado 2024.2.
RTL at git commit `b9c0723`. All six system bitstreams and the echo bitstream were rebuilt from that
commit just before the test. Each rebuild reproduced the WNS/WHS in `docs/status.md` exactly.

| File | What ran | Result |
|---|---|---|
| `echo.txt` | `pqc_host.py echo` on `build/echo/echo.bit` | PASS, 1000 bytes |
| `selftest_P<P>_DIL_SPECIAL<s>.txt` | `pqc_host.py selftest` (3 rounds, seed 2026) on each of the 6 system bitstreams | 6/6 PASS |
| `soak_P<P>_DIL_SPECIAL<s>_seed4242_x20.txt` | `selftest --repeat 20 --seed 4242` on each of the 6 system bitstreams | 6/6 PASS |
| `soak_P4_DIL_SPECIAL1_seed777_x20.txt` | `selftest --repeat 20 --seed 777`, P = 4 special form | PASS |
| `after_reset_P4_DIL_SPECIAL1.txt` | selftest after pressing CPU_RESET | PASS |
| `op_cycles.txt` | `python/host/opcycles.py` on each of the 6 system bitstreams | 6/6 results OK |
| `manual_checks.txt` | LEDs and the reset button, checked by eye | all as designed |

`opcycles.py` runs NTT and INTT on buffers 0, 1 and 2, then PWM and MUL. It reads back every result
and compares it with `pqc_golden`, using random, all-zero and all-(q − 1) inputs for both schemes.
The cycle counts it records match `docs/report.md` §3.1 (RTL simulation and `schedule.py`) exactly,
for all 6 configurations and every operation, and they do not depend on the data.

**Host timing.** The "RUN (host)" column in the selftest logs is about 16 ms at every P. That is the
FTDI driver's latency timer (`LatencyTimer` = 16 ms for COM6 in the Windows registry): the short
RUN response waits in the USB chip until the timer flushes it. It is not compute time; the FPGA
cycle counter gives that. LOAD and READ take about 80 ms each: 775 bytes at 115200 baud (about 67 ms)
plus the same latency.

To reproduce, program a bitstream with `scripts/flow.py program sys P=<P> DIL_SPECIAL=<s>` and run:
```
uv run python python/host/pqc_host.py selftest --port COMx
uv run python python/host/opcycles.py COMx
```
