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
# Build dialogprobe and run it on the Windows VM. See src/main.rs for
# what it measures.
#
# THE INTERACTIVE SESSION IS NOT OPTIONAL: the probe shows a real Shell
# dialog, and a task without /it runs in session 0 where no window
# manager will ever create one. This is the same schtasks shape
# deploy-win.sh's run_oneshot uses, kept here rather than shared
# because a probe must not be able to change the lane's runner.
#
# Usage: build.sh <user@host>
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOST="${1:?usage: build.sh <user@host>}"

cd "$HERE"
cargo xwin build --locked --release --target aarch64-pc-windows-msvc >&2
EXE="$HERE/target/aarch64-pc-windows-msvc/release/dialogprobe.exe"

ssh -n -o BatchMode=yes "$HOST" 'cmd /c if not exist C:\kaya mkdir C:\kaya'
scp -q "$EXE" "$HOST:C:/kaya/dialogprobe.exe"
# CRLF, because cmd.exe reads a lone LF as part of the command.
printf '@echo off\r\nC:\\kaya\\dialogprobe.exe %%1 > C:\\kaya\\out_dialogprobe.txt 2>&1\r\n' \
    > "$HERE/dialogprobe.cmd"
scp -q "$HERE/dialogprobe.cmd" "$HOST:C:/kaya/dialogprobe.cmd"

ssh -n -o BatchMode=yes "$HOST" \
    'del C:\kaya\out_dialogprobe.txt 2>nul & schtasks /create /tn kaya_dialogprobe /tr "C:\kaya\dialogprobe.cmd C:\kaya\probe-dir" /sc once /st 00:00 /it /rl highest /f >nul && schtasks /run /tn kaya_dialogprobe >nul'

tries=0
until ssh -n -o BatchMode=yes "$HOST" 'type C:\kaya\out_dialogprobe.txt' 2>/dev/null \
    | grep -q PROBEDONE; do
    tries=$((tries + 1))
    if [ "$tries" -gt 40 ]; then
        echo "dialogprobe: no PROBEDONE after 40 polls" >&2
        ssh -n -o BatchMode=yes "$HOST" 'type C:\kaya\out_dialogprobe.txt' 2>/dev/null || true
        exit 1
    fi
    sleep 2
done
ssh -n -o BatchMode=yes "$HOST" 'type C:\kaya\out_dialogprobe.txt'
