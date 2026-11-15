#!/usr/bin/env python3
"""Drive the Windows highlight probe on the VM (docs/highlight-plan.md §3).

    run.py <user@host>

Ships the sources, builds on the guest, runs drive.cmd as a one-shot /it
scheduled task (an ssh session cannot open a window), reads log.txt back, then
kills the probe, deletes its task and its directory, and lists what is left.
"""
import pathlib
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
R = r"C:\kaya\hl-probe"
TASK = "kaya_hlprobe"


def ssh(host, cmd):
    p = subprocess.run(["ssh", "-n", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=10", host, cmd],
                       capture_output=True, text=True, timeout=600)
    return p


def main():
    host = sys.argv[1]
    for d in ("src", "bin"):
        ssh(host, f"cmd /c if not exist {R}\\{d} mkdir {R}\\{d}")
    srcs = [str(p) for p in HERE.glob("*") if p.suffix in (".cs", ".csproj", ".xaml")]
    subprocess.run(["scp", "-q", *srcs, f"{host}:{R}/src/"], check=True)
    subprocess.run(["scp", "-q", str(HERE / "drive.cmd"), f"{host}:{R}/"], check=True)
    p = ssh(host, f'cmd /c "cd /d {R}\\src && dotnet build -v m --nologo -c Release -o {R}\\bin"')
    print(p.stdout[-1500:])
    if p.returncode != 0:
        sys.exit("run.py: the guest build failed")
    ssh(host, f"cmd /c copy /y C:\\kaya\\resources.pri {R}\\bin\\resources.pri >nul")
    ssh(host, f'schtasks /create /tn {TASK} /tr "{R}\\drive.cmd" /sc once /st 00:00 /it /rl highest /f')
    ssh(host, f"schtasks /run /tn {TASK}")
    log = ""
    for _ in range(60):
        log = ssh(host, f"cmd /c type {R}\\log.txt").stdout
        if "PROBEDONE" in log:
            break
        time.sleep(2)
    (HERE / "log.txt").write_text(log.replace("\r\n", "\n"))
    print(log)
    ssh(host, "taskkill /f /im KayaHlProbe.exe")
    ssh(host, f"schtasks /delete /tn {TASK} /f")
    ssh(host, f"cmd /c rmdir /s /q {R}")
    print(ssh(host, 'cmd /c tasklist /fi "imagename eq KayaHlProbe.exe"').stdout)
    print(ssh(host, f"schtasks /query /tn {TASK}").stderr.strip())


main()
