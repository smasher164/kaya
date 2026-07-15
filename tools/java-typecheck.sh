#!/usr/bin/env bash
# Compile-check the Java binding and example against a KayaRing stub —
# the fast gate that catches KayaApp.java breakage without Gradle or
# an emulator. javac comes from the PATH or, failing that, from nix.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

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
    bindings/java/dev/kaya/KayaWire.java \
    android/milestone2kt/src/main/java/dev/kaya/milestone2kt/Milestone2.java \
    android/milestone2kt/src/main/java/dev/kaya/milestone2kt/Entry.java; then
    echo "java-typecheck: OK"
else
    echo "java-typecheck: FAIL"
    exit 1
fi
