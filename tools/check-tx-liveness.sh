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
#   `closed` flag at ONE chokepoint every write goes through, AND the
#   THREAD at that same chokepoint and at the build entry.
#   AMBIENT bindings have no handle to invalidate, so Python, OCaml and
#   Haskell check the THREAD at the entry to a build.
#   The C floor has neither: its buffers are caller-owned.
#
# CLOSED WAS NEVER THE WHOLE RULE, and for four milestones this gate
# only asked for that half: a transaction still OPEN, written from a
# thread the handler spawned, passed every check here, and a background
# Build opening one of its own reached no chokepoint at all. Both race
# the app thread's model in silence (docs/deferred.md).
#
# This checks the STRUCTURE. The behaviour is pinned per language (Go's
# app_test.go, C#'s AbortCheck.cs, Rust's compile_fail doctest,
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

# --- the handle bindings: the THREAD, at the same chokepoint ---------
#
# A CENSUS OVER EXTRACTED BODIES, not a grep for a name: the definition
# matches the same pattern as the call, which is how three of this
# gate's first five clauses passed with the guard deleted. Each fact
# below is read out of the body it must live in.
GO=bindings/go/app.go
JAVA=bindings/java/dev/kaya/KayaApp.java
CS=bindings/csharp/KayaApp.cs
SWIFT=bindings/swift/KayaApp.swift

thread_clause() { # $1 go  $2 java  $3 csharp  $4 swift
    python3 - "$@" <<'PY'
import sys

go, java, cs, swift = sys.argv[1:5]

# THE TX SCOPE IS LOAD-BEARING: `alive()` is also the name of the ASSET
# handle's own liveness check in Java and Swift, and it comes FIRST in
# both files — a file-wide search for the header reads the wrong
# function and reports on a body that could never hold the rule.
BINDINGS = [
    dict(name="go", path=go, tx_scope=None,
         require="func requireAppThread() {",
         alive="func (tx *Tx) alive() {",
         build="func (a *App) Build(fn func(*Tx)) {",
         dispatch="func (a *App) Serve() {",
         call="requireAppThread()", claim="claimAppThread()", post="App.Post"),
    dict(name="java", path=java, tx_scope="public final class Tx {",
         require="static void requireAppThread() {",
         alive="void alive() {",
         build="public <R> R build(java.util.function.Function<Tx, R> build) {",
         dispatch="public void dispatchLoop() {",
         call="requireAppThread()", claim="claimAppThread()", post="App.post"),
    dict(name="csharp", path=cs, tx_scope="sealed class Tx",
         require="internal static void RequireAppThread()",
         alive="internal void Alive()",
         build="public void Build(Action<Tx> build)",
         dispatch="void DispatchLoop()",
         call="RequireAppThread()", claim="ClaimAppThread()", post="App.Post"),
    dict(name="swift", path=swift, tx_scope="final class KayaAppTx {",
         require="static func requireAppThread() {",
         alive="func alive() {",
         build="func build<R>(_ build: (KayaAppTx) throws -> R) rethrows -> R {",
         dispatch="private func dispatchLoop() {",
         call="requireAppThread()", claim="claimAppThread()", post="app.post"),
]

bad, facts = [], 0


def body(text, header):
    """The braced body that follows `header`, or None if it is gone."""
    at = text.find(header)
    if at < 0:
        return None
    open_at = text.find("{", at + len(header) - 1)
    if open_at < 0:
        return None
    depth = 0
    for i in range(open_at, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[open_at:i + 1]
    return None


for b in BINDINGS:
    path, call, claim, post = b["path"], b["call"], b["claim"], b["post"]
    text = open(path).read()
    tx_scope = text if b["tx_scope"] is None else body(text, b["tx_scope"])
    if tx_scope is None:
        print(f"{path}: the transaction type is gone ({b['tx_scope']!r}) — this "
              f"census cannot find the surface it reads")
        sys.exit(2)

    facts += 1
    req = body(text, b["require"])
    if req is None:
        bad.append(f"{path}: no {call} — the handle bindings check the THREAD as "
                   f"well as `closed`, and nothing here does")
    else:
        facts += 1
        if "belongs to the app thread" not in req or post not in req:
            bad.append(f"{path}: the wrong-thread refusal must say what the rule is "
                       f"and name {post} as the way out — the ambient bindings' "
                       f"sentence, one observable semantics in all of them")

    for what, hdr, where in (("the write chokepoint", b["alive"], tx_scope),
                             ("the build entry", b["build"], text)):
        facts += 1
        got = body(where, hdr)
        if got is None:
            bad.append(f"{path}: {what} is gone ({hdr!r}) — this gate cannot see "
                       f"the rule it holds")
        elif call not in got:
            bad.append(f"{path}: {what} does not call {call}. An OPEN transaction "
                       f"used from another thread is accepted there, and the write "
                       f"races the app thread's model with no error")

    facts += 1
    at = text.find(b["dispatch"])
    if at < 0:
        bad.append(f"{path}: the dispatch loop is gone ({b['dispatch']!r})")
    elif claim not in "\n".join(text[at:].split("\n")[:9]):
        bad.append(f"{path}: the dispatch loop does not {claim} on the way in — "
                   f"unclaimed, every wrong-thread check above is inert")

# A census that read nothing agrees with everything.
WANT = 5 * len(BINDINGS)
if facts != WANT:
    print(f"read {facts} facts, expected {WANT} — the census table and this "
          f"walk disagree")
    sys.exit(2)
if bad:
    print("\n".join(bad))
    sys.exit(1)
print(f"{facts} thread facts across {len(BINDINGS)} handle bindings")
sys.exit(0)
PY
}

out="$(thread_clause "$GO" "$JAVA" "$CS" "$SWIFT")"
rc=$?
if [ "$rc" = 2 ]; then
    echo "check-tx-liveness: REFUSED A VERDICT: $out" >&2
    exit 2
elif [ "$rc" != 0 ]; then
    echo "check-tx-liveness: the wrong-thread half of the rule:" >&2
    echo "$out" >&2
    fail=1
fi

# THE GUARD GUARDS ITSELF: every clause above was watched failing
# through this block, each perturbation applied to a COPY of the real
# bytes with its substitution count printed.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cp "$GO" "$T/app.go"; cp "$JAVA" "$T/KayaApp.java"
cp "$CS" "$T/KayaApp.cs"; cp "$SWIFT" "$T/KayaApp.swift"

selftest() { # $1 label, $2 file-to-perturb (in $T), $3 py-perturb, $4 expect-fragment
    local hits drift
    hits="$(python3 -c "
import re, sys
text = open(sys.argv[1]).read()
drifted, n = $3
open(sys.argv[1], 'w').write(drifted)
print(n)
" "$2")"
    if [ "$hits" != 1 ]; then
        echo "check-tx-liveness: SELF-TEST $1 applied $hits perturbation(s), want 1" >&2
        exit 1
    fi
    drift="$(thread_clause "${ARGS[@]}")"
    case "$drift" in
        *"$4"*) echo "check-tx-liveness: self-test $1, 1 substitution(s), red as demanded" ;;
        *)
            echo "check-tx-liveness: SELF-TEST $1 FAIL — wanted \"$4\" in: $drift" >&2
            exit 1
            ;;
    esac
    return 0
}

# N1: the call gone from a write chokepoint — the OPEN-transaction hole.
ARGS=("$T/app.go" "$JAVA" "$CS" "$SWIFT")
selftest N1 "$T/app.go" "re.subn(r'\n\trequireAppThread\(\)\n\}', '\n}', text, count=1)" "the write chokepoint does not call"
cp "$GO" "$T/app.go"

# N2: the call gone from a build entry — the background-Build hole.
ARGS=("$GO" "$JAVA" "$T/KayaApp.cs" "$SWIFT")
selftest N2 "$T/KayaApp.cs" "re.subn(r'\{\n        RequireAppThread\(\);\n', '{\n', text, count=1)" "the build entry does not call"
cp "$CS" "$T/KayaApp.cs"

# N3: the dispatch loop stops claiming — every check above goes inert.
ARGS=("$GO" "$T/KayaApp.java" "$CS" "$SWIFT")
selftest N3 "$T/KayaApp.java" "re.subn(r'\n        claimAppThread\(\);', '', text, count=1)" "does not claimAppThread() on the way in"
cp "$JAVA" "$T/KayaApp.java"

# N4: the refusal stops naming the way out.
ARGS=("$GO" "$JAVA" "$CS" "$T/KayaApp.swift")
selftest N4 "$T/KayaApp.swift" "re.subn(r'\"app\.post, which runs', '\"something, which runs', text, count=1)" "name app.post as the way out"

if [ "$fail" != 0 ]; then
    echo "check-tx-liveness: FAILURES ABOVE" >&2
    exit 1
fi
echo "check-tx-liveness: OK (9 tiers: 5 handle, 3 ambient, 1 floor with no transaction; $out)"
