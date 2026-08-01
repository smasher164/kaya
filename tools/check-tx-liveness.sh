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
# THE TRANSACTION-LIVENESS GATE: one rule, all nine tiers.
#
# A transaction is valid ONLY inside the build or handler that created
# it, on the app thread. A background thread may call exactly ONE
# method — the post — and everything else needs a transaction that only
# exists over there.
#
# WHY THIS IS A GATE AND NOT A CODE REVIEW. The failure it guards is
# SILENT: a write through a transaction that has already been submitted
# appends to a list nobody will submit again. No exception, no error,
# the write vanishes. Go shipped exactly that for months — its `closed`
# flag existed and the Widget and MenuItem chains checked it, so the
# bug lived in the hundred callsites that did not. Nothing invited the
# mistake until the post primitive arrived; posting is precisely what
# puts a transaction next to a background thread.
#
# THE LANGUAGES SPLIT IN TWO, and the split is real rather than
# stylistic:
#
#   HANDLE bindings hand the guest a transaction object, so a stale one
#   can be recognised and refused. Rust does it at COMPILE TIME (its Tx
#   is !Send and !Sync, pinned by a compile_fail doctest); Go, Java, C#
#   and Swift check a `closed` flag at ONE chokepoint that every write
#   goes through.
#
#   AMBIENT bindings keep the open transaction in a global, so there is
#   no handle to invalidate and nothing to make stale — but a build
#   started on another thread would stamp into the app thread's
#   transaction, or race its state. Python, OCaml and Haskell therefore
#   check the THREAD instead, at the entry to a build.
#
# The C floor has neither: its buffers are caller-owned, so there is no
# transaction to outlive and nothing to pin.
#
# This checks the STRUCTURE — that each guard exists and that each
# chokepoint is still the only way in. The behaviour is pinned per
# language (Go's app_test.go, Rust's compile_fail doctest, Python's
# kaya_app_checks.py).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

fail=0
note() {
    echo "check-tx-liveness: $1" >&2
    fail=1
}

# --- the handle bindings: one chokepoint, and it must stay one -------

# Go: every append goes through Tx.emit. app_test.go already pins the
# count; this pins that the chokepoint still exists and still checks.
grep -q 'func (tx \*Tx) emit(' bindings/go/app.go \
    || note "go: Tx.emit is gone — the write chokepoint moved"
grep -q 'func (tx \*Tx) alive()' bindings/go/app.go \
    || note "go: Tx.alive is gone — nothing refuses a closed transaction"

# Java: same shape, spelled with a private emit.
grep -q 'private void emit(byte\[\] record)' bindings/java/dev/kaya/KayaApp.java \
    || note "java: Tx.emit is gone — the write chokepoint moved"
java_direct=$(grep -c 'records\.add(' bindings/java/dev/kaya/KayaApp.java)
[ "$java_direct" = 1 ] \
    || note "java: $java_direct direct records.add calls, expected exactly 1 (emit's own body). A callsite that appends directly skips the liveness check, and a write through a closed transaction would vanish. Route it through emit."

# C# and Swift make the chokepoint a PROPERTY, so no callsite can miss
# it — which means the thing to guard is that the raw backing field
# stays private to the property and the submit.
grep -q 'internal List<byte\[\]> Records' bindings/csharp/KayaApp.cs \
    || note "csharp: the Records liveness property is gone"
# EXACTLY TWO, not "at most": the raw field is reachable only from the
# submit, which must read past its own guard. Any third use is a write
# that skipped the liveness check.
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
# THE DEFINITION IS NOT THE CALL, and grepping the bare name matches
# both — which made this clause pass with the call deleted. Count them.
ocaml_uses=$(grep -c 'require_app_thread' bindings/ocaml/kaya_app.ml)
[ "$ocaml_uses" -ge 2 ] \
    || note "ocaml: require_app_thread is defined but never called — build must check the thread"
grep -q 'requireAppThread ::' bindings/haskell/KayaApp.hs \
    || note "haskell: requireAppThread is gone"
# Three: the signature, the definition, and the call in buildTx.
haskell_uses=$(grep -c 'requireAppThread' bindings/haskell/KayaApp.hs)
[ "$haskell_uses" -ge 3 ] \
    || note "haskell: requireAppThread is defined but never called — buildTx must check the thread"

# --- and every one of them must name the post as the way out --------
#
# A guard that says "that is illegal" and not "do this instead" sends
# the reader to the source. Each message names the post primitive.
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
