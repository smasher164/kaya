#!/usr/bin/env bash

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
# Cross-target compile check: catch per-platform Rust breakage (a
# non-exhaustive match in a cfg'd backend, a missing stub arm) in
# seconds, before any emulator, simulator, or VM is involved. Run
# inside the dev shell; the device scripts run their own target's check
# first, and validate-mac runs all of them as a gate.
#
# Usage: check-targets.sh [native|ios|android|windows|all]   (default all)
#
# The Linux/GTK backend is the one absentee: gtk-sys needs the
# distro's pkg-config world, so its compile check lives where it can
# run — the validate-linux docker suite.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

want="${1:-all}"
status=0

check() {
    local name="$1"
    shift
    if [ "$want" != "all" ] && [ "$want" != "$name" ]; then
        return
    fi
    # Warnings stay quiet (some cfg'd backends carry known ones); the
    # full output appears only when the check fails.
    local out
    if out="$(cargo check -p kaya --lib --quiet "$@" 2>&1)"; then
        echo "check-targets: $name OK"
    else
        echo "$out"
        echo "check-targets: $name FAIL"
        status=1
    fi
}

check native
check ios --target aarch64-apple-ios
check android --target aarch64-linux-android
check windows --target aarch64-pc-windows-msvc

if [ "$status" = 0 ]; then echo "check-targets: ALL OK"; else echo "check-targets: FAILURES ABOVE"; fi
exit "$status"
