#!/usr/bin/env bash

kaya_flake="$(cd "$(dirname "$0")/../../.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# Build clipprobe and run it on the Windows VM (see src/main.rs).
# Usage: build.sh <user@host>
#
# ONE INTERACTIVE-SESSION TASK RUNS EVERYTHING: each ssh connection has
# its own window station and therefore its own clipboard (docs/traps.md),
# so neither the seeds nor the reads may run over ssh directly.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOST="${1:?usage: build.sh <user@host>}"

cd "$HERE"
cargo xwin build --locked --release --target aarch64-pc-windows-msvc >&2
EXE="$HERE/target/aarch64-pc-windows-msvc/release/clipprobe.exe"

ssh -n -o BatchMode=yes "$HOST" 'cmd /c if not exist C:\kaya\clipprobe mkdir C:\kaya\clipprobe'
scp -q "$EXE" "$HOST:C:/kaya/clipprobe/clipprobe.exe"
scp -q "$HERE/clipprobe.ps1" "$HOST:C:/kaya/clipprobe/clipprobe.ps1"

# CRLF, because cmd.exe reads a lone LF as part of the command.
printf '@echo off\r\npowershell -NoProfile -ExecutionPolicy Bypass -File C:\\kaya\\clipprobe\\clipprobe.ps1 > C:\\kaya\\out_clipprobe.txt 2>&1\r\n' \
    > "$HERE/clipprobe.cmd"
scp -q "$HERE/clipprobe.cmd" "$HOST:C:/kaya/clipprobe/clipprobe.cmd"

ssh -n -o BatchMode=yes "$HOST" \
    'del C:\kaya\out_clipprobe.txt 2>nul & schtasks /create /tn kaya_clipprobe /tr C:\kaya\clipprobe\clipprobe.cmd /sc once /st 00:00 /it /rl highest /f >nul && schtasks /run /tn kaya_clipprobe >nul'

tries=0
until ssh -n -o BatchMode=yes "$HOST" 'type C:\kaya\out_clipprobe.txt' 2>/dev/null \
    | grep -q PROBEDONE; do
    tries=$((tries + 1))
    if [ "$tries" -gt 40 ]; then
        echo "clipprobe: no PROBEDONE after 40 polls" >&2
        ssh -n -o BatchMode=yes "$HOST" 'type C:\kaya\out_clipprobe.txt' 2>/dev/null || true
        exit 1
    fi
    sleep 2
done
ssh -n -o BatchMode=yes "$HOST" 'type C:\kaya\out_clipprobe.txt'
