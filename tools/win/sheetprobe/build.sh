#!/usr/bin/env bash

# Dev-shell guard; the marker is the flake fingerprint (CLAUDE.md).
kaya_flake="$(cd "$(dirname "$0")/../../.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# THROWAWAY undo probe (docs/sheet-plan.md U1, cells P3-win / P4 / P5).
# Ships into C:\kaya\sheetprobe, NEVER into C:\kaya itself: the lane's
# deployed artifacts must not gain a probe hook behind a deploy stamp
# that says they are unchanged.
#
# Usage: build.sh <user@host>
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
HOST="${1:?usage: build.sh <user@host>}"
TARGET="$ROOT/target/aarch64-pc-windows-msvc/release"

cd "$ROOT"
cargo xwin build --locked --features harness --release \
    --target aarch64-pc-windows-msvc --lib --example sheetprobe >&2
"$ROOT/tools/build-id.py" --verify "$TARGET/kaya.dll" || exit 1

ssh -n -o BatchMode=yes "$HOST" 'cmd /c if not exist C:\kaya\sheetprobe mkdir C:\kaya\sheetprobe'
# A live guest holds kaya.dll and scp then fails unhelpfully.
ssh -n -o BatchMode=yes "$HOST" 'cmd /c "taskkill /f /im sheetprobe.exe & exit /b 0"' >/dev/null 2>&1
scp -q "$TARGET/examples/sheetprobe.exe" "$HOST:C:/kaya/sheetprobe/sheetprobe.exe"
scp -q "$TARGET/kaya.dll" "$HOST:C:/kaya/sheetprobe/kaya.dll"
# Two exe-adjacent prerequisites: the bootstrap DLL is loaded by name,
# and MRT init needs resources.pri beside the exe.
ssh -n -o BatchMode=yes "$HOST" \
    'cmd /c "copy /y C:\kaya\Microsoft.WindowsAppRuntime.Bootstrap.dll C:\kaya\sheetprobe\ >nul && copy /y C:\kaya\resources.pri C:\kaya\sheetprobe\ >nul"'

# CRLF, because cmd.exe reads a lone LF as part of the command.
printf '@echo off\r\ncd /d C:\\kaya\\sheetprobe\r\nset KAYA_SHEET_PROBE=1\r\nsheetprobe.exe > C:\\kaya\\sheetprobe\\out.txt 2>&1\r\necho EXIT=%%ERRORLEVEL%% >> C:\\kaya\\sheetprobe\\out.txt\r\n' \
    > "$HERE/sheetprobe.cmd"
scp -q "$HERE/sheetprobe.cmd" "$HOST:C:/kaya/sheetprobe/sheetprobe.cmd"

ssh -n -o BatchMode=yes "$HOST" \
    'del C:\kaya\sheetprobe\out.txt 2>nul & schtasks /create /tn kaya_sheetprobe /tr "wscript C:\kaya\run-hidden.vbs sheetprobe\sheetprobe.cmd" /sc once /st 00:00 /it /rl highest /f >nul && schtasks /run /tn kaya_sheetprobe >nul'

tries=0
until ssh -n -o BatchMode=yes "$HOST" 'cmd /c type C:\kaya\sheetprobe\out.txt' 2>/dev/null \
    | grep -q -e PROBEDONE -e 'EXIT='; do
    tries=$((tries + 1))
    if [ "$tries" -gt 90 ]; then
        echo "sheetprobe: no PROBEDONE after 90 polls" >&2
        ssh -n -o BatchMode=yes "$HOST" 'cmd /c type C:\kaya\sheetprobe\out.txt' 2>/dev/null || true
        ssh -n -o BatchMode=yes "$HOST" 'cmd /c "taskkill /f /im sheetprobe.exe & exit /b 0"' || true
        exit 1
    fi
    sleep 2
done
sleep 2
ssh -n -o BatchMode=yes "$HOST" 'cmd /c type C:\kaya\sheetprobe\out.txt'
# Belt: nothing of the probe survives the run.
ssh -n -o BatchMode=yes "$HOST" 'cmd /c "taskkill /f /im sheetprobe.exe & exit /b 0"' >/dev/null 2>&1
ssh -n -o BatchMode=yes "$HOST" 'cmd /c "schtasks /delete /tn kaya_sheetprobe /f & exit /b 0"' >/dev/null 2>&1
