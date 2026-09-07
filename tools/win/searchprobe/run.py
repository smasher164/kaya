#!/usr/bin/env python3
"""Drive the Windows search probe on the VM (docs/search-plan.md §7).

    tools/win/searchprobe/run.py <user@host> [--build]

Everything that measures runs in the guest's INTERACTIVE session as a
scheduled task (an ssh session has its own window station and can neither
see the windows nor synthesize input into them, docs/traps.md), so this
script only ships, builds, schedules, polls and reads the log back.

The probe's own exe gets kaya's minimal-resources.pri beside it: ms-appx
resolves against the PROCESS executable's directory, and without it
XamlControlsResources cannot merge and an AutoSuggestBox has no template
to measure (docs/traps.md; the dragprobe measured that failure).
"""
import pathlib
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
R = r"C:\kaya\searchprobe"
TASK = "kaya_sp"
BUILD = ('cmd /c "cd /d C:\\kaya\\searchprobe\\src && '
         'dotnet build -v m --nologo -c Release -o C:\\kaya\\searchprobe\\bin"')


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
    args = sys.argv[1:]
    build = "--build" in args
    args = [a for a in args if not a.startswith("--")]
    if not args:
        sys.exit(__doc__)
    host = args[0]

    for d in ("src", "bin"):
        ssh(host, f"cmd /c if not exist {R}\\{d} mkdir {R}\\{d}", quiet=True)
    scp(host, sorted(p for p in HERE.glob("*")
                     if p.suffix in (".cs", ".csproj", ".xaml")), f"{R}/src/".replace("\\", "/"))
    scp(host, [HERE / "drive.cmd"], f"{R}/".replace("\\", "/"))

    if build:
        print("== building on the guest ==")
        p = ssh(host, BUILD)
        if p.returncode != 0:
            sys.exit("run.py: the guest build failed")
    # ms-appx resolves against the exe's directory: without kaya's index
    # beside it the control resources cannot merge.
    ssh(host, f"cmd /c copy /y C:\\kaya\\resources.pri {R}\\bin\\resources.pri >nul",
        check=True, quiet=True)

    ssh(host, f"cmd /c del {R}\\log.txt 2>nul & del {R}\\out.txt 2>nul", quiet=True)
    ssh(host, f'schtasks /create /tn {TASK} /tr "{R}\\drive.cmd" /sc once /st 00:00 '
              f"/it /rl highest /f >nul", check=True, quiet=True)
    ssh(host, f"schtasks /run /tn {TASK} >nul", check=True, quiet=True)

    print("== waiting for PROBEDONE ==")
    for _ in range(90):
        out = ssh(host, f"cmd /c type {R}\\log.txt", quiet=True).stdout
        if "PROBEDONE" in out:
            print(out)
            break
        time.sleep(2)
    else:
        print("run.py: no PROBEDONE after 180s; the log so far:", file=sys.stderr)
        print(ssh(host, f"cmd /c type {R}\\log.txt", quiet=True).stdout)
    ssh(host, f"taskkill /f /im KayaSearchProbe.exe >nul 2>&1", quiet=True)
    ssh(host, f"schtasks /delete /tn {TASK} /f >nul 2>&1", quiet=True)


main()
