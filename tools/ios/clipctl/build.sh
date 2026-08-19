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

# Build clipctl, the iOS lane's foreign clipboard process (see
# main.swift), and print its path on stdout. Always fresh, deliberately:
# no mtime cache on a binary that decides whether a lane passes.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$ROOT"

# Inside the dev shell DEVELOPER_DIR/SDKROOT point at a nix apple-sdk
# where xcrun finds neither swiftc nor the simulator SDK; this steers
# back to a real Apple toolchain.
# shellcheck source=tools/lib/swift-toolchain.sh
. "$ROOT/tools/lib/swift-toolchain.sh"
kaya_resolve_swiftc || exit 1
[ -n "${SWIFT_DEVELOPER_DIR:-}" ] && export DEVELOPER_DIR="$SWIFT_DEVELOPER_DIR"

OUT="$ROOT/target/ios-clipctl"
mkdir -p "$OUT"

# The iphonesimulator SDK, not the macOS one kaya_swiftc pins: this runs
# INSIDE the simulator under `simctl spawn`, against the same UIKit the
# guest sees.
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
env -u SDKROOT "$SWIFTC" \
    -target arm64-apple-ios17.0-simulator \
    -sdk "$SDK" \
    -o "$OUT/clipctl" \
    "$HERE/main.swift" >&2

echo "$OUT/clipctl"
