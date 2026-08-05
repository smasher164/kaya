#!/usr/bin/env bash
# The menus scene runs every language here (the WinUI backend
# materializes the command vocabulary). Its legs are the one
# exception to the four-wide pool: SERIAL, between drains — see the
# barrier at the bottom of the `all` case (docs/traps.md, OS-global
# shortcut injection).

# Everything runs inside the dev shell: the flake pins every toolchain
# (rust + cross targets, swiftc, ffmpeg, the android sdk). Running
# against anything else is an error, not something to paper over — and
# a shell entered before the flake last changed is just as much a
# bystander toolchain, so the marker carries the fingerprint of
# flake.nix+flake.lock the shell was actually built from.
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# Deploy milestone-0 artifacts to the Windows VM and run the validations.
#
# Usage: tools/deploy-win.sh user@host [--provision] [rust|python|go|csharp|all]
#        tools/deploy-win.sh user@host probe=<exe>   # aliveness probe, e.g. probe=entry
#
# Convention: everything that lands on the VM as a FILE is shipped with
# scp from this repo (tools/guest/*.cmd and the built artifacts) —
# never constructed remotely by echoing escaped text over ssh. Two
# escaping layers (bash quoting, then cmd.exe carets) mangle such
# constructions reliably; run_ssh is for running commands only. New
# guest-side scripts go in tools/guest/, where the deploy's glob ships
# them automatically.
#
# Requirements in the guest (one-time; snapshot afterward, portsh-style):
#   - OpenSSH server with key auth, sshd start type Automatic
#   - a logged-in console session (WinUI cannot run in the SSH service
#     session; tests run via scheduled tasks with /it)
#   - for --provision: nothing else (installs the Windows App Runtime)
#   - for the python/go/csharp suites: winget install Python.Python.3.13 /
#     GoLang.Go / Microsoft.DotNet.SDK.10, and an llvm-mingw ucrt-aarch64
#     release unpacked under C:\kaya (cgo needs a C compiler; policy is
#     clang everywhere)
#
# Builds before deploying (release: the hybrid CRT policy in build.rs
# makes release artifacts self-contained; debug builds still import
# vcruntime), so the VM can never run yesterday's artifacts against
# today's sources. Run inside the dev shell (cargo-xwin comes from the
# flake).
set -euo pipefail

ROOT_FOR_CHECK="$(cd "$(dirname "$0")/.." && pwd)"
# Phase timing: greppable "TIMING <phase> <n>s" lines say where a
# run's wall time went — build, deploy, or suites.
KAYA_T0=$SECONDS
timing() {
    echo "TIMING $1 $((SECONDS - KAYA_T0))s"
    KAYA_T0=$SECONDS
}
# Compile the windows target before touching the VM.
"$ROOT_FOR_CHECK/tools/check-targets.sh" windows || exit 1
timing check-targets

HOST="${1:?usage: deploy-win.sh user@host [--provision] [rust|python|go|all]}"
shift
PROVISION=0
SUITE="all"
for arg in "$@"; do
    case "$arg" in
        --provision) PROVISION=1 ;;
        rust|python|go|csharp|java|all) SUITE="$arg" ;;
        entry_rust|entry_python|entry_go|entry_csharp|entry_java) SUITE="$arg" ;;
        gallery_rust|gallery_python|gallery_go|gallery_csharp|gallery_java) SUITE="$arg" ;;
        todos_rust|todos_python|todos_go|todos_csharp|todos_java) SUITE="$arg" ;;
        reorder_rust|reorder_python|reorder_go|reorder_csharp|reorder_java) SUITE="$arg" ;;
        feed_rust|feed_python|feed_go|feed_csharp|feed_java) SUITE="$arg" ;;
        grow_rust|grow_python|grow_go|grow_csharp|grow_java) SUITE="$arg" ;;
        align_rust|align_python|align_go|align_csharp|align_java) SUITE="$arg" ;;
        window_rust|window_python|window_go|window_csharp|window_java) SUITE="$arg" ;;
        panels_rust|panels_python|panels_go|panels_csharp|panels_java) SUITE="$arg" ;;
        confirm_rust|confirm_python|confirm_go|confirm_csharp|confirm_java) SUITE="$arg" ;;
        nav_rust|nav_python|nav_go|nav_csharp|nav_java) SUITE="$arg" ;;
        split_rust|split_python|split_go|split_csharp|split_java) SUITE="$arg" ;;
        listdetail_rust|listdetail_python|listdetail_go|listdetail_csharp|listdetail_java) SUITE="$arg" ;;
        scroll_rust|scroll_python|scroll_go|scroll_csharp|scroll_java) SUITE="$arg" ;;
        progress_rust|progress_python|progress_go|progress_csharp|progress_java) SUITE="$arg" ;;
        a11y_rust|a11y_python|a11y_go|a11y_csharp|a11y_java) SUITE="$arg" ;;
        select_rust|select_python|select_go|select_csharp|select_java) SUITE="$arg" ;;
        radio_rust|radio_python|radio_go|radio_csharp|radio_java) SUITE="$arg" ;;
        grid_rust|grid_python|grid_go|grid_csharp|grid_java) SUITE="$arg" ;;
        textarea_rust|textarea_python|textarea_go|textarea_csharp|textarea_java) SUITE="$arg" ;;
        sections_rust|sections_python|sections_go|sections_csharp|sections_java) SUITE="$arg" ;;
        layout_rust|layout_python|layout_go|layout_csharp|layout_java) SUITE="$arg" ;;
        menus_rust|menus_python|menus_go|menus_csharp|menus_java) SUITE="$arg" ;;
        filedialog_rust|filedialog_python|filedialog_go|filedialog_csharp|filedialog_java) SUITE="$arg" ;;
        commands_rust|commands_python|commands_go|commands_csharp|commands_java) SUITE="$arg" ;;
        clipboard_rust|clipboard_python|clipboard_go|clipboard_csharp|clipboard_java) SUITE="$arg" ;;
        # A DEPTH SCENE, so rust alone (docs/undo-plan.md §4's fan-out):
        # the other eight guests land with the `undoable` sweep.
        undo_rust) SUITE="$arg" ;;
        # These two were wired as legs without arms here, so a single
        # leg could not be re-run in isolation — the one-leg-repeatedly
        # loop is the only practical way to characterise a rare flake.
        background_rust|background_python|background_go|background_csharp|background_java) SUITE="$arg" ;;
        stall_rust|stall_python|stall_go|stall_csharp|stall_java) SUITE="$arg" ;;
        probe=*) SUITE="$arg" ;;
        enable-dumps|crash-report|analyze-dump) SUITE="$arg" ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$ROOT/target/aarch64-pc-windows-msvc/release"
SDK="$ROOT/third_party/winappsdk"
BOOTSTRAP="$SDK/Microsoft.WindowsAppSDK.Foundation-2.1.0/extracted/runtimes/win-arm64/native/Microsoft.WindowsAppRuntime.Bootstrap.dll"

# Connection multiplexing: ONE master TCP/auth handshake, every
# subsequent ssh/scp rides it (~1.4s per round trip before; the
# suites phase alone makes hundreds of schtasks/type calls). The
# socket lives in the repo's target/ and persists briefly past the
# run so back-to-back invocations reuse it.
# ConnectTimeout rides every call: when the guest OS wedges mid-run
# (observed 2026-07-22 — UTM "started", sshd gone), each poll would
# otherwise hang the full TCP timeout (~75s) and stretch the suite
# poll loops' try-bounded deadlines toward hours. With it, a dead VM
# fails the run in minutes.
SSH_MUX=(-o ConnectTimeout=5 -o ControlMaster=auto -o "ControlPath=$ROOT/target/.ssh-mux-%r@%h" -o ControlPersist=120)
run_ssh() { ssh -n -o BatchMode=yes "${SSH_MUX[@]}" "$HOST" "$@"; }
scp() { command scp "${SSH_MUX[@]}" "$@"; }

# The VM must be up before anything else: check reachability, and if the
# guest is down, boot it through UTM and wait for sshd. The trailing
# grace period lets the console session finish logging in — the suites
# run as scheduled tasks with /it, which need it.
VM_NAME="${KAYA_WIN_VM:-Windows}"
utmctl_bin() {
    command -v utmctl 2>/dev/null || echo /Applications/UTM.app/Contents/MacOS/utmctl
}
if ! ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$HOST" 'exit 0' 2>/dev/null; then
    # Unreachable can mean stopped OR wedged: a guest whose OS hung
    # mid-run leaves UTM reporting "started" while sshd is gone, and
    # `utmctl start` on a started VM is a no-op — the old loop waited
    # five minutes and gave up. Force the wedged case down first.
    if "$(utmctl_bin)" status "$VM_NAME" 2>/dev/null | grep -qi started; then
        # WAIT BEFORE KILLING: "started but unreachable" is the shape of a
        # guest that BUGCHECKED and is rebooting, not only of one that
        # hung. Killing it there costs twice — the crash dump is written
        # to the pagefile and only converts to C:\Windows\Minidump on the
        # NEXT boot, so a kill five seconds in erases the evidence (7 of
        # 12 crashes left no dump that way), and a power cut mid-boot is
        # what corrupted this VM's boot volume on 2026-08-04. A reboot
        # takes about a minute; only a guest that misses that whole
        # window is genuinely wedged.
        echo "== $HOST unreachable; giving \"$VM_NAME\" 3 minutes to finish a possible bugcheck reboot =="
        booted=0
        waited=0
        while [ "$waited" -lt 180 ]; do
            if ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$HOST" 'exit 0' 2>/dev/null; then
                echo "== $HOST came back on its own after ${waited}s (a crash reboot, not a wedge) =="
                booted=1
                break
            fi
            sleep 10
            waited=$((waited + 10))
        done
    fi
    if [ "${booted:-0}" = 0 ] &&
        "$(utmctl_bin)" status "$VM_NAME" 2>/dev/null | grep -qi started; then
        echo "== $HOST still unreachable after 3 minutes; force-restarting =="
        "$(utmctl_bin)" stop --kill "$VM_NAME" || true
        tries=0
        while "$(utmctl_bin)" status "$VM_NAME" 2>/dev/null | grep -qi started; do
            tries=$((tries + 1))
            if [ "$tries" -gt 12 ]; then
                echo "VM \"$VM_NAME\" would not stop" >&2
                exit 1
            fi
            sleep 5
        done
    fi
    [ "${booted:-0}" = 0 ] && echo "== $HOST unreachable; starting VM \"$VM_NAME\" =="
    "$(utmctl_bin)" start "$VM_NAME"
    tries=0
    until ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$HOST" 'exit 0' 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -gt 60 ]; then
            echo "VM \"$VM_NAME\" did not become reachable" >&2
            exit 1
        fi
        sleep 5
    done
    sleep 30
    # AND SAY WHETHER THE GUEST CRASHED, because "the VM was
    # unreachable" reads as host contention and was recorded as such in
    # docs/traps.md for two weeks while the guest was really
    # BUGCHECKING — twelve times, all viogpudo.sys+0xB52C, the first
    # 2h25m after the matrix went concurrent. A dump written to the
    # pagefile only becomes a file on the boot AFTER the crash, so this
    # is the first moment it can be seen.
    latest_dump=$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$HOST" \
        'powershell -NoProfile -Command "Get-ChildItem C:\Windows\Minidump\*.dmp -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1 -ExpandProperty Name"' \
        2>/dev/null | tr -d '\r')
    if [ -n "$latest_dump" ]; then
        echo "== the guest's newest crash dump is $latest_dump — if that is from this run," \
            "the VM did not hang, it BUGCHECKED (docs/traps.md, the viogpudo class) =="
    fi
fi
timing vm-ready

# THE scene list: every mechanical per-scene surface below derives
# from it (cross-build examples, exe/python/go shipping, taskkill).
# Adding a scene here is the ONE registration; the suite blocks stay
# explicit because they encode per-language coverage decisions. The
# class this kills: four hand-maintained lists in this file, where a
# forgotten entry shipped every artifact except the one a leg needed
# (panels_go: sources never reached the VM; check-steps' per-runner
# grep was satisfied by the other three lists).
SCENES="background stall milestone2 entry gallery todos reorder feed grow layout align window panels confirm nav split scroll progress select radio grid textarea sections menus commands a11y filedialog clipboard"
# Depth-slice scenes: a rust example + steps exist, the language sweep
# has not landed yet. Built, shipped and run RUST-ONLY, so a backend can
# be validated before nine guests exist — the deploy-win twin of
# validate-mac's DEPTH_SCENES. Without it a new scene must either join
# SCENES (whose per-language surfaces glob for a11y.py, a11y.go, ... and
# fail loudly, correctly) or go unexercised on this lane entirely, which
# is how the WinUI accessibility read ended up committed unproven.
DEPTH_SCENES="${KAYA_WIN_DEPTH_SCENES:-undo}"

SCENE_EXES=()
SCENE_PYS=()
BUILD_EXAMPLES=()
for s in $SCENES; do
    SCENE_EXES+=("$TARGET/examples/$s.exe")
    SCENE_PYS+=("$ROOT/guests/python/$s.py")
    BUILD_EXAMPLES+=(--example "$s")
done
# Depth scenes contribute their EXE only: no .py, no go package, no
# csharp/java surface — those are exactly the halves that do not exist
# yet.
for s in $DEPTH_SCENES; do
    SCENE_EXES+=("$TARGET/examples/$s.exe")
    BUILD_EXAMPLES+=(--example "$s")
done
# (No mid-sweep list any more: filedialog joined SCENES when its eighth
# guest landed, so its per-language surfaces glob with everyone else's.)

echo "== building (aarch64-pc-windows-msvc, release) =="
(cd "$ROOT" && cargo xwin build --locked --features harness --release --target aarch64-pc-windows-msvc --lib \
    && cargo xwin build --locked --features harness --release --target aarch64-pc-windows-msvc \
        "${BUILD_EXAMPLES[@]}")
# Verify BEFORE the deploy: a stale dll that reaches the VM is a
# stale dll on another machine, where nothing local can see it.
"$ROOT/tools/build-id.sh" --verify "$TARGET/kaya.dll" || exit 1
"$ROOT/tools/gen-header.sh" --check
"$ROOT/tools/gen-bindings.sh" --check

# Every kaya_* function declared in kaya.h must be exported by the DLL;
# a missing export would otherwise surface as a remote link or load
# error, or worse, pass by resolving against a stale deployed copy.
declared=$(python3 -c '
import re, sys
# A declaration line: starts in column 0 and names kaya_<something>(
pat = re.compile(r"^[A-Za-z_].*[ *](kaya_[a-z0-9_]+)\(")
seen = {m.group(1) for line in open(sys.argv[1]) if (m := pat.match(line))}
print("\n".join(sorted(seen)))' "$ROOT/crates/kaya/include/kaya.h")
exported=$(objdump -p "$TARGET/kaya.dll" | python3 -c '
import re, sys
# Only the Export Table section, then every kaya_ symbol in it.
out, inside = set(), False
for line in sys.stdin:
    if "Export Table:" in line:
        inside = True
        continue
    if inside and not line.strip():
        break
    if inside:
        out.update(re.findall(r"kaya_[a-z0-9_]+", line))
print("\n".join(sorted(out)))')
missing=$(comm -23 <(echo "$declared") <(echo "$exported"))
if [ -n "$missing" ]; then
    echo "kaya.dll does not export functions declared in kaya.h:" >&2
    echo "$missing" >&2
    exit 1
fi
timing build

run_ssh 'cmd /c if not exist C:\kaya mkdir C:\kaya'
run_ssh 'cmd /c if not exist C:\kaya\bindings\python mkdir C:\kaya\bindings\python'
run_ssh 'cmd /c if not exist C:\kaya\bindings\go mkdir C:\kaya\bindings\go'
# The scenes: the Rust backends resolve a scene NAME to
# <KAYA_SCENES_DIR>/<name>.steps, so the .steps files must reach the VM.
# EVERY run, not the --provision block: legs depend on these, and a
# provisioning-only ship means a scene edit never arrives (cost a
# debugging round on 2026-07-25, and the empty C:\kaya\scenes was
# briefly misread as the deploy stamp masking a change — the stamp
# hashes $0 and was innocent).
run_ssh 'cmd /c if not exist C:\kaya\scenes mkdir C:\kaya\scenes'
scp -q "$ROOT"/tools/scenes/*.steps "$HOST:C:/kaya/scenes/"
# Set once for the machine rather than in forty checked-in .cmd files:
# every leg runs through schtasks, which inherits the user environment.
run_ssh 'setx KAYA_SCENES_DIR C:\kaya\scenes >nul' 


# EXTENSIONS MUST BE VISIBLE, and this is not cosmetic. Explorer ships
# with HideFileExt=1, so the file picker's rows publish "picked" where
# mac and GTK publish "picked.txt" — and tools/scenes/*.steps are
# compared BYTE-FOR-BYTE across every platform (CLAUDE.md, invariant 6).
# A fresh VM with the default would fail the filedialog leg looking
# exactly like a backend bug.
#
# Set every deploy rather than once at --provision: it is a per-user
# registry value that any Explorer settings change can put back, and a
# silent revert would cost the same debugging round twice. Verified
# after setting, because a setx-style write that did not take is the
# kind of thing that reads as success.
run_ssh 'reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v HideFileExt /t REG_DWORD /d 0 /f >nul'
hide_ext="$(run_ssh 'reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v HideFileExt' 2>/dev/null | tr -d '\r')"
case "$hide_ext" in
    *0x0*) ;;
    *)
        echo "deploy-win: HideFileExt is not 0 on the guest — the picker would" >&2
        echo "  publish rows without extensions and the filedialog leg would fail" >&2
        echo "  as though the backend were wrong. Got: $hide_ext" >&2
        exit 1
        ;;
esac
# AND NO NOTIFICATION TOASTS, for a sharper version of the same reason.
# A toast is a foreground window owned by the shell, and while one is up
# SetForegroundWindow FAILS for everything else — so every leg that
# injects a real keyboard chord (menus_*, commands_*, one per language)
# dies with "could not foreground the guest window", which reads exactly
# like a WinUI bug. Measured 2026-07-31: a "Turn off notifications from
# OneDrive?" SUGGESTION toast took out all ten of them, twice in a row,
# while the other 121 legs passed. The lane had been green the day
# before; nothing in the tree had changed.
#
# Three values, because the shell has three places to say it: toasts at
# all, the notification centre's master switch, and the "suggestions"
# channel that raised this particular one unprompted. Set every deploy,
# like HideFileExt above, and for the same reason — any settings visit
# can put them back and a silent revert costs the round twice.
run_ssh 'reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\PushNotifications" /v ToastEnabled /t REG_DWORD /d 0 /f >nul'
run_ssh 'reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings" /v NOC_GLOBAL_SETTING_TOASTS_ENABLED /t REG_DWORD /d 0 /f >nul'
run_ssh 'reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338389Enabled /t REG_DWORD /d 0 /f >nul'
toasts="$(run_ssh 'reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\PushNotifications" /v ToastEnabled' 2>/dev/null | tr -d '\r')"
case "$toasts" in
    *0x0*) ;;
    *)
        echo "deploy-win: toasts are still enabled on the guest — a shell toast" >&2
        echo "  holds the foreground and every shortcut-injection leg would fail" >&2
        echo "  as though WinUI could not raise its own window. Got: $toasts" >&2
        exit 1
        ;;
esac

# THE FOREGROUND LOCK MUST BE OFF, and this is the third setting in a
# row that exists because the desktop can quietly refuse a window the
# foreground.
#
# Windows denies SetForegroundWindow to a process that has not received
# the last input event, and waits ForegroundLockTimeout (200000 ms by
# default) before letting anyone else in. Every shortcut-injection leg
# needs the guest window foregrounded, so with the default value the
# ONLY reason those legs pass is that some earlier leg happened to
# deliver input to the session. A long-running VM accumulates that
# incidentally, which is why this was invisible for months.
#
# A REBOOT REMOVES IT. Measured 2026-07-31: after restarting the VM,
# every menus and commands leg failed — ten of them, in all five
# languages, reproducibly, alone and concurrent — with "could not
# foreground the guest window". Nothing had changed in kaya; the same
# commit had passed three times that evening. Synthesizing input from a
# helper does NOT fix it, because the foreground right is granted to the
# process that received the input, which was the helper.
#
# Zero means SetForegroundWindow always succeeds. The registry write
# seeds the NEXT logon; the live session is done by the desktop warm-up
# below, which calls SystemParametersInfo from INSIDE that session.
#
# It used to be called from here, over ssh, and could not work:
# measured 2026-08-04, the console session still read 2147483647 after
# every deploy that day, because an ssh session is session 0 with its
# own window station and SPI applies per window station. This check is
# left reading the registry — it is the part a write from here can
# affect — and the warm-up reports the live value it actually changed.
run_ssh 'reg add "HKCU\Control Panel\Desktop" /v ForegroundLockTimeout /t REG_DWORD /d 0 /f >nul'
fglock="$(run_ssh 'reg query "HKCU\Control Panel\Desktop" /v ForegroundLockTimeout' 2>/dev/null | tr -d '\r')"
case "$fglock" in
    *0x0*) ;;
    *)
        echo "deploy-win: the guest still holds a foreground lock — every" >&2
        echo "  shortcut-injection leg will fail as though WinUI could not raise" >&2
        echo "  its own window, which is what a freshly rebooted VM looks like." >&2
        echo "  Got: $fglock" >&2
        exit 1
        ;;
esac

for guest in $SCENES; do
    run_ssh "cmd /c if not exist C:\\kaya\\guests\\go\\$guest mkdir C:\\kaya\\guests\\go\\$guest"
    # The whole package, not just main.go: guests with generated sum
    # surfaces (kaya-gen) carry a checked-in *_kaya.go beside it.
    scp -q "$ROOT/guests/go/$guest/"*.go "$HOST:C:/kaya/guests/go/$guest/"
done

if [ "$PROVISION" = 1 ]; then
    echo "== provisioning Windows App Runtime (one-time) =="
    scp -q "$SDK/WindowsAppRuntimeInstall-arm64.exe" "$HOST:C:/kaya/"
    run_ssh 'C:\kaya\WindowsAppRuntimeInstall-arm64.exe --quiet --force'
fi

# The ARM64 JDK for the java legs: fetched once, idempotently, via
# winget. --architecture arm64 is LOAD-BEARING: winget under the
# emulated x64 shell defaults to the x64 build, whose JVM cannot
# load the aarch64 kaya.dll ("Can't load ARM 64-bit .dll on a AMD
# 64-bit platform"); zulu ships no arm64 winget package, Microsoft's
# OpenJDK does.
run_ssh 'cmd /c java -version >nul 2>&1 && echo jdk present || winget install --id Microsoft.OpenJDK.17 --architecture arm64 --silent --accept-package-agreements --accept-source-agreements --scope machine'

# Go 1.27rc2 on the VM (generic methods; pre-release until August
# 2026): fetched once, idempotently; the go guest scripts prepend
# C:\kaya\go127\go\bin so it wins over any stable install.
run_ssh 'cmd /c if exist C:\kaya\go127\go\bin\go.exe (echo go127 present) else (powershell -Command "Invoke-WebRequest -Uri https://go.dev/dl/go1.27rc2.windows-arm64.zip -OutFile C:\kaya\go127.zip; Expand-Archive -Path C:\kaya\go127.zip -DestinationPath C:\kaya\go127 -Force; Remove-Item C:\kaya\go127.zip")'

# A hung or leftover guest keeps kaya.dll locked: the next deploy's
# copy fails under set -e, or a fresh suite runs beside a zombie. This
# is a dedicated test VM — python/go/dotnet processes are always kaya
# guests — so killing by image name is safe. Swept before deploying,
# after any suite timeout, and on every exit path (trap below).
kill_guests() {
    # Two name families beyond <scene>.exe: the go legs build
    # <scene>_go.exe (the pri-adjacency arrangement), and the C# legs
    # run the kaya-guests.exe apphost — both held kaya.dll through a
    # deploy once (2026-07-22).
    kill_list=$(for s in $SCENES $DEPTH_SCENES; do printf 'taskkill /f /im %s.exe 2>nul & taskkill /f /im %s_go.exe 2>nul & ' "$s" "$s"; done)
    run_ssh "cmd /c \"${kill_list}taskkill /f /im python.exe 2>nul & taskkill /f /im go.exe 2>nul & taskkill /f /im dotnet.exe 2>nul & taskkill /f /im kaya-guests.exe 2>nul & taskkill /f /im java.exe 2>nul & taskkill /f /im cdb.exe 2>nul & exit /b 0\"" || true
}
# Is the guest stuck in the state taskkill CANNOT clear? The signature
# is a contradiction: tasklist still LISTS an image while taskkill says
# "There is no running instance of the task" — a process past the point
# where it can be signalled, not a permissions failure (that reports
# "Access is denied", which is a different message and a different
# problem). Confirmed 2026-07-25 after the second occurrence; the class
# is in docs/traps.md. Only a VM restart clears it.
guests_wedged() {
    local listed killed
    listed=$(run_ssh "tasklist" 2>/dev/null \
        | grep -icE "^(go|java|python|dotnet|kaya-guests)\.exe" || true)
    [ "${listed:-0}" -gt 0 ] || return 1
    killed=$(run_ssh "cmd /c \"taskkill /f /im go.exe & taskkill /f /im java.exe & taskkill /f /im python.exe & taskkill /f /im dotnet.exe & exit /b 0\"" 2>&1 || true)
    grep -qi "no running instance" <<<"$killed"
}

# Force the VM down and back up, then wait for sshd. The ONLY escape
# from the wedged state above.
vm_restart() {
    echo "== force-restarting VM \"$VM_NAME\" ==" >&2
    "$(utmctl_bin)" stop --kill "$VM_NAME" || true
    local tries=0
    while "$(utmctl_bin)" status "$VM_NAME" 2>/dev/null | grep -qi started; do
        tries=$((tries + 1))
        [ "$tries" -le 12 ] || { echo "VM would not stop" >&2; return 1; }
        sleep 5
    done
    "$(utmctl_bin)" start "$VM_NAME" || true
    tries=0
    until ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$HOST" 'exit 0' 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -le 60 ] || { echo "VM did not come back" >&2; return 1; }
        sleep 5
    done
    sleep 20 # the /it scheduled tasks need a logged-in console session
    echo "== VM back =="  >&2
}

LEGS_DIR="$(mktemp -d)"
cleanup() {
    kill_guests
    rm -rf "$LEGS_DIR"
}
trap cleanup EXIT
kill_guests

# Skip-unchanged deploy: the scp+javac block cost ~20s per run and
# usually ships IDENTICAL bytes (measured 2026-07-22). The stamp is
# the content hash of everything the deploy ships; the VM holds the
# stamp of its last successful deploy, and a match skips the whole
# block. All-or-nothing on purpose: the cs/python/java trees are
# recreated from scratch on every real deploy, and a per-file diff
# would reintroduce the stale-mix class those recreations kill. The
# kaya.dll remote-hash verify below runs EITHER WAY — the stamp
# optimizes shipping, never the verification (a wiped or hand-edited
# VM fails the verify, and deleting C:\kaya\deploy.stamp forces a
# full ship).
deploy_stamp() {
    {
        # THIS SCRIPT is part of the stamp: the shipped bytes are not the
        # whole deploy — the remote javac/dotnet command lines live here,
        # and a flag change with unchanged sources would otherwise reuse
        # stale classes (caught 2026-07-24: adding `javac -encoding
        # UTF-8` fixed nothing until the stamp was cleared by hand).
        shasum -a 256 "$0" \
            "${SCENE_EXES[@]}" \
            "$TARGET/kaya.dll" \
            "$BOOTSTRAP" \
            "${SCENE_PYS[@]}" \
            "$ROOT/go.mod" \
            "$ROOT/crates/kaya/include/kaya.h" \
            "$ROOT"/tools/guest/*.cmd \
            "$ROOT"/tools/guest/*.vbs \
            "$ROOT/tools/guest/minimal-resources.pri" \
            "$ROOT/tools/guest/shot.ps1" \
            "$ROOT/tools/guest/desk-warm.ps1" \
            "$ROOT"/bindings/go/*.go \
            "$ROOT"/guests/csharp/*.cs "$ROOT/guests/csharp/kaya-guests.csproj" \
            "$ROOT"/bindings/csharp/*.cs \
            "$ROOT"/bindings/java/dev/kaya/*.java \
            "$ROOT/bindings/java-desktop/dev/kaya/KayaRing.java" \
            "$ROOT"/guests/java/dev/kaya/milestone2kt/*.java \
            "$ROOT/guests/java-desktop/dev/kaya/milestone2kt/Main.java"
        find "$ROOT/bindings/python/kaya" -type f -print0 | sort -z | xargs -0 shasum -a 256
    } | shasum -a 256 | cut -c1-16
}
STAMP=$(deploy_stamp)
REMOTE_STAMP=$(run_ssh 'cmd /c type C:\kaya\deploy.stamp' 2>/dev/null | tr -d '\r\n ' || true)
if [ "$REMOTE_STAMP" = "$STAMP" ]; then
    echo "== deploy unchanged (stamp $STAMP) =="
else
    echo "== deploying artifacts =="
    scp -q \
        "${SCENE_EXES[@]}" \
        "$TARGET/kaya.dll" \
        "$BOOTSTRAP" \
        "${SCENE_PYS[@]}" \
        "$ROOT/go.mod" \
        "$ROOT/crates/kaya/include/kaya.h" \
        "$ROOT"/tools/guest/*.cmd \
        "$ROOT"/tools/guest/*.vbs \
        "$ROOT/tools/guest/minimal-resources.pri" \
        "$ROOT/tools/guest/shot.ps1" \
        "$ROOT/tools/guest/desk-warm.ps1" \
        "$HOST:C:/kaya/" || {
        # WHAT TO DO NEXT, because scp's own message ("dest open ...:
        # Failure") names neither the cause nor the fix. A copy of
        # kaya.dll fails for exactly one reason in practice: a guest
        # from an earlier run is still alive and holding it. Aborted
        # deploys are the usual source — killing this script leaves the
        # wscript shims and their guests orphaned on the VM.
        #
        # set -e already stops here, which is the important part: the
        # alternative is a lane that runs every leg against the PREVIOUS
        # dll and reports green for code that was never deployed.
        echo "deploy-win: could not overwrite the deployed artifacts." >&2
        echo "  A guest process from an earlier run is almost certainly still" >&2
        echo "  holding C:\\kaya\\kaya.dll. Check with:" >&2
        echo "    ssh $HOST 'tasklist | findstr /i \"wscript exe\"'" >&2
        echo "  and clear it with:" >&2
        echo "    ssh $HOST 'cmd /c \"taskkill /f /im wscript.exe & exit /b 0\"'" >&2
        echo "  A process tasklist shows but taskkill cannot kill is wedged;" >&2
        echo "  reboot the VM (ssh $HOST 'shutdown /r /t 0') and re-run." >&2
        exit 1
    }
    # Recreated from scratch every deploy: dotnet run picks up whatever
    # sources and project files are in the directory, so a leftover from a
    # renamed or removed example would poison the build.
    run_ssh 'cmd /c "if exist C:\kaya\cs rmdir /s /q C:\kaya\cs & mkdir C:\kaya\cs"'
    # Recreated from scratch every deploy: a stale flat-module layout
    # (kaya_app.py) beside the kaya/ package would be a second import
    # mechanism.
    run_ssh 'cmd /c "if exist C:\kaya\bindings\python rmdir /s /q C:\kaya\bindings\python & mkdir C:\kaya\bindings\python"'
    scp -q -r "$ROOT"/bindings/python/kaya "$HOST:C:/kaya/bindings/python/"
    scp -q "$ROOT"/bindings/go/*.go "$HOST:C:/kaya/bindings/go/"
    scp -q "$ROOT"/guests/csharp/*.cs "$ROOT/guests/csharp/kaya-guests.csproj" \
        "$ROOT"/bindings/csharp/*.cs \
        "$HOST:C:/kaya/cs/"
    # Built ONCE here (the javac precedent below); the legs run
    # `dotnet exec` on the produced dll. When every leg ran `dotnet
    # run`, four-wide suites raced the shared obj/bin and VBCSCompiler
    # held kaya-guests.dll against a concurrent rebuild (CS2012,
    # observed 2026-07-22).
    run_ssh 'cmd /c "cd /d C:\kaya\cs && dotnet build -v q --nologo"' || {
        echo "dotnet build failed on the VM" >&2
        exit 1
    }
    # Second output for the pri-adjacency legs: the apphost exe with
    # resources.pri beside it (ms-appx resolves against the PROCESS
    # exe's directory). Also built once here — the five pri legs used
    # to each build into the SAME cs-out and raced.
    run_ssh 'cmd /c "cd /d C:\kaya\cs && dotnet build -v q --nologo -o C:\kaya\cs-out && copy /y C:\kaya\resources.pri C:\kaya\cs-out\resources.pri >nul"' || {
        echo "dotnet build (cs-out) failed on the VM" >&2
        exit 1
    }
    # The java guests: sources shipped flat (every basename is unique and
    # javac takes explicit files, so package-dir layout is classpath
    # business, not source business) and compiled IN PLACE — the C#
    # precedent: the suite builds what it verifies. Recreated from
    # scratch every deploy; a javac failure fails the deploy loudly.
    # Quote-free on purpose: Windows sshd re-wraps the command in its
    # own cmd /c "...", and interior double quotes re-pair across the
    # line (docs/traps.md). mkdir creates parents with extensions on.
    run_ssh 'cmd /c if exist C:\kaya\java rmdir /s /q C:\kaya\java'
    run_ssh 'cmd /c mkdir C:\kaya\java\src'
    scp -q "$ROOT"/bindings/java/dev/kaya/*.java \
        "$ROOT/bindings/java-desktop/dev/kaya/KayaRing.java" \
        "$ROOT"/guests/java/dev/kaya/milestone2kt/*.java \
        "$ROOT/guests/java-desktop/dev/kaya/milestone2kt/Main.java" \
        "$HOST:C:/kaya/java/src/"
    run_ssh 'cmd /c javac -encoding UTF-8 -d C:\kaya\java\classes C:\kaya\java\src\*.java' || {
        echo "javac failed on the VM" >&2
        exit 1
    }
    run_ssh "cmd /c echo $STAMP>C:\\kaya\\deploy.stamp"
fi

# What landed must be what was built: Windows keeps loaded DLLs locked,
# so an overwrite can fail while everything else copies fine, and the
# suites would then run against the previous deploy.
# One Get-FileHash round trip for the whole set (each individual
# round trip cost ~1.4s; ten of them were most of the deploy phase
# once shipping went stamp-skipped, 2026-07-22). Order is the
# contract: the remote list and the local list are compared
# line-by-line.
verify_deployed() {
    local locals=(
        "$TARGET/kaya.dll"
        "$TARGET/examples/milestone2.exe"
        "$TARGET/examples/entry.exe"
        "$TARGET/examples/gallery.exe"
        "$TARGET/examples/todos.exe"
        "$TARGET/examples/reorder.exe"
        "$TARGET/examples/feed.exe"
        "$TARGET/examples/grow.exe"
        "$TARGET/examples/align.exe"
        "$TARGET/examples/layout.exe"
    )
    local remotes='C:\kaya\kaya.dll,C:\kaya\milestone2.exe,C:\kaya\entry.exe,C:\kaya\gallery.exe,C:\kaya\todos.exe,C:\kaya\reorder.exe,C:\kaya\feed.exe,C:\kaya\grow.exe,C:\kaya\align.exe,C:\kaya\layout.exe'
    local got want i line
    got=$(run_ssh "powershell -Command \"(Get-FileHash $remotes -Algorithm SHA256).Hash\"" \
        | tr -d '\r' | tr '[:upper:]' '[:lower:]')
    local got_lines=()
    while IFS= read -r line; do
        [ -n "$line" ] && got_lines+=("$line")
    done <<<"$got"
    if [ "${#got_lines[@]}" != "${#locals[@]}" ]; then
        echo "remote hash count ${#got_lines[@]} != ${#locals[@]} — deploy verification failed" >&2
        exit 1
    fi
    i=0
    for local_path in "${locals[@]}"; do
        want=$(shasum -a 256 "$local_path" | cut -d' ' -f1 | tr '[:upper:]' '[:lower:]')
        if [ "${got_lines[$i]}" != "$want" ]; then
            echo "remote hash mismatch for $local_path after deploy" >&2
            exit 1
        fi
        i=$((i + 1))
    done
}
verify_deployed
timing deploy

# Recording mode (KAYA_RECORD=1): a WGC capturer (tools/guest/
# record-win, built on the VM) films kaya windows for the whole run,
# saving frames named by VM-clock epoch ms. GDI-family capture shows
# WinUI's DirectComposition content as blank; WGC reads the compositor
# and is window-scoped, so nothing else on the desktop enters the
# film. Anchoring never crosses machines: frame names and harness
# epochs share the VM clock. Per-leg films are assembled host-side
# from each leg's frame range, so extraction reuses harness-extract
# unchanged.
rec_suite_start() {
    [ -n "${KAYA_RECORD:-}" ] || return 0
    command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null \
        || { echo "recording mode needs ffmpeg/ffprobe — run inside nix develop"; exit 1; }
    "$ROOT/tools/harness-extract.sh" --selftest || exit 1
    # Build the capturer on the VM, once per source version (the
    # marker carries the content hash).
    local rw_hash
    rw_hash=$(cat "$ROOT/tools/guest/record-win/Program.cs" \
        "$ROOT/tools/guest/record-win/record-win.csproj" | shasum | cut -c1-12)
    run_ssh 'cmd /c if not exist C:\kaya\record-win mkdir C:\kaya\record-win' || true
    scp -q "$ROOT/tools/guest/record-win/Program.cs" \
        "$ROOT/tools/guest/record-win/record-win.csproj" "$HOST:C:/kaya/record-win/"
    if ! run_ssh "cmd /c dir C:\\kaya\\record-win\\.built-$rw_hash >nul 2>nul"; then
        echo "== building record-win on the VM =="
        run_ssh 'cmd /c "cd /d C:\kaya\record-win && dotnet build -c Release -v q"' \
            || { echo "recording: record-win build failed on the VM"; exit 1; }
        run_ssh "cmd /c del C:\\kaya\\record-win\\.built-* 2>nul & cmd /c echo built > C:\\kaya\\record-win\\.built-$rw_hash" || true
    fi
    # The guest display must never sleep: a slept display stops DWM
    # composition and every window is GENUINELY white on screen — the
    # stills pass the count guard while showing nothing. The fix
    # (powercfg monitor-timeout 0) lives in VM state, so assert it
    # here rather than remember it.
    if ! run_ssh 'powercfg /q SCHEME_CURRENT SUB_VIDEO VIDEOIDLE' 2>/dev/null \
        | grep -q 'AC Power Setting Index: 0x00000000'; then
        echo "recording: the VM display can sleep, which blanks every window."
        echo "run on the VM:  powercfg /change monitor-timeout-ac 0"
        exit 1
    fi
    # A recorder left over from an aborted run would fight this one.
    run_ssh 'cmd /c "taskkill /f /im record-win.exe 2>nul & exit /b 0"' || true
    run_ssh 'cmd /c "if exist C:\kaya\frames rmdir /s /q C:\kaya\frames & mkdir C:\kaya\frames"' || true
    run_ssh "schtasks /create /tn kaya_record /tr \"wscript C:\\kaya\\run-hidden.vbs record.cmd\" /sc once /st 00:00 /it /rl highest /f >nul && schtasks /run /tn kaya_record >nul"
    # Hold the suites until the capturer is up; per-window capture
    # attaches in well under the scenes' opening settle.
    local tries=0
    until run_ssh 'type C:\kaya\out_record.txt 2>nul' 2>/dev/null \
        | grep -q RECORDER_READY; do
        tries=$((tries + 1))
        if [ "$tries" -gt 60 ]; then
            echo "recording: record-win never came up:" >&2
            run_ssh 'type C:\kaya\out_record.txt' >&2 || true
            exit 1
        fi
        sleep 1
    done
}

rec_suite_stop() {
    [ -n "${KAYA_RECORD:-}" ] || return 0
    # The stop file is the recorder's own shutdown protocol; the
    # taskkill is the bound on it never noticing.
    run_ssh 'cmd /c echo stop > C:\kaya\frames\stop' || true
    sleep 3
    run_ssh 'cmd /c "taskkill /f /im record-win.exe 2>nul & exit /b 0"' || true
    local recdir="$ROOT/target/recordings/windows"
    rm -rf "$recdir"
    mkdir -p "$recdir"
    # Plain tar: the VM's bsdtar would write real zip for a .zip name
    # (-a), which the host's GNU tar refuses to read.
    run_ssh 'cmd /c "cd /d C:\kaya && tar -c -f frames.tar frames"' \
        || { echo "recording: could not pack frames"; return 1; }
    scp -q "$HOST:C:/kaya/frames.tar" "$recdir/" \
        || { echo "recording: could not pull frames"; return 1; }
    (cd "$recdir" && tar -xf frames.tar && rm frames.tar)
    local count
    count=$(find "$recdir/frames" -name '*.png' | wc -l | tr -d ' ')
    if [ "$count" = 0 ]; then
        echo "recording: the capturer produced no frames"
        run_ssh 'type C:\kaya\out_record.txt' || true
        return 1
    fi
    # Per leg: transcript from the VM, then a film assembled from the
    # leg's own frame range (concat with real inter-frame durations),
    # anchored at its first frame's epoch. Same window per leg, so
    # frame sizes agree within each film.
    local name failed=0
    local pids=()
    for name in "${SUITES_RUN[@]}"; do
        local dir="$recdir/$name"
        mkdir -p "$dir"
        run_ssh "type C:\\kaya\\out_$name.txt" | tr -d '\r' >"$dir/leg.log" 2>/dev/null
        (
            epoch=$(grep -m1 -o 'KAYA_HARNESS: epoch [0-9]*' "$dir/leg.log" | grep -o '[0-9]*$')
            last_off=$(grep -o 'KAYA_HARNESS: +[0-9]*ms' "$dir/leg.log" \
                | grep -o '[0-9]*' | sort -n | tail -1)
            if [ -z "$epoch" ]; then
                echo "$name: no harness epoch in transcript"
                exit 1
            fi
            slot=$(cat "$LEGS_DIR/$name.slot" 2>/dev/null || echo 0)
            echo "$slot" >"$dir/slot"
            lo=$((epoch - 1500))
            hi=$((epoch + last_off + 2000))
            find "$recdir/frames" -name "${slot}-*.png" \
                | KAYA_LO="$lo" KAYA_HI="$hi" python3 -c '
import os, pathlib, sys
# Frame files are <slot>-<epoch-ms>.png; keep the ones inside the legs
# window, sorted by time.
lo, hi = int(os.environ["KAYA_LO"]), int(os.environ["KAYA_HI"])
stamps = []
for line in sys.stdin:
    stem = pathlib.Path(line.strip()).stem
    ts = stem.rsplit("-", 1)[-1]
    if ts.isdigit() and lo <= int(ts) <= hi:
        stamps.append(int(ts))
print("\n".join(str(t) for t in sorted(stamps)))' >"$dir/frames.txt"
            if [ ! -s "$dir/frames.txt" ]; then
                echo "$name: no frames overlap the leg's transcript"
                exit 1
            fi
            anchor=$(head -1 "$dir/frames.txt")
            KAYA_FRAMES="$recdir/frames" KAYA_SLOT="$slot" python3 -c '
import os, sys
# ffconcat: each frame held until the next one is due, the last for a
# fixed beat so the tail is not dropped.
frames, slot = os.environ["KAYA_FRAMES"], os.environ["KAYA_SLOT"]
stamps = [int(x) for x in open(sys.argv[1]).read().split()]
out = []
for prev, cur in zip(stamps, stamps[1:]):
    out.append("file %s/%s-%d.png" % (frames, slot, prev))
    out.append("duration %s" % ((cur - prev) / 1000))
if stamps:
    out.append("file %s/%s-%d.png" % (frames, slot, stamps[-1]))
    out.append("duration 0.2")
print("\n".join(out))' "$dir/frames.txt" >"$dir/concat.txt"
            # Tiled windows have odd content sizes; h264 wants even.
            ffmpeg -nostdin -loglevel error -f concat -safe 0 -i "$dir/concat.txt" \
                -fps_mode vfr -vf "pad=ceil(iw/2)*2:ceil(ih/2)*2" \
                -pix_fmt yuv420p -c:v libx264 -preset ultrafast \
                -y "$dir/video.mkv"
            "$ROOT/tools/harness-extract.sh" "$dir/video.mkv" "$dir/leg.log" \
                "$anchor" "$dir/steps"
        ) >"$dir/extract.log" 2>&1 || : >"$dir/extract-failed" &
        pids+=($!)
    done
    [ ${#pids[@]} -eq 0 ] || wait "${pids[@]}" 2>/dev/null || true
    for name in "${SUITES_RUN[@]}"; do
        cat "$recdir/$name/extract.log" 2>/dev/null
        [ ! -e "$recdir/$name/extract-failed" ] || failed=1
    done
    [ "$failed" = 0 ] || { echo "recording: extraction failures above"; return 1; }
}
SUITES_RUN=()

# Run a shipped one-shot guest script via schtasks and print the file
# it writes once its done-marker appears.
run_guest_oneshot() {
    local script="$1" outfile="$2" marker="$3"
    run_ssh "schtasks /create /tn kaya_oneshot /tr C:\\kaya\\$script /sc once /st 00:00 /it /rl highest /f >nul && schtasks /run /tn kaya_oneshot >nul"
    local tries=0
    until run_ssh "type C:\\kaya\\$outfile" 2>/dev/null | grep -q "$marker"; do
        tries=$((tries + 1))
        if [ "$tries" -gt 60 ]; then
            echo "$script: no $marker after 60 polls" >&2
            return 1
        fi
        sleep 2
    done
    run_ssh "type C:\\kaya\\$outfile"
}

# Start <exe> with no selftest via the shipped probe.cmd and report
# whether it survives scene construction — the first question when a
# suite exits with a stowed exception and no output.
run_probe() {
    # probe=<exe> or probe=<exe>,<selftest-script>
    local exe="${1%%,*}" script=""
    case "$1" in *,*) script="${1#*,}" ;; esac
    run_ssh "del C:\\kaya\\out_probe.txt 2>nul & schtasks /create /tn kaya_probe /tr \"C:\\kaya\\probe.cmd $exe $script\" /sc once /st 00:00 /it /rl highest /f >nul && schtasks /run /tn kaya_probe >nul"
    local tries=0
    until run_ssh "type C:\\kaya\\out_probe.txt" 2>/dev/null | grep -q "PROBEDONE"; do
        tries=$((tries + 1))
        if [ "$tries" -gt 60 ]; then
            echo "probe: no PROBEDONE after 60 polls" >&2
            return 1
        fi
        sleep 2
    done
    run_ssh "type C:\\kaya\\out_probe.txt"
}

# Suites run in a pool KAYA_WIN_JOBS wide (default 4): each leg claims
# a tile slot, launches its scheduled task through the hidden-window
# shim with the slot argument (windows tile; titles carry the slot for
# the recorder), and polls its own output file. Verdicts print in
# submission order at drain. Note: a timed-out leg's kill_guests sweep
# is VM-wide and takes concurrent legs with it — acceptable, since a
# hung guest already means the run has failed.
WIDTH="${KAYA_WIN_JOBS:-4}"
leg_names=()
leg_pids=()

run_one_suite() {
    local name="$1" slot="$2"
    # A LANE THAT DECLARED ITS VM DEAD STAYS DEAD. The unreachable
    # diagnosis below used to return from ONE leg while the lane walked
    # every remaining leg into its own 300-try timeout — 96 minutes of
    # burning after the lane had already printed "this lane is over"
    # (measured 2026-08-03, the first clipboard matrix). A diagnosis
    # the code does not act on is the same class as a guard nobody
    # runs.
    if [ -f "$LEGS_DIR/.vm-dead" ]; then
        echo "$name: skipped — the VM was declared unreachable earlier in this lane" >&2
        return 1
    fi
    run_ssh "del C:\\kaya\\out_$name.txt 2>nul & schtasks /create /tn kaya_$name /tr \"wscript C:\\kaya\\run-hidden.vbs run_$name.cmd $slot\" /sc once /st 00:00 /it /rl highest /f >nul && schtasks /run /tn kaya_$name >nul"
    local tries=0
    until run_ssh "type C:\\kaya\\out_$name.txt" 2>/dev/null | grep -q "EXIT="; do
        tries=$((tries + 1))
        if [ "$tries" -gt 300 ]; then
            # A guest that never writes EXIT= is hung: kill it so it
            # cannot hold kaya.dll into the next suite or deploy, and
            # fail this leg loudly.
            echo "$name: timed out waiting for output; killing guests" >&2
            # IS THE VM EVEN ALIVE? The startup check runs ONCE, so an
            # OS hang mid-lane is invisible: every remaining leg waits
            # out its own 300s in silence while UTM still reports
            # "started". Measured 2026-07-25 — a 14-minute stall with
            # zero verdicts and no guests in tasklist, because the guest
            # OS had died, not the guests. The wedge fingerprint below
            # cannot see this either: it needs ssh to ask.
            #
            # Checked FIRST, because "the VM is gone" makes every other
            # diagnosis wrong.
            if ! ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$HOST" 'exit 0' 2>/dev/null; then
                echo "$name: THE VM IS UNREACHABLE mid-lane — the guest OS hung," \
                    "not the guests (utmctl will still say \"started\"; that is the" \
                    "documented class in docs/traps.md). This lane is over; every" \
                    "remaining leg fails fast against the .vm-dead flag instead of" \
                    "burning its own timeout. Most likely cause is host contention:" \
                    "the windows lane is reliable standalone and degrades under the" \
                    "full five-lane matrix." >&2
                touch "$LEGS_DIR/.vm-dead"
                return 1
            fi
            kill_guests
            # A plain timeout is recoverable; the WEDGED state is not,
            # and taskkill cannot tell you which you have. Fingerprint
            # it, because otherwise EVERY remaining leg pays this same
            # 300s (110 legs of that is the hours-long silent stall this
            # guard exists to stop, measured 2026-07-25). Restart once
            # per run: if the wedge recurs after a restart it is not
            # this class and must not be papered over.
            if guests_wedged; then
                if mkdir "$LEGS_DIR/.vm-restarted" 2>/dev/null; then
                    echo "$name: guests are WEDGED (tasklist lists them, taskkill reports no running instance) — the documented unkillable-terminating-state class; taskkill cannot clear it, restarting the VM" >&2
                    vm_restart || true
                else
                    echo "$name: guests WEDGED AGAIN after a VM restart — not the known transient class; investigate rather than retrying" >&2
                fi
            fi
            return 1
        fi
        sleep 1
    done
    local out
    out=$(run_ssh "type C:\\kaya\\out_$name.txt")
    printf '%s\n' "$out"
    # The suite's verdict lives in the output file, not in any ssh exit
    # code; a failure that isn't parsed here would read as green.
    #
    # The verdict TEXT is the authority and the exit code only
    # corroborates it. EXIT=0 alone was not enough: WinUI's window-Closed
    # handler used to overwrite a failing run's exit code with 0 (Exit()
    # closes the window, the handler fires, last writer won), so a scene
    # that printed FAILED still exited 0 and the leg reported PASS. Any
    # future way of losing the code is caught here regardless of cause.
    if grep -q "KAYA_SELFTEST: FAILED" <<<"$out"; then
        return 1
    fi
    grep -q "EXIT=0" <<<"$out"
}

run_suite() {
    local name="$1"
    SUITES_RUN+=("$name")
    leg_names+=("$name")
    (
        local slot=
        local i
        while [ -z "$slot" ]; do
            i=0
            while [ "$i" -lt "$WIDTH" ]; do
                if mkdir "$LEGS_DIR/.slot-$i" 2>/dev/null; then
                    slot=$i
                    break
                fi
                i=$((i + 1))
            done
            [ -n "$slot" ] || sleep 0.2
        done
        echo "$slot" >"$LEGS_DIR/$name.slot"
        # Per-leg wall time rides the verdict (the bottleneck-hunt
        # instrumentation, uniform across runners).
        local t0=$SECONDS
        local verdict=FAIL
        if run_one_suite "$name" "$slot"; then
            verdict=PASS
        fi
        echo $((SECONDS - t0)) >"$LEGS_DIR/$name.secs"
        rmdir "$LEGS_DIR/.slot-$slot" 2>/dev/null
        echo "$verdict" >"$LEGS_DIR/$name.verdict"
    ) >"$LEGS_DIR/$name.log" 2>&1 &
    leg_pids+=($!)
    while [ "$(jobs -rp | wc -l)" -ge "$WIDTH" ]; do
        wait -n || true
    done
}

drain_suites() {
    if [ ${#leg_pids[@]} -gt 0 ]; then
        wait "${leg_pids[@]}" 2>/dev/null || true
    fi
    leg_pids=()
    local name verdict
    for name in "${leg_names[@]}"; do
        verdict=$(cat "$LEGS_DIR/$name.verdict" 2>/dev/null || echo FAIL)
        echo "== $name =="
        cat "$LEGS_DIR/$name.log" 2>/dev/null
        [ "$verdict" = PASS ] || status=1
        echo "$name: $verdict ($(cat "$LEGS_DIR/$name.secs" 2>/dev/null || echo '?')s)"
    done
    leg_names=()
}

# WILL THIS DESKTOP HAND A WINDOW THE FOREGROUND? Asked once, here,
# before any leg — because ten legs per lane bet on the answer and
# nothing on this side of the ssh connection can see it.
#
# Every chord-injecting leg (menus_*, commands_*) raises the guest
# window and confirms it before pressing anything. When the desktop
# refuses, each dies 3s later with "could not foreground the guest
# window for shortcut injection", which reads as a WinUI bug and is not
# one; the rest of the lane passes, because nothing else needs the
# foreground. That happened on 2026-08-04 after a VM restart, cost a
# lane, and was cleared by a reboot — a remedy that lived in a human's
# head.
#
# THE STATE IS INVISIBLE FROM SSH. An ssh session has its own window
# station (`query session` marks it `>services`, session 0): it cannot
# see the input desktop, and a toast has no title to list. So the
# question is asked from where the legs ask it, an interactive
# scheduled task, and answered the way they answer it — a real window
# and a real SetForegroundWindow, ESC and ALT taps included
# (tools/guest/desk-warm.ps1 carries the measurements; docs/traps.md
# carries the class).
#
# Cheap (~3s) because it runs every lane, and LOUD when it fails: a
# warm-up that silently did not work would only move the confusion
# later.
desk_warm() {
    local out="" verdict="" tries=0
    run_ssh "del C:\\kaya\\out_deskwarm.txt 2>nul & schtasks /create /tn kaya_deskwarm /tr \"wscript C:\\kaya\\run-hidden.vbs desk-warm.cmd\" /sc once /st 00:00 /it /rl highest /f >nul && schtasks /run /tn kaya_deskwarm >nul"
    while :; do
        out=$(run_ssh 'cmd /c type C:\kaya\out_deskwarm.txt' 2>/dev/null | tr -d '\r' || true)
        case "$out" in *DESKWARMEXIT=*) break ;; esac
        tries=$((tries + 1))
        if [ "$tries" -gt 80 ]; then
            echo "deploy-win: the desktop warm-up never answered." >&2
            echo "  It runs as an interactive scheduled task, which needs a LOGGED-IN" >&2
            echo "  console session — 'query session' showing console/Active. If nothing" >&2
            echo "  is signed in at the VM's console window, no leg can run either:" >&2
            echo "  sign in through UTM, or restart the VM, and re-run." >&2
            echo "  What it had written so far:" >&2
            printf '%s\n' "$out" >&2
            return 1
        fi
        sleep 0.5
    done
    verdict=$(printf '%s\n' "$out" | grep -o 'deskwarm\.verdict=[A-Z]*' | cut -d= -f2 | head -1)
    if [ "$verdict" = OK ]; then
        # One line on the happy path, carrying what it had to get past:
        # a Start menu left open on the VM shows up here as the holder.
        echo "== desktop warm ($(printf '%s\n' "$out" | grep -E 'deskwarm\.(tries|ms|before)=' | tr '\n' ' ')) =="
        return 0
    fi
    echo "deploy-win: THE GUEST DESKTOP WILL NOT HAND OVER THE FOREGROUND." >&2
    printf '%s\n' "$out" | grep '^deskwarm\.' >&2
    case "$(printf '%s\n' "$out" | grep -o 'deskwarm\.reason=[a-z]*' | cut -d= -f2 | head -1)" in
        inputdesktop)
            echo "  The console session is LOCKED, or a secure desktop (a UAC prompt) is" >&2
            echo "  up: input goes to a different desktop than the one the legs' windows" >&2
            echo "  live on. Injected keys land there too, so the backend's ESC and ALT" >&2
            echo "  are delivered somewhere else and every menus_*/commands_* leg would" >&2
            echo "  fail after 3s. Nothing over ssh can clear it — an ssh session cannot" >&2
            echo "  reach the interactive desktop at all." >&2
            echo "  Sign in at the VM's console window in UTM, or restart the VM:" >&2
            echo "    $(utmctl_bin) stop --kill \"$VM_NAME\" && $(utmctl_bin) start \"$VM_NAME\"" >&2
            echo "  (the guest signs itself back in), then re-run." >&2
            ;;
        foreground)
            echo "  A window is holding the foreground through both remedies the backend" >&2
            echo "  tries — the ESC that dismisses a menu and the bare ALT that releases a" >&2
            echo "  foreground lock. A notification toast is the usual one and has no" >&2
            echo "  title, so the class and owning process above are the identification" >&2
            echo "  (docs/traps.md: a shell toast holds the foreground)." >&2
            echo "  Look at it — the picture ends the search in two minutes:" >&2
            echo "    ssh $HOST 'schtasks /create /tn kaya_shot /tr \"wscript C:\\kaya\\run-hidden.vbs shot.cmd\" /sc once /st 00:00 /it /rl highest /f && schtasks /run /tn kaya_shot'" >&2
            echo "    scp $HOST:C:/kaya/shot.png ." >&2
            echo "  Dismiss it, or restart the VM, then re-run." >&2
            ;;
        *)
            echo "  The warm-up answered without a verdict this script understands." >&2
            ;;
    esac
    return 1
}
# The diagnostic verbs are exempt: they exist to interrogate a VM that
# is already sick, and a warm-up refusing to start one of them would
# take away the tool you reach for when this fails.
case "$SUITE" in
    probe=*|enable-dumps|crash-report|analyze-dump) ;;
    *) desk_warm || exit 1 ;;
esac
timing desk-warm

status=0
rec_suite_start
case "$SUITE" in
    all)
        run_suite rust
        run_suite python
        run_suite go
        run_suite csharp
        run_suite java
        run_suite entry_rust
        run_suite entry_python
        run_suite entry_go
        run_suite entry_csharp
        run_suite entry_java
        run_suite gallery_rust
        run_suite gallery_python
        run_suite gallery_go
        run_suite gallery_csharp
        run_suite gallery_java
        run_suite todos_rust
        run_suite todos_python
        run_suite todos_go
        run_suite todos_csharp
        run_suite todos_java
        run_suite reorder_rust
        run_suite reorder_python
        run_suite reorder_go
        run_suite reorder_csharp
        run_suite reorder_java
        run_suite feed_rust
        run_suite feed_python
        run_suite feed_go
        run_suite feed_csharp
        run_suite feed_java
        # The grow scene (the layout contract, asserted as shares and
        # root-fills) and the layout observation scene, every language
        # this platform runs.
        run_suite grow_rust
        run_suite grow_python
        run_suite grow_go
        run_suite grow_csharp
        run_suite grow_java
        # The align scene (the cross-axis contract: center + baseline),
        # every language this platform runs.
        run_suite align_rust
        run_suite align_python
        run_suite align_go
        run_suite align_csharp
        run_suite align_java
        # The window scene: the primary surface's props — title
        # materialized, the advisory 640x400 honored.
        run_suite window_rust
        run_suite window_python
        run_suite window_go
        run_suite window_csharp
        run_suite window_java
        # The panels scene: the auxiliary-window grammar (rust depth;
        # the language sweep rides the next slice of the phase).
        run_suite panels_rust
        run_suite panels_python
        run_suite panels_go
        run_suite panels_csharp
        run_suite panels_java
        # The confirm scene: the modal-alert grammar (ContentDialog),
        # all three answer paths through the REAL press (automation
        # peer Invoke; Hide for the cancel slot).
        # The stall diagnostic (crates/kaya/src/stall.rs): the one
        # scene that deliberately blocks the app thread, asserting that
        # kaya REPORTS it. EVERY LANGUAGE THIS LANE CARRIES, because
        # the misuse it guards is available in all of them; the
        # watchdog itself is core-side and needs no WinUI arm.
        run_suite stall_rust
        run_suite stall_python
        run_suite stall_go
        run_suite stall_csharp
        run_suite stall_java
        run_suite confirm_rust
        run_suite confirm_python
        run_suite confirm_go
        run_suite confirm_csharp
        run_suite confirm_java
        # The nav scene: the serial navigation grammar — the wrapper
        # Grid's back bar is this backend's back affordance, driven
        # through the REAL automation-peer press; intercept_back
        # answers with pop_entry.
        run_suite nav_rust
        run_suite nav_python
        run_suite nav_go
        run_suite nav_csharp
        run_suite nav_java
        # (The depth scenes' legs are not here: they run drained, in
        # their own block below.)
        # The scroll scene: the viewport's contract through
        # ScrollViewer — ChangeView is the real scrolling API.
        run_suite scroll_rust
        run_suite scroll_python
        run_suite scroll_go
        run_suite scroll_csharp
        run_suite scroll_java
        # The progress scene: fraction + activity mode read back from
        # ProgressBar (IsIndeterminate is the platform's own flag).
        # ProgressBar is the first control whose template REQUIRES the
        # XamlControlsResources merge, and ms-appx resolves against
        # the PROCESS exe's directory — so every leg arranges kaya's
        # minimal resources.pri beside its host exe (go builds into
        # C:\kaya like rust; C# runs its apphost with the pri copied
        # beside it; python/java get the pri beside their
        # interpreters, idempotent and inert elsewhere). See
        # docs/traps.md (the pri-adjacency rule).
        run_suite progress_rust
        run_suite progress_python
        run_suite progress_go
        run_suite progress_csharp
        run_suite progress_java
        # The a11y scene: every widget kind's role and NAME read back
        # off the REAL UIA peer — the tree Narrator walks — so the
        # wrap-native bet's central claim is a matrix fact here too.
        run_suite a11y_rust
        run_suite a11y_python
        run_suite a11y_go
        run_suite a11y_csharp
        run_suite a11y_java
        # The select scene: ComboBox — same XamlControlsResources
        # dependency as ProgressBar, so the legs reuse the
        # pri-adjacency arrangement above.
        run_suite select_rust
        run_suite select_python
        run_suite select_go
        run_suite select_csharp
        run_suite select_java
        # The radio scene: RadioButtons — same XamlControlsResources
        # dependency class, same pri-adjacency arrangement.
        run_suite radio_rust
        run_suite radio_python
        run_suite radio_go
        run_suite radio_csharp
        run_suite radio_java
        # The grid scene: WinUI Grid with Auto tracks + the spacer's
        # grow sugar.
        run_suite grid_rust
        run_suite grid_python
        run_suite grid_go
        run_suite grid_csharp
        run_suite grid_java
        # The textarea scene: AcceptsReturn TextBox, entry contract
        # multi-line (the swallow counters ride along).
        run_suite textarea_rust
        run_suite textarea_python
        run_suite textarea_go
        run_suite textarea_csharp
        run_suite textarea_java
        # The sections scene: NavigationView — the presentation
        # context (echo doctrine both ways + retention).
        run_suite sections_rust
        run_suite sections_python
        run_suite sections_go
        run_suite sections_csharp
        run_suite sections_java
        run_suite layout_rust
        run_suite layout_python
        run_suite layout_go
        run_suite layout_csharp
        run_suite layout_java
        # Depth scenes: rust-only, one leg each, from their CHECKED-IN
        # launchers (tools/guest/run_<scene>_rust.cmd, shipped by the
        # deploy glob). Run BEFORE the menu block's foreground-sensitive
        # legs, and drained around, since an accessibility read
        # foregrounds nothing but a scene may.
        #
        # NAMED ONE BY ONE rather than looped over $DEPTH_SCENES, which
        # is what this block used to do while generating each .cmd on
        # the fly. Two gates make the generator unreachable: check-steps
        # requires a LITERAL `run_suite <scene>_` here (a loop over a
        # variable is invisible to it) and then requires that leg's
        # launcher to be checked in. So every depth scene had both, and
        # the loop ran each of them a SECOND time — split_rust ran twice
        # per full matrix from the day it was wired until now.
        # The background scene: work off the app thread, posted back.
        # Its worker parks until a click releases it, so a binding that
        # ran background work ON the app thread cannot deliver its own
        # release and this leg TIMES OUT rather than failing an
        # assertion. The deadlock IS the gate
        # (docs/background-work-plan.md §5) — read a timeout here as
        # that, not as VM load, before blaming the lane.
        # The filedialog scene: the Shell's own dialog, driven for
        # real over UI Automation, in every language this lane carries.
        # SERIAL, BETWEEN DRAINS, like the menus legs and for a sibling
        # reason. A file dialog is OS-GLOBAL chrome: it is modal, it
        # must hold the FOREGROUND to be driven, and the harness finds
        # it by searching the desktop. Two of them up at once on one
        # desktop means one is in the background with its presses
        # swallowed — and BOTH legs fail, which reads as a backend bug
        # rather than a scheduling one. Measured 2026-07-31: the rust
        # leg had been green for weeks and started failing the moment a
        # python leg joined it in the four-wide pool, with two dialogs
        # visible on the VM at once.
        drain_suites
        run_suite filedialog_rust
        drain_suites
        run_suite filedialog_python
        drain_suites
        run_suite filedialog_go
        drain_suites
        run_suite filedialog_csharp
        drain_suites
        run_suite filedialog_java
        drain_suites
        run_suite background_rust
        run_suite background_python
        run_suite background_go
        run_suite background_csharp
        run_suite background_java
        drain_suites
        # The split scene: adaptive list-detail through TwoPaneView,
        # with resize_window driving the real size-class transition.
        # Every language this lane runs.
        #
        # TwoPaneView is a pri-adjacency control, like ProgressBar
        # below: its template needs the XamlControlsResources merge,
        # and ms-appx resolves against the PROCESS exe's directory. So
        # the go and csharp launchers here take the progress shape (go
        # builds into C:\kaya, csharp runs the cs-out apphost) rather
        # than the plain one. Measured 2026-07-27: with the plain
        # launchers both crashed at the first expect_split with
        # 0xc000027b, a stowed XAML exception, while rust/python/java —
        # which already have the pri beside their hosts — passed.
        # Both blocks build the same split_go.exe, which is safe
        # because drain_suites separates them.
        run_suite split_rust
        run_suite split_python
        run_suite split_go
        run_suite split_csharp
        run_suite split_java
        drain_suites
        # The listdetail scene: THE SAME GUESTS, asserting list-detail's
        # bare invariant at whatever width this VM's window manager
        # gives. One app, two scripts — a scene selects a SCRIPT, never
        # an app, so each launcher here runs the split guest under the
        # other name. Shared verbatim with the phone lanes, where it is
        # the only list-detail coverage there is.
        run_suite listdetail_rust
        run_suite listdetail_python
        run_suite listdetail_go
        run_suite listdetail_csharp
        run_suite listdetail_java
        drain_suites
        # The undo scene: two tiers behind one Edit>Undo, and the
        # ledger that orders them (docs/undo-plan.md). A DEPTH SCENE —
        # rust only until the `undoable` sweep lands the other eight
        # guests — and it belongs in THIS serial block rather than the
        # depth block above, for the menus reason exactly: its `type`
        # verb puts REAL KEYSTROKES on the system input queue and
        # foregrounds the guest to do it, so a concurrent leg's
        # SetForegroundWindow would take the typing. Two legs typing at
        # one desktop do not fail cleanly — the characters go to
        # whichever window won, and the scene reads it as a backend
        # that dropped input.
        #
        # NOT PINNED BY check-steps' menu_serial CLAUSE, which matches
        # `run_suite (menus|filedialog)_` by name: that pattern must
        # grow an `undo` arm, or a future refactor can re-pool this leg
        # with nothing to say so. Named in the arm's report as the one
        # gate this slice could not extend itself (tools/check-steps.sh
        # belongs to no single arm).
        run_suite undo_rust
        drain_suites
        # The menus scene — every language, each leg ALONE between
        # drains, never in the pool above. WinUI shortcut injection is
        # OS-global (docs/traps.md): the harness foregrounds the guest
        # and puts the real chord on the system input queue, so a
        # concurrent leg's SetForegroundWindow would steal it.
        # check-steps pins the drain/run/drain barrier on each one.
        run_suite menus_rust
        drain_suites
        run_suite menus_python
        drain_suites
        run_suite menus_go
        drain_suites
        run_suite menus_csharp
        drain_suites
        run_suite menus_java
        drain_suites
        # The commands scene joins the same serial block: its chords ride
        # the same OS-global injection.
        run_suite commands_rust
        drain_suites
        run_suite commands_python
        drain_suites
        run_suite commands_go
        drain_suites
        run_suite commands_csharp
        drain_suites
        run_suite commands_java
        drain_suites
        # The clipboard scene: one clip in several representations, the
        # privileged read, the paste split, and Paste as a standard
        # command. THE LEGS ARE MUTUALLY EXCLUSIVE, ONE DRAIN EACH
        # (docs/clipboard-plan.md §0d, the 2026-08-02 correction): there
        # is one system clipboard per session, and legs writing it
        # concurrently are processes assigning one variable — measured
        # on mac, six of eight failed concurrently and the same eight
        # passed serially. NOT the menus reason: menu_activate here
        # drives the real invoke pipeline, no chord is injected — the
        # same barrier, a different cause. check-steps pins the
        # drain/run/drain shape on each leg.
        run_suite clipboard_rust
        drain_suites
        run_suite clipboard_python
        drain_suites
        run_suite clipboard_go
        drain_suites
        run_suite clipboard_csharp
        drain_suites
        run_suite clipboard_java
        drain_suites
        ;;
    probe=*) run_probe "${SUITE#probe=}" || status=1 ;;
    enable-dumps) run_guest_oneshot enable-dumps.cmd out_enable_dumps.txt "EXIT=" || status=1 ;;
    crash-report) run_guest_oneshot crash-report.cmd out_crash_report.txt "REPORTDONE" || status=1 ;;
    analyze-dump) run_guest_oneshot analyze-dump.cmd out_analyze.txt "ANALYZEDONE" || status=1 ;;
    *) run_suite "$SUITE" ;;
esac
drain_suites
timing suites
rec_suite_stop || status=1
[ -z "${KAYA_RECORD:-}" ] || timing recording-pull+stills
exit "$status"
