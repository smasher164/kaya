#!/usr/bin/env python3
"""Drive the Windows drag probe on the VM (docs/dnd-plan.md §2, probes 1-2).

    tools/win/dragprobe/run.py <user@host> <scenario> [--build] [--elevated]

Everything that measures runs in the guest's INTERACTIVE session as a
scheduled task (an ssh session has its own window station and can neither
see the windows nor synthesize input into them, docs/traps.md), so this
script only ships, schedules, polls and reads the logs back.

Scenarios live in drive.ps1: a-winrt-to-win32, b-win32-to-winrt,
c-same-process, d-explorer-to-xaml, e-explorer-to-ole, f-explorer-to-stock.
"""
import pathlib
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
R = r"C:\kaya\dragprobe"
TASK = "kaya_dp"

WINUI_BUILD = 'cmd /c "cd /d C:\\kaya\\dragprobe\\src\\winui && dotnet build -v m --nologo -c Release"'
STOCK_BUILD = 'cmd /c "cd /d C:\\kaya\\dragprobe\\src\\stock && dotnet build -v m --nologo -c Release"'


def ssh(host, cmd, check=False, quiet=False):
    p = subprocess.run(["ssh", "-n", "-o", "BatchMode=yes", host, cmd],
                       capture_output=True, text=True)
    if not quiet and p.stdout.strip():
        print(p.stdout.rstrip())
    if not quiet and p.stderr.strip():
        print(p.stderr.rstrip(), file=sys.stderr)
    if check and p.returncode != 0:
        sys.exit(f"run.py: ssh failed ({p.returncode}): {cmd}")
    return p


def scp(host, sources, dest):
    p = subprocess.run(["scp", "-q"] + [str(s) for s in sources] + [f"{host}:{dest}"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"run.py: scp failed: {p.stderr}")


def main():
    args = [a for a in sys.argv[1:]]
    build = "--build" in args
    elevated = "--elevated" in args
    args = [a for a in args if not a.startswith("--")]
    if len(args) < 2:
        sys.exit(__doc__)
    host, scenario = args[0], args[1]

    for d in (r"src\winui", r"src\stock", r"src\shared", "files"):
        ssh(host, f"cmd /c if not exist {R}\\{d} mkdir {R}\\{d}", quiet=True)
    scp(host, sorted((HERE / "winui").glob("*")), f"{R}/src/winui/".replace("\\", "/"))
    scp(host, sorted((HERE / "stock").glob("*")), f"{R}/src/stock/".replace("\\", "/"))
    scp(host, sorted((HERE / "shared").glob("*")), f"{R}/src/shared/".replace("\\", "/"))
    scp(host, [HERE / "drive.ps1"], f"{R}/".replace("\\", "/"))

    # The file Explorer drags. Written from here so the probe never depends
    # on what happens to be on the guest's desktop.
    note = HERE / "note.txt"
    note.write_text("kaya dragprobe payload\r\n", encoding="utf-8")
    scp(host, [note], f"{R}/files/".replace("\\", "/"))
    note.unlink()

    if build:
        print("== building on the guest ==")
        ssh(host, STOCK_BUILD, check=True)
        ssh(host, WINUI_BUILD, check=True)

    # CRLF, because cmd.exe reads a lone LF as part of the command; and no
    # `&`-joined compound line, because cmd's precedence swallows the tail
    # of an `if exist X … & …` (docs/traps.md, tools/check-steps.py).
    launcher = HERE / "probe.cmd"
    launcher.write_bytes(
        ("@echo off\r\n"
         f"powershell -NoProfile -ExecutionPolicy Bypass -File {R}\\drive.ps1 "
         f"-Scenario {scenario} > {R}\\psout.txt 2>&1\r\n").encode("utf-8"))
    hidden = HERE / "hidden.vbs"
    hidden.write_bytes(
        b'CreateObject("Wscript.Shell").Run "cmd /c " & WScript.Arguments(0), 0, False\r\n')
    scp(host, [launcher, hidden], f"{R}/".replace("\\", "/"))
    launcher.unlink()
    hidden.unlink()

    for f in ("log-drive.txt", "log-winui.txt", "log-stock.txt", "log-stock2.txt", "log-winui2.txt", "psout.txt"):
        ssh(host, f"cmd /c del /q {R}\\{f}", quiet=True)

    rl = " /rl highest" if elevated else ""
    ssh(host, f'schtasks /create /tn {TASK} /tr "wscript.exe {R}\\hidden.vbs {R}\\probe.cmd" '
              f"/sc once /st 00:00 /it{rl} /f", check=True, quiet=True)
    print(f"== running {scenario} (elevated={elevated}) ==")
    ssh(host, f"schtasks /run /tn {TASK}", check=True, quiet=True)

    deadline = time.time() + 300
    done = False
    while time.time() < deadline:
        out = ssh(host, f"cmd /c type {R}\\log-drive.txt", quiet=True).stdout
        if f"scenario {scenario} done" in out:
            done = True
            break
        time.sleep(3)
    if not done:
        print("run.py: the driver never printed its done line; what it wrote is below")

    for name in ("log-drive.txt", "log-winui.txt", "log-winui2.txt", "log-stock.txt", "log-stock2.txt"):
        out = ssh(host, f"cmd /c type {R}\\{name}", quiet=True).stdout
        print(f"\n===== {name} =====")
        print(out.rstrip() or "(empty)")
    ps = ssh(host, f"cmd /c type {R}\\psout.txt", quiet=True).stdout.strip()
    if ps:
        print("\n===== psout.txt (the driver's own console) =====")
        print(ps)

    ssh(host, f"schtasks /delete /tn {TASK} /f", quiet=True)
    ssh(host, "taskkill /f /im KayaDragProbe.exe", quiet=True)
    ssh(host, "taskkill /f /im StockOle.exe", quiet=True)
    sys.exit(0 if done else 1)


main()
