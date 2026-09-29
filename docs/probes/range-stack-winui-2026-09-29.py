#!/usr/bin/env python3
"""Drive range-stack-winui-2026-09-29.ps1 against a live range guest on the
Windows VM (docs/range-plan.md §4, the WinUI MEASURED paragraph):

    docs/probes/range-stack-winui-2026-09-29.py akhil@192.168.64.2 OUT [--rtl]

The guest is the lane's own range.exe (run `tools/deploy-win.py HOST
range_rust` first), held open by a scratch scene of one `settle` and started
with KAYA_RANGE_PROBE_GAP0. That switch lived in the arm ONLY for the run of
2026-09-29 and is gone: it passed 0 for the gap to `clamp_thumb` in
winui_range_moved so a tie could be pressed, and a re-run puts that one
argument back by hand and takes it out after. Guest and probe are two `schtasks /it` tasks, since an
ssh session can neither see the window nor put input into it
(crates/kaya/src/winui/title-centre-probe.sh's shape). Both tasks are deleted
and the guest killed on the way out, and the probe's log and pictures are
copied into OUT."""

import pathlib
import subprocess
import sys
import tempfile
import time

HERE = pathlib.Path(__file__).resolve().parent
R = r"C:\Users\akhil\kaya-range-probe"


def ssh(host, command, check=False):
    return subprocess.run(["ssh", host, command], capture_output=True, text=True,
                          encoding="utf-8", check=check)


def main():
    host, out = sys.argv[1], pathlib.Path(sys.argv[2])
    rtl = "--rtl" in sys.argv
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as work:
        w = pathlib.Path(work)
        (w / "range.steps").write_text('expect_value range#0 "2 8"\nsettle 240000\n', encoding="utf-8")
        locale = "set KAYA_LOCALE=ar-EG\r\n" if rtl else ""
        (w / "guest.cmd").write_bytes(
            (f"@echo off\r\ncd /d C:\\kaya\r\n{locale}set KAYA_SELFTEST=range\r\n"
             f"set KAYA_RANGE_PROBE_GAP0=1\r\nset KAYA_SCENES_DIR={R}\\scenes\r\n"
             f"range.exe > {R}\\guest.txt 2>&1\r\n").encode())
        flag = " -Rtl" if rtl else ""
        (w / "probe.cmd").write_bytes(
            (f"@echo off\r\npowershell -NoProfile -ExecutionPolicy Bypass -File "
             f"{R}\\probe.ps1 -Log {R}\\log.txt -Shots {R}\\shots{flag} > {R}\\psout.txt 2>&1\r\n"
             ).encode())
        (w / "hidden.vbs").write_bytes(
            b'CreateObject("Wscript.Shell").Run "cmd /c " & WScript.Arguments(0), 0, False\r\n')
        ssh(host, f"cmd /c rmdir /s /q {R} & mkdir {R} & mkdir {R}\\scenes & mkdir {R}\\shots")
        subprocess.run(["scp", "-q", str(HERE / "range-stack-winui-2026-09-29.ps1"),
                        f"{host}:{R}\\probe.ps1"], check=True)
        subprocess.run(["scp", "-q", str(w / "guest.cmd"), str(w / "probe.cmd"),
                        str(w / "hidden.vbs"), f"{host}:{R}\\"], check=True)
        subprocess.run(["scp", "-q", str(w / "range.steps"), f"{host}:{R}\\scenes\\"], check=True)
    try:
        for name, cmd in (("kaya_rp_g", "guest.cmd"), ("kaya_rp_p", "probe.cmd")):
            ssh(host, f'schtasks /create /tn {name} /tr "wscript.exe {R}\\hidden.vbs {R}\\{cmd}" '
                      f"/sc once /st 00:00 /it /f", check=True)
        ssh(host, "schtasks /run /tn kaya_rp_g", check=True)
        time.sleep(6)
        ssh(host, "schtasks /run /tn kaya_rp_p", check=True)
        deadline = time.monotonic() + 240
        log = ""
        while time.monotonic() < deadline:
            log = ssh(host, f"cmd /c type {R}\\log.txt").stdout
            if "PROVE: done" in log:
                break
            time.sleep(3)
        else:
            print(f"range-probe: no 'PROVE: done' within 240s; the log so far:\n{log}")
    finally:
        ssh(host, "taskkill /f /im range.exe & schtasks /delete /tn kaya_rp_g /f & "
                  "schtasks /delete /tn kaya_rp_p /f")
    fwd = R.replace("\\", "/")
    subprocess.run(["scp", "-q", "-r", f"{host}:{fwd}/log.txt", f"{host}:{fwd}/psout.txt",
                    f"{host}:{fwd}/guest.txt", f"{host}:{fwd}/shots", str(out)], check=False)
    print((out / "log.txt").read_text(encoding="utf-8-sig") if (out / "log.txt").exists()
          else "range-probe: no log came back")


main()
