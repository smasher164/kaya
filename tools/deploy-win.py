#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# Deploy to the Windows VM and run the validations.
#
# Usage: tools/deploy-win.py user@host [--provision] [<leg>|all]
#        tools/deploy-win.py user@host <scene>_<lang>  # ONE leg
#        tools/deploy-win.py user@host probe=<exe>     # aliveness probe
#
# The roster, its order and the drain barriers are DATA:
# tools/lib/lanes/win.py, the one source the gates import too.
#
# EVERYTHING THAT LANDS ON THE VM AS A FILE IS SHIPPED WITH scp, never
# constructed remotely by echoing escaped text over ssh: two escaping
# layers (bash quoting, then cmd.exe carets) mangle it reliably. New
# guest-side scripts go in tools/guest/, where the deploy's glob ships
# them.
#
# Guest requirements (one-time; snapshot afterward): OpenSSH with key
# auth and sshd Automatic; a LOGGED-IN console session, since WinUI
# cannot run in the SSH service session; and, for the python/go/csharp
# suites, winget Python.Python.3.13 / GoLang.Go / Microsoft.DotNet.SDK.10
# plus an llvm-mingw ucrt-aarch64 release under C:\kaya (cgo needs a C
# compiler).
#
# Builds RELEASE: build.rs's hybrid CRT policy makes release artifacts
# self-contained, while a debug build still imports vcruntime.

import atexit
import hashlib
import json
import re
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import os

from lanes import win as lane
import flightrec_lane

SELF = pathlib.Path(__file__).resolve()
LANE_MODULE = ROOT / "tools/lib/lanes/win.py"

# THE SSH MUX SOCKET, COMPUTED AND REFUSED BEFORE ANYTHING IS BUILT:
# sun_path is 104 bytes INCLUDING the terminator. NOT $TMPDIR — `nix
# develop` deletes it on exit, so ControlPersist would have nothing to
# persist in (docs/traps.md, "A deep worktree MADE deploy-win.py
# unreachable, and the error named ssh").
KAYA_SOCK_MAX = 103
MUX_DIR = pathlib.Path(os.environ.get("KAYA_SSH_MUX_DIR",
                                      os.path.expanduser("~/.ssh/kaya-mux")))
_mux_key = hashlib.sha256(
    f"{ROOT}\n{sys.argv[1] if len(sys.argv) > 1 else ''}\n".encode()
).hexdigest()[:16]
CONTROL_PATH = str(MUX_DIR) + f"/m-{_mux_key}"
# NO ssh TOKENS, or the length clause below is a lie: ssh expands
# %r/%h/%C when it binds, so a literal length is only a lower bound.
if "%" in CONTROL_PATH:
    print("deploy-win: the ssh ControlPath carries a % token, which expands "
          "when ssh binds:", file=sys.stderr)
    print(f"  {CONTROL_PATH}", file=sys.stderr)
    print("  The length clause below reads the literal, so it cannot see the "
          "bound path.", file=sys.stderr)
    print("  Fold the destination into the mux key instead of naming it with "
          "a token.", file=sys.stderr)
    sys.exit(1)
_sock_len = len(CONTROL_PATH.encode())
if _sock_len > KAYA_SOCK_MAX:
    print(f"deploy-win: the ssh ControlPath is {_sock_len} bytes, past the "
          f"{KAYA_SOCK_MAX}-byte unix-socket limit (sun_path is 104 with the "
          f"terminator):", file=sys.stderr)
    print(f"  {CONTROL_PATH}", file=sys.stderr)
    print("  Set KAYA_SSH_MUX_DIR to a shorter directory and re-run.",
          file=sys.stderr)
    print("  Refusing here rather than at the first ssh, which is after the "
          "windows cross-build.", file=sys.stderr)
    sys.exit(1)
MUX_DIR.mkdir(parents=True, exist_ok=True)
MUX_DIR.chmod(0o700)

_t0 = time.monotonic()


def timing(phase):
    global _t0
    print(f"TIMING {phase} {int(time.monotonic() - _t0)}s", flush=True)
    _t0 = time.monotonic()


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


# Compile the windows target before touching the VM.
if subprocess.run([str(ROOT / "tools/check-targets.py"), "windows"],
                  check=False).returncode != 0:
    sys.exit(1)
timing("check-targets")

if len(sys.argv) < 2:
    die("usage: deploy-win.py user@host [--provision] [rust|python|go|all]")
HOST = sys.argv[1]
PROVISION = False
SUITE = "all"
PHASES = ("caption-centre", "enable-dumps", "crash-report", "analyze-dump")
for arg in sys.argv[2:]:
    if arg == "--provision":
        PROVISION = True
    elif arg == "all" or arg in PHASES or arg.startswith("probe="):
        SUITE = arg
    elif arg in lane.legs():
        # EVERY LEG CAN BE RUN ON ITS OWN: the roster is the argument
        # grammar.
        SUITE = arg
    else:
        print(f"unknown argument: {arg}", file=sys.stderr)
        sys.exit(2)

TARGET = ROOT / "target/aarch64-pc-windows-msvc/release"
SDK = ROOT / "third_party/winappsdk"
BOOTSTRAP = (SDK / "Microsoft.WindowsAppSDK.Foundation-2.1.0/extracted/"
             "runtimes/win-arm64/native/Microsoft.WindowsAppRuntime."
             "Bootstrap.dll")
# NAMED BEFORE IT IS MISSED: third_party/ is gitignored, so a worktree
# is born without the SDK, and the failure without this is two bare
# `shasum: ... No such file` lines minutes apart (measured 2026-08-28).
if not BOOTSTRAP.is_file():
    die(f"deploy-win: the Windows App SDK is not unpacked under {SDK} — run "
        f"tools/fetch-winappsdk.sh first (it fetches the five pinned "
        f"packages and verifies each one's sha256). A worktree needs its own "
        f"copy, or a symlink to one.")

# ONE master TCP/auth handshake, every subsequent ssh/scp rides it
# (~1.4s per round trip before). ConnectTimeout rides every call and
# ServerAlive the master, because a guest OS that wedges mid-run leaves
# UTM saying "started" and sshd gone (docs/traps.md, "The wedged-VM
# class"): without them the blocked leg waiter hangs its full deadline.
SSH_MUX = ["-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=15",
           "-o", "ServerAliveCountMax=4", "-o", "ControlMaster=auto",
           "-o", f"ControlPath={CONTROL_PATH}", "-o", "ControlPersist=120"]


def run_ssh(cmd, log=None):
    """One remote command over the mux; returns the rc. Output goes to
    this process's streams (or the leg's log when given)."""
    return subprocess.run(
        ["ssh", "-n", "-o", "BatchMode=yes", *SSH_MUX, HOST, cmd],
        stdout=log, stderr=log, check=False).returncode


def run_ssh_out(cmd, log=None):
    """Captured stdout of a remote command, or None on failure."""
    out = subprocess.run(
        ["ssh", "-n", "-o", "BatchMode=yes", *SSH_MUX, HOST, cmd],
        stdout=subprocess.PIPE, stderr=log, text=True,
        encoding="utf-8", errors="replace", check=False)
    return out.stdout if out.returncode == 0 else None


def must_ssh(cmd):
    if run_ssh(cmd) != 0:
        die(f"deploy-win: remote command failed: {cmd}")


def scp_to(sources, dest, log=None):
    """scp local files to the VM over the mux; returns the rc."""
    return subprocess.run(
        ["scp", *SSH_MUX, "-q", *[str(s) for s in sources],
         f"{HOST}:{dest}"],
        stdout=log, stderr=log, check=False).returncode


def scp_dir_to(sources, dest):
    """Recursive copy; a list ships each entry (the shell's `dir/*`)."""
    if not isinstance(sources, list):
        sources = [sources]
    return subprocess.run(
        ["scp", *SSH_MUX, "-q", "-r", *[str(s) for s in sources],
         f"{HOST}:{dest}"],
        check=False).returncode


def scp_from(remote, local, log=None):
    out = subprocess.run(
        ["scp", *SSH_MUX, "-q", f"{HOST}:{remote}", str(local)],
        stdout=log, stderr=subprocess.DEVNULL, check=False)
    return out.returncode == 0


def ssh_probe():
    """Reachability, NOT through the mux: a dead master must not answer
    for a live guest or the reverse."""
    return subprocess.run(
        ["ssh", "-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", HOST,
         "exit 0"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        check=False).returncode == 0


# The trailing grace period lets the console session finish logging in —
# the suites run as scheduled tasks with /it, which need it.
VM_NAME = os.environ.get("KAYA_WIN_VM", "Windows")


def utmctl_bin():
    return (shutil.which("utmctl")
            or "/Applications/UTM.app/Contents/MacOS/utmctl")


def utm_started():
    out = subprocess.run([utmctl_bin(), "status", VM_NAME],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         text=True, encoding="utf-8", errors="replace", check=False)
    return "started" in out.stdout.lower()


def vm_boot():
    booted = False
    if utm_started():
        # WAIT BEFORE KILLING: "started but unreachable" is the shape of
        # a guest that BUGCHECKED and is rebooting, not only of one that
        # hung. Killing it there costs twice — the crash dump converts
        # to C:\Windows\Minidump only on the NEXT boot (7 of 12 crashes
        # left no dump that way), and a power cut mid-boot corrupted
        # this VM's boot volume on 2026-08-04.
        print(f'== {HOST} unreachable; giving "{VM_NAME}" 3 minutes to '
              f'finish a possible bugcheck reboot ==')
        waited = 0
        while waited < 180:
            if ssh_probe():
                print(f"== {HOST} came back on its own after {waited}s "
                      f"(a crash reboot, not a wedge) ==")
                booted = True
                break
            time.sleep(10)
            waited += 10
    if not booted and utm_started():
        print(f"== {HOST} still unreachable after 3 minutes; "
              f"force-restarting ==")
        subprocess.run([utmctl_bin(), "stop", "--kill", VM_NAME], check=False)
        tries = 0
        while utm_started():
            tries += 1
            if tries > 12:
                die(f'VM "{VM_NAME}" would not stop')
            time.sleep(5)
    if not booted:
        print(f'== {HOST} unreachable; starting VM "{VM_NAME}" ==')
    subprocess.run([utmctl_bin(), "start", VM_NAME], check=False)
    tries = 0
    while not ssh_probe():
        tries += 1
        if tries > 60:
            die(f'VM "{VM_NAME}" did not become reachable')
        time.sleep(5)
    time.sleep(30)
    # AND SAY WHETHER THE GUEST CRASHED: "the VM was unreachable" reads
    # as host contention and was recorded as such while the guest was
    # really BUGCHECKING (docs/traps.md, "The wedge is a BSOD in
    # viogpudo.sys"). A dump written to the pagefile only becomes a file
    # on the boot AFTER the crash, so this is the first moment it shows.
    out = subprocess.run(
        ["ssh", "-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", HOST,
         'powershell -NoProfile -Command "Get-ChildItem '
         "C:\\Windows\\Minidump\\*.dmp -ErrorAction SilentlyContinue | "
         "Sort-Object LastWriteTime | Select-Object -Last 1 "
         '-ExpandProperty Name"'],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        encoding="utf-8", errors="replace",
        check=False)
    latest = out.stdout.replace("\r", "").strip()
    if latest:
        print(f"== the guest's newest crash dump is {latest} — if that is "
              f"from this run, the VM did not hang, it BUGCHECKED "
              f"(docs/traps.md, the viogpudo class) ==")


if not ssh_probe():
    vm_boot()
timing("vm-ready")

SCENES = lane.SCENES
DEPTH_SCENES = lane.depth_scenes()
GO_ONLY_SCENES = lane.GO_ONLY_SCENES
PY_ONLY_SCENES = lane.PY_ONLY_SCENES

SCENE_EXES = [TARGET / f"examples/{s}.exe" for s in SCENES + DEPTH_SCENES]
SCENE_PYS = ([ROOT / f"guests/python/{s}.py" for s in SCENES]
             + [ROOT / f"guests/python/{s}.py" for s in PY_ONLY_SCENES])
# The JS guests ship FLAT beside the python ones (C:\kaya\<scene>.ts) and
# import the binding from C:\kaya\node_modules\kaya-gui, which is where
# node's bare-specifier resolution looks from a flat file
# (docs/js-plan.md §5).
SCENE_TSS = [ROOT / f"guests/js/{s}.ts" for s in SCENES]
NODE_VERSION = "24.19.0"
NODE_WIN_ARM64_SHA256 = "8502f4a50b458d4cc38ed8f2001556c2cd239d464920f74017926ccb1e1c157f"
NODE_DIR = f"C:\\kaya\\node24\\node-v{NODE_VERSION}-win-arm64"
# The Go toolchain, the same rule: go.dev's published sha256, verified
# before expansion.
GO_VERSION = "1.27.0"
GO_WIN_ARM64_SHA256 = "6e0156b9788209931dd340fadc04171ce15063c17b51c92e7b86b51109626e90"
BUILD_EXAMPLES = []
for _s in SCENES + DEPTH_SCENES:
    BUILD_EXAMPLES += ["--example", _s]


# ONE CAPTION WRITER, enforced before anything is built. The `dirty`
# prop lowers to TEXT on Windows — a leading `*` composed into the
# caption — so a second caption writer blinks the mark out on a push, a
# pop or a split-mode change (docs/dirty-plan.md D2). A text check
# because `Window::SetTitle` is a WinRT projection method and is always
# callable; HERE because every Windows change goes through this deploy.
NOT_A_CAPTION = {"bar_item", "dialog"}
CAPTION_CALL = re.compile(r"(\w+)\.SetTitle\(")
# ANY indent, so a method inside an impl block resets the tracker too —
# a column-0-only match would let a `SetTitle` in the Stage impl inherit
# the sanction of whatever free function was declared above it.
FN_HEADER = re.compile(r"\s*(?:pub(?:\(\w+\))?\s+)?(?:unsafe\s+)?fn\s")
CAPTION_WRITER = "fn refresh_caption("
CAPTION_PLACEHOLDER = "fn setup("


def caption_audit(text):
    """Offending caption writes as (line-number, receiver) pairs."""
    fn, bad = "", []
    for n, line in enumerate(text.splitlines(), 1):
        if FN_HEADER.match(line):
            fn = line.strip()
        for m in CAPTION_CALL.finditer(line):
            recv = m.group(1)
            if recv in NOT_A_CAPTION:
                continue
            if CAPTION_WRITER in fn or CAPTION_PLACEHOLDER in fn:
                continue
            bad.append((n, recv))
    return bad


def caption_census():
    # THE SELF-TEST RUNS FIRST, because a checker that cannot see a
    # bypass reports OK on every tree including a broken one.
    bypass = 'fn refresh_nav() {\n    target.SetTitle(&HSTRING::from(t));\n}\n'
    indented = ('fn refresh_caption() {\n    target.SetTitle(&x);\n}\n'
                'impl Stage {\n    fn other(&self) {\n'
                '        target.SetTitle(&x);\n    }\n}\n')
    clean = ('fn refresh_caption() {\n    target.SetTitle(&x);\n}\n'
             'fn setup() {\n    window.SetTitle(&y);\n}\n'
             'fn build_menu() {\n    bar_item.SetTitle(&z);\n}\n')
    if caption_audit(bypass) != [(2, "target")]:
        die("deploy-win: SELF-TEST FAIL (a bypassing SetTitle was not seen)")
    if caption_audit(indented) != [(6, "target")]:
        die("deploy-win: SELF-TEST FAIL (an indented method inherited the "
            "caption writer's sanction)")
    if caption_audit(clean):
        die(f"deploy-win: SELF-TEST FAIL (a sanctioned SetTitle was refused: "
            f"{caption_audit(clean)})")
    path = ROOT / "crates/kaya/src/winui/mod.rs"
    text = path.read_text(encoding="utf-8")
    if CAPTION_WRITER not in text:
        die(f"deploy-win: {path} has no `{CAPTION_WRITER}` — the WinUI dirty "
            f"lowering composes its marker there, and without it every "
            f"caption write is a bypass")
    found = caption_audit(text)
    if found:
        where = ", ".join(f"line {n} (`{r}.SetTitle`)" for n, r in found)
        die(f"deploy-win: {path} writes a window caption outside "
            f"refresh_caption: {where}. Call `refresh_caption(core, "
            f"window)` instead — it composes the dirty marker (a leading "
            f"`*`, the measured Notepad convention) into whichever title "
            f"the window should be showing. A raw SetTitle drops the mark "
            f"the next time that path runs (docs/dirty-plan.md D2).")


caption_census()

print("== building (aarch64-pc-windows-msvc, release) ==", flush=True)
for build_args in (
        ["cargo", "xwin", "build", "--locked", "--features", "harness",
         "--release", "--target", "aarch64-pc-windows-msvc", "--lib"],
        ["cargo", "xwin", "build", "--locked", "--features", "harness",
         "--release", "--target", "aarch64-pc-windows-msvc",
         *BUILD_EXAMPLES]):
    if subprocess.run(build_args, cwd=ROOT, check=False).returncode != 0:
        sys.exit(1)
# Verify BEFORE the deploy: a stale dll that reaches the VM is a stale
# dll on another machine, where nothing local can see it.
if subprocess.run([str(ROOT / "tools/build-id.py"), "--verify",
                   str(TARGET / "kaya.dll")], check=False).returncode != 0:
    sys.exit(1)
for gen in ("gen-header", "gen-bindings"):
    if subprocess.run([str(ROOT / f"tools/{gen}.py"), "--check"],
                      check=False).returncode != 0:
        sys.exit(1)

# Every kaya_* function declared in kaya.h must be exported by the DLL;
# a missing export would otherwise surface as a remote link or load
# error, or pass by resolving against a stale deployed copy.
_decl_pat = re.compile(r"^[A-Za-z_].*[ *](kaya_[a-z0-9_]+)\(")
declared = set()
for _line in (ROOT / "crates/kaya/include/kaya.h").read_text(
        encoding="utf-8").splitlines():
    m = _decl_pat.match(_line)
    if m:
        declared.add(m.group(1))
_objdump = subprocess.run(["objdump", "-p", str(TARGET / "kaya.dll")],
                          stdout=subprocess.PIPE, text=True,
                          encoding="utf-8", errors="replace", check=False)
exported, _inside = set(), False
for _line in _objdump.stdout.splitlines():
    if "Export Table:" in _line:
        _inside = True
        continue
    if _inside and not _line.strip():
        break
    if _inside:
        exported.update(re.findall(r"kaya_[a-z0-9_]+", _line))
_missing = sorted(declared - exported)
if _missing:
    print("kaya.dll does not export functions declared in kaya.h:",
          file=sys.stderr)
    print("\n".join(_missing), file=sys.stderr)
    sys.exit(1)
timing("build")

must_ssh("cmd /c if not exist C:\\kaya mkdir C:\\kaya")
must_ssh("cmd /c if not exist C:\\kaya\\bindings\\python mkdir "
         "C:\\kaya\\bindings\\python")
must_ssh("cmd /c if not exist C:\\kaya\\bindings\\go mkdir "
         "C:\\kaya\\bindings\\go")
# EVERY run, not the --provision block: a provisioning-only ship means a
# scene edit never arrives.
must_ssh("cmd /c if not exist C:\\kaya\\scenes mkdir C:\\kaya\\scenes")
if scp_to(sorted((ROOT / "tools/scenes").glob("*.steps")),
          "C:/kaya/scenes/") != 0:
    die("deploy-win: could not ship the scene scripts")
# Set once for the machine rather than in forty checked-in .cmd files:
# every leg runs through schtasks, which inherits the user environment.
must_ssh("setx KAYA_SCENES_DIR C:\\kaya\\scenes >nul")

# THE ASSET ROOT, AS A UNIT (docs/assets-plan.md A2, A5.2). SHIPPED
# EVERY RUN, OUTSIDE THE DEPLOY STAMP, like the .steps above.
# KAYA_ASSET_DIR is absolute and machine-wide because the C# leg's cwd
# is C:\kaya\cs, where a relative default would miss. AND ONE FILE
# UNDER IT IS DERIVED, never committed, so a fresh clone would ship a
# root without it and the hash check below would agree, both sides
# missing the same file.
if subprocess.run([sys.executable, str(ROOT / "tools/gen-market.py"),
                   "--ensure"], check=False).returncode != 0:
    print("deploy-win: python3 tools/gen-market.py --ensure failed — the "
          "market", file=sys.stderr)
    print("  family's transactions.csv is derived, so the root about to be "
          "shipped", file=sys.stderr)
    print("  is incomplete and the VM would get it that way", file=sys.stderr)
    sys.exit(1)
must_ssh('cmd /c "if exist C:\\kaya\\guests\\assets rmdir /s /q '
         'C:\\kaya\\guests\\assets"')
must_ssh("cmd /c if not exist C:\\kaya\\guests mkdir C:\\kaya\\guests")
if scp_dir_to(ROOT / "guests/assets", "C:/kaya/guests/") != 0:
    die("deploy-win: could not ship the asset root")
must_ssh("setx KAYA_ASSET_DIR C:\\kaya\\guests\\assets >nul")

# AND THE INDEX GOES BESIDE THE EXE: every kaya host on Windows needs an
# MRT resources.pri in the PROCESS executable's directory or the XAML
# parser fail-fasts at 0xC000027B (docs/traps.md).
if run_ssh("cmd /c copy /y C:\\kaya\\guests\\assets\\win\\"
           "minimal-resources.pri C:\\kaya\\resources.pri >nul") != 0:
    print("deploy-win: could not place C:\\kaya\\resources.pri — every WinUI "
          "host", file=sys.stderr)
    print("  needs an MRT index beside its exe or the XAML parser fail-fasts "
          "at", file=sys.stderr)
    print("  0xC000027B (docs/traps.md)", file=sys.stderr)
    sys.exit(1)


def verify_staged_assets():
    """WHAT ARRIVED IS WHAT WAS SENT, BY HASH AND NOT BY SIZE: a size
    check passes a same-length corruption, and a half-written scp over a
    previous run's file is exactly that (docs/assets-plan.md A5.1)."""
    staged = run_ssh_out(
        'powershell -NoProfile -Command "Get-ChildItem -Recurse -File '
        "C:\\kaya\\guests\\assets | ForEach-Object { (Get-FileHash "
        '$_.FullName -Algorithm SHA256).Hash + \\" \\" + $_.FullName }"')
    if staged is None:
        die("deploy-win: could not hash the staged asset root on the VM")
    there = {}
    prefix = "c:\\kaya\\guests\\assets\\"
    for line in staged.replace("\r", "").splitlines():
        line = line.strip()
        if " " not in line:
            continue
        digest, full = line.split(" ", 1)
        if len(digest) != 64:
            continue
        # The VM answers in its own spelling; the tree speaks `/`.
        if not full.strip().lower().startswith(prefix):
            continue
        rel = full.strip()[len(prefix):].replace("\\", "/")
        there[rel] = digest.lower()
    root = ROOT / "guests/assets"
    here = {}
    for f in sorted(root.rglob("*")):
        if f.is_file():
            here[f.relative_to(root).as_posix()] = hashlib.sha256(
                f.read_bytes()).hexdigest()
    bad = []
    for name, digest in sorted(here.items()):
        got = there.get(name)
        if got is None:
            bad.append(f"  {name}: never arrived on the VM")
        elif got != digest:
            bad.append(f"  {name}: arrived as {got[:12]}, the tree has "
                       f"{digest[:12]}")
    for name in sorted(set(there) - set(here)):
        bad.append(f"  {name}: is on the VM and not in the tree — a stale "
                   f"asset a guest can still resolve by name")
    if bad:
        print("deploy-win: the staged asset root does not match the tree:",
              file=sys.stderr)
        print("\n".join(bad), file=sys.stderr)
        sys.exit(1)
    print(f"assets: {len(here)} files staged to C:\\kaya\\guests\\assets, "
          f"every one hash-equal to the tree")


verify_staged_assets()

# EXTENSIONS MUST BE VISIBLE: Explorer ships with HideFileExt=1, so the
# picker's rows publish "picked" where mac and GTK publish "picked.txt"
# (docs/traps.md, "What the Windows file dialog publishes, and the
# setting that changes it"). Set every deploy — any Explorer settings
# visit puts it back — and verified, because a write that did not take
# reads as success.
must_ssh('reg add "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\'
         'Explorer\\Advanced" /v HideFileExt /t REG_DWORD /d 0 /f >nul')
_hide = run_ssh_out('reg query "HKCU\\Software\\Microsoft\\Windows\\'
                    'CurrentVersion\\Explorer\\Advanced" /v HideFileExt')
if "0x0" not in (_hide or ""):
    print("deploy-win: HideFileExt is not 0 on the guest — the picker would",
          file=sys.stderr)
    print("  publish rows without extensions and the filedialog leg would "
          "fail", file=sys.stderr)
    print(f"  as though the backend were wrong. Got: {_hide}", file=sys.stderr)
    sys.exit(1)
# AND NO NOTIFICATION TOASTS: while one is up SetForegroundWindow FAILS
# for everything else, so every shortcut-injection leg dies looking like
# a WinUI bug (docs/traps.md, "A shell toast holds the foreground, and
# ten legs die of it"). Three values, because the shell has three places
# to say it.
must_ssh('reg add "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\'
         'PushNotifications" /v ToastEnabled /t REG_DWORD /d 0 /f >nul')
must_ssh('reg add "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\'
         'Notifications\\Settings" /v NOC_GLOBAL_SETTING_TOASTS_ENABLED '
         '/t REG_DWORD /d 0 /f >nul')
must_ssh('reg add "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\'
         'ContentDeliveryManager" /v SubscribedContent-338389Enabled '
         '/t REG_DWORD /d 0 /f >nul')
_toasts = run_ssh_out('reg query "HKCU\\Software\\Microsoft\\Windows\\'
                      'CurrentVersion\\PushNotifications" /v ToastEnabled')
if "0x0" not in (_toasts or ""):
    print("deploy-win: toasts are still enabled on the guest — a shell toast",
          file=sys.stderr)
    print("  holds the foreground and every shortcut-injection leg would "
          "fail", file=sys.stderr)
    print(f"  as though WinUI could not raise its own window. Got: {_toasts}",
          file=sys.stderr)
    sys.exit(1)
# THE FOREGROUND LOCK MUST BE OFF (docs/traps.md, "A rebooted Windows VM
# refuses every shortcut-injection leg"). This write seeds the NEXT
# logon; the LIVE session is done by the desktop warm-up below, from
# INSIDE it — an ssh session is session 0 with its own window station,
# and SPI applies per window station.
must_ssh('reg add "HKCU\\Control Panel\\Desktop" /v ForegroundLockTimeout '
         '/t REG_DWORD /d 0 /f >nul')
_fglock = run_ssh_out('reg query "HKCU\\Control Panel\\Desktop" '
                      '/v ForegroundLockTimeout')
if "0x0" not in (_fglock or ""):
    print("deploy-win: the guest still holds a foreground lock — every",
          file=sys.stderr)
    print("  shortcut-injection leg will fail as though WinUI could not "
          "raise", file=sys.stderr)
    print("  its own window, which is what a freshly rebooted VM looks like.",
          file=sys.stderr)
    print(f"  Got: {_fglock}", file=sys.stderr)
    sys.exit(1)

# WIPED AND RECREATED, NOT COPIED OVER: scp deletes nothing, so a source
# file that leaves the repo lives on in C:\kaya forever — and Go compiles
# a DIRECTORY, so one leftover is a compile error in a package that is
# correct in the tree (measured 2026-08-07, a stale todo_kaya.go after
# the scene-library split). ONE RECURSIVE COPY OF THE WHOLE GO TREE, not
# a loop over SCENES: the guests are ONE PROGRAM.
must_ssh('cmd /c "if exist C:\\kaya\\guests\\go rmdir /s /q '
         'C:\\kaya\\guests\\go"')
must_ssh('cmd /c "mkdir C:\\kaya\\guests\\go"')
if scp_dir_to(sorted((ROOT / "guests/go").iterdir()),
              "C:/kaya/guests/go/") != 0:
    die("deploy-win: could not ship the go guests")

if PROVISION:
    print("== provisioning Windows App Runtime (one-time) ==")
    if scp_to([SDK / "WindowsAppRuntimeInstall-arm64.exe"], "C:/kaya/") != 0:
        die("deploy-win: could not ship the App Runtime installer")
    must_ssh("C:\\kaya\\WindowsAppRuntimeInstall-arm64.exe --quiet --force")

# --architecture arm64 MUST STAY: winget under the emulated x64 shell
# defaults to the x64 build, whose JVM cannot load the aarch64 kaya.dll.
# zulu ships no arm64 winget package; Microsoft's OpenJDK does.
must_ssh("cmd /c java -version >nul 2>&1 && echo jdk present || winget "
         "install --id Microsoft.OpenJDK.17 --architecture arm64 --silent "
         "--accept-package-agreements --accept-source-agreements "
         "--scope machine")

# GO AND NODE, BY VERSION AND BY BYTES, THROUGH A SHIPPED SCRIPT: an
# inline `powershell -Command \"...\"` through ssh and cmd arrives as one
# quoted string PowerShell PRINTS instead of running (docs/traps.md,
# measured 2026-09-01). The check is VERSION-KEYED, not exists-keyed: an
# exists check kept the VM on rc2 through a pin bump forever.
# tools/check-pins.py holds the shape.
if scp_to([ROOT / "tools/guest/fetch-zip.ps1"], "C:/kaya/") != 0:
    die("deploy-win: could not ship fetch-zip.ps1")


def fetch_zip(url, sha256, dest):
    return ("powershell -NoProfile -ExecutionPolicy Bypass -File "
            f"C:\\kaya\\fetch-zip.ps1 -Url {url} -Sha256 {sha256} -Dest {dest}")


GO_PRESENT = ('C:\\kaya\\go127\\go\\bin\\go.exe version 2>nul | findstr '
              f'/c:go{GO_VERSION} >nul')
NODE_PRESENT = (NODE_DIR + '\\node.exe --version 2>nul | findstr '
                f'/c:v{NODE_VERSION} >nul')
must_ssh('cmd /c "' + GO_PRESENT + f' && echo go{GO_VERSION} present || '
         + fetch_zip(f"https://go.dev/dl/go{GO_VERSION}.windows-arm64.zip",
                     GO_WIN_ARM64_SHA256, "C:\\kaya\\go127") + '"')
must_ssh('cmd /c "' + NODE_PRESENT + f' && echo node{NODE_VERSION} present || '
         + fetch_zip(f"https://nodejs.org/dist/v{NODE_VERSION}/node-v{NODE_VERSION}-win-arm64.zip",
                     NODE_WIN_ARM64_SHA256, "C:\\kaya\\node24") + '"')
# VERIFIED AFTER THE FETCH, not only before it: a provisioning step that
# "succeeded" without producing the toolchain is how the Go pin went
# uninstalled for weeks.
must_ssh('cmd /c "' + GO_PRESENT + f' || (echo deploy-win: go{GO_VERSION} is not '
         'at C:\\kaya\\go127 after provisioning & exit /b 1)"')
must_ssh('cmd /c "' + NODE_PRESENT + f' || (echo deploy-win: node v{NODE_VERSION} '
         'is not at C:\\kaya\\node24 after provisioning & exit /b 1)"')


# A hung or leftover guest keeps kaya.dll locked. This is a dedicated
# test VM — python/go/dotnet processes are always kaya guests — so
# killing by image name is safe.
def kill_guests(log=None):
    # Two name families beyond <scene>.exe: the go legs build
    # <scene>_go.exe (the pri-adjacency arrangement), and the C# legs
    # run the kaya-guests.exe apphost — both held kaya.dll through a
    # deploy once (2026-07-22).
    kill_list = "".join(
        f"taskkill /f /im {s}.exe 2>nul & taskkill /f /im {s}_go.exe 2>nul & "
        for s in SCENES + DEPTH_SCENES + GO_ONLY_SCENES)
    run_ssh(f'cmd /c "{kill_list}taskkill /f /im python.exe 2>nul & '
            f"taskkill /f /im go.exe 2>nul & taskkill /f /im dotnet.exe "
            f"2>nul & taskkill /f /im kaya-guests.exe 2>nul & taskkill /f "
            f'/im java.exe 2>nul & taskkill /f /im cdb.exe 2>nul & '
            f'exit /b 0"', log=log)


def guests_wedged(log=None):
    """The state taskkill CANNOT clear: tasklist still LISTS an image
    while taskkill says "no running instance" — a process past the point
    where it can be signalled, not a permissions failure (that reports
    "Access is denied"). Only a VM restart clears it (docs/traps.md)."""
    listed = run_ssh_out("tasklist", log=log) or ""
    n = len([ln for ln in listed.splitlines()
             if re.match(r"^(go|java|python|dotnet|kaya-guests)\.exe",
                         ln, re.I)])
    if n == 0:
        return False
    killed = subprocess.run(
        ["ssh", "-n", "-o", "BatchMode=yes", *SSH_MUX, HOST,
         'cmd /c "taskkill /f /im go.exe & taskkill /f /im java.exe & '
         'taskkill /f /im python.exe & taskkill /f /im dotnet.exe & '
         'exit /b 0"'],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        encoding="utf-8", errors="replace",
        check=False)
    return "no running instance" in killed.stdout.lower()


def vm_restart(log=None):
    """Force the VM down and back up, then wait for sshd. The ONLY
    escape from the wedged state above."""
    err = log if log is not None else sys.stderr
    print(f'== force-restarting VM "{VM_NAME}" ==', file=err)
    subprocess.run([utmctl_bin(), "stop", "--kill", VM_NAME],
                   stdout=log, stderr=log, check=False)
    tries = 0
    while utm_started():
        tries += 1
        if tries > 12:
            print("VM would not stop", file=err)
            return False
        time.sleep(5)
    subprocess.run([utmctl_bin(), "start", VM_NAME],
                   stdout=log, stderr=log, check=False)
    tries = 0
    while not ssh_probe():
        tries += 1
        if tries > 60:
            print("VM did not come back", file=err)
            return False
        time.sleep(5)
    time.sleep(20)  # the /it scheduled tasks need a logged-in console session
    print("== VM back ==", file=err)
    return True


LEGS_DIR = pathlib.Path(tempfile.mkdtemp())

# The flight recorder: tools/lib/flightrec_lane.py holds the rules; the
# guest half is tools/guest/flightrec.ps1.
FR = flightrec_lane.WinRecorder(ROOT)
# Quiet transports: the recorder may never write into the runner's
# verdict surface.
FR.bind(lambda cmd: run_ssh(cmd, log=subprocess.DEVNULL),
        lambda cmd: run_ssh_out(cmd, log=subprocess.DEVNULL),
        scp_from)
FR.lane_start()

_cleaned = threading.Lock()


def cleanup():
    if not _cleaned.acquire(blocking=False):
        return
    kill_guests()
    FR.cleanup()
    # The spool becomes journal records here as well as at lane end: the
    # flush truncates it, so whichever runs first wins and an
    # interrupted lane still lands the legs it finished.
    FR.flush()
    shutil.rmtree(LEGS_DIR, ignore_errors=True)


atexit.register(cleanup)
# atexit does not run on TERM, so TERM is converted into the exit path.
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
kill_guests()

# Skip-unchanged deploy. The stamp is the content hash of everything the
# deploy ships; a match against the VM's stamp skips the whole block.
# All-or-nothing on purpose: the cs/python/java trees are recreated from
# scratch on every real deploy, and a per-file diff would reintroduce
# the stale-mix class those recreations kill. The kaya.dll remote-hash
# verify below runs EITHER WAY.
#
# ONE LIST feeds both the flat-artifact manifest and the stamp. A .ps1
# is NAMED individually (the .cmd/.vbs globs ship themselves), and
# check-staging censuses this list against tools/guest/*.ps1 on disk.
def deploy_artifacts():
    return (SCENE_EXES
            + [TARGET / "kaya.dll", BOOTSTRAP]
            + SCENE_PYS
            + SCENE_TSS
            + [ROOT / "go.mod", ROOT / "crates/kaya/include/kaya.h"]
            + sorted((ROOT / "tools/guest").glob("*.cmd"))
            + sorted((ROOT / "tools/guest").glob("*.vbs"))
            + [ROOT / "tools/guest/shot.ps1",
               ROOT / "tools/guest/shot-window.ps1",
               ROOT / "tools/guest/desk-warm.ps1",
               ROOT / "tools/guest/wait-exit.ps1",
               ROOT / "tools/guest/fetch-zip.ps1",
               ROOT / "tools/guest/flightrec.ps1"])


def deploy_stamp():
    # THIS SCRIPT and the lane module are part of the stamp: the remote
    # javac/dotnet command lines live here, so a flag change with
    # unchanged sources would otherwise reuse stale classes (caught
    # 2026-07-24: adding `javac -encoding UTF-8` fixed nothing until the
    # stamp was cleared by hand).
    inputs = ([SELF, LANE_MODULE]
              + deploy_artifacts()
              + sorted((ROOT / "bindings/go").glob("*.go"))
              + sorted((ROOT / "guests/csharp").glob("*.cs"))
              + [ROOT / "guests/csharp/kaya-guests.csproj"]
              + sorted((ROOT / "bindings/csharp").glob("*.cs"))
              + sorted((ROOT / "bindings/java/dev/kaya").glob("*.java"))
              + [ROOT / "bindings/java-desktop/dev/kaya/KayaRing.java"]
              + sorted((ROOT / "guests/java/dev/kaya/guests")
                       .glob("*.java"))
              + sorted(p for p in (ROOT / "bindings/python/kaya").rglob("*")
                       if p.is_file())
              + [ROOT / "bindings/js/package.json"]
              + sorted((ROOT / "bindings/js/kaya").glob("*.ts")))
    h = hashlib.sha256()
    for p in inputs:
        body = p.read_bytes()
        h.update(f"{p}\0{len(body)}\0".encode())
        h.update(body)
    return h.hexdigest()[:16]


def ship_flat_artifacts():
    """The manifest diff: only files whose hash differs ride the wire,
    written remotely ONLY after the whole deploy succeeds so a
    half-shipped set re-diffs honestly next run.

    THE MANIFEST MAY ONLY VOUCH FOR FILES THE GUEST STILL LISTS: a file
    deleted guest-side left every later deploy skipping the ship, and the
    flight recorder's lane sampler silently never ran (2026-08-27)."""
    artifacts = deploy_artifacts()
    remote_manifest = run_ssh_out("cmd /c type C:\\kaya\\deploy.manifest") or ""
    listing = run_ssh_out("cmd /c dir /b C:\\kaya") or ""
    present = {ln.strip() for ln in listing.replace("\r", "").splitlines()
               if ln.strip()}
    held = {}
    for line in remote_manifest.replace("\r", "").splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[1].strip() in present:
            held[parts[1].strip()] = parts[0]
    want = {}
    for p in artifacts:
        name = p.name
        if name in want:
            die(f"deploy-win: two artifacts share the basename {name!r} — "
                f"the manifest cannot key them")
        want[name] = (hashlib.sha256(p.read_bytes()).hexdigest(), p)
    manifest = LEGS_DIR / "deploy.manifest"
    with open(manifest, "w", encoding="utf-8") as out:
        for name, (sha, _p) in sorted(want.items()):
            out.write(f"{sha} {name}\n")
    ship = [p for name, (sha, p) in sorted(want.items())
            if held.get(name) != sha]
    print(f"artifacts: shipping {len(ship)} of {len(artifacts)} (the rest "
          f"match the VM's manifest)")
    if ship and scp_to(ship, "C:/kaya/") != 0:
        # WHAT TO DO NEXT, because scp's own message names neither the
        # cause nor the fix.
        print("deploy-win: could not overwrite the deployed artifacts.",
              file=sys.stderr)
        print("  A guest process from an earlier run is almost certainly "
              "still", file=sys.stderr)
        print("  holding C:\\kaya\\kaya.dll. Check with:", file=sys.stderr)
        print(f"    ssh {HOST} 'tasklist | findstr /i \"wscript exe\"'",
              file=sys.stderr)
        print("  and clear it with:", file=sys.stderr)
        print(f"    ssh {HOST} 'cmd /c \"taskkill /f /im wscript.exe & "
              f"exit /b 0\"'", file=sys.stderr)
        print("  A process tasklist shows but taskkill cannot kill is "
              "wedged;", file=sys.stderr)
        print(f"  reboot the VM (ssh {HOST} 'shutdown /r /t 0') and re-run.",
              file=sys.stderr)
        sys.exit(1)
    return manifest


STAMP = deploy_stamp()
_remote_stamp = (run_ssh_out("cmd /c type C:\\kaya\\deploy.stamp") or "")
_remote_stamp = re.sub(r"[\r\n ]", "", _remote_stamp)
if _remote_stamp == STAMP:
    print(f"== deploy unchanged (stamp {STAMP}) ==")
else:
    print("== deploying artifacts ==", flush=True)
    _manifest = ship_flat_artifacts()
    # Recreated from scratch every deploy: dotnet picks up whatever
    # sources are in the directory, so a leftover from a renamed example
    # poisons the build.
    # A `rmdir` and a `mkdir` are two commands, never `if exist X rmdir
    # X & mkdir Y` in one: cmd runs the mkdir INSIDE the if, so a path
    # that never existed is never created (tools/check-steps.py holds it).
    must_ssh('cmd /c "if exist C:\\kaya\\cs rmdir /s /q C:\\kaya\\cs"')
    must_ssh('cmd /c "mkdir C:\\kaya\\cs"')
    must_ssh('cmd /c "if exist C:\\kaya\\bindings\\python rmdir /s /q '
             'C:\\kaya\\bindings\\python"')
    must_ssh('cmd /c "mkdir C:\\kaya\\bindings\\python"')
    if scp_dir_to(ROOT / "bindings/python/kaya",
                  "C:/kaya/bindings/python/") != 0:
        die("deploy-win: could not ship the python binding")
    # The JS binding staged at C:\kaya\kaya-gui BEHIND A JUNCTION from
    # node_modules: node refuses to strip types for a file whose real
    # path is under node_modules
    # (ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING) and resolves a link
    # to its target, which is how the workspace symlink works on the
    # other two desktops (docs/traps.md).
    # The junction goes first and on its own: a bare rmdir unlinks a
    # junction without touching its target, and a leftover REAL directory
    # from an older deploy makes that rmdir fail, which the exit /b 0
    # tolerates and the /s below then removes.
    must_ssh('cmd /c "rmdir C:\\kaya\\node_modules\\kaya-gui 2>nul & exit /b 0"')
    must_ssh('cmd /c "if exist C:\\kaya\\node_modules rmdir /s /q '
             'C:\\kaya\\node_modules"')
    must_ssh('cmd /c "if exist C:\\kaya\\kaya-gui rmdir /s /q '
             'C:\\kaya\\kaya-gui"')
    must_ssh('cmd /c "mkdir C:\\kaya\\kaya-gui"')
    must_ssh('cmd /c "mkdir C:\\kaya\\node_modules"')
    if scp_to([ROOT / "bindings/js/package.json"],
              "C:/kaya/kaya-gui/") != 0:
        die("deploy-win: could not ship the JS binding's package.json")
    if scp_dir_to(ROOT / "bindings/js/kaya", "C:/kaya/kaya-gui/") != 0:
        die("deploy-win: could not ship the JS binding")
    must_ssh('cmd /c "mklink /J C:\\kaya\\node_modules\\kaya-gui '
             'C:\\kaya\\kaya-gui >nul"')
    if scp_to(sorted((ROOT / "bindings/go").glob("*.go")),
              "C:/kaya/bindings/go/") != 0:
        die("deploy-win: could not ship the go binding")
    if scp_to(sorted((ROOT / "guests/csharp").glob("*.cs"))
              + [ROOT / "guests/csharp/kaya-guests.csproj"]
              + sorted((ROOT / "bindings/csharp").glob("*.cs")),
              "C:/kaya/cs/") != 0:
        die("deploy-win: could not ship the C# sources")
    # Built ONCE here; the legs run `dotnet exec` on the produced dll.
    # Per-leg `dotnet run` raced the shared obj/bin (CS2012 — see
    # docs/traps.md, "Shared build directories cannot be built per-leg").
    if run_ssh('cmd /c "cd /d C:\\kaya\\cs && dotnet build -v q '
               '--nologo"') != 0:
        die("dotnet build failed on the VM")
    # Second output for the pri-adjacency legs: the apphost exe with
    # resources.pri beside it (ms-appx resolves against the PROCESS
    # exe's directory). Also built once, for the same race.
    if run_ssh('cmd /c "cd /d C:\\kaya\\cs && dotnet build -v q --nologo '
               "-o C:\\kaya\\cs-out && copy /y C:\\kaya\\resources.pri "
               'C:\\kaya\\cs-out\\resources.pri >nul"') != 0:
        die("dotnet build (cs-out) failed on the VM")
    # Quote-free on purpose: Windows sshd re-wraps the command in its
    # own cmd /c "...", and interior double quotes re-pair across the
    # line (docs/traps.md).
    must_ssh("cmd /c if exist C:\\kaya\\java rmdir /s /q C:\\kaya\\java")
    must_ssh("cmd /c mkdir C:\\kaya\\java\\src")
    if scp_to(sorted((ROOT / "bindings/java/dev/kaya").glob("*.java"))
              + [ROOT / "bindings/java-desktop/dev/kaya/KayaRing.java"]
              + sorted((ROOT / "guests/java/dev/kaya/guests")
                       .glob("*.java")),
              "C:/kaya/java/src/") != 0:
        die("deploy-win: could not ship the java sources")
    if run_ssh("cmd /c javac -encoding UTF-8 -d C:\\kaya\\java\\classes "
               "C:\\kaya\\java\\src\\*.java") != 0:
        die("javac failed on the VM")
    # The manifest lands WITH the stamp, after everything above held: a
    # deploy that died mid-way leaves the old manifest, and the next run
    # re-diffs against what the VM verifiably had.
    if scp_to([_manifest], "C:/kaya/deploy.manifest") != 0:
        die("deploy-win: could not write the deploy manifest")
    must_ssh(f"cmd /c echo {STAMP}>C:\\kaya\\deploy.stamp")


def verify_deployed():
    """What landed must be what was built: Windows keeps loaded DLLs
    locked, so an overwrite can fail while everything else copies fine
    and the suites then run against the previous deploy. Order is the
    contract: the remote list and the local list are compared
    line-by-line."""
    locals_ = [TARGET / "kaya.dll"] + [
        TARGET / f"examples/{s}.exe"
        for s in ("milestone2", "entry", "gallery", "todos", "reorder",
                  "feed", "grow", "align", "layout")]
    remotes = ",".join(
        ["C:\\kaya\\kaya.dll"]
        + [f"C:\\kaya\\{s}.exe"
           for s in ("milestone2", "entry", "gallery", "todos", "reorder",
                     "feed", "grow", "align", "layout")])
    got = run_ssh_out(f'powershell -Command "(Get-FileHash {remotes} '
                      f'-Algorithm SHA256).Hash"')
    got_lines = [ln.strip().lower() for ln in
                 (got or "").replace("\r", "").splitlines() if ln.strip()]
    if len(got_lines) != len(locals_):
        die(f"remote hash count {len(got_lines)} != {len(locals_)} — deploy "
            f"verification failed")
    for i, local_path in enumerate(locals_):
        want = hashlib.sha256(local_path.read_bytes()).hexdigest().lower()
        if got_lines[i] != want:
            die(f"remote hash mismatch for {local_path} after deploy")


verify_deployed()
timing("deploy")


# THE CORE'S UNIT TESTS, EXECUTED ON WINDOWS: rung 1 of the ladder runs
# on the machine you type it on, so protocol.rs's HANDLE arms have
# coverage only here (CLAUDE.md's ladder rung 1). Proven 2026-08-09:
# breaking the windows arm of raw_handle reddened this phase alone.
def declared_tests(file, module):
    """THE COUNT COMES OUT OF THE SOURCE: a filter that matches nothing
    exits 0 with "0 passed", so the number of `#[test]`s in the module
    is read and the run must report exactly that many passed."""
    text = pathlib.Path(file).read_text(encoding="utf-8")
    m = re.search(rf"(?m)^mod {re.escape(module)} \{{", text)
    if not m:
        die(f"deploy-win: {file} has no `mod {module}` — the module this "
            f"lane runs on the guest moved or was renamed, and a filter "
            f"that matches nothing would report a clean run")
    end = text.index("\n}", m.end())
    count = text.count("#[test]", m.end(), end)
    if count < 1:
        die(f"deploy-win: `mod {module}` declares no #[test] at all")
    return count


def guest_unit_module(file, module, filt, blurb, hint):
    want = declared_tests(file, module)
    out = subprocess.run(
        ["ssh", "-n", "-o", "BatchMode=yes", *SSH_MUX, HOST,
         f'cmd /c "cd /d C:\\kaya && kaya-unittests.exe {filt} '
         f'--test-threads=1"'],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        encoding="utf-8", errors="replace",
        check=False)
    print(out.stdout, end="")
    if out.returncode != 0:
        print(f"deploy-win: the core's {filt} unit tests FAILED on the guest "
              f"(rc={out.returncode}).", file=sys.stderr)
        print(f"  {hint}", file=sys.stderr)
        return False
    m = re.search(r"(\d+) passed", out.stdout)
    passed = m.group(1) if m else "-1"
    if passed != str(want):
        print(f"deploy-win: the guest ran {passed} of the {want} tests in",
              file=sys.stderr)
        print(f"  {filt}. A filter that selects nothing exits 0 with",
              file=sys.stderr)
        print('  "0 passed", so the count is what makes this phase mean',
              file=sys.stderr)
        print("  something — fix the filter or the module name, do not lower",
              file=sys.stderr)
        print("  the count. (The count is every #[test] the module declares;",
              file=sys.stderr)
        print("  this phase builds --features harness, so a harness-gated "
              "test", file=sys.stderr)
        print("  counts and runs.)", file=sys.stderr)
        return False
    print(f"deploy-win: {passed}/{want} unit tests passed on the guest "
          f"({filt} — {blurb})")
    return True


def unit_tests_on_windows():
    print("== unit tests on the guest (aarch64-pc-windows-msvc) ==",
          flush=True)
    json_path = ROOT / "target/win-unit-tests.json"
    with open(json_path, "w", encoding="utf-8") as jf:
        built = subprocess.run(
            ["cargo", "xwin", "test", "--locked", "--features", "harness",
             "--release", "--target", "aarch64-pc-windows-msvc", "-p", "kaya",
             "--lib", "--no-run", "--message-format=json"],
            cwd=ROOT, stdout=jf, check=False).returncode
    if built != 0:
        print("deploy-win: the unit test binary would not build for windows.",
              file=sys.stderr)
        print("  This is the ONLY thing that compiles crates/kaya's tests "
              "for", file=sys.stderr)
        print("  this target — tools/check-targets.py checks --lib alone — "
              "so a", file=sys.stderr)
        print("  test that only compiles on unix fails HERE and nowhere "
              "else.", file=sys.stderr)
        sys.exit(1)
    exe = None
    for line in json_path.read_text(encoding="utf-8").splitlines():
        try:
            m = json.loads(line)
        except ValueError:
            continue
        if (m.get("reason") == "compiler-artifact" and m.get("executable")
                and m.get("profile", {}).get("test")):
            exe = m["executable"]
            break
    json_path.unlink()
    if not exe:
        die("deploy-win: cargo built no test executable — the --no-run "
            "build reported nothing to run")
    if scp_to([exe], "C:/kaya/kaya-unittests.exe") != 0:
        die("deploy-win: could not ship the unit-test binary")
    ok = True
    # THE HANDLE ARMS, which no unix run compiles.
    ok &= guest_unit_module(
        ROOT / "crates/kaya/src/capi.rs", "picked_tests",
        "capi::picked_tests",
        "the file-handle redemption, including the WRITE half and a save "
        "destination's create-and-truncate",
        "These are the same tests rung 1 runs on mac; a failure here and "
        "not there is Windows-only code — the HANDLE arms of protocol.rs's "
        "raw_handle/file_from_raw, or an OpenOptions combination that means "
        "something else on this OS.")
    # THE WINUI BACKEND'S OWN TESTS need this machine because they
    # measure it: DirectWrite's system font collection, and a font file
    # written under the app root and read back through its name table.
    ok &= guest_unit_module(
        ROOT / "crates/kaya/src/winui/mod.rs", "tests", "winui::tests",
        "the brand dictionary's crossed stops, the a11y role ladder, and "
        "the typeface blob route read back off its own file",
        "This is the WinUI backend measured against the real DirectWrite on "
        "this guest: a per-app font file written under the app root and "
        "read back through its name table, the system font collection's "
        "answer for a bare family, and the pure lowerings beside them.")
    # THE EXIT GRACE IS FINAL ON THIS OS: harness_exit must end a
    # process whose CRT teardown is wedged, and the primitive it replaced
    # must still be measured hostage (docs/traps.md, the 64s dialog legs
    # of 2026-08-27).
    ok &= guest_unit_module(
        ROOT / "crates/kaya/src/harness.rs", "win_exit_tests",
        "harness::win_exit_tests",
        "the exit grace escaping a wedged loader shutdown, and "
        "std::process::exit measured hostage to it",
        "This is the grace's last-resort exit measured against a real "
        "wedged loader shutdown on this OS: an FLS callback that never "
        "returns holds ExitProcess exactly as the 2026-08-27 dialog legs' "
        "captor held it ~40s past the grace, and TerminateProcess is what "
        "makes the invariant true. (atexit is NOT the hook: ExitProcess "
        "never runs it — the guest falsified that draft.)")
    # The binary goes whatever the verdict is: one left behind would be
    # the next run's stale exe waiting for a build that failed.
    run_ssh('cmd /c "del C:\\kaya\\kaya-unittests.exe 2>nul & exit /b 0"')
    if not ok:
        sys.exit(1)


unit_tests_on_windows()
timing("unit-tests")


def go_warm():
    """ONE cgo COMPILE, ALONE, BEFORE THE POOL OPENS: every Go leg builds
    the same package (dev.kaya/guests/go/cmd) and shares Go's build cache,
    so a regenerated binding had the first four legs compile it at once
    and read 105/96/84/74s (docs/traps.md: The Windows lane's first
    matrix after a spec change). The verdict is the build's own exit."""
    run_ssh('cmd /c "del C:\\kaya\\out_gowarm.txt 2>nul & exit /b 0"')
    rc = run_ssh("cmd /c C:\\kaya\\go-warm.cmd")
    out = (run_ssh_out("cmd /c type C:\\kaya\\out_gowarm.txt")
           or "").replace("\r", "")
    m = re.search(r"EXIT=(\d+)", out)
    if rc != 0 or not m or m.group(1) != "0":
        print("deploy-win: the Go warm-up build failed (go-warm.cmd); what "
              "it wrote:", file=sys.stderr)
        print(out, file=sys.stderr)
        sys.exit(1)
    print("== go warm (dev.kaya/guests/go/cmd built once, alone) ==")


if SUITE == "all" or SUITE.endswith("_go") or SUITE == "go":
    go_warm()
timing("go-warm")

# THE CAPTION TITLE'S AIM. NO SCENE CAN SEE IT: every harness read of a
# title goes through the string, the same whether the TextBlock sits on
# the centre line or 63 DIP left of it. THE COUNT RULES, because a probe
# that measures nothing reports no drift, which reads like finding none.
CAPTION_CENTRE_MIN_CLEAR = 6


def caption_centre_verdict(text, want_clear):
    plan = re.search(r"^AIMPLAN (\d+)$", text, re.M)
    if not plan:
        print("deploy-win: the probe printed no AIMPLAN line; there is no "
              "plan to check the rows against, so no number of rows would "
              "mean anything.", file=sys.stderr)
        return False
    want = int(plan.group(1))
    rows = re.findall(
        r"^AIMV (\S+) drift=(\S+) clamped=(true|false) absent=(true|false)$",
        text, re.M)
    if len(rows) != want:
        print(f"deploy-win: the caption-centre probe planned {want} "
              f"measurements and reported {len(rows)}. A sweep that stopped "
              f"early reports no drift, which is the same output as a sweep "
              f"that found none — fix the probe or the guest, do not lower "
              f"the plan.", file=sys.stderr)
        return False
    floor = re.search(r"^AIMFLOOR (\S+)$", text, re.M)
    if not floor:
        print("deploy-win: the probe printed no AIMFLOOR line, so there is "
              "no width at which a vanished title is allowed and the absence "
              "rule below could only be vacuous.", file=sys.stderr)
        return False
    stray = [t for t, _d, _c, a in rows if a == "true" and t != floor.group(1)]
    if stray:
        print("deploy-win: the caption title VANISHED at " + ", ".join(stray)
              + f". A title UIA does not publish is only correct at the "
              f"sweep's narrowest width ({floor.group(1)}), where the menu, "
              f"the commands, the drag strip and the caption cluster fill "
              f"the band and collapsing the title is the clamp taken to its "
              f"limit. At any wider width it is a title that stopped "
              f"existing.", file=sys.stderr)
        return False
    clear = [r for r in rows if r[2] == "false"]
    if len(clear) < want_clear:
        print(f"deploy-win: only {len(clear)} of {len(rows)} caption-centre "
              f"rows were UNCLAMPED and this lane requires {want_clear}. A "
              f"clamped row's drift is the rule working, so a run where "
              f"everything clamped would pass the drift rule having proved "
              f"nothing about the aim. Rows: "
              + ", ".join(f"{t}={'clamped' if c == 'true' else d}"
                          for t, d, c, _a in rows), file=sys.stderr)
        return False
    bad = [(t, d) for t, d, _c, _a in clear if float(d) != 0.0]
    if bad:
        print("deploy-win: the caption title is not on the window's centre "
              "at " + ", ".join(f"{t} (drift {d})" for t, d in bad)
              + ". DRIFT is the title's centre-x minus the visible frame's "
              "centre-x, both read; a non-zero drift on an UNCLAMPED row "
              "means center_caption_title's bias is not reaching the "
              "TextBlock — the historic value is -63, the leftover slot's "
              "own centre.", file=sys.stderr)
        return False
    overlaps = re.findall(r"^AIM .*THE TITLE OVERLAPS.*$", text, re.M)
    if overlaps:
        print("deploy-win: the caption title crosses a header:\n  "
              + "\n  ".join(overlaps), file=sys.stderr)
        return False
    print(f"deploy-win: caption title aimed at the window's centre — "
          f"{len(rows)} widths measured, {len(clear)} unclamped, all at "
          f"DRIFT 0")
    return True


def caption_centre_probe():
    print("== the caption title's aim (title-centre-probe, on the guest) ==",
          flush=True)
    log = LEGS_DIR / "caption-centre.log"
    with open(log, "w", encoding="utf-8") as lf:
        rc = subprocess.run(
            [str(ROOT / "crates/kaya/src/winui/title-centre-probe.sh"), HOST],
            env=dict(os.environ, KAYA_TCP_NO_DEPLOY="1"),
            stdout=lf, stderr=subprocess.STDOUT, check=False).returncode
    text = log.read_text(encoding="utf-8", errors="replace")
    print(text, end="")
    if rc != 0:
        print("deploy-win: the caption-centre probe did not produce a "
              "measurement.", file=sys.stderr)
        return False
    return caption_centre_verdict(text, CAPTION_CENTRE_MIN_CLEAR)


# Recording mode (KAYA_RECORD=1): a WGC capturer (tools/guest/record-win,
# built on the VM) films kaya windows, saving frames named by VM-clock
# epoch ms. GDI-family capture shows WinUI's DirectComposition content
# as BLANK; WGC reads the compositor and is window-scoped. Anchoring
# never crosses machines: frame names and harness epochs share the VM
# clock.
SUITES_RUN = []


def rec_suite_start():
    if not os.environ.get("KAYA_RECORD"):
        return
    if not (shutil.which("ffmpeg") and shutil.which("ffprobe")):
        die("recording mode needs ffmpeg/ffprobe — run inside nix develop")
    if subprocess.run([str(ROOT / "tools/harness-extract.sh"), "--selftest"],
                      check=False).returncode != 0:
        sys.exit(1)
    # Built once per source version (the marker carries the hash).
    h = hashlib.sha1()
    h.update((ROOT / "tools/guest/record-win/Program.cs").read_bytes())
    h.update((ROOT / "tools/guest/record-win/record-win.csproj").read_bytes())
    rw_hash = h.hexdigest()[:12]
    run_ssh("cmd /c if not exist C:\\kaya\\record-win mkdir "
            "C:\\kaya\\record-win")
    if scp_to([ROOT / "tools/guest/record-win/Program.cs",
               ROOT / "tools/guest/record-win/record-win.csproj"],
              "C:/kaya/record-win/") != 0:
        die("recording: could not ship record-win sources")
    if run_ssh(f"cmd /c dir C:\\kaya\\record-win\\.built-{rw_hash} "
               f">nul 2>nul") != 0:
        print("== building record-win on the VM ==")
        if run_ssh('cmd /c "cd /d C:\\kaya\\record-win && dotnet build '
                   '-c Release -v q"') != 0:
            die("recording: record-win build failed on the VM")
        run_ssh(f"cmd /c del C:\\kaya\\record-win\\.built-* 2>nul & cmd /c "
                f"echo built > C:\\kaya\\record-win\\.built-{rw_hash}")
    # The guest display must never sleep: a slept display stops DWM
    # composition and every window is GENUINELY white on screen — the
    # stills pass the count guard while showing nothing.
    powercfg = run_ssh_out("powercfg /q SCHEME_CURRENT SUB_VIDEO VIDEOIDLE")
    if "AC Power Setting Index: 0x00000000" not in (powercfg or ""):
        print("recording: the VM display can sleep, which blanks every "
              "window.")
        print("run on the VM:  powercfg /change monitor-timeout-ac 0")
        sys.exit(1)
    # A recorder left over from an aborted run would fight this one.
    run_ssh('cmd /c "taskkill /f /im record-win.exe 2>nul & exit /b 0"')
    run_ssh('cmd /c "if exist C:\\kaya\\frames rmdir /s /q C:\\kaya\\frames"')
    run_ssh('cmd /c "mkdir C:\\kaya\\frames"')
    must_ssh('schtasks /create /tn kaya_record /tr "wscript '
             'C:\\kaya\\run-hidden.vbs record.cmd" /sc once /st 00:00 /it '
             "/rl highest /f >nul && schtasks /run /tn kaya_record >nul")
    # Hold the suites until the capturer is up.
    for _ in range(60):
        out = run_ssh_out("type C:\\kaya\\out_record.txt")
        if out and "RECORDER_READY" in out:
            return
        time.sleep(1)
    print("recording: record-win never came up:", file=sys.stderr)
    run_ssh("type C:\\kaya\\out_record.txt")
    sys.exit(1)


def _extract_leg_recording(name, recdir):
    dirp = recdir / name
    dirp.mkdir(parents=True, exist_ok=True)
    log = dirp / "extract.log"
    with open(log, "w", encoding="utf-8") as lf:
        leg_log = run_ssh_out(f"type C:\\kaya\\out_{name}.txt") or ""
        (dirp / "leg.log").write_text(leg_log.replace("\r", ""),
                                      encoding="utf-8")
        text = (dirp / "leg.log").read_text(encoding="utf-8")
        m = re.search(r"KAYA_HARNESS: epoch ([0-9]+)", text)
        if not m:
            lf.write(f"{name}: no harness epoch in transcript\n")
            return False
        epoch = int(m.group(1))
        offs = [int(x) for x in
                re.findall(r"KAYA_HARNESS: \+([0-9]+)ms", text)]
        last_off = max(offs) if offs else 0
        slot_file = LEGS_DIR / f"{name}.slot"
        slot = (slot_file.read_text(encoding="utf-8").strip()
                if slot_file.is_file() else "0")
        (dirp / "slot").write_text(f"{slot}\n", encoding="utf-8")
        lo, hi = epoch - 1500, epoch + last_off + 2000
        # Frame files are <slot>-<epoch-ms>.png.
        stamps = []
        for f in (recdir / "frames").glob(f"{slot}-*.png"):
            ts = f.stem.rsplit("-", 1)[-1]
            if ts.isdigit() and lo <= int(ts) <= hi:
                stamps.append(int(ts))
        stamps.sort()
        (dirp / "frames.txt").write_text(
            "\n".join(str(t) for t in stamps) + ("\n" if stamps else ""),
            encoding="utf-8")
        if not stamps:
            lf.write(f"{name}: no frames overlap the leg's transcript\n")
            return False
        anchor = stamps[0]
        # ffconcat: each frame held until the next one is due, the last
        # for a fixed beat so the tail is not dropped.
        concat = []
        for prev, cur in zip(stamps, stamps[1:]):
            concat.append(f"file {recdir}/frames/{slot}-{prev}.png")
            concat.append(f"duration {(cur - prev) / 1000}")
        concat.append(f"file {recdir}/frames/{slot}-{stamps[-1]}.png")
        concat.append("duration 0.2")
        (dirp / "concat.txt").write_text("\n".join(concat) + "\n",
                                         encoding="utf-8")
        # Tiled windows have odd content sizes; h264 wants even.
        rc = subprocess.run(
            ["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "concat",
             "-safe", "0", "-i", str(dirp / "concat.txt"), "-fps_mode",
             "vfr", "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", "-pix_fmt",
             "yuv420p", "-c:v", "libx264", "-preset", "ultrafast", "-y",
             str(dirp / "video.mkv")],
            stdout=lf, stderr=subprocess.STDOUT, check=False).returncode
        if rc != 0:
            return False
        rc = subprocess.run(
            [str(ROOT / "tools/harness-extract.sh"), str(dirp / "video.mkv"),
             str(dirp / "leg.log"), str(anchor), str(dirp / "steps")],
            stdout=lf, stderr=subprocess.STDOUT, check=False).returncode
        return rc == 0


def rec_suite_stop():
    if not os.environ.get("KAYA_RECORD"):
        return True
    # The stop file is the recorder's own shutdown protocol; the
    # taskkill is the bound on it never noticing.
    run_ssh("cmd /c echo stop > C:\\kaya\\frames\\stop")
    time.sleep(3)
    run_ssh('cmd /c "taskkill /f /im record-win.exe 2>nul & exit /b 0"')
    recdir = ROOT / "target/recordings/windows"
    shutil.rmtree(recdir, ignore_errors=True)
    recdir.mkdir(parents=True)
    # Plain tar: the VM's bsdtar would write real zip for a .zip name
    # (-a), which the host's GNU tar refuses to read.
    if run_ssh('cmd /c "cd /d C:\\kaya && tar -c -f frames.tar frames"') != 0:
        print("recording: could not pack frames")
        return False
    if not scp_from("C:/kaya/frames.tar", recdir / "frames.tar"):
        print("recording: could not pull frames")
        return False
    if subprocess.run(["tar", "-xf", "frames.tar"], cwd=recdir,
                      check=False).returncode != 0:
        return False
    (recdir / "frames.tar").unlink()
    count = len(list((recdir / "frames").rglob("*.png")))
    if count == 0:
        print("recording: the capturer produced no frames")
        run_ssh("type C:\\kaya\\out_record.txt")
        return False
    # Per leg: transcript from the VM, then a film assembled from the
    # leg's own frame range, anchored at its first frame's epoch.
    results = {}
    threads = []
    for name in SUITES_RUN:
        t = threading.Thread(
            target=lambda n=name: results.__setitem__(
                n, _extract_leg_recording(n, recdir)))
        t.start()
        threads.append(t)
    for t in threads:
        t.join()
    failed = False
    for name in SUITES_RUN:
        log = recdir / name / "extract.log"
        if log.is_file():
            print(log.read_text(encoding="utf-8"), end="")
        if not results.get(name, False):
            failed = True
    if failed:
        print("recording: extraction failures above")
        return False
    return True


def run_guest_oneshot(script, outfile, marker):
    """Run a shipped one-shot guest script via schtasks and print the
    file it writes once its done-marker appears."""
    must_ssh(f"schtasks /create /tn kaya_oneshot /tr C:\\kaya\\{script} "
             f"/sc once /st 00:00 /it /rl highest /f >nul && schtasks /run "
             f"/tn kaya_oneshot >nul")
    for _ in range(60):
        out = run_ssh_out(f"type C:\\kaya\\{outfile}")
        if out and marker in out:
            print(out, end="")
            return True
        time.sleep(2)
    print(f"{script}: no {marker} after 60 polls", file=sys.stderr)
    return False


def run_probe(spec):
    """Start <exe> with no selftest via the shipped probe.cmd and report
    whether it survives scene construction — the first question when a
    suite exits with a stowed exception and no output."""
    exe, _, script = spec.partition(",")
    run_ssh(f"del C:\\kaya\\out_probe.txt 2>nul & schtasks /create /tn "
            f'kaya_probe /tr "C:\\kaya\\probe.cmd {exe} {script}" /sc once '
            f"/st 00:00 /it /rl highest /f >nul && schtasks /run /tn "
            f"kaya_probe >nul")
    for _ in range(60):
        out = run_ssh_out("type C:\\kaya\\out_probe.txt")
        if out and "PROBEDONE" in out:
            print(out, end="")
            return True
        time.sleep(2)
    print("probe: no PROBEDONE after 60 polls", file=sys.stderr)
    return False


# Suites run in a pool KAYA_WIN_JOBS wide (default 6, the VM's -smp;
# the width was measured twice, 420 contended against 434 at width 4 —
# docs/deferred.md). Each leg claims a tile slot, launches its scheduled
# task through the hidden-window shim with the slot argument, and blocks
# on the waiter for its output file. A timed-out leg's kill_guests sweep
# is VM-WIDE and takes concurrent legs with it.
WIDTH = int(os.environ.get("KAYA_WIN_JOBS", "6"))
_slots = list(range(WIDTH))
_slots_lock = threading.Condition()
_leg_names = []
_leg_threads = []
_restart_lock = threading.Lock()
_restarted = False
status = 0


def _claim_slot():
    with _slots_lock:
        while not _slots:
            _slots_lock.wait()
        return _slots.pop(0)


def _release_slot(slot):
    with _slots_lock:
        _slots.append(slot)
        # SORTED, so a leg that runs ALONE always gets slot 0 and its
        # window always lands in the same place: the tiling's slots 4 and
        # 5 sit at y=786 on this VM's 800-tall screen, off the bottom, and
        # a leg that aims REAL INPUT at screen pixels (dnd's `drag`) then
        # presses the taskbar (docs/traps.md: TWO OF THE SIX WINDOW TILES).
        _slots.sort()
        _slots_lock.notify()


def run_one_suite(name, slot, log):
    # A LANE THAT DECLARED ITS VM DEAD STAYS DEAD: without this every
    # remaining leg walks into its own 300-try timeout — 96 minutes of
    # burning after the lane printed "this lane is over" (2026-08-03).
    if (LEGS_DIR / ".vm-dead").exists():
        print(f"{name}: skipped — the VM was declared unreachable earlier "
              f"in this lane", file=log)
        return False
    run_ssh(f"del C:\\kaya\\out_{name}.txt 2>nul & schtasks /create /tn "
            f'kaya_{name} /tr "wscript C:\\kaya\\run-hidden.vbs '
            f'run_{name}.cmd {slot}" /sc once /st 00:00 /it /rl highest /f '
            f">nul && schtasks /run /tn kaya_{name} >nul", log=log)
    # ONE RESIDENT WAITER ON THE VM in place of a host-driven poll
    # (2026-08-20): at any host cadence each round paid a cmd.exe spawn
    # on vCPUs already oversubscribed under the matrix. wait-exit.ps1
    # polls LOCALLY at 150ms and charges one blocked mux channel; a
    # guest-OS wedge breaks the call at the master's keepalive rather
    # than hanging it. Stdout is kept even when ssh exits nonzero:
    # wait-exit.ps1 itself always exits 0, so a nonzero rc is the
    # transport's.
    out = subprocess.run(
        ["ssh", "-n", "-o", "BatchMode=yes", *SSH_MUX, HOST,
         f"powershell -NoProfile -ExecutionPolicy Bypass -File "
         f"C:\\kaya\\wait-exit.ps1 out_{name}.txt 290"],
        stdout=subprocess.PIPE, stderr=log, text=True,
        encoding="utf-8", errors="replace", check=False).stdout
    # KAYA_LINGER is liveness, not a hang: the verdict is out and only
    # the kernel-held termination is pending (wait-exit.ps1). Reading it
    # as a timeout kills a leg that has already passed.
    if "EXIT=" not in out and "KAYA_LINGER:" not in out:
        # A guest that never writes EXIT= is hung: kill it so it cannot
        # hold kaya.dll into the next suite or deploy.
        print(f"{name}: timed out waiting for output; killing guests",
              file=log)
        # IS THE VM EVEN ALIVE? The startup check runs ONCE, so an OS
        # hang mid-lane is otherwise invisible — every remaining leg
        # waits out its own 300s while UTM still reports "started"
        # (docs/traps.md, "The wedged-VM class"). Checked FIRST, because
        # "the VM is gone" makes every other diagnosis wrong.
        if not ssh_probe():
            print(f"{name}: THE VM IS UNREACHABLE mid-lane — the guest OS "
                  f'hung, not the guests (utmctl will still say "started"; '
                  f"that is the documented class in docs/traps.md). This "
                  f"lane is over; every remaining leg fails fast against "
                  f"the .vm-dead flag instead of burning its own timeout. "
                  f"Most likely cause is host contention: the windows lane "
                  f"is reliable standalone and degrades under the full "
                  f"five-lane matrix.", file=log)
            (LEGS_DIR / ".vm-dead").touch()
            return False
        # THE ONLY MOMENT A FAILING GUEST IS STILL ALIVE: every other
        # failure path arrives after the guest wrote EXIT= and went.
        # Collected BEFORE kill_guests, which destroys the evidence.
        FR.collect(name)
        (LEGS_DIR / f"{name}.collected").touch()
        kill_guests(log=log)
        # A plain timeout is recoverable; the WEDGED state is not, and
        # taskkill cannot tell you which you have (docs/traps.md,
        # "Windows guests wedge UNKILLABLY"). Restart once per run: a
        # wedge that recurs after a restart is not this class.
        if guests_wedged(log=log):
            global _restarted
            with _restart_lock:
                first = not _restarted
                _restarted = True
            if first:
                print(f"{name}: guests are WEDGED (tasklist lists them, "
                      f"taskkill reports no running instance) — the "
                      f"documented unkillable-terminating-state class; "
                      f"taskkill cannot clear it, restarting the VM",
                      file=log)
                vm_restart(log=log)
            else:
                print(f"{name}: guests WEDGED AGAIN after a VM restart — "
                      f"not the known transient class; investigate rather "
                      f"than retrying", file=log)
        return False
    print(out, file=log)
    # The verdict TEXT is the authority and the exit code only
    # corroborates it: WinUI's window-Closed handler overwrote a failing
    # run's exit code with 0, so a scene that printed FAILED exited 0.
    if "KAYA_SELFTEST: FAILED" in out:
        return False
    # KAYA_LINGER: the guest published its verdict and its process is
    # kernel-held in termination (wait-exit.ps1's grace; docs/traps.md
    # "exit() is not final on Windows"). EXIT= never landed, so the
    # verdict text alone decides.
    if "KAYA_LINGER:" in out:
        return "KAYA_SELFTEST: OK" in out
    return "EXIT=0" in out


def _leg_worker(name):
    # Line-buffered: a lane killed mid-leg keeps the evidence so far.
    with open(LEGS_DIR / f"{name}.log", "w", encoding="utf-8",
              errors="replace", buffering=1) as log:
        slot = _claim_slot()
        (LEGS_DIR / f"{name}.slot").write_text(f"{slot}\n", encoding="utf-8")
        t0 = time.monotonic()
        leg_epoch = int(time.time())
        ok = run_one_suite(name, slot, log)
        secs = int(time.monotonic() - t0)
        (LEGS_DIR / f"{name}.secs").write_text(f"{secs}\n", encoding="utf-8")
        _release_slot(slot)
        verdict = "PASS" if ok else "FAIL"
        (LEGS_DIR / f"{name}.verdict").write_text(f"{verdict}\n",
                                                  encoding="utf-8")
        log.flush()
        # The recorder's failure-path prints belong to THIS leg's log,
        # passed as a stream: sys.stdout is process-global and a redirect
        # would cross two concurrently failing legs' logs.
        FR.win_leg(name, verdict, secs, LEGS_DIR / f"{name}.log",
                   (LEGS_DIR / f"{name}.collected").exists(), leg_epoch,
                   out=log)


def run_suite(name):
    SUITES_RUN.append(name)
    _leg_names.append(name)
    t = threading.Thread(target=_leg_worker, args=(name,))
    t.start()
    _leg_threads.append(t)


def drain_suites():
    global status
    for t in _leg_threads:
        t.join()
    _leg_threads.clear()
    for name in _leg_names:
        vfile = LEGS_DIR / f"{name}.verdict"
        verdict = (vfile.read_text(encoding="utf-8").strip()
                   if vfile.is_file() else "FAIL")
        print(f"== {name} ==")
        lfile = LEGS_DIR / f"{name}.log"
        if lfile.is_file():
            print(lfile.read_text(encoding="utf-8", errors="replace"),
                  end="", flush=True)
        if verdict != "PASS":
            status = 1
        sfile = LEGS_DIR / f"{name}.secs"
        secs = (sfile.read_text(encoding="utf-8").strip()
                if sfile.is_file() else "?")
        print(f"{name}: {verdict} ({secs}s)", flush=True)
    _leg_names.clear()


def desk_warm():
    """WILL THIS DESKTOP HAND A WINDOW THE FOREGROUND? Asked once,
    before any leg. THE STATE IS INVISIBLE FROM SSH: an ssh session has
    its own window station (session 0) and cannot see the input desktop,
    so the question is asked from where the legs ask it — an interactive
    scheduled task — and answered the way they answer it: a real window
    and a real SetForegroundWindow (tools/guest/desk-warm.ps1 carries
    the measurements; docs/traps.md carries the class)."""
    run_ssh("del C:\\kaya\\out_deskwarm.txt 2>nul & schtasks /create /tn "
            'kaya_deskwarm /tr "wscript C:\\kaya\\run-hidden.vbs '
            'desk-warm.cmd" /sc once /st 00:00 /it /rl highest /f >nul && '
            "schtasks /run /tn kaya_deskwarm >nul")
    out = ""
    for tries in range(81):
        out = (run_ssh_out("cmd /c type C:\\kaya\\out_deskwarm.txt")
               or "").replace("\r", "")
        if "DESKWARMEXIT=" in out:
            break
        if tries == 80:
            print("deploy-win: the desktop warm-up never answered.",
                  file=sys.stderr)
            print("  It runs as an interactive scheduled task, which needs "
                  "a LOGGED-IN", file=sys.stderr)
            print("  console session — 'query session' showing "
                  "console/Active. If nothing", file=sys.stderr)
            print("  is signed in at the VM's console window, no leg can "
                  "run either:", file=sys.stderr)
            print("  sign in through UTM, or restart the VM, and re-run.",
                  file=sys.stderr)
            print("  What it had written so far:", file=sys.stderr)
            print(out, file=sys.stderr)
            return False
        time.sleep(0.5)
    m = re.search(r"deskwarm\.verdict=([A-Z]*)", out)
    if m and m.group(1) == "OK":
        # One line on the happy path, carrying what it had to get past:
        # a Start menu left open on the VM shows up here as the holder.
        stats = " ".join(re.findall(r"deskwarm\.(?:tries|ms|before)=\S*",
                                    out))
        print(f"== desktop warm ({stats} ) ==")
        return True
    print("deploy-win: THE GUEST DESKTOP WILL NOT HAND OVER THE FOREGROUND.",
          file=sys.stderr)
    for line in out.splitlines():
        if line.startswith("deskwarm."):
            print(line, file=sys.stderr)
    reason = re.search(r"deskwarm\.reason=([a-z]*)", out)
    reason = reason.group(1) if reason else ""
    if reason == "inputdesktop":
        print("  The console session is LOCKED, or a secure desktop (a UAC "
              "prompt) is", file=sys.stderr)
        print("  up: input goes to a different desktop than the one the "
              "legs' windows", file=sys.stderr)
        print("  live on. Injected keys land there too, so the backend's "
              "ESC and ALT", file=sys.stderr)
        print("  are delivered somewhere else and every menus_*/commands_* "
              "leg would", file=sys.stderr)
        print("  fail after 3s. Nothing over ssh can clear it — an ssh "
              "session cannot", file=sys.stderr)
        print("  reach the interactive desktop at all.", file=sys.stderr)
        print("  Sign in at the VM's console window in UTM, or restart the "
              "VM:", file=sys.stderr)
        print(f'    {utmctl_bin()} stop --kill "{VM_NAME}" && {utmctl_bin()} '
              f'start "{VM_NAME}"', file=sys.stderr)
        print("  (the guest signs itself back in), then re-run.",
              file=sys.stderr)
    elif reason == "foreground":
        print("  A window is holding the foreground through both remedies "
              "the backend", file=sys.stderr)
        print("  tries — the ESC that dismisses a menu and the bare ALT "
              "that releases a", file=sys.stderr)
        print("  foreground lock. A notification toast is the usual one and "
              "has no", file=sys.stderr)
        print("  title, so the class and owning process above are the "
              "identification", file=sys.stderr)
        print("  (docs/traps.md: a shell toast holds the foreground).",
              file=sys.stderr)
        print("  Look at it — the picture ends the search in two minutes:",
              file=sys.stderr)
        print(f"    ssh {HOST} 'schtasks /create /tn kaya_shot /tr \"wscript "
              f'C:\\kaya\\run-hidden.vbs shot.cmd" /sc once /st 00:00 /it '
              f"/rl highest /f && schtasks /run /tn kaya_shot'",
              file=sys.stderr)
        print(f"    scp {HOST}:C:/kaya/shot.png .", file=sys.stderr)
        print("  Dismiss it, or restart the VM, then re-run.",
              file=sys.stderr)
    else:
        print("  The warm-up answered without a verdict this script "
              "understands.", file=sys.stderr)
    return False


# The diagnostic verbs are exempt: they interrogate a VM that is already
# sick, and a warm-up refusing them takes away the tool you reach for.
if not (SUITE.startswith("probe=")
        or SUITE in ("enable-dumps", "crash-report", "analyze-dump")):
    if not desk_warm():
        sys.exit(1)
timing("desk-warm")

rec_suite_start()
if SUITE == "all":
    # FIRST, AND ALONE: the probe drives a real border drag and a width
    # sweep on the one window it can find by class, so it needs the
    # desktop to itself.
    if not caption_centre_probe():
        status = 1
    timing("caption-centre")
    # THE ROSTER IS DATA: tools/lib/lanes/win.py, blocks between drains.
    for block in lane.ORDER:
        for leg in block:
            run_suite(leg)
        drain_suites()
elif SUITE == "caption-centre":
    if not caption_centre_probe():
        status = 1
elif SUITE.startswith("probe="):
    if not run_probe(SUITE[len("probe="):]):
        status = 1
elif SUITE == "enable-dumps":
    if not run_guest_oneshot("enable-dumps.cmd", "out_enable_dumps.txt",
                             "EXIT="):
        status = 1
elif SUITE == "crash-report":
    if not run_guest_oneshot("crash-report.cmd", "out_crash_report.txt",
                             "REPORTDONE"):
        status = 1
elif SUITE == "analyze-dump":
    if not run_guest_oneshot("analyze-dump.cmd", "out_analyze.txt",
                             "ANALYZEDONE"):
        status = 1
else:
    run_suite(SUITE)
drain_suites()
timing("suites")
if not rec_suite_stop():
    status = 1
if os.environ.get("KAYA_RECORD"):
    timing("recording-pull+stills")
# Suites accumulate failures rather than abort, so a truncated log must
# still end with the answer: a log that stops early reads exactly like a
# complete one, which is how an ios run that reached no leg at all was
# read as a pass (2026-08-29). tools/check-gates.py holds all five
# runners to this.
if status == 0:
    print("deploy-win: ALL PASS")
else:
    print("deploy-win: FAILURES ABOVE")
sys.exit(status)
