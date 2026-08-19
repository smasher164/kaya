#!/usr/bin/env bash

# Dev-shell guard; the marker is the flake fingerprint (CLAUDE.md).
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# THE TRANSACTION-LIVENESS GATE: one rule, all nine tiers (CLAUDE.md).
# A transaction is valid ONLY inside the build or handler that created
# it, on the app thread; a background thread may call only the post.
#
#   HANDLE bindings hand the guest a transaction object, so a stale one
#   can be refused. Rust does it at COMPILE TIME (Tx is !Send/!Sync,
#   pinned by a compile_fail doctest); Go, Java, C# and Swift check a
#   `closed` flag at ONE chokepoint every write goes through.
#   AMBIENT bindings have no handle to invalidate, so Python, OCaml and
#   Haskell check the THREAD at the entry to a build.
#   The C floor has neither: its buffers are caller-owned.
#
# This checks the STRUCTURE. The behaviour is pinned per language (Go's
# app_test.go, Rust's compile_fail doctest, kaya_app_checks.py).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

fail=0
note() {
    echo "check-tx-liveness: $1" >&2
    fail=1
}

# --- the handle bindings: one chokepoint, and it must stay one -------

grep -q 'func (tx \*Tx) emit(' bindings/go/app.go \
    || note "go: Tx.emit is gone — the write chokepoint moved"
grep -q 'func (tx \*Tx) alive()' bindings/go/app.go \
    || note "go: Tx.alive is gone — nothing refuses a closed transaction"

grep -q 'private void emit(byte\[\] record)' bindings/java/dev/kaya/KayaApp.java \
    || note "java: Tx.emit is gone — the write chokepoint moved"
java_direct=$(grep -c 'records\.add(' bindings/java/dev/kaya/KayaApp.java)
[ "$java_direct" = 1 ] \
    || note "java: $java_direct direct records.add calls, expected exactly 1 (emit's own body). A callsite that appends directly skips the liveness check, and a write through a closed transaction would vanish. Route it through emit."

# C# and Swift make the chokepoint a PROPERTY, so what needs guarding is
# that the raw backing field stays private to the property and submit.
grep -q 'internal List<byte\[\]> Records' bindings/csharp/KayaApp.cs \
    || note "csharp: the Records liveness property is gone"
# EXACTLY TWO, not "at most": any third use is a write that skipped the
# liveness check.
cs_raw=$(grep -c 'records\.' bindings/csharp/KayaApp.cs)
[ "$cs_raw" = 2 ] \
    || note "csharp: $cs_raw uses of the raw records field, expected exactly 2 (the submit's Count and ToArray). Every write must go through the Records property, which checks liveness first."

grep -q 'var tx: KayaTx {' bindings/swift/KayaApp.swift \
    || note "swift: the tx liveness property is gone"
swift_raw=$(grep -c 'storage\.' bindings/swift/KayaApp.swift)
[ "$swift_raw" = 2 ] \
    || note "swift: $swift_raw uses of the raw storage field, expected exactly 2 (the submit's bytes and submit). Every write must go through the tx property, which checks liveness first."

# --- the ambient bindings: the thread, checked at the build ----------

grep -q 'def _require_app_thread' bindings/python/kaya/__init__.py \
    || note "python: _require_app_thread is gone"
grep -q 'let require_app_thread' bindings/ocaml/kaya_app.ml \
    || note "ocaml: require_app_thread is gone"
# THE DEFINITION IS NOT THE CALL: a bare name matches both, so count.
ocaml_uses=$(grep -c 'require_app_thread' bindings/ocaml/kaya_app.ml)
[ "$ocaml_uses" -ge 2 ] \
    || note "ocaml: require_app_thread is defined but never called — build must check the thread"
grep -q 'requireAppThread ::' bindings/haskell/KayaApp.hs \
    || note "haskell: requireAppThread is gone"
# Three: the signature, the definition, and the call in buildTx.
haskell_uses=$(grep -c 'requireAppThread' bindings/haskell/KayaApp.hs)
[ "$haskell_uses" -ge 3 ] \
    || note "haskell: requireAppThread is defined but never called — buildTx must check the thread"

# --- and every message must name the post as the way out ------------
for pair in \
    "bindings/go/app.go:App.Post" \
    "bindings/java/dev/kaya/KayaApp.java:App.post" \
    "bindings/csharp/KayaApp.cs:App.Post" \
    "bindings/swift/KayaApp.swift:app.post" \
    "bindings/ocaml/kaya_app.ml:Kaya_app.post" \
    "bindings/haskell/KayaApp.hs:post" \
    "bindings/python/kaya/__init__.py:app.post"; do
    file="${pair%%:*}"
    want="${pair##*:}"
    grep -q "transaction" "$file" || note "$file: no transaction guard message at all"
    grep -q "$want" "$file" || note "$file: the liveness message must name $want as the way to mutate from a background thread"
done

if [ "$fail" != 0 ]; then
    echo "check-tx-liveness: FAILURES ABOVE" >&2
    exit 1
fi
echo "check-tx-liveness: OK (9 tiers: 5 handle, 3 ambient, 1 floor with no transaction)"
