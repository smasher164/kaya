#!/usr/bin/env python3
"""Drive the Windows rich-text probe on the VM (docs/rich-text-plan.md §3.3).

    run.py <user@host> [--build] [--keep]

Everything that measures runs in the guest's INTERACTIVE session as a
scheduled task (an ssh session has its own window station and can neither see
the windows nor synthesize input into them, docs/traps.md), so this script
only ships, builds, schedules, polls and reads the log back.

The probe's own exe gets kaya's minimal-resources.pri beside it: ms-appx
resolves against the PROCESS executable's directory, and without it
XamlControlsResources cannot merge and a RichEditBox has no template
(docs/traps.md; the dragprobe measured that failure).

--keep leaves C:\\kaya\\richtext-probe in place for a second run; without it
the staged directory is deleted and the task removed.
"""
import pathlib
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
R = r"C:\kaya\richtext-probe"
TASK = "kaya_rt"
BUILD = ('cmd /c "cd /d C:\\kaya\\richtext-probe\\src && '
         'dotnet build -v m --nologo -c Release -o C:\\kaya\\richtext-probe\\bin"')


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


def fetch(host, remote, local):
    p = subprocess.run(["scp", "-q", f"{host}:{remote}", str(local)],
                       capture_output=True, text=True)
    if p.returncode != 0:
        print(f"run.py: could not fetch {remote}: {p.stderr.strip()}", file=sys.stderr)
        return False
    return True


def main():
    args = sys.argv[1:]
    build = "--build" in args
    keep = "--keep" in args
    args = [a for a in args if not a.startswith("--")]
    if not args:
        sys.exit(__doc__)
    host = args[0]

    for d in ("src", "bin"):
        ssh(host, f"cmd /c if not exist {R}\\{d} mkdir {R}\\{d}", quiet=True)
    scp(host, sorted(p for p in HERE.glob("*")
                     if p.suffix in (".cs", ".csproj", ".xaml")), f"{R}/src/")
    scp(host, [HERE / "drive.cmd", HERE / "uia.ps1"], f"{R}/")
    ssh(host, f"cmd /c if not exist {R}\\uia3 mkdir {R}\\uia3", quiet=True)
    scp(host, sorted((HERE / "uia3").glob("*")), f"{R}/uia3/")

    if build:
        print("== building on the guest ==")
        p = ssh(host, BUILD)
        if p.returncode != 0:
            sys.exit("run.py: the guest build failed")
        p = ssh(host, 'cmd /c "cd /d C:\\kaya\\richtext-probe\\uia3 && '
                      'dotnet build -v m --nologo -c Release"')
        if p.returncode != 0:
            sys.exit("run.py: the guest UIA3 build failed")
    ssh(host, f"cmd /c copy /y C:\\kaya\\resources.pri {R}\\bin\\resources.pri >nul",
        check=True, quiet=True)

    ssh(host, f"cmd /c del {R}\\log.txt 2>nul & del {R}\\out.txt 2>nul "
              f"& del {R}\\uia.txt 2>nul & del {R}\\ready.txt 2>nul "
              f"& del {R}\\uia_done.txt 2>nul", quiet=True)
    ssh(host, f'schtasks /create /tn {TASK} /tr "{R}\\drive.cmd" /sc once /st 00:00 '
              f"/it /rl highest /f >nul", check=True, quiet=True)
    ssh(host, f"schtasks /run /tn {TASK} >nul", check=True, quiet=True)

    print("== waiting for PROBEDONE ==")
    for _ in range(150):
        out = ssh(host, f"cmd /c type {R}\\log.txt", quiet=True).stdout
        if "PROBEDONE" in out:
            break
        time.sleep(2)
    else:
        print("run.py: no PROBEDONE after 300s", file=sys.stderr)

    for name in ("log.txt", "out.txt", "uia.txt", "uia3.txt", "specimen.bmp"):
        fetch(host, "C:/kaya/richtext-probe/" + name, HERE / name)

    ssh(host, "taskkill /f /im KayaRichProbe.exe >nul 2>&1", quiet=True)
    ssh(host, f"schtasks /delete /tn {TASK} /f >nul 2>&1", quiet=True)
    if not keep:
        ssh(host, f"cmd /c rmdir /s /q {R}", quiet=True)
    print("== tasklist for the probe ==")
    ssh(host, "cmd /c tasklist /fi \"imagename eq KayaRichProbe.exe\"")


main()
