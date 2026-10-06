#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent.parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die, scratch_dir

dev_shell_or_die()

"""Drive the WinUI in-process keystroke probe on the lane's VM.

    tools/win/keyprobe/run.py <user@host> [--no-build]

THROWAWAY, wired into no lane and no gate (tools/win/keyprobe/README.md).
The probe is a module compiled INTO kaya.dll behind the env var
KAYA_KEY_PROBE, reached through tools/win/keyprobe/hook.patch, which must be
applied before this runs and reverted after (`git apply -R`). It ships into
C:\\kaya\\keyprobe, never into C:\\kaya itself, so the lane's deployed
artifacts never gain a probe hook behind a deploy stamp that says they are
unchanged (the undoprobe's rule).

Two copies of one guest run side by side in the interactive session: the
WITNESS takes the foreground and idles with its own entry focused; the
DRIVER, in the background, posts keystrokes to its OWN window and reads
what landed. Both write PROBEDONE; this script ships, builds, schedules,
polls, prints both logs and cleans up.
"""
import subprocess
import time

HERE = pathlib.Path(__file__).resolve().parent
R = r"C:\kaya\keyprobe"
TARGET = ROOT / "target/aarch64-pc-windows-msvc/release"
MOD = ROOT / "crates/kaya/src/winui/mod.rs"
MANIFEST = ROOT / "crates/kaya/Cargo.toml"
ROLES = ("driver", "witness")


def ssh(host, cmd, check=False, quiet=False):
    p = subprocess.run(["ssh", "-n", "-o", "BatchMode=yes", host, cmd],
                       capture_output=True, text=True, encoding="utf-8",
                       errors="replace", check=False)
    if not quiet and p.stdout.strip():
        print(p.stdout.rstrip())
    if not quiet and p.stderr.strip():
        print(p.stderr.rstrip(), file=sys.stderr)
    if check and p.returncode != 0:
        sys.exit(f"keyprobe: ssh failed ({p.returncode}): {cmd}")
    return p


def scp(host, sources, dest):
    p = subprocess.run(["scp", "-q"] + [str(s) for s in sources] + [f"{host}:{dest}"],
                       capture_output=True, text=True, encoding="utf-8",
                       errors="replace", check=False)
    if p.returncode != 0:
        sys.exit(f"keyprobe: scp failed: {p.stderr}")


def hook_applied():
    """The patch is the only way the probe module reaches the build; a run
    against an unpatched tree would measure last week's kaya.dll."""
    mod = MOD.read_text(encoding="utf-8")
    manifest = MANIFEST.read_text(encoding="utf-8")
    return "keyprobe::maybe_spawn();" in mod and 'name = "keyprobe"' in manifest


def build():
    print("== cargo xwin build (kaya.dll + keyprobe.exe) ==")
    p = subprocess.run(
        ["cargo", "xwin", "build", "--locked", "--features", "harness", "--release",
         "--target", "aarch64-pc-windows-msvc", "--lib", "--example", "keyprobe"],
        cwd=ROOT, check=False)
    if p.returncode != 0:
        sys.exit("keyprobe: the build failed")
    p = subprocess.run([str(ROOT / "tools/build-id.py"), "--verify", str(TARGET / "kaya.dll")],
                       cwd=ROOT, check=False)
    if p.returncode != 0:
        sys.exit("keyprobe: kaya.dll does not carry this tree's build id")


def launcher(role):
    # CRLF, because cmd.exe reads a lone LF as part of the command. The
    # driver's and the witness's out files are separate so neither can
    # overwrite the other's PROBEDONE.
    return (
        "@echo off\r\n"
        f"cd /d {R}\r\n"
        f"set KAYA_KEY_PROBE={role}\r\n"
        f"keyprobe.exe > {R}\\out_{role}.txt 2>&1\r\n"
        f"echo EXIT=%ERRORLEVEL% >> {R}\\out_{role}.txt\r\n"
    )


def desk_warm(host):
    """The lane's desktop warm-up: the witness must be able to take the
    foreground, which an interactive session that never painted cannot
    grant (tools/guest/desk-warm.cmd)."""
    ssh(host, r'del C:\kaya\out_deskwarm.txt 2>nul & schtasks /create /tn kaya_deskwarm '
              r'/tr "wscript C:\kaya\run-hidden.vbs desk-warm.cmd" /sc once /st 00:00 '
              r'/it /rl highest /f >nul && schtasks /run /tn kaya_deskwarm >nul',
        check=True, quiet=True)
    for _ in range(60):
        out = ssh(host, r"cmd /c type C:\kaya\out_deskwarm.txt", quiet=True).stdout
        if "DESKWARMEXIT=" in out:
            for line in out.splitlines():
                if "deskwarm.verdict" in line:
                    print(line.rstrip())
            return
        time.sleep(0.5)
    sys.exit("keyprobe: the desktop warm-up never answered")


def schedule(host, role):
    task = f"kaya_keyprobe_{role}"
    ssh(host, f'schtasks /create /tn {task} /tr "wscript C:\\kaya\\run-hidden.vbs '
              f'keyprobe\\{role}.cmd" /sc once /st 00:00 /it /rl highest /f >nul '
              f"&& schtasks /run /tn {task} >nul", check=True, quiet=True)


def cleanup(host):
    ssh(host, 'cmd /c "taskkill /f /im keyprobe.exe & exit /b 0"', quiet=True)
    for role in ROLES:
        ssh(host, f'cmd /c "schtasks /delete /tn kaya_keyprobe_{role} /f & exit /b 0"',
            quiet=True)


def main():
    args = sys.argv[1:]
    no_build = "--no-build" in args
    args = [a for a in args if not a.startswith("--")]
    if not args:
        sys.exit(__doc__)
    host = args[0]

    if not hook_applied():
        sys.exit("keyprobe: the probe hook is not applied — run\n"
                 "    git apply tools/win/keyprobe/hook.patch\n"
                 "first (and `git apply -R tools/win/keyprobe/hook.patch` after the run)")
    if not no_build:
        build()
    for name in ("keyprobe.exe", "kaya.dll"):
        path = TARGET / ("examples/keyprobe.exe" if name.endswith(".exe") else name)
        if not path.exists():
            sys.exit(f"keyprobe: {path} is missing — build first")

    ssh(host, f"cmd /c if not exist {R} mkdir {R}", quiet=True)
    # A live guest holds kaya.dll and scp then fails unhelpfully.
    cleanup(host)
    scp(host, [TARGET / "examples/keyprobe.exe", TARGET / "kaya.dll"], f"{R}/".replace("\\", "/"))
    # The bootstrap DLL is loaded by name and MRT init wants resources.pri
    # beside the exe (the undoprobe's two exe-adjacent prerequisites).
    ssh(host, f'cmd /c "copy /y C:\\kaya\\Microsoft.WindowsAppRuntime.Bootstrap.dll {R}\\ >nul '
              f'&& copy /y C:\\kaya\\resources.pri {R}\\ >nul"', check=True, quiet=True)
    with scratch_dir("keyprobe-") as stage:
        for role in ROLES:
            (stage / f"{role}.cmd").write_text(launcher(role), encoding="utf-8", newline="")
        scp(host, [stage / f"{role}.cmd" for role in ROLES], f"{R}/".replace("\\", "/"))

    ssh(host, f"cmd /c del {R}\\out_driver.txt {R}\\out_witness.txt "
              f"{R}\\witness-ready.txt {R}\\driver-done.txt 2>nul", quiet=True)
    desk_warm(host)

    # The driver first, so its window is up and has been passed over by the
    # time the witness arrives and takes the foreground; the probe module
    # itself confirms the order (the driver refuses to measure while it is
    # the foreground window, and says so).
    schedule(host, "driver")
    time.sleep(4)
    schedule(host, "witness")

    print("== waiting for both PROBEDONEs ==")
    done = set()
    for _ in range(150):
        for role in ROLES:
            if role in done:
                continue
            out = ssh(host, f"cmd /c type {R}\\out_{role}.txt", quiet=True).stdout
            if "PROBEDONE" in out or "EXIT=" in out:
                done.add(role)
        if len(done) == len(ROLES):
            break
        time.sleep(2)
    else:
        print("keyprobe: no PROBEDONE from both halves after 300s; the logs so far:",
              file=sys.stderr)
    time.sleep(1)
    for role in ROLES:
        print(f"===== out_{role}.txt =====")
        print(ssh(host, f"cmd /c type {R}\\out_{role}.txt", quiet=True).stdout)
    cleanup(host)
    print("keyprobe: done — revert the hook with `git apply -R tools/win/keyprobe/hook.patch`")


main()
