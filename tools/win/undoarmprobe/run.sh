#!/usr/bin/env bash

kaya_flake="$(cd "$(dirname "$0")/../../.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    # TWO CAUSES, TWO SENTENCES; the canonical pair lives in
    # tools/lib/kaya_gate.py's dev_shell_refusal, whose self-test prints
    # both branches.
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# THROWAWAY runner for the WinUI undo-arm probe (docs/undo-plan.md §3a).
# Ships into C:\kaya\undoarmprobe, NEVER into C:\kaya itself: the lane's
# deployed artifacts must not gain a probe hook behind a deploy stamp
# that says they are unchanged.
#
# Usage: run.sh <user@host>
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
HOST="${1:?usage: run.sh <user@host>}"
TARGET="$ROOT/target/aarch64-pc-windows-msvc/release"

cd "$ROOT" || exit 1
cargo xwin build --locked --features harness --release \
    --target aarch64-pc-windows-msvc --lib --example undo >&2
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "undoarmprobe: build failed" >&2
    exit 1
fi

ssh -n -o BatchMode=yes "$HOST" 'cmd /c if not exist C:\kaya\undoarmprobe mkdir C:\kaya\undoarmprobe'
ssh -n -o BatchMode=yes "$HOST" 'cmd /c "taskkill /f /im undo.exe & exit /b 0"' >/dev/null 2>&1
scp -q "$TARGET/examples/undo.exe" "$HOST:C:/kaya/undoarmprobe/undo.exe"
scp -q "$TARGET/kaya.dll" "$HOST:C:/kaya/undoarmprobe/kaya.dll"
ssh -n -o BatchMode=yes "$HOST" \
    'cmd /c "copy /y C:\kaya\Microsoft.WindowsAppRuntime.Bootstrap.dll C:\kaya\undoarmprobe\ >nul && copy /y C:\kaya\resources.pri C:\kaya\undoarmprobe\ >nul"'

# CRLF, because cmd.exe reads a lone LF as part of the command.
printf '@echo off\r\ncd /d C:\\kaya\\undoarmprobe\r\nset KAYA_UNDO_ARM_PROBE=1\r\nundo.exe > C:\\kaya\\undoarmprobe\\out.txt 2>&1\r\necho EXIT=%%ERRORLEVEL%% >> C:\\kaya\\undoarmprobe\\out.txt\r\n' \
    > "$HERE/undoarmprobe.cmd"
scp -q "$HERE/undoarmprobe.cmd" "$HOST:C:/kaya/undoarmprobe/undoarmprobe.cmd"

# The lane's desktop warm-up: this probe injects real keystrokes.
ssh -n -o BatchMode=yes "$HOST" \
    'del C:\kaya\out_deskwarm.txt 2>nul & schtasks /create /tn kaya_deskwarm /tr "wscript C:\kaya\run-hidden.vbs desk-warm.cmd" /sc once /st 00:00 /it /rl highest /f >nul && schtasks /run /tn kaya_deskwarm >nul'
warm=0
until ssh -n -o BatchMode=yes "$HOST" 'cmd /c type C:\kaya\out_deskwarm.txt' 2>/dev/null \
    | grep -q DESKWARMEXIT=; do
    warm=$((warm + 1))
    if [ "$warm" -gt 60 ]; then
        echo "undoarmprobe: the desktop warm-up never answered" >&2
        exit 1
    fi
    sleep 0.5
done

ssh -n -o BatchMode=yes "$HOST" \
    'del C:\kaya\undoarmprobe\out.txt 2>nul & schtasks /create /tn kaya_undoarmprobe /tr "wscript C:\kaya\run-hidden.vbs undoarmprobe\undoarmprobe.cmd" /sc once /st 00:00 /it /rl highest /f >nul && schtasks /run /tn kaya_undoarmprobe >nul'

tries=0
until ssh -n -o BatchMode=yes "$HOST" 'cmd /c type C:\kaya\undoarmprobe\out.txt' 2>/dev/null \
    | grep -q -e PROBEDONE -e 'EXIT='; do
    tries=$((tries + 1))
    if [ "$tries" -gt 60 ]; then
        echo "undoarmprobe: no PROBEDONE after 60 polls" >&2
        ssh -n -o BatchMode=yes "$HOST" 'cmd /c type C:\kaya\undoarmprobe\out.txt' 2>/dev/null || true
        ssh -n -o BatchMode=yes "$HOST" 'cmd /c "taskkill /f /im undo.exe & exit /b 0"' || true
        exit 1
    fi
    sleep 2
done
sleep 1
ssh -n -o BatchMode=yes "$HOST" 'cmd /c type C:\kaya\undoarmprobe\out.txt'
# Belt: the probe exits itself, but nothing of it may survive the run.
ssh -n -o BatchMode=yes "$HOST" 'cmd /c "taskkill /f /im undo.exe & exit /b 0"' >/dev/null 2>&1
ssh -n -o BatchMode=yes "$HOST" 'cmd /c "schtasks /delete /tn kaya_undoarmprobe /f & exit /b 0"' >/dev/null 2>&1
