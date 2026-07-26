#!/usr/bin/env bash

# Everything runs inside the dev shell: the flake pins every toolchain
# (rust + cross targets, swiftc, ffmpeg, the android sdk). Running
# against anything else is an error, not something to paper over — and
# a shell entered before the flake last changed is just as much a
# bystander toolchain, so the marker carries the fingerprint of
# flake.nix+flake.lock the shell was actually built from.
kaya_flake="$(cd "$(dirname "$0")/../.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# Build the SwiftUI backend dylib (macOS): the Swift presentation layer
# plus the kaya_swiftui_run C entry, loadable by any guest-hosted process
# as the one Apple backend. Run inside the dev shell.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck source=tools/lib/swift-toolchain.sh
source "$ROOT/tools/lib/swift-toolchain.sh"

cargo build --locked --lib
# The Swift dylib below is compiled against this library's header
# and loads it at run time; both must come from one tree.
tools/build-id.sh --verify target/debug/libkaya.dylib
tools/gen-header.sh --check

mkdir -p target/swiftui
OUT=target/swiftui/libkaya_swiftui.dylib

# A FAILED BUILD MUST NOT LEAVE A USABLE ARTIFACT. Compile to a scratch
# path and move it into place only on success, deleting any previous
# dylib first. Without this, a broken build leaves yesterday's dylib
# sitting there and the next run silently tests THAT — a false PASS with
# no signal anywhere, which is the worst failure shape there is.
#
# Measured 2026-07-25: a compile error here was followed by a green
# scene run against the stale dylib. The build's own exit status was the
# only evidence, and anything that reads output instead of status (a
# grep, a tail, a human skimming) misses it entirely. Callers should
# still check the exit status; this makes the artifact honest even when
# they do not.
rm -f "$OUT"
if ! kaya_swiftc \
    -emit-library \
    -import-objc-header crates/kaya/include/kaya.h \
    swift/KayaSwiftUI.swift swift/KayaSwiftUIEntry.swift \
    -Xlinker -undefined -Xlinker dynamic_lookup \
    -framework AppKit -framework Foundation \
    -o "$OUT.tmp"; then
    rm -f "$OUT.tmp"
    echo "build-dylib: FAILED — no dylib left in place (a stale one would be tested silently)" >&2
    exit 1
fi
mv -f "$OUT.tmp" "$OUT"
echo "built $OUT"
