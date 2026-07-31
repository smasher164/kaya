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

# Build simdrive, the iOS lane's out-of-app driver. See main.swift for
# what it is and why iOS needs one at all.
#
# Prints the built binary's path on stdout so a caller can use it
# directly; the runner builds it once per run and passes the path to
# every leg.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$ROOT"

# shellcheck source=tools/lib/swift-toolchain.sh
. "$ROOT/tools/lib/swift-toolchain.sh"
kaya_resolve_swiftc || exit 1

OUT="$ROOT/target/ios-simdrive"
mkdir -p "$OUT"

# -O because the accessibility walk makes a bridge round trip per
# attribute, and the tool is invoked once per harness verb.
kaya_swiftc -O -o "$OUT/simdrive" "$HERE/main.swift" >&2

echo "$OUT/simdrive"
