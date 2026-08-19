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
# Usage: tools/deploy-win.sh user@host [--provision] [rust|python|go|csharp|java|all]
#        tools/deploy-win.sh user@host <scene>_<lang>  # ONE leg, e.g. menus_java
#        tools/deploy-win.sh user@host probe=<exe>   # aliveness probe, e.g. probe=entry
#
# The <scene>_<lang> family is the parser's real surface (the arms at
# :72-126, which the clause below holds level with the `all` case's
# run_suite calls). Every leg this script runs can be run alone —
# rust/python/go/csharp/java for the breadth scenes, plus the depth
# slices' rust-only legs and editor_go. Not enumerated here on purpose:
# a second hand-written list of the same thing is the drift this file
# already had once.
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
        # Likewise, until the `dirty` window prop has a sugar spelling in
        # the other seven bindings (docs/dirty-plan.md §2's fan-out).
        dirty_rust) SUITE="$arg" ;;
        # Likewise, until the three range verbs and `set_text` have a
        # sugar spelling in the other seven bindings
        # (docs/ranges-plan.md §2's fan-out).
        ranges_rust) SUITE="$arg" ;;
        # Likewise, until `save_file` has a sugar spelling in the other
        # seven bindings (docs/save-plan.md §2's fan-out).
        save_rust) SUITE="$arg" ;;
        # THE TEXT EDITOR is Go and only Go, by design rather than by
        # sequencing: an editor in Rust would be kaya testing itself
        # (docs/editor-plan.md). There is no editor_rust to add later.
        editor_go) SUITE="$arg" ;;
        # These two were wired as legs without arms here, so a single
        # leg could not be re-run in isolation — the one-leg-repeatedly
        # loop is the only practical way to characterise a rare flake.
        background_rust|background_python|background_go|background_csharp|background_java) SUITE="$arg" ;;
        stall_rust|stall_python|stall_go|stall_csharp|stall_java) SUITE="$arg" ;;
        a11yrows_rust|a11yrows_python|a11yrows_go|a11yrows_csharp|a11yrows_java) SUITE="$arg" ;;
        styling_rust|styling_python|styling_go|styling_csharp|styling_java) SUITE="$arg" ;;
        typeface_rust|typeface_python|typeface_go|typeface_csharp|typeface_java) SUITE="$arg" ;;
        toolbar_rust|toolbar_python|toolbar_go|toolbar_csharp|toolbar_java) SUITE="$arg" ;;
        identity_rust|identity_python|identity_go|identity_csharp|identity_java) SUITE="$arg" ;;
        assets_rust|assets_python|assets_go|assets_csharp|assets_java) SUITE="$arg" ;;
        probe=*) SUITE="$arg" ;;
        # PHASES, not legs: they run inside `all` and are named here so
        # each can be re-run on its own while fixing what it found.
        caption-centre) SUITE="$arg" ;;
        enable-dumps|crash-report|analyze-dump) SUITE="$arg" ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# EVERY LEG THIS SCRIPT RUNS CAN BE RUN ON ITS OWN, and that is checked
# here rather than remembered. The arms above and the `run_suite` calls
# in the `all` case are two hand-written lists of one thing; when they
# drift, the missing half is discovered by someone who needs a SINGLE
# leg — mid-debugging, with a five-lane matrix behind them, being told
# "unknown argument" by the script that just ran that very leg. The
# three families this caught the day it landed (a11yrows_*, styling_*,
# typeface_*) had been wired for a milestone each; the file already
# carried the same regret in prose above background_*/stall_*.
if ! python3 - "$0" <<'PY'
import pathlib
import re
import sys


def audit(text):
    """Suite names `run_suite` runs that no case arm accepts."""
    run = re.findall(r"(?m)^\s*run_suite (\w+)$", text)
    arms = set()
    for m in re.finditer(r"(?m)^\s*([\w|=*-]+)\) SUITE=", text):
        arms.update(m.group(1).split("|"))
    # `all` is the arm that runs them; a name it reaches needs an arm of
    # its own to be reachable alone.
    return sorted({name for name in run if name not in arms})


def audit_phases(text):
    """PHASES the `all` case runs that no other arm of that case runs.

    A phase is not a leg — it is a shell function, called as
    `name || status=1` — so the leg audit above cannot see it. It carries
    exactly the same regret: `caption_centre_probe` drives a window sweep
    that takes a minute, and a phase you can only reach by running the
    whole lane is a phase nobody re-runs while fixing what it found.
    """
    body = text.split("\n    all)\n", 1)
    if len(body) != 2:
        sys.exit("deploy-win: the `all` case arm could not be located, so the "
                 "phase census read nothing and would agree with anything.")
    inside = body[1].split("\n        ;;\n", 1)[0]
    in_all = set(re.findall(r"(?m)^\s+(\w+) \|\| status=1$", inside))
    alone = set(re.findall(r"(?m)^\s*[\w|=*-]+\) (\w+) \|\| status=1 ;;$", text))
    return sorted(in_all - alone)


# THE SELF-TEST FIRST: a checker that cannot see the drift it exists for
# reports OK on every tree, including the one this fixed.
#
# The fixtures are COMPOSED rather than written out, and that is not
# style: tools/check-steps.sh greps this file for `run_suite <name>` to
# pair every leg with its launcher, and a fixture spelled in full is a
# leg it would go looking for a run_x_rust.cmd for. Caught by that gate
# the day this landed — two guards reading one file, which is the point
# of both.
call = "run_suite"
drifted = f'x_rust) SUITE="$arg" ;;\n    all)\n        {call} x_rust\n        {call} y_go\n'
if audit(drifted) != ["y_go"]:
    sys.exit("deploy-win: SELF-TEST FAIL (a leg with no arm of its own was not seen)")
if audit(f'y_go|x_rust) SUITE="$arg" ;;\n    {call} y_go\n    {call} x_rust\n'):
    sys.exit("deploy-win: SELF-TEST FAIL (an arm'd leg was reported as unreachable)")
fixture = ("\n    all)\n        only_in_all || status=1\n        both || status=1\n"
           "        ;;\n    x) both || status=1 ;;\n")
if audit_phases(fixture) != ["only_in_all"]:
    sys.exit("deploy-win: SELF-TEST FAIL (a phase reachable only from `all` was not seen; "
             f"the census answered {audit_phases(fixture)})")

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
stranded = audit_phases(text)
if stranded:
    sys.exit(
        "deploy-win: these phases run in the `all` case and are called from "
        f"nowhere else, so none can be re-run alone: {', '.join(stranded)}. "
        "Give each an arm in BOTH case statements — one in `case \"$arg\"` "
        "naming the verb, one in `case \"$SUITE\"` calling the function — "
        "the way caption-centre/caption_centre_probe does."
    )
missing = audit(text)
if missing:
    sys.exit(
        "deploy-win: these legs run in the `all` case but no argument arm "
        f"accepts them, so none can be re-run alone: {', '.join(missing)}. "
        "Add each to the `case \"$arg\"` list above (one line per scene "
        "family) — the one-leg-repeatedly loop is how a flake gets "
        "characterised, and it is unavailable exactly when it is needed."
    )
PY
then
    exit 1
fi

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
SCENES="background stall milestone2 entry gallery todos reorder feed grow layout align window panels confirm nav split scroll progress select radio grid textarea sections menus commands a11y a11yrows filedialog clipboard undo dirty ranges save styling typeface toolbar identity assets"
# Depth-slice scenes: a rust example + steps exist, the language sweep
# has not landed yet. Built, shipped and run RUST-ONLY, so a backend can
# be validated before nine guests exist — the deploy-win twin of
# validate-mac's DEPTH_SCENES. Without it a new scene must either join
# SCENES (whose per-language surfaces glob for a11y.py, a11y.go, ... and
# fail loudly, correctly) or go unexercised on this lane entirely, which
# is how the WinUI accessibility read ended up committed unproven.
#
# EMPTY TODAY, and that is the list working rather than the list being
# unused: `save` graduated when its eighth guest landed and `identity`
# did the same on 2026-08-18 — the day check-sugar-surface's `identity`
# row went green — exactly as filedialog had. The variable stays because
# the next depth slice needs it on its first day, and because
# KAYA_WIN_DEPTH_SCENES is how one is driven before it graduates.
DEPTH_SCENES="${KAYA_WIN_DEPTH_SCENES:-}"
# GO-ONLY SCENES: a guest that exists in Go and only Go BY DESIGN rather
# than by sequencing — an editor written in Rust would be kaya testing
# itself (docs/editor-plan.md), so there is no editor_rust to add later.
# Such a scene can join neither list above: SCENES' per-language surfaces
# glob for editor.py / editor.cs / editor.java and would fail loudly and
# correctly, and DEPTH_SCENES builds and ships a RUST example.
#
# What it must still join is the TASKKILL SWEEP, which is the one
# mechanical surface that does not care what language a guest is in: a
# leg that aborts leaves editor_go.exe holding kaya.dll, and the next
# deploy's copy then fails under `set -e` — or worse, a fresh suite runs
# beside the zombie. The editor's first three runs on this lane all ended
# in an abort, which is exactly when the sweep is the only thing between
# a failed leg and a failed LANE.
GO_ONLY_SCENES="editor"

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

# ONE CAPTION WRITER, enforced before anything is built.
#
# Windows publishes no document-modified affordance at any layer
# (scratchpad/dirty-probe-windows.md §2: all 28 App SDK .winmd scanned,
# UIA's WindowPattern checked, nothing), so on this platform the `dirty`
# prop lowers to TEXT — a leading `*` composed into the rendered caption.
# The probe costed that up front: the caption is already a composition
# of the window's own title and a covering nav entry's, and a text
# marker becomes a third input that EVERY caption write has to apply or
# the mark blinks out on a push, a pop, or a split-mode change. There
# were five such writes.
#
# So the backend has one: `refresh_caption`, which derives the whole
# caption from state. This refuses a sixth. It is a text check because
# the type system cannot help — `Window::SetTitle` is a WinRT projection
# method and is always callable — and it lives HERE, in the deploy every
# Windows change goes through, rather than in a gate list somebody has
# to remember: a caption write that bypasses the composition is a
# Windows-lane defect and this is the Windows lane's door. The kaya.h
# export check below is the same idea one layer down.
if ! python3 - "$ROOT/crates/kaya/src/winui/mod.rs" <<'PY'
import pathlib, re, sys

# A caption write is `<recv>.SetTitle(` in the WinUI backend. Two
# receivers are NOT window captions and never were: a menu bar item's
# label and a ContentDialog's title.
NOT_A_CAPTION = {"bar_item", "dialog"}
CALL = re.compile(r"(\w+)\.SetTitle\(")
# ANY indent, so a method inside an impl block resets the tracker too —
# a column-0-only match would let a `SetTitle` in the Stage impl inherit
# the sanction of whatever free function was declared above it.
HEADER = re.compile(r"\s*(?:pub(?:\(\w+\))?\s+)?(?:unsafe\s+)?fn\s")
# The two sanctioned window-caption writes, each identified by the
# function it sits in rather than by its line number.
WRITER = "fn refresh_caption("
PLACEHOLDER = "fn setup("


def audit(text):
    """Offending caption writes as (line-number, receiver) pairs."""
    fn, bad = "", []
    for n, line in enumerate(text.splitlines(), 1):
        if HEADER.match(line):
            fn = line.strip()
        for m in CALL.finditer(line):
            recv = m.group(1)
            if recv in NOT_A_CAPTION:
                continue
            if WRITER in fn or PLACEHOLDER in fn:
                continue
            bad.append((n, recv))
    return bad


# THE SELF-TEST RUNS FIRST, because a checker that cannot see a bypass
# reports OK on every tree including a broken one. Both directions: a
# bypass is caught, and the sanctioned shapes are not.
bypass = 'fn refresh_nav() {\n    target.SetTitle(&HSTRING::from(t));\n}\n'
# ...and the one the column-0 matcher used to miss: an indented method
# BELOW the sanctioned writer, which inherited its sanction.
indented = ('fn refresh_caption() {\n    target.SetTitle(&x);\n}\n'
            'impl Stage {\n    fn other(&self) {\n'
            '        target.SetTitle(&x);\n    }\n}\n')
clean = ('fn refresh_caption() {\n    target.SetTitle(&x);\n}\n'
         'fn setup() {\n    window.SetTitle(&y);\n}\n'
         'fn build_menu() {\n    bar_item.SetTitle(&z);\n}\n')
if audit(bypass) != [(2, "target")]:
    sys.exit("deploy-win: SELF-TEST FAIL (a bypassing SetTitle was not seen)")
if audit(indented) != [(6, "target")]:
    sys.exit("deploy-win: SELF-TEST FAIL (an indented method inherited the "
             "caption writer's sanction)")
if audit(clean):
    sys.exit("deploy-win: SELF-TEST FAIL (a sanctioned SetTitle was refused: "
             f"{audit(clean)})")

path = pathlib.Path(sys.argv[1])
text = path.read_text()
if WRITER not in text:
    sys.exit(f"deploy-win: {path} has no `{WRITER}` — the WinUI dirty "
             f"lowering composes its marker there, and without it every "
             f"caption write is a bypass")
found = audit(text)
if found:
    where = ", ".join(f"line {n} (`{r}.SetTitle`)" for n, r in found)
    sys.exit(f"deploy-win: {path} writes a window caption outside "
             f"refresh_caption: {where}. Call `refresh_caption(core, "
             f"window)` instead — it composes the dirty marker (a leading "
             f"`*`, the measured Notepad convention) into whichever title "
             f"the window should be showing. A raw SetTitle drops the mark "
             f"the next time that path runs (docs/dirty-plan.md D2).")
PY
then
    exit 1
fi

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

# THE ASSET ROOT, AS A UNIT. The typeface scene hands the backend the
# vendored font's BYTES and the identity scene the mark's, so a guest
# that cannot open them cannot run those scenes at all; and `asset(name)`
# resolves both through ONE root, which the core finds by
# KAYA_ASSET_DIR (docs/assets-plan.md A2, A5.2).
#
# THE ROOT AND NOT THE FILES, which is the single change from what this
# block used to do. It shipped `fonts/*.ttf` by glob and one
# manifest-named icon — two staging paragraphs for two assets, and a
# third asset would have been a third. `scp -r` of the root is one
# paragraph for every asset there will ever be, and a file that fails to
# arrive fails the hash below rather than one scene on one lane.
#
# SHIPPED EVERY RUN, OUTSIDE THE DEPLOY STAMP, exactly like the .steps
# above: an asset edit that a stamp skip swallows is the same defect as
# a scene edit that never arrives.
#
# INTO THE REPO-MIRROR PATH. C:\kaya is already the repo root as far as
# the guests are concerned — go.mod ships to C:\kaya and guests/go to
# C:\kaya\guests\go below — so the root lands at C:\kaya\guests\assets
# and anything run from C:\kaya would resolve it by the relative default
# anyway. KAYA_ASSET_DIR is set absolutely all the same, machine-wide
# beside KAYA_SCENES_DIR above, because the C# leg's cwd is C:\kaya\cs
# where a relative default would miss, and one spelling for every leg
# beats four that work by cwd and one that does not.
run_ssh 'cmd /c "if exist C:\kaya\guests\assets rmdir /s /q C:\kaya\guests\assets"'
run_ssh 'cmd /c if not exist C:\kaya\guests mkdir C:\kaya\guests'
scp -q -r "$ROOT/guests/assets" "$HOST:C:/kaya/guests/"
run_ssh 'setx KAYA_ASSET_DIR C:\kaya\guests\assets >nul'

# AND THE INDEX GOES BESIDE THE EXE, from the copy that just arrived
# rather than from a second scp of its own. Every kaya host on Windows
# needs an MRT resources.pri in the PROCESS executable's directory or
# the XAML parser fail-fasts at 0xC000027B (docs/traps.md); the index is
# an asset like any other and now travels with the root, so this is a
# rename on the VM and not a staging decision.
run_ssh 'cmd /c copy /y C:\kaya\guests\assets\win\minimal-resources.pri C:\kaya\resources.pri >nul' || {
    echo "deploy-win: could not place C:\\kaya\\resources.pri — every WinUI host" >&2
    echo "  needs an MRT index beside its exe or the XAML parser fail-fasts at" >&2
    echo "  0xC000027B (docs/traps.md)" >&2
    exit 1
}

# WHAT ARRIVED IS WHAT WAS SENT, BY HASH AND NOT BY SIZE. A size check
# passes a same-length corruption, and a half-written scp over a
# previous run's file is exactly that (docs/assets-plan.md A5.1 asks for
# the change in these words). One round trip: PowerShell hashes the
# whole staged tree, python holds it against this one.
staged="$(run_ssh 'powershell -NoProfile -Command "Get-ChildItem -Recurse -File C:\kaya\guests\assets | ForEach-Object { (Get-FileHash $_.FullName -Algorithm SHA256).Hash + \" \" + $_.FullName }"' 2>&1 | tr -d '\r')"
staged_rc=$?
if [ "$staged_rc" -ne 0 ]; then
    echo "deploy-win: could not hash the staged asset root on the VM: $staged" >&2
    exit 1
fi
staged_list="$(mktemp)"
printf '%s\n' "$staged" >"$staged_list"
python3 - "$ROOT/guests/assets" "$staged_list" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
there = {}
PREFIX = "c:\\kaya\\guests\\assets\\"
for line in pathlib.Path(sys.argv[2]).read_text().splitlines():
    line = line.strip()
    if " " not in line:
        continue
    digest, full = line.split(" ", 1)
    if len(digest) != 64:
        continue
    # The VM answers in its own spelling; the tree speaks `/`. One
    # normalisation, here, so neither side has to know about the other.
    low = full.strip().lower()
    if not low.startswith(PREFIX):
        continue
    there[full.strip()[len(PREFIX):].replace("\\", "/")] = digest.lower()
here = {}
for f in sorted(root.rglob("*")):
    if f.is_file():
        here[f.relative_to(root).as_posix()] = hashlib.sha256(f.read_bytes()).hexdigest()
bad = []
for name, digest in sorted(here.items()):
    got = there.get(name)
    if got is None:
        bad.append(f"  {name}: never arrived on the VM")
    elif got != digest:
        bad.append(f"  {name}: arrived as {got[:12]}, the tree has {digest[:12]}")
for name in sorted(set(there) - set(here)):
    bad.append(f"  {name}: is on the VM and not in the tree — a stale asset a "
               "guest can still resolve by name")
if bad:
    print("deploy-win: the staged asset root does not match the tree:",
          file=sys.stderr)
    print("\n".join(bad), file=sys.stderr)
    sys.exit(1)
print(f"assets: {len(here)} files staged to C:\\kaya\\guests\\assets, "
       "every one hash-equal to the tree")
PY
assets_rc=$?
rm -f "$staged_list"
if [ "$assets_rc" -ne 0 ]; then
    exit 1
fi


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

# WIPED AND RECREATED, NOT COPIED OVER, which is the cs and python
# dirs' rule below and now this one's. scp writes the files it is given
# and DELETES NOTHING, so a source file that leaves the repo lives on
# in C:\kaya forever — and Go compiles a directory, not a file list, so
# one leftover is a compile error in a package that is correct in the
# tree. MEASURED 2026-08-07 on the live VM: after the scene-library
# split moved todo_kaya.go out of guests/go/todos, the VM's stale copy
# made the build fail with `guests\go\todos\todo_kaya.go: undefined:
# Todo` — a message that names a file the repo no longer has there.
#
# ONE RECURSIVE COPY OF THE WHOLE GO TREE, not a loop over SCENES. The
# guests are ONE PROGRAM now: guests/go/cmd is the only main package,
# it imports all 31 scene libraries, and every .cmd launcher builds
# `dev.kaya/guests/go/cmd`. So a leg needs every scene present, not the
# one it names — a per-scene loop would ship exactly the scenes this
# lane runs and fail on the rest with "no required module provides
# package dev.kaya/guests/go/<scene>". A scene added later needs no
# edit here at all. 204 KB, 38 files.
run_ssh 'cmd /c "if exist C:\kaya\guests\go rmdir /s /q C:\kaya\guests\go & mkdir C:\kaya\guests\go"'
scp -q -r "$ROOT"/guests/go/* "$HOST:C:/kaya/guests/go/"

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
    kill_list=$(for s in $SCENES $DEPTH_SCENES $GO_ONLY_SCENES; do printf 'taskkill /f /im %s.exe 2>nul & taskkill /f /im %s_go.exe 2>nul & ' "$s" "$s"; done)
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

# THE CORE'S UNIT TESTS, EXECUTED ON WINDOWS — where they never had been.
#
# Rung 1 of the ladder is `cargo test -p kaya`, and it runs on the
# machine you type it on: mac, or linux in the container. The Windows
# half of the core therefore had no unit coverage at all, and the one
# test of the handle-redemption path said so in its own attribute —
# `#[cfg(all(test, unix))]`, docs/save-plan.md D3's third defect. Taking
# the gate off is half the fix: a test no lane runs is a test nobody
# runs. So this phase builds the lib test binary for
# aarch64-pc-windows-msvc, ships it, and runs it on the guest.
#
# WHAT IT REACHES THAT NO OTHER LANE CAN. On Windows the redeemed handle
# is a Win32 HANDLE and not a descriptor, so protocol.rs's `raw_handle`
# and `file_from_raw` take their OTHER arm — code no unix run compiles,
# let alone executes — and a save destination's create-and-truncate goes
# through a different syscall underneath `OpenOptions`. Proven by
# construction on 2026-08-09: breaking the windows arm of `raw_handle`
# alone turned this phase red while `cargo test` on mac stayed green.
#
# THE COUNT COMES OUT OF THE SOURCE. A filter that matches nothing exits
# 0 with "0 passed" — the same shape as the sweep that ran 1 of 24 gates
# and printed a clean run (tools/gates.sh) — so the number of `#[test]`s
# in the module is read from capi.rs and the run must report exactly that
# many passed. Renaming the module fails this phase rather than emptying
# it.
#
# SCOPED TO capi::picked_tests, and the scope is measured rather than
# timid: the whole lib suite on this guest is 309 passed / 3 failed
# today, and all three failures are POSIX assumptions in HARNESS tests
# (`expand_path("$TMPDIR/x")` against a backslash join, twice, and a
# clipboard seed naming `/nope/kaya-missing.txt`) rather than anything
# about Windows in the core. Widening this filter to the whole suite is
# one edit the day those three are fixed, and it is the widening to make.
# ONE MODULE of the core's unit tests, run on the guest with its own
# count rule: the filter selects it, the source file says how many
# `#[test]`s it declares, and the two numbers must agree — a filter that
# matches nothing exits 0 saying "0 passed", which is a green phase that
# ran no code.
guest_unit_module() {
    local file="$1" module="$2" filter="$3" blurb="$4" hint="$5"
    local want out rc passed
    want=$(python3 - "$file" "$module" <<'PY'
import pathlib
import re
import sys

path, module = sys.argv[1], sys.argv[2]
text = pathlib.Path(path).read_text(encoding="utf-8")
m = re.search(rf"(?m)^mod {re.escape(module)} \{{", text)
if not m:
    sys.exit(f"deploy-win: {path} has no `mod {module}` — the module this lane "
             "runs on the guest moved or was renamed, and a filter that matches "
             "nothing would report a clean run")
end = text.index("\n}", m.end())
count = text.count("#[test]", m.end(), end)
if count < 1:
    sys.exit(f"deploy-win: `mod {module}` declares no #[test] at all")
print(count)
PY
    ) || return 1
    rc=0
    out=$(run_ssh "cmd /c \"cd /d C:\\kaya && kaya-unittests.exe $filter --test-threads=1\"" 2>&1) || rc=$?
    echo "$out"
    if [ "$rc" -ne 0 ]; then
        echo "deploy-win: the core's $filter unit tests FAILED on the guest (rc=$rc)." >&2
        echo "  $hint" >&2
        return 1
    fi
    passed=$(printf '%s' "$out" | python3 -c '
import re
import sys

m = re.search(r"(\d+) passed", sys.stdin.read())
print(m.group(1) if m else -1)')
    if [ "$passed" != "$want" ]; then
        echo "deploy-win: the guest ran $passed of the $want tests in" >&2
        echo "  $filter. A filter that selects nothing exits 0 with" >&2
        echo "  \"0 passed\", so the count is what makes this phase mean" >&2
        echo "  something — fix the filter or the module name, do not lower" >&2
        echo "  the count. (The count is every #[test] the module declares;" >&2
        echo "  this phase builds --features harness, so a harness-gated test" >&2
        echo "  counts and runs.)" >&2
        return 1
    fi
    echo "deploy-win: $passed/$want unit tests passed on the guest ($filter — $blurb)"
}

unit_tests_on_windows() {
    echo "== unit tests on the guest (aarch64-pc-windows-msvc) =="
    local exe built json ran
    json="$ROOT/target/win-unit-tests.json"
    built=0
    (cd "$ROOT" && cargo xwin test --locked --features harness --release \
        --target aarch64-pc-windows-msvc -p kaya --lib --no-run \
        --message-format=json >"$json") || built=$?
    if [ "$built" -ne 0 ]; then
        echo "deploy-win: the unit test binary would not build for windows." >&2
        echo "  This is the ONLY thing that compiles crates/kaya's tests for" >&2
        echo "  this target — tools/check-targets.sh checks --lib alone — so a" >&2
        echo "  test that only compiles on unix fails HERE and nowhere else." >&2
        exit 1
    fi
    exe=$(python3 - "$json" <<'PY'
import json
import pathlib
import sys

for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if (m.get("reason") == "compiler-artifact" and m.get("executable")
            and m.get("profile", {}).get("test")):
        print(m["executable"])
        break
else:
    sys.exit("deploy-win: cargo built no test executable — the --no-run build "
             "reported nothing to run")
PY
    ) || exit 1
    rm -f "$json"
    scp -q "$exe" "$HOST:C:/kaya/kaya-unittests.exe"
    ran=0
    # THE HANDLE ARMS, which no unix run compiles.
    guest_unit_module "$ROOT/crates/kaya/src/capi.rs" picked_tests capi::picked_tests \
        "the file-handle redemption, including the WRITE half and a save destination's create-and-truncate" \
        "These are the same tests rung 1 runs on mac; a failure here and not there is Windows-only code — the HANDLE arms of protocol.rs's raw_handle/file_from_raw, or an OpenOptions combination that means something else on this OS." ||
        ran=1
    # THE WINUI BACKEND'S OWN TESTS, which no unix run compiles either —
    # and which nothing ran ANYWHERE until 2026-08-16: they were built by
    # the --no-run above (so they could not rot into non-compiling code)
    # and then filtered out of the only invocation that runs anything.
    # Four of them had never executed. They need this machine because
    # they measure this machine: DirectWrite's system font collection,
    # and a font file written under the app root and read back through
    # its own name table (the typeface blob route, both directions).
    guest_unit_module "$ROOT/crates/kaya/src/winui/mod.rs" tests winui::tests \
        "the brand dictionary's crossed stops, the a11y role ladder, and the typeface blob route read back off its own file" \
        "This is the WinUI backend measured against the real DirectWrite on this guest: a per-app font file written under the app root and read back through its name table, the system font collection's answer for a bare family, and the pure lowerings beside them." ||
        ran=1
    # The binary goes whatever the verdict is: it is a transient of this
    # phase, not a deployed artifact, and one left behind would be the
    # next run's stale exe waiting for a build that failed. Which is why
    # both modules above RETURN rather than exit — a failure that skipped
    # this line would leave that exe on the guest.
    run_ssh 'cmd /c "del C:\kaya\kaya-unittests.exe 2>nul & exit /b 0"' || true
    [ "$ran" -eq 0 ] || exit 1
}
unit_tests_on_windows
timing unit-tests

# THE CAPTION TITLE'S AIM, measured on this guest, on every full lane.
#
# WHY IT IS A LANE PHASE. A promoted window's caption title is aimed at the
# WINDOW's centre (the maintainer's ruling of 2026-08-17, VS Code's rule),
# clamped when a header would collide. NO SCENE CAN SEE THAT: every harness
# read of a window's title goes through the string, and the string is the
# same whether the TextBlock sits on the window's centre line or 63 DIP
# left of it on the leftover slot's. The in-process post-condition inside
# `center_caption_title` catches the aim being WRONG; only an outside
# observer with UIA and the window's visible frame can say by how many
# physical pixels, and say it at widths a scene never drives.
#
# It lived beside the backend as a hand-run script for one milestone
# (crates/kaya/src/winui/title-centre-probe.sh, whose header said so), which
# is the shape this repo calls barely a guard: the session that needs it
# most is the one with no context and it will not think to run it. This is
# that script, on the path a full lane already walks, reusing the driver
# rather than copying its scheduling.
#
# THE COUNT RULES, because a probe that measures nothing reports no drift,
# which reads exactly like reporting no drift because there is none:
#   - the probe declares its plan (AIMPLAN n) before it runs any of it, and
#     exactly n AIMV rows must come back;
#   - at least CAPTION_CENTRE_MIN_CLEAR of those rows must be UNCLAMPED —
#     the toolbar scene's title provably fits at the launch width, after
#     the border drag, and at 1100/900/800/700 — so a run in which every
#     row went clamped (a menu that grew, a window that never widened)
#     cannot satisfy the drift rule vacuously;
#   - every unclamped row's drift must be 0;
#   - and no row may report the title OVERLAPPING a header, at any width.
CAPTION_CENTRE_MIN_CLEAR=6
caption_centre_probe() {
    echo "== the caption title's aim (title-centre-probe, on the guest) =="
    local log rc
    log="$LEGS_DIR/caption-centre.log"
    KAYA_TCP_NO_DEPLOY=1 "$ROOT/crates/kaya/src/winui/title-centre-probe.sh" "$HOST" \
        >"$log" 2>&1
    rc=$?
    cat "$log"
    if [ "$rc" -ne 0 ]; then
        echo "deploy-win: the caption-centre probe did not produce a measurement." >&2
        return 1
    fi
    python3 - "$log" "$CAPTION_CENTRE_MIN_CLEAR" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
want_clear = int(sys.argv[2])
plan = re.search(r"^AIMPLAN (\d+)$", text, re.M)
if not plan:
    sys.exit("deploy-win: the probe printed no AIMPLAN line; there is no plan to "
             "check the rows against, so no number of rows would mean anything.")
want = int(plan.group(1))
rows = re.findall(r"^AIMV (\S+) drift=(\S+) clamped=(true|false) absent=(true|false)$",
                  text, re.M)
if len(rows) != want:
    sys.exit(f"deploy-win: the caption-centre probe planned {want} measurements and "
             f"reported {len(rows)}. A sweep that stopped early reports no drift, "
             "which is the same output as a sweep that found none — fix the probe or "
             "the guest, do not lower the plan.")
floor = re.search(r"^AIMFLOOR (\S+)$", text, re.M)
if not floor:
    sys.exit("deploy-win: the probe printed no AIMFLOOR line, so there is no width at "
             "which a vanished title is allowed and the absence rule below could only "
             "be vacuous.")
stray = [t for t, _d, _c, a in rows if a == "true" and t != floor.group(1)]
if stray:
    sys.exit("deploy-win: the caption title VANISHED at " + ", ".join(stray) +
             f". A title UIA does not publish is only correct at the sweep's narrowest "
             f"width ({floor.group(1)}), where the menu, the commands, the drag strip and "
             "the caption cluster fill the band and collapsing the title is the clamp "
             "taken to its limit. At any wider width it is a title that stopped existing.")
clear = [r for r in rows if r[2] == "false"]
if len(clear) < want_clear:
    sys.exit(f"deploy-win: only {len(clear)} of {len(rows)} caption-centre rows were "
             f"UNCLAMPED and this lane requires {want_clear}. A clamped row's drift is "
             "the rule working, so a run where everything clamped would pass the drift "
             "rule having proved nothing about the aim. Rows: " +
             ", ".join(f"{t}={'clamped' if c == 'true' else d}" for t, d, c, _a in rows))
bad = [(t, d) for t, d, _c, _a in clear if float(d) != 0.0]
if bad:
    sys.exit("deploy-win: the caption title is not on the window's centre at " +
             ", ".join(f"{t} (drift {d})" for t, d in bad) +
             ". DRIFT is the title's centre-x minus the visible frame's centre-x, both "
             "read; a non-zero drift on an UNCLAMPED row means center_caption_title's "
             "bias is not reaching the TextBlock — the historic value is -63, the "
             "leftover slot's own centre.")
overlaps = re.findall(r"^AIM .*THE TITLE OVERLAPS.*$", text, re.M)
if overlaps:
    sys.exit("deploy-win: the caption title crosses a header:\n  " +
             "\n  ".join(overlaps))
print(f"deploy-win: caption title aimed at the window's centre — {len(rows)} widths "
      f"measured, {len(clear)} unclamped, all at DRIFT 0")
PY
}

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
        # FIRST, AND ALONE. The probe drives a real border drag and a
        # width sweep on the one window it can find by class, so it needs
        # the desktop to itself — the same reason the menus legs sit
        # between drains. Nothing has been submitted to the pool yet here.
        caption_centre_probe || status=1
        timing caption-centre
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
        #
        # The dirty scene: unsaved work as window chrome
        # (docs/dirty-plan.md). Rust-only until the sugar sweep gives the
        # other eight guests a `dirty` spelling. On this platform the
        # chrome is TEXT — Windows has no modified affordance at any
        # layer — so `expect_dirty` reads the real OS caption for a
        # leading `*`, which is also why the scene asserts its title only
        # while clean (the two reads share a channel here and nowhere
        # else). Drained around, not for the foreground reason: the leg
        # drives a real WM_CLOSE on its own window, and the veto keeps it
        # — but a window disappearing out from under a pooled leg is the
        # one failure that reads as somebody else's bug.
        drain_suites
        run_suite dirty_rust
        drain_suites
        # The stamped-accessibility scene: two entries stamped from one
        # template, each named by its own row, read from UIA's real
        # tree — the a11y scene's sibling, split out because a For's
        # column shifts ordinal container targets per language.
        # Graduated 2026-08-11 with wave 2's guests; this lane's
        # language roster matches the a11y family's.
        run_suite a11yrows_rust
        run_suite a11yrows_python
        run_suite a11yrows_go
        run_suite a11yrows_csharp
        run_suite a11yrows_java
        # THE STYLING SCENE (docs/styling-plan.md slice 1): brand +
        # roles + inset. On this backend the brand is the six
        # SystemAccentColor* stops in the Light/Dark ThemeDictionaries
        # (never SystemAccentColor itself, the documented no-op),
        # prominent is AccentButtonStyle, destructive the critical
        # brush on the caption, and `heading` is
        # AutomationProperties.HeadingLevel — the UIA read the
        # expect_ax step freezes. Graduated 2026-08-12 when the winui
        # heading arm closed the last depth stub; this lane's language
        # roster matches the a11y family's. Pooled: no typed input, no
        # window close, nothing foreground-sensitive.
        run_suite styling_rust
        run_suite styling_python
        run_suite styling_go
        run_suite styling_csharp
        run_suite styling_java
        # THE TYPEFACE SCENE (docs/styling-plan.md Slice 2b): the brand
        # font's BYTES reach the text system and the FAMILY swaps, while
        # sizes, weights and metrics stay the platform's. It exists
        # because a typeface fails SILENTLY — DirectWrite, like every
        # other font stack, renders a family it does not have in
        # something else — so a typo, a stale lowering and a working swap
        # all look identical to every other observation kaya owns, and
        # only `expect_typeface`, which reads the family the text system
        # actually resolved off the real TextBlocks, can tell them apart
        # (tools/scenes/typeface.steps' header carries the reasoning, and
        # why the font is vendored rather than installed). Pooled with
        # the styling family: no typed input, no window close, nothing
        # foreground-sensitive. The vendored font reaches these guests
        # through the ship near the top of this script and the
        # KAYA_FONT_FILE line in each launcher.
        run_suite typeface_rust
        run_suite typeface_python
        run_suite typeface_go
        run_suite typeface_csharp
        run_suite typeface_java
        # THE TOOLBAR SCENE (docs/chrome-plan.md C2): the window's chrome
        # carries the app's primary actions. On this backend that is a
        # CommandBar in the shell Grid's second Auto row — one
        # AppBarButton per `primary` catalog action, in catalog preorder,
        # with the Fluent icon the menu row already carries — and the
        # scene reads the REAL bar: the promoted names it publishes to
        # UIA, the icon in each button's slot, and IsEnabled on the one
        # button object. The unpromoted catalog stays in the MenuBar one
        # row above, which is why nothing fills SecondaryCommands.
        #
        # Pooled with the styling/typeface family, and it is the same
        # three reasons: no typed input (the scene's `click` is
        # in-process, not an injected keystroke), no window close, and
        # nothing foreground-sensitive — no chord is pressed, unlike the
        # menus and commands legs that assert the same catalog.
        run_suite identity_rust
        run_suite identity_python
        run_suite identity_go
        run_suite identity_csharp
        run_suite identity_java
        run_suite toolbar_rust
        run_suite toolbar_python
        run_suite toolbar_go
        run_suite toolbar_csharp
        run_suite toolbar_java
        # The assets conformance scene (docs/assets-plan.md). THIS LANE
        # IS THE ONE WHERE THE STAGED ROOT IS THE ONLY ROUTE: the VM has
        # no repo of its own, so the deploy copies guests/assets into the
        # repo mirror every run and names it machine-wide in
        # KAYA_ASSET_DIR, and the scene's frozen census is what proves it
        # copied the WHOLE root rather than the file a leg happened to
        # need. Deliberately outside the deploy stamp, so an asset edit
        # cannot be swallowed by a stamp skip.
        #
        # Pooled with the family above for the same three reasons: no
        # typed input, no window close, nothing foreground-sensitive.
        run_suite assets_rust
        run_suite assets_python
        run_suite assets_go
        run_suite assets_csharp
        run_suite assets_java
        drain_suites
        # The ranges scene: HIGHLIGHT a set, SELECT one, REVEAL one
        # (docs/ranges-plan.md D1), plus the two rules that make those
        # three a contract — a user's keystroke DROPS the declared set
        # (D2) and a select_range arriving mid-composition is REFUSED
        # (D4). Rust-only until the sugar sweep gives the other eight
        # guests a spelling.
        #
        # DRAINED AROUND, and for the `type`/`compose` reason rather than
        # the window one: both put real input where the platform sends
        # it. `type` injects OS-GLOBAL keystrokes (the foreground
        # confirmation is what keeps them out of a bystander's window),
        # and `compose` starts a TSF composition in whatever document
        # holds the KEYBOARD FOCUS — so a pooled leg stealing the
        # foreground mid-scene would put a composition in someone else's
        # control and this leg would fail for their reason.
        run_suite ranges_rust
        drain_suites
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
        # The save scene: the round trip an editor walks — open, save
        # back, save as, reopen (docs/save-plan.md D5). Rust-only until
        # the sugar sweep gives the other guests a `save_file` spelling,
        # which is why it sits in DEPTH_SCENES.
        #
        # SERIAL, BETWEEN DRAINS, and it is the filedialog rule rather
        # than a second one: the Shell's save dialog is the same OS-GLOBAL
        # modal chrome, found the same way — `live_dialog` walks the
        # DESKTOP for a visible `#32770` and takes the first. With a
        # picker up beside it, `file_dialog_name` types into whichever the
        # walk reached first and both legs fail, which reads as a backend
        # bug rather than a scheduling one. The same measurement that put
        # the filedialog legs here (2026-07-31) covers this leg; it needs
        # no separate one, because it is the same window class on the same
        # desktop.
        run_suite save_rust
        drain_suites
        # THE TEXT EDITOR — kaya's forcing artifact (docs/editor-plan.md),
        # and the only script on this lane that drives an APP rather than
        # a feature: launch to an empty buffer, type, save-as, open,
        # edit, undo, save, find with a regex, and the unsaved-work
        # warning on close.
        #
        # GO ALONE, and no rust leg is coming: the plan chose Go so that
        # a BINDING's awkward corners would show. `editor` is therefore
        # in neither SCENES nor DEPTH_SCENES — both of those derive a
        # cross-built rust example this app does not have — and the leg
        # runs from its own checked-in launcher, which builds
        # dev.kaya/guests/go/cmd on the VM like every other Go leg.
        #
        # SERIAL, BETWEEN DRAINS, and it needs BOTH of the reasons this
        # file already gives. The Shell's open and save dialogs are
        # OS-GLOBAL modal chrome found by walking the DESKTOP for a
        # visible `#32770`, so a second dialog anywhere takes the typing;
        # and `type` injects OS-global keystrokes, which land wherever
        # the foreground is rather than where this leg is.
        run_suite editor_go
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
    # Standalone, because every gate in this repo is standalone: a phase
    # you can only reach by running the whole lane is a phase nobody
    # re-runs while fixing what it found.
    caption-centre) caption_centre_probe || status=1 ;;
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
