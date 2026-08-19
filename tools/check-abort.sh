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
# The uniform-abort gate: every binding's negative test that a handler
# abort rolls the model mirror back, ships nothing, and lets the app
# continue. Headless — the core loop is never entered.
#
# Not here: Rust's pin is in `cargo test -p kaya`, Python's in
# kaya_app_checks.py, and C has no mirror to roll back.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
export KAYA_LIB="$ROOT/target/debug/libkaya.dylib"
[ -f "$KAYA_LIB" ] || { echo "check-abort: build libkaya first (cargo build --locked --lib)"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "check-abort: $1 FAILED" >&2
    exit 1
}

# Go: the in-package test (also pins Build-in-Build misuse and the
# derived-registration non-leak).
go test dev.kaya/bindings/go >"$TMP/go.log" 2>&1 || { cat "$TMP/go.log"; fail go; }

# Swift: one module with the bindings, so internal mirrors are
# assertable.
if SWIFTC="$(env -u DEVELOPER_DIR -u SDKROOT xcrun --find swiftc 2>/dev/null)"; then
    SDK_ARGS=()
else
    SWIFTC=/usr/bin/swiftc
    SDK_ARGS=(-sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)
fi
env -u DEVELOPER_DIR -u SDKROOT "$SWIFTC" "${SDK_ARGS[@]}" -o "$TMP/swift-abort" \
    bindings/swift/*.swift tools/checks/swift-abort/main.swift \
    -import-objc-header crates/kaya/include/kaya.h -I crates/kaya/include \
    -L target/debug -lkaya -Xlinker -rpath -Xlinker "$ROOT/target/debug" \
    >"$TMP/swift.log" 2>&1 || { cat "$TMP/swift.log"; fail swift-build; }
"$TMP/swift-abort" >"$TMP/swift.log" 2>&1 || { cat "$TMP/swift.log"; fail swift; }

# C#: the KAYA_CHECK=abort branch of the guest binary.
[ -f guests/csharp/bin/Debug/net10.0/kaya-guests.dll ] \
    || dotnet build --nologo -v q guests/csharp/kaya-guests.csproj >"$TMP/cs.log" 2>&1 \
    || { cat "$TMP/cs.log"; fail csharp-build; }
KAYA_CHECK=abort dotnet exec guests/csharp/bin/Debug/net10.0/kaya-guests.dll \
    >"$TMP/cs.log" 2>&1 || { cat "$TMP/cs.log"; fail csharp; }

# Java: pure JVM against the ring stub — no natives, so mutating
# transactions always abort (AbortCheck.java's header has the shape).
rm -rf "$TMP/java"
javac -encoding UTF-8 -d "$TMP/java" bindings/java-desktop/dev/kaya/KayaRing.java \
    bindings/java/dev/kaya/*.java tools/checks/java-abort/AbortCheck.java \
    >"$TMP/java.log" 2>&1 || { cat "$TMP/java.log"; fail java-build; }
java -cp "$TMP/java" AbortCheck >"$TMP/java.log" 2>&1 || { cat "$TMP/java.log"; fail java; }

# OCaml: the checks/ executable beside the binding.
dune build ./bindings/ocaml/checks/abort_check.exe >"$TMP/ml.log" 2>&1 \
    || { cat "$TMP/ml.log"; fail ocaml-build; }
dune exec bindings/ocaml/checks/abort_check.exe >"$TMP/ml.log" 2>&1 \
    || { cat "$TMP/ml.log"; fail ocaml; }

# Haskell: the kaya-abort-check executable beside the scene guests.
# This gate builds in its OWN build tree, never the shared
# dist-newstyle: the repo is mounted into the linux container, so
# wiping the shared one destroys the docker lane's freshly built
# Haskell guests mid-run (caught by the matrix, 2026-07-24).
#
# Inside that private tree the component's build directory goes EVERY
# run, so the library and the executable genuinely recompile and LINK
# here: cabal skips a link whose inputs are unchanged and trusts its
# plan cache over the artifact's existence, so neither deleting the
# binary nor -fforce-recomp forces it (docs/traps.md).
HS_DIST="$ROOT/target/hs-abort-dist"
rm -rf "$HS_DIST"/build/*/*/kaya-guests-0
(cd guests/haskell && cabal build kaya-abort-check --builddir="$HS_DIST" \
    --extra-lib-dirs="$ROOT/target/debug" \
    --ghc-options="-L$ROOT/target/debug -optl-Wl,-rpath,$ROOT/target/debug" -v0) >"$TMP/hs.log" 2>&1 \
    || { cat "$TMP/hs.log"; fail haskell-build; }
"$(cd guests/haskell && cabal list-bin kaya-abort-check --builddir="$HS_DIST" -v0)" >"$TMP/hs.log" 2>&1 \
    || { cat "$TMP/hs.log"; fail haskell; }

# Haskell's mirror-read guard is the Build/Tpl monad wall itself, pinned
# by a must-not-compile fixture. The grep insists on the TYPE error — a
# syntax error must not pass as "didn't compile".
if ghc -fno-code -XGHC2021 -ibindings/haskell -hidir "$TMP/hs-guard" -odir "$TMP/hs-guard" \
    tools/checks/haskell-guard-fail/TplRead.hs >"$TMP/hs-guard.log" 2>&1; then
    echo "check-abort: haskell guard fixture COMPILED — the Build/Tpl wall fell" >&2
    exit 1
fi
grep -q "Couldn't match" "$TMP/hs-guard.log" \
    || { cat "$TMP/hs-guard.log"; fail haskell-guard-fixture; }

echo "check-abort: OK"
