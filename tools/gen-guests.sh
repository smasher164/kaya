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
# Regenerate the per-language guest surfaces from the guests' own
# KayaGen-marked declarations (the type is the schema; the generators
# read it, never restate it; the declaration's shape decides record or
# sum) — the Form-A tier of DESIGN.md's eliminator-convergence note.
# Generated files are checked in; --check regenerates in place and
# fails on any diff, so a drifted surface dies in the gates, not in a
# guest build.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

# Go: every //go:generate directive under guests/go runs cmd/kaya-gen.
go generate ./guests/go/... || exit 1

# Java: the annotation processor over the APK guest sources
# (-proc:only parses and generates without compiling; generated
# *Kaya.java files are excluded from the run's inputs and rewritten).
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
run_javac() {
    if javac -version >/dev/null 2>&1; then
        javac "$@"
    else
        nix shell nixpkgs#jdk17 -c javac "$@"
    fi
}
run_javac -d "$TMP/japt" \
    bindings/java/dev/kaya/KayaGen.java \
    tools/java-processor/dev/kaya/processor/KayaProcessor.java || exit 1
JAVA_GUESTS=()
while IFS= read -r f; do
    JAVA_GUESTS+=("$f")
done < <(find guests/java -name '*.java' ! -name '*Kaya.java')
run_javac -proc:only \
    -processorpath "$TMP/japt" -processor dev.kaya.processor.KayaProcessor \
    -Akaya.out=guests/java \
    bindings/java-desktop/dev/kaya/KayaRing.java \
    bindings/java/dev/kaya/KayaApp.java \
    bindings/java/dev/kaya/KayaRecords.java \
    bindings/java/dev/kaya/KayaSums.java \
    bindings/java/dev/kaya/KayaWire.java \
    bindings/java/dev/kaya/KayaGen.java \
    "${JAVA_GUESTS[@]}" || exit 1

# C#: the Roslyn CLI over the guest sources (the tool's NuGet
# dependency stays the tool's — guests remain dependency-free).
dotnet run --project tools/kaya-csgen -- guests/csharp || exit 1

# Swift: the swift-syntax CLI over each guest file that declares sums.
# SPM runs outside the nix DEVELOPER_DIR — the swift-typecheck escape
# hatch: nix's apple-sdk has no SPM on darwin.
env -u DEVELOPER_DIR -u SDKROOT swift run --package-path tools/kaya-swift-gen \
    kaya-swift-gen guests/swift/feed.swift guests/swift/todos.swift \
    guests/swift/reorder.swift || exit 1

GENERATED=('guests/*_kaya.go' 'guests/*Kaya.java' 'guests/*Kaya.cs' 'guests/*+Kaya.swift')
if [ "${1:-}" = --check ]; then
    # Both drift (tracked file no longer matches what the generator
    # produces) and omission (generated file never checked in) fail —
    # git diff alone is vacuous for untracked paths.
    if ! git diff --exit-code -- "${GENERATED[@]}" >/dev/null; then
        echo "gen-guests: generated surfaces are stale — run tools/gen-guests.sh and commit" >&2
        git diff --stat -- "${GENERATED[@]}" >&2
        exit 1
    fi
    untracked="$(git ls-files --others --exclude-standard -- "${GENERATED[@]}")"
    if [ -n "$untracked" ]; then
        echo "gen-guests: generated surfaces are not checked in:" >&2
        echo "$untracked" >&2
        exit 1
    fi
fi
echo "gen-guests: OK"
