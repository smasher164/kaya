#!/usr/bin/env python3
"""Run the rich document probe on the VM: ship, build, schedule /it, poll, fetch, clean.

    run.py <user@host> [--build] [--keep]
"""
import pathlib
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
R = r"C:\kaya\doc-probe"
TASK = "kaya_docprobe"
BUILD = ('cmd /c "cd /d C:\\kaya\\doc-probe\\src && '
         'dotnet build -v m --nologo -c Release -o C:\\kaya\\doc-probe\\bin"')


def ssh(host, cmd, check=False, quiet=False):
    p = subprocess.run(["ssh", "-n", "-o", "BatchMode=yes", host, cmd], capture_output=True, text=True,
                       timeout=900)
    if not quiet and p.stdout.strip():
        print(p.stdout.rstrip())
    if not quiet and p.stderr.strip():
        print(p.stderr.rstrip(), file=sys.stderr)
    if check and p.returncode != 0:
        sys.exit(f"run.py: ssh failed ({p.returncode}): {cmd}")
    return p


def main():
    args = sys.argv[1:]
    build = "--build" in args
    keep = "--keep" in args
    host = [a for a in args if not a.startswith("--")][0]
    for d in ("src", "bin"):
        ssh(host, f"cmd /c if not exist {R}\\{d} mkdir {R}\\{d}", quiet=True)
    srcs = sorted(p for p in HERE.glob("*") if p.suffix in (".cs", ".csproj", ".xaml"))
    subprocess.run(["scp", "-q"] + [str(s) for s in srcs] + [f"{host}:{R}/src/"], check=True)
    (HERE / "drive.cmd").write_text(
        "@echo off\r\ncd /d C:\\kaya\\doc-probe\r\ndel log.txt 2>nul\r\n"
        "C:\\kaya\\doc-probe\\bin\\KayaDocProbe.exe > C:\\kaya\\doc-probe\\out.txt 2>&1\r\n")
    subprocess.run(["scp", "-q", str(HERE / "drive.cmd"), f"{host}:{R}/"], check=True)
    if build:
        p = ssh(host, BUILD)
        if p.returncode != 0:
            sys.exit("run.py: the guest build failed")
    ssh(host, f"cmd /c copy /y C:\\kaya\\resources.pri {R}\\bin\\resources.pri >nul", check=True, quiet=True)
    ssh(host, f"cmd /c del {R}\\log.txt 2>nul", quiet=True)
    ssh(host, f'schtasks /create /tn {TASK} /tr "{R}\\drive.cmd" /sc once /st 00:00 /it /rl highest /f >nul',
        check=True, quiet=True)
    ssh(host, f"schtasks /run /tn {TASK} >nul", check=True, quiet=True)
    for _ in range(90):
        out = ssh(host, f"cmd /c type {R}\\log.txt", quiet=True).stdout
        if "PROBEDONE" in out:
            break
        time.sleep(2)
    else:
        print("run.py: no PROBEDONE after 180s", file=sys.stderr)
    for name in ("log.txt", "out.txt", "g1.bmp", "g2.bmp", "g3.bmp", "t-light.bmp", "t-dark.bmp", "t-light2.bmp"):
        subprocess.run(["scp", "-q", f"{host}:C:/kaya/doc-probe/{name}", str(HERE / name)])
    ssh(host, "taskkill /f /im KayaDocProbe.exe >nul 2>&1", quiet=True)
    ssh(host, f"schtasks /delete /tn {TASK} /f", quiet=False)
    if not keep:
        ssh(host, f"cmd /c rmdir /s /q {R}", quiet=True)
    ssh(host, 'cmd /c tasklist /fi "imagename eq KayaDocProbe.exe"')
    ssh(host, f'cmd /c schtasks /query /tn {TASK} 2>&1')


main()
