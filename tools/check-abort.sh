#!/usr/bin/env bash

# Everything runs inside the dev shell: the flake pins every toolchain.
# A shell entered before the flake last changed is a bystander
# toolchain; the marker carries the fingerprint the shell was built
# from.
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# The uniform-abort gate: every binding carries the same negative test
# — a handler abort rolls the model mirror back, ships nothing, and
# the app continues (idiom decides the spelling, never the semantics).
# Headless: libraries load, records queue, the core loop is never
# entered. Rust's pin lives in `cargo test -p kaya`; Python's in
# kaya_app_checks.py; C has no mirror and no dispatch (caller-owned
# buffers) so there is nothing to pin.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
export KAYA_LIB="$ROOT/target/debug/libkaya.dylib"
[ -f "$KAYA_LIB" ] || { echo "check-abort: build libkaya first (cargo build --lib)"; exit 1; }

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
# assertable. The swiftc selection mirrors swift-typecheck.sh (nix
# shells break xcrun's DEVELOPER_DIR).
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

# C#: the KAYA_CHECK=abort branch of the guest binary (assumes the
# suite's dotnet build ran; build here if not).
[ -f guests/csharp/bin/Debug/net10.0/kaya-guests.dll ] \
    || dotnet build --nologo -v q guests/csharp/kaya-guests.csproj >"$TMP/cs.log" 2>&1 \
    || { cat "$TMP/cs.log"; fail csharp-build; }
KAYA_CHECK=abort dotnet exec guests/csharp/bin/Debug/net10.0/kaya-guests.dll \
    >"$TMP/cs.log" 2>&1 || { cat "$TMP/cs.log"; fail csharp; }

# Java: pure JVM against the ring stub — no natives, so mutating
# transactions always abort (the check's header explains the shape).
rm -rf "$TMP/java"
javac -d "$TMP/java" tools/guest/java-stub/dev/kaya/KayaRing.java \
    bindings/java/dev/kaya/*.java tools/checks/java-abort/AbortCheck.java \
    >"$TMP/java.log" 2>&1 || { cat "$TMP/java.log"; fail java-build; }
java -cp "$TMP/java" AbortCheck >"$TMP/java.log" 2>&1 || { cat "$TMP/java.log"; fail java; }

# OCaml: the checks/ executable beside the binding.
dune build ./bindings/ocaml/checks/abort_check.exe >"$TMP/ml.log" 2>&1 \
    || { cat "$TMP/ml.log"; fail ocaml-build; }
dune exec bindings/ocaml/checks/abort_check.exe >"$TMP/ml.log" 2>&1 \
    || { cat "$TMP/ml.log"; fail ocaml; }

# Haskell: the kaya-abort-check executable beside the scene guests.
(cd guests/haskell && cabal build kaya-abort-check \
    --extra-lib-dirs="$ROOT/target/debug" \
    --ghc-options="-optl-Wl,-rpath,$ROOT/target/debug" -v0) >"$TMP/hs.log" 2>&1 \
    || { cat "$TMP/hs.log"; fail haskell-build; }
"$(cd guests/haskell && cabal list-bin kaya-abort-check -v0)" >"$TMP/hs.log" 2>&1 \
    || { cat "$TMP/hs.log"; fail haskell; }

# Haskell's mirror-read guard is the Build/Tpl monad wall itself; pin
# it with a must-not-compile fixture. -fno-code type-checks without
# linking libkaya; the grep insists on the type error (a syntax error
# must not pass as "didn't compile").
if ghc -fno-code -XGHC2021 -ibindings/haskell -hidir "$TMP/hs-guard" -odir "$TMP/hs-guard" \
    tools/checks/haskell-guard-fail/TplRead.hs >"$TMP/hs-guard.log" 2>&1; then
    echo "check-abort: haskell guard fixture COMPILED — the Build/Tpl wall fell" >&2
    exit 1
fi
grep -q "Couldn't match" "$TMP/hs-guard.log" \
    || { cat "$TMP/hs-guard.log"; fail haskell-guard-fixture; }

echo "check-abort: OK"
