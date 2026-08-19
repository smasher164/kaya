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
# Regenerate the per-language guest surfaces from the guests' own
# KayaGen-marked declarations (DESIGN.md's eliminator-convergence note).
# Generated files are checked in; --check regenerates in place and fails
# on any diff.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

# Go: every //go:generate directive under guests/go runs cmd/kaya-gen.
go generate ./guests/go/... || exit 1

# Java: the annotation processor over the APK guest sources. -proc:only
# parses and generates without compiling; the generated *Kaya.java are
# excluded from the run's inputs and rewritten.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
run_javac() {
    if javac -version >/dev/null 2>&1; then
        javac "$@"
    else
        nix shell nixpkgs#jdk17 -c javac "$@"
    fi
}
run_javac -encoding UTF-8 -d "$TMP/japt" \
    bindings/java/dev/kaya/KayaGen.java \
    tools/java-processor/dev/kaya/processor/KayaProcessor.java || exit 1
JAVA_GUESTS=()
while IFS= read -r f; do
    JAVA_GUESTS+=("$f")
done < <(find guests/java -name '*.java' ! -name '*Kaya.java')
run_javac -encoding UTF-8 -proc:only \
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
# SPM runs outside the nix DEVELOPER_DIR — nix's apple-sdk has no SPM on
# darwin. --disable-automatic-resolution is SwiftPM's --locked: the
# swift-syntax dependency is a RANGE and only the checked-in
# Package.resolved makes it a version.
env -u DEVELOPER_DIR -u SDKROOT swift run --disable-automatic-resolution \
    --package-path tools/kaya-swift-gen \
    kaya-swift-gen guests/swift/feed.swift guests/swift/todos.swift \
    guests/swift/reorder.swift guests/swift/undo.swift || exit 1

GENERATED=('guests/*_kaya.go' 'guests/*Kaya.java' 'guests/*Kaya.cs' 'guests/*+Kaya.swift')
if [ "${1:-}" = --check ]; then
    # Drift AND omission both fail: git diff is vacuous for untracked
    # paths, so the ls-files clause below is not redundant.
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
