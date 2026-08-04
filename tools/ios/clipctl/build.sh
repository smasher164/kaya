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

# Build clipctl, the iOS lane's foreign clipboard process (reader and
# writer). See main.swift for what it is and why the lane needs a
# binary of its own.
#
# Prints the built binary's path on stdout so a caller can use it
# directly; the runner builds it once per run and passes the path to
# every leg's watcher.
#
# ALWAYS FRESH, deliberately — the same shape tools/ios/simdrive/build.sh
# has. A cache keyed on mtimes would buy a second and reintroduce the
# stale-artifact class on a binary that decides whether a lane passes.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$ROOT"

# Inside the dev shell DEVELOPER_DIR/SDKROOT point at a nix apple-sdk
# where xcrun finds neither swiftc nor the simulator SDK.
# tools/lib/swift-toolchain.sh is the single source of truth for
# steering back to a real Apple toolchain.
# shellcheck source=tools/lib/swift-toolchain.sh
. "$ROOT/tools/lib/swift-toolchain.sh"
kaya_resolve_swiftc || exit 1
[ -n "${SWIFT_DEVELOPER_DIR:-}" ] && export DEVELOPER_DIR="$SWIFT_DEVELOPER_DIR"

OUT="$ROOT/target/ios-clipctl"
mkdir -p "$OUT"

# The iphonesimulator SDK, not the macOS one kaya_swiftc pins: this runs
# INSIDE the simulator under `simctl spawn`, against the same UIKit the
# guest sees. So it borrows the resolved toolchain's swiftc and
# overrides -sdk, the way tools/ios/clipprobe/build.sh does.
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
env -u SDKROOT "$SWIFTC" \
    -target arm64-apple-ios17.0-simulator \
    -sdk "$SDK" \
    -o "$OUT/clipctl" \
    "$HERE/main.swift" >&2

echo "$OUT/clipctl"
