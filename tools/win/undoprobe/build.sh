#!/usr/bin/env bash

# Everything runs inside the dev shell: the flake pins every toolchain
# (rust + cross targets, swiftc, ffmpeg, the android sdk). Running
# against anything else is an error, not something to paper over — and
# a shell entered before the flake last changed is just as much a
# bystander toolchain, so the marker carries the fingerprint of
# flake.nix+flake.lock the shell was actually built from.
kaya_flake="$(cd "$(dirname "$0")/../../.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# THROWAWAY undo probe (docs/undo-plan.md §0, cells P3-win / P4 / P5).
# Builds the hooked libkaya + the throwaway guest, ships them into
# C:\kaya\undoprobe (NEVER into C:\kaya itself — the lane's deployed
# artifacts must not gain a probe hook behind a deploy stamp that says
# they are unchanged), and runs one interactive scheduled task.
#
# Usage: build.sh <user@host>
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
HOST="${1:?usage: build.sh <user@host>}"
TARGET="$ROOT/target/aarch64-pc-windows-msvc/release"

cd "$ROOT"
cargo xwin build --locked --features harness --release \
    --target aarch64-pc-windows-msvc --lib --example undoprobe >&2
"$ROOT/tools/build-id.sh" --verify "$TARGET/kaya.dll" || exit 1

ssh -n -o BatchMode=yes "$HOST" 'cmd /c if not exist C:\kaya\undoprobe mkdir C:\kaya\undoprobe'
# Kill anything left from an earlier attempt before the copy: a live
# guest holds kaya.dll and scp fails with an unhelpful message.
ssh -n -o BatchMode=yes "$HOST" 'cmd /c "taskkill /f /im undoprobe.exe & exit /b 0"' >/dev/null 2>&1
scp -q "$TARGET/examples/undoprobe.exe" "$HOST:C:/kaya/undoprobe/undoprobe.exe"
scp -q "$TARGET/kaya.dll" "$HOST:C:/kaya/undoprobe/kaya.dll"
# The runtime's two exe-adjacent prerequisites, copied ON the VM from
# what the lane already deployed (the bootstrap DLL is loaded by name,
# and MRT init needs resources.pri beside the exe).
ssh -n -o BatchMode=yes "$HOST" \
    'cmd /c "copy /y C:\kaya\Microsoft.WindowsAppRuntime.Bootstrap.dll C:\kaya\undoprobe\ >nul && copy /y C:\kaya\resources.pri C:\kaya\undoprobe\ >nul"'

# CRLF, because cmd.exe reads a lone LF as part of the command.
printf '@echo off\r\ncd /d C:\\kaya\\undoprobe\r\nset KAYA_UNDO_PROBE=1\r\nundoprobe.exe > C:\\kaya\\undoprobe\\out.txt 2>&1\r\necho EXIT=%%ERRORLEVEL%% >> C:\\kaya\\undoprobe\\out.txt\r\n' \
    > "$HERE/undoprobe.cmd"
scp -q "$HERE/undoprobe.cmd" "$HOST:C:/kaya/undoprobe/undoprobe.cmd"
scp -q "$HERE/uia.ps1" "$HOST:C:/kaya/undoprobe/uia.ps1"

# The desktop warm-up the lane runs before anything that needs the
# foreground — this probe injects real keystrokes and takes screenshots.
ssh -n -o BatchMode=yes "$HOST" \
    'del C:\kaya\out_deskwarm.txt 2>nul & schtasks /create /tn kaya_deskwarm /tr "wscript C:\kaya\run-hidden.vbs desk-warm.cmd" /sc once /st 00:00 /it /rl highest /f >nul && schtasks /run /tn kaya_deskwarm >nul'
warm=0
until ssh -n -o BatchMode=yes "$HOST" 'cmd /c type C:\kaya\out_deskwarm.txt' 2>/dev/null \
    | grep -q DESKWARMEXIT=; do
    warm=$((warm + 1))
    if [ "$warm" -gt 60 ]; then
        echo "undoprobe: the desktop warm-up never answered" >&2
        exit 1
    fi
    sleep 0.5
done
ssh -n -o BatchMode=yes "$HOST" 'cmd /c type C:\kaya\out_deskwarm.txt' | grep 'deskwarm\.verdict' || true

ssh -n -o BatchMode=yes "$HOST" \
    'del C:\kaya\undoprobe\out.txt 2>nul & del C:\kaya\undoprobe\shot-*.png 2>nul & schtasks /create /tn kaya_undoprobe /tr "wscript C:\kaya\run-hidden.vbs undoprobe\undoprobe.cmd" /sc once /st 00:00 /it /rl highest /f >nul && schtasks /run /tn kaya_undoprobe >nul'

tries=0
until ssh -n -o BatchMode=yes "$HOST" 'cmd /c type C:\kaya\undoprobe\out.txt' 2>/dev/null \
    | grep -q -e PROBEDONE -e 'EXIT='; do
    tries=$((tries + 1))
    if [ "$tries" -gt 90 ]; then
        echo "undoprobe: no PROBEDONE after 90 polls" >&2
        ssh -n -o BatchMode=yes "$HOST" 'cmd /c type C:\kaya\undoprobe\out.txt' 2>/dev/null || true
        ssh -n -o BatchMode=yes "$HOST" 'cmd /c "taskkill /f /im undoprobe.exe & exit /b 0"' || true
        exit 1
    fi
    sleep 2
done
sleep 2
ssh -n -o BatchMode=yes "$HOST" 'cmd /c type C:\kaya\undoprobe\out.txt'
# The probe exits itself; this is the belt, and it also clears the
# scheduled task so nothing of the probe survives the run.
ssh -n -o BatchMode=yes "$HOST" 'cmd /c "taskkill /f /im undoprobe.exe & exit /b 0"' >/dev/null 2>&1
ssh -n -o BatchMode=yes "$HOST" 'cmd /c "schtasks /delete /tn kaya_undoprobe /f & exit /b 0"' >/dev/null 2>&1
