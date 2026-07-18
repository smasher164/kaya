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
# Compile-check the Java binding and example against a KayaRing stub —
# the fast gate that catches KayaApp.java breakage without Gradle or
# an emulator. javac comes from the PATH or, failing that, from nix.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

run_javac() {
    # `javac -version` rather than `command -v`: macOS ships a stub
    # javac that exists on PATH but errors without a JDK installed.
    if javac -version >/dev/null 2>&1; then
        javac "$@"
    else
        nix shell nixpkgs#jdk17 -c javac "$@"
    fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if run_javac -d "$TMP" \
    tools/guest/java-stub/dev/kaya/KayaRing.java \
    bindings/java/dev/kaya/KayaApp.java \
    bindings/java/dev/kaya/KayaRecords.java \
    bindings/java/dev/kaya/KayaSums.java \
    bindings/java/dev/kaya/KayaWire.java \
    guests/java/dev/kaya/milestone2kt/Milestone2.java \
    guests/java/dev/kaya/milestone2kt/Entry.java \
    guests/java/dev/kaya/milestone2kt/Gallery.java \
    guests/java/dev/kaya/milestone2kt/Todos.java \
    guests/java/dev/kaya/milestone2kt/Reorder.java \
    guests/java/dev/kaya/milestone2kt/Feed.java \
    guests/java/dev/kaya/milestone2kt/PostKaya.java \
    guests/java/dev/kaya/milestone2kt/TodoKaya.java \
    guests/java/dev/kaya/milestone2kt/ItemKaya.java \
    bindings/java/dev/kaya/KayaGen.java; then
    echo "java-typecheck: OK"
else
    echo "java-typecheck: FAIL"
    exit 1
fi
