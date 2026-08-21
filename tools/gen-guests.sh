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
# Generated files are checked in. --check compares what the generators
# produce against the tree AS IT STOOD and then puts every byte back —
# the four generators only write in place, so the check snapshots first,
# regenerates, diffs against the snapshot, restores, and REFUSES A
# VERDICT if the restore left the tree changed. The old --check
# regenerated in place and diffed against git, which silently reverted
# any hand-edit to a generated file and then called the tree clean
# (docs/traps.md).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

GENERATED=('guests/*_kaya.go' 'guests/*Kaya.java' 'guests/*Kaya.cs' 'guests/*+Kaya.swift')
CHECK=0
if [ "${1:-}" = --check ]; then CHECK=1; fi

list_generated() {
    {
        git ls-files -- "${GENERATED[@]}"
        git ls-files --others --exclude-standard -- "${GENERATED[@]}"
    } | sort -u
}

sha_over() {
    while IFS= read -r f; do
        if [ -e "$f" ]; then shasum -a 256 "$f"; else echo "MISSING $f"; fi
    done <"$1" | shasum -a 256
}

if [ "$CHECK" = 1 ]; then
    list_generated >"$TMP/all.list"
    : >"$TMP/before.list"
    : >"$TMP/missing.list"
    while IFS= read -r f; do
        if [ -e "$f" ]; then
            mkdir -p "$TMP/saved/$(dirname "$f")"
            cp "$f" "$TMP/saved/$f" || exit 1
            # The pre-check mtime, kept so an in-place rewrite of
            # IDENTICAL bytes can be undone below: a fresh mtime on
            # unchanged sources makes cargo relink libkaya on every
            # sweep, and every relink mints a new LC_UUID (measured
            # 2026-08-20 — the artifact gate keys never hit).
            python3 -c "import os,sys;print(os.stat(sys.argv[1]).st_mtime_ns)" "$f" \
                >"$TMP/saved/$f.mtime" || exit 1
            echo "$f" >>"$TMP/before.list"
        else
            # Tracked as a generated surface, absent from the tree — its
            # own red below, and the restore keeps it absent.
            echo "$f" >>"$TMP/missing.list"
        fi
    done <"$TMP/all.list"
    before_sha="$(sha_over "$TMP/all.list")"
fi

# Go: every //go:generate directive under guests/go runs cmd/kaya-gen.
go generate ./guests/go/... || exit 1

# Java: the annotation processor over the APK guest sources. -proc:only
# parses and generates without compiling; the generated *Kaya.java are
# excluded from the run's inputs and rewritten.
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
    guests/swift/reorder.swift guests/swift/undo.swift \
    guests/swift/table.swift || exit 1

if [ "$CHECK" = 1 ]; then
    red=0
    list_generated >"$TMP/after.list"
    while IFS= read -r f; do
        if ! grep -Fxq "$f" "$TMP/all.list"; then
            echo "gen-guests: generators produce $f, which the tree does not carry — run tools/gen-guests.sh and commit" >&2
            rm -f "$f"
            red=1
        fi
    done <"$TMP/after.list"
    while IFS= read -r f; do
        echo "gen-guests: $f is tracked as a generated surface but missing from the tree — run tools/gen-guests.sh and commit" >&2
        rm -f "$f"
        red=1
    done <"$TMP/missing.list"
    while IFS= read -r f; do
        if [ ! -e "$f" ] || ! cmp -s "$TMP/saved/$f" "$f"; then
            echo "gen-guests: $f is stale against its generator — run tools/gen-guests.sh and commit" >&2
            cp "$TMP/saved/$f" "$f" || exit 1
            red=1
        fi
    done <"$TMP/before.list"
    after_sha="$(sha_over "$TMP/all.list")"
    if [ "$after_sha" != "$before_sha" ]; then
        echo "gen-guests: REFUSING A VERDICT — --check modified the tree it was checking" >&2
        exit 2
    fi
    # Bytes are proven identical (the sha above); give every file its
    # pre-check mtime back so the regeneration is invisible to cargo —
    # see the snapshot comment for the relink churn this stops.
    while IFS= read -r f; do
        if [ -f "$TMP/saved/$f.mtime" ]; then
            python3 -c "
import os, sys
os.utime(sys.argv[1], ns=(int(sys.argv[2]), int(sys.argv[2])))
" "$f" "$(cat "$TMP/saved/$f.mtime")" || exit 1
        fi
    done <"$TMP/before.list"
    # Drift's sibling, omission: a generated file the tree carries but
    # git does not.
    untracked="$(git ls-files --others --exclude-standard -- "${GENERATED[@]}")"
    if [ -n "$untracked" ]; then
        echo "gen-guests: generated surfaces are not checked in:" >&2
        echo "$untracked" >&2
        red=1
    fi
    if [ "$red" = 1 ]; then exit 1; fi
fi
echo "gen-guests: OK"
