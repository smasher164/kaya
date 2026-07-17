#!/usr/bin/env bash
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
