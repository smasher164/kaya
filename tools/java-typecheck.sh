#!/usr/bin/env bash

kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# Compile-check the Java binding and every guest against the real
# desktop KayaRing (bindings/java-desktop). Globbed, not listed: a
# hand-maintained file list here once skipped three scenes silently.
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

if run_javac -encoding UTF-8 -d "$TMP" \
    bindings/java-desktop/dev/kaya/KayaRing.java \
    bindings/java/dev/kaya/*.java \
    guests/java/dev/kaya/milestone2kt/*.java \
    guests/java-desktop/dev/kaya/milestone2kt/Main.java; then
    echo "java-typecheck: OK"
else
    echo "java-typecheck: FAIL"
    exit 1
fi
