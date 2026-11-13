"""One entry point for simulation, builds and regressions. Run from the repo root:

    uv run python scripts/flow.py tools                  # what was found (OS, Vivado, board)
    uv run python scripts/flow.py sim tb_mod_mul [-g DIL_SPECIAL=1] [-p EXHAUSTIVE]
    uv run python scripts/flow.py regress [--slow]       # every testbench, all configurations
    uv run python scripts/flow.py build <target>         # Vivado synth + impl + reports (+ bitstream)
    uv run python scripts/flow.py program <target>       # load build/<target>/<target>.bit onto the board

Vivado is found through VIVADO_BIN, then PATH, then the default install folders of the running OS.
A testbench passes only if its log contains "TEST PASSED" and no "TEST FAILED"/"ERROR"/"FATAL".
"""

import argparse
import glob
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
WIN = platform.system() == "Windows"


def find_vivado_bin() -> Path | None:
    env = os.environ.get("VIVADO_BIN")
    if env and Path(env).is_dir():
        return Path(env)
    exe = shutil.which("vivado")
    if exe:
        return Path(exe).parent
    if WIN:
        pats = [r"C:\Xilinx\Vivado\*\bin", r"C:\AMDDesignTools\*\Vivado\bin", r"D:\Xilinx\Vivado\*\bin"]
    elif platform.system() == "Linux":
        pats = ["/tools/Xilinx/Vivado/*/bin", "/opt/Xilinx/Vivado/*/bin", "/tools/AMD/*/Vivado/bin"]
    else:
        pats = []  # macOS: Vivado does not run natively; see README "Running on another machine"
    hits = sorted(h for p in pats for h in glob.glob(p))
    return Path(hits[-1]) if hits else None


def tool(name: str) -> str:
    vb = find_vivado_bin()
    if vb is None:
        sys.exit(f"Vivado not found (OS: {platform.system()}). Set VIVADO_BIN to <install>/Vivado/<ver>/bin.")
    p = vb / (name + (".bat" if WIN else ""))
    if not p.exists():
        sys.exit(f"{p} missing")
    return str(p)


def run(cmd: list[str], cwd: Path, log: Path | None = None) -> tuple[int, str]:
    if WIN:
        # Vivado's .bat wrappers split unquoted arguments at '=', so quote every argument explicitly.
        cmd = " ".join(f'"{c}"' for c in cmd)
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, errors="replace")
    out = proc.stdout + proc.stderr
    if log:
        log.write_text(out, encoding="utf8")
    return proc.returncode, out


# Testbench name -> RTL files it needs (relative to rtl/).
TB_SOURCES = {
    "tb_mod_mul": ["mod_mul.v"],
    "tb_butterfly": ["mod_mul.v", "butterfly.v"],
    "tb_uart": ["uart_rx.v", "uart_tx.v"],
    "tb_top_uart_echo": ["uart_rx.v", "uart_tx.v", "fifo_sync.v", "reset_sync.v", "top_uart_echo.v"],
    "tb_ntt_core": ["mod_mul.v", "butterfly.v", "twiddle_rom.v", "ntt_core.v"],
    "tb_keccak": ["keccak_f1600.v", "keccak_core.v"],
    "tb_top": [
        "mod_mul.v", "butterfly.v", "twiddle_rom.v", "ntt_core.v", "keccak_f1600.v", "keccak_core.v",
        "uart_rx.v", "uart_tx.v", "reset_sync.v", "cmd_ctrl.v", "top.v",
    ],
}


def sim(tb: str, generics: list[str], plusargs: list[str], tag: str = "", quiet: bool = False) -> bool:
    work = BUILD / "sim" / (tb + (("_" + tag) if tag else ""))
    work.mkdir(parents=True, exist_ok=True)
    srcs = [str(ROOT / "rtl" / f) for f in TB_SOURCES[tb]] + [str(ROOT / "tb" / f"{tb}.v")]
    rc, out = run([tool("xvlog"), "--incr", "-i", str(ROOT / "rtl"), *srcs], work, work / "xvlog.log")
    if rc:
        print(out[-3000:])
        return False
    gen = [x for g in generics for x in ("-generic_top", g)]
    rc, out = run([tool("xelab"), "--incr", "--debug", "off", "--timescale", "1ns/1ps", "-s", "snap", *gen, tb], work, work / "xelab.log")
    if rc:
        print(out[-3000:])
        return False
    if tb == "tb_ntt_core":
        cfg = dict(g.split("=") for g in generics)
        vec = BUILD / "vectors"
        plusargs = plusargs + [f"CASES={(vec / 'ntt_cases.txt').as_posix()}",
                               f"MEM={(vec / f'ntt_P{cfg.get("P", 1)}_S{cfg.get("DIL_SPECIAL", 0)}_mem.txt').as_posix()}"]
    if tb == "tb_keccak":
        plusargs = plusargs + [f"CASES={(BUILD / 'vectors' / 'keccak_cases.txt').as_posix()}"]
    if tb == "tb_top":
        cfg = dict(g.split("=") for g in generics)
        name = f"top_P{cfg.get('P', 1)}_S{cfg.get('DIL_SPECIAL', 0)}.txt"
        plusargs = plusargs + [f"SCRIPT={(BUILD / 'vectors' / name).as_posix()}"]
    pa =[x for p in plusargs for x in ("-testplusarg", p)]
    rc, out = run([tool("xsim"), "snap", "-R", *pa], work, work / "xsim.log")
    ok = "TEST PASSED" in out and not any(s in out for s in ("TEST FAILED", "ERROR:", "FATAL"))
    label = f"{tb} {' '.join(generics)} {' '.join('+' + p for p in plusargs if '/' not in p)}".strip()
    print(f"[{'PASS' if ok else 'FAIL'}] {label}   (log: {work / 'xsim.log'})")
    if not ok and not quiet:
        lines = [ln for ln in out.splitlines() if "ERROR" in ln or "FAIL" in ln or "mismatch" in ln]
        print("\n".join(lines[:20]))
    return ok


def regress(slow: bool) -> bool:
    import gen_vectors  # noqa: F401  (python/ on sys.path below)

    gen_vectors.main()
    jobs = [("tb_mod_mul", [f"DIL_SPECIAL={d}"], []) for d in (0, 1)]
    jobs += [("tb_butterfly", [f"DIL_SPECIAL={d}"], []) for d in (0, 1)]
    jobs += [("tb_uart", [], []), ("tb_top_uart_echo", [], [])]
    jobs += [("tb_ntt_core", [f"P={p}", f"DIL_SPECIAL={d}"], []) for p in (1, 2, 4) for d in (0, 1)]
    jobs += [("tb_keccak", [], [])]
    jobs += [("tb_top", [f"P={p}", f"DIL_SPECIAL={d}"], []) for p in (1, 2, 4) for d in (0, 1)]
    if slow:
        jobs += [("tb_mod_mul", [f"DIL_SPECIAL={d}"], ["EXHAUSTIVE"]) for d in (0, 1)]
    results = []
    for tb, g, p in jobs:
        tag = "_".join(x.replace("=", "") for x in g + p)
        ok = sim(tb, g, p, tag)
        if ok and tb == "tb_ntt_core":
            ok = compare_ntt_traces(BUILD / "sim" / f"{tb}_{tag}", g)
        results.append(ok)
    print(f"\n{sum(results)}/{len(results)} testbenches passed")
    return all(results)


def compare_ntt_traces(work: Path, generics: list[str]) -> bool:
    """RTL cycle trace vs python/pqc_golden/schedule.py trace, record by record."""
    cfg = dict(g.split("=") for g in generics)
    exp = (ROOT / "build" / "vectors" / f"ntt_P{cfg['P']}_S{cfg['DIL_SPECIAL']}_trace.txt").read_text().split("\n")
    got_path = work / "rtl_trace.txt"
    if not got_path.exists():
        print("  trace: rtl_trace.txt missing")
        return False
    got = got_path.read_text().split("\n")
    exp = sorted(x for x in exp if x.strip())
    got = sorted(x for x in got if x.strip())
    if exp == got:
        print(f"  trace: {len(got)} records identical to schedule.py")
        return True
    se, sg = set(exp), set(got)
    print(f"  trace MISMATCH: {len(exp)} expected, {len(got)} from RTL")
    for x in sorted(se - sg)[:8]:
        print("    missing in RTL:", x)
    for x in sorted(sg - se)[:8]:
        print("    extra in RTL:  ", x)
    return False


def build_dir(target: str, extra: list[str]) -> Path:
    return BUILD / "_".join([target] + [x.replace("=", "") for x in extra])


def build(target: str, extra: list[str]) -> bool:
    out = build_dir(target, extra)
    out.mkdir(parents=True, exist_ok=True)
    cmd = [tool("vivado"), "-mode", "batch", "-nojournal", "-log", str(out / "vivado.log"),
           "-source", str(ROOT / "scripts" / "build.tcl"), "-tclargs", target, str(out), *extra]
    rc, text = run(cmd, ROOT)
    print("\n".join(ln for ln in text.splitlines() if "BUILD DONE" in ln or ln.startswith("ERROR")))
    if rc != 0 or not (out / "summary.txt").exists():
        print(f"BUILD FAILED: see {out / 'vivado.log'}")
        return False
    wns = float(read_summary(out)["wns_ns"])
    if wns < 0:
        print(f"TIMING FAILED: WNS {wns} ns at the constrained period (outputs written, not usable)")
        return False
    return True


def read_summary(d: Path) -> dict:
    """summary.txt key = value lines plus the instance row of route_util_hier.rpt and synth_util.rpt."""
    info = {}
    for ln in (d / "summary.txt").read_text().splitlines():
        if " = " in ln:
            k, v = ln.split(" = ", 1)
            info[k.strip()] = v.strip()
    inst = {"mul": "u_mul", "core": "u_core"}.get(info.get("target"), None)
    rows = [ln for ln in (d / "route_util_hier.rpt").read_text().splitlines()
            if ln.startswith("|") and ln.count("|") >= 11 and ln.split("|")[3].strip().isdigit()]
    row = next((r for r in rows if inst and r.split("|")[1].strip() == inst), rows[0])  # rows[0] = top level
    cols = [c.strip() for c in row.split("|")[1:-1]]
    # Instance | Module | Total LUTs | Logic LUTs | LUTRAMs | SRLs | FFs | RAMB36 | RAMB18 | DSP Blocks
    info.update(lut=int(cols[2]), lutram=int(cols[4]), ff=int(cols[6]), ramb36=int(cols[7]),
                ramb18=int(cols[8]), dsp=int(cols[9]))
    util = (d / "route_util.rpt").read_text().splitlines()
    sl = [ln for ln in util if ln.startswith("| Slice ") and "LUTs" not in ln and "Registers" not in ln]
    info["slices_total"] = int(sl[0].split("|")[2]) if sl else None
    return info


def sweep(target: str, extra: list[str], periods: list[float]) -> None:
    """Build at decreasing clock periods until one fails timing; the last passing one bounds Fmax."""
    for per in periods:
        opts = extra + [f"period={per}"]
        build(target, opts)
        info = read_summary(build_dir(target, opts))
        wns = float(info["wns_ns"])
        print(f"SWEEP {target} {' '.join(extra)} period={per} wns={wns}")
        if wns < 0:
            break


def summarize() -> None:
    """Markdown table of every build directory."""
    print("| build | period ns | WNS ns | WHS ns | LUT | LUTRAM | FF | RAMB18 | RAMB36 | DSP | slices (whole design) |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for d in sorted(BUILD.iterdir()):
        if not (d / "summary.txt").exists() or not (d / "route_util_hier.rpt").exists():
            continue
        try:
            i = read_summary(d)
        except Exception as e:  # incomplete build
            print(f"| {d.name} | incomplete ({e}) |")
            continue
        per = i.get("period", "")
        print(f"| {d.name} | {per} | {i['wns_ns']} | {i['whs_ns']} | {i['lut']} | {i['lutram']} | {i['ff']} | "
              f"{i['ramb18']} | {i['ramb36']} | {i['dsp']} | {i['slices_total']} |")


def main() -> None:
    sys.path.insert(0, str(ROOT / "python"))
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("tools")
    s = sub.add_parser("sim")
    s.add_argument("tb")
    s.add_argument("-g", "--generic", action="append", default=[])
    s.add_argument("-p", "--plusarg", action="append", default=[])
    r = sub.add_parser("regress")
    r.add_argument("--slow", action="store_true")
    b = sub.add_parser("build")
    b.add_argument("target")
    b.add_argument("extra", nargs="*", help="key=value options passed to build.tcl")
    sw = sub.add_parser("sweep")
    sw.add_argument("target")
    sw.add_argument("extra", nargs="*")
    sw.add_argument("--periods", default="10,9.5,9,8.5,8,7.5,7,6.5,6")
    sub.add_parser("summarize")
    pg = sub.add_parser("program")
    pg.add_argument("target")
    pg.add_argument("extra", nargs="*")
    a = ap.parse_args()
    if a.cmd == "tools":
        print("OS:", platform.system(), platform.release())
        print("Vivado bin:", find_vivado_bin())
        try:
            from serial.tools import list_ports

            print("serial ports:", [f"{p.device} ({p.description})" for p in list_ports.comports()])
        except ImportError:
            print("pyserial not installed (uv sync installs it)")
    elif a.cmd == "sim":
        tag = "_".join(x.replace("=", "") for x in a.generic + a.plusarg)
        ok = sim(a.tb, a.generic, a.plusarg, tag)
        if ok and a.tb == "tb_ntt_core":
            ok = compare_ntt_traces(BUILD / "sim" / f"{a.tb}_{tag}", a.generic)
        sys.exit(0 if ok else 1)
    elif a.cmd == "regress":
        sys.exit(0 if regress(a.slow) else 1)
    elif a.cmd == "build":
        sys.exit(0 if build(a.target, a.extra) else 1)
    elif a.cmd == "sweep":
        sweep(a.target, a.extra, [float(x) for x in a.periods.split(",")])
    elif a.cmd == "summarize":
        summarize()
    elif a.cmd == "program":
        out = build_dir(a.target, a.extra)
        rc, text = run([tool("vivado"), "-mode", "batch", "-nojournal", "-source", str(ROOT / "scripts" / "program.tcl"),
                        "-tclargs", str(out / f"{a.target}.bit")], ROOT)
        print("\n".join(text.splitlines()[-15:]))
        sys.exit(rc)


if __name__ == "__main__":
    main()
