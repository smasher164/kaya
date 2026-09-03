#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import Gate, dev_shell_or_die

dev_shell_or_die()

# THE TRANSACTION-LIVENESS GATE: one rule, all nine tiers (CLAUDE.md's
# gate list). A transaction is valid ONLY inside the build or handler
# that created it, on the app thread; a background thread may call only
# the post. HANDLE bindings refuse a stale handle at ONE chokepoint and
# check the THREAD there and at the build entry; AMBIENT ones have no
# handle to invalidate and check the thread alone; the C floor has
# neither, its buffers being caller-owned. This checks the STRUCTURE —
# the behaviour is pinned per language (Go's app_test.go, C#'s
# AbortCheck.cs, Rust's compile_fail doctest, kaya_app_checks.py).

GO = "bindings/go/app.go"
JAVA = "bindings/java/dev/kaya/KayaApp.java"
CS = "bindings/csharp/KayaApp.cs"
SWIFT = "bindings/swift/KayaApp.swift"

gate = Gate("check-tx-liveness")

fail = 0


def note(msg):
    global fail
    print(f"check-tx-liveness: {msg}", file=sys.stderr)
    fail = 1


go_text = gate.read(GO)
java_text = gate.read(JAVA)
cs_text = gate.read(CS)
swift_text = gate.read(SWIFT)

# --- the handle bindings: one chokepoint, and it must stay one -------

if "func (tx *Tx) emit(" not in go_text:
    note("go: Tx.emit is gone — the write chokepoint moved")
if "func (tx *Tx) alive()" not in go_text:
    note("go: Tx.alive is gone — nothing refuses a closed transaction")

if "private void emit(byte[] record)" not in java_text:
    note("java: Tx.emit is gone — the write chokepoint moved")
java_direct = java_text.count("records.add(")
if java_direct != 1:
    note(f"java: {java_direct} direct records.add calls, expected exactly 1 "
         f"(emit's own body). A callsite that appends directly skips the "
         f"liveness check, and a write through a closed transaction would "
         f"vanish. Route it through emit.")

# C# and Swift make the chokepoint a PROPERTY, so what needs guarding is
# that the raw backing field stays private to the property and submit.
if "internal List<byte[]> Records" not in cs_text:
    note("csharp: the Records liveness property is gone")
# EXACTLY TWO, not "at most": any third use is a write that skipped the
# liveness check.
cs_raw = cs_text.count("records.")
if cs_raw != 2:
    note(f"csharp: {cs_raw} uses of the raw records field, expected exactly "
         f"2 (the submit's Count and ToArray). Every write must go through "
         f"the Records property, which checks liveness first.")

if "var tx: KayaTx {" not in swift_text:
    note("swift: the tx liveness property is gone")
swift_raw = swift_text.count("storage.")
if swift_raw != 2:
    note(f"swift: {swift_raw} uses of the raw storage field, expected "
         f"exactly 2 (the submit's bytes and submit). Every write must go "
         f"through the tx property, which checks liveness first.")

# --- the ambient bindings: the thread, checked at the build ----------

python_text = gate.read("bindings/python/kaya/__init__.py")
js_text = gate.read("bindings/js/kaya/index.ts")
ocaml_text = gate.read("bindings/ocaml/kaya_app.ml")
haskell_text = gate.read("bindings/haskell/KayaApp.hs")

if "def _require_app_thread" not in python_text:
    note("python: _require_app_thread is gone")
# THE DEFINITION IS NOT THE CALL: the definition plus the two scope
# entries (the scene scope and the live window form).
if "function requireAppThread()" not in js_text:
    note("js: requireAppThread is gone")
if js_text.count("requireAppThread()") < 3:
    note("js: requireAppThread is defined but never called — runScope "
         "and the live window form must check the thread")
if "let require_app_thread" not in ocaml_text:
    note("ocaml: require_app_thread is gone")
# THE DEFINITION IS NOT THE CALL: a bare name matches both, so count.
if ocaml_text.count("require_app_thread") < 2:
    note("ocaml: require_app_thread is defined but never called — build "
         "must check the thread")
if "requireAppThread ::" not in haskell_text:
    note("haskell: requireAppThread is gone")
# Three: the signature, the definition, and the call in buildTx.
if haskell_text.count("requireAppThread") < 3:
    note("haskell: requireAppThread is defined but never called — buildTx "
         "must check the thread")

# --- and every message must name the post as the way out ------------
for file, want in [(GO, "App.Post"), (JAVA, "App.post"), (CS, "App.Post"),
                   (SWIFT, "app.post"), ("bindings/ocaml/kaya_app.ml",
                                         "Kaya_app.post"),
                   ("bindings/haskell/KayaApp.hs", "post"),
                   ("bindings/python/kaya/__init__.py", "app.post"),
                   ("bindings/js/kaya/index.ts", "app.post")]:
    text = gate.read(file)
    if "transaction" not in text:
        note(f"{file}: no transaction guard message at all")
    if want not in text:
        note(f"{file}: the liveness message must name {want} as the way to "
             f"mutate from a background thread")

# --- the handle bindings: the THREAD, at the same chokepoint ---------
# A CENSUS OVER EXTRACTED BODIES, not a grep for a name: the definition
# matches the same pattern as the call, which is how three of this gate's
# first five clauses passed with the guard deleted.

# THE TX SCOPE IS LOAD-BEARING: `alive()` is also the name of the ASSET
# handle's own liveness check in Java and Swift, and it comes FIRST in
# both files — a file-wide search for the header reads the wrong
# function and reports on a body that could never hold the rule.
BINDINGS = [
    dict(name="go", path=GO, tx_scope=None,
         require="func requireAppThread() {",
         alive="func (tx *Tx) alive() {",
         build="func (a *App) Build(fn func(*Tx)) {",
         dispatch="func (a *App) Serve() {",
         call="requireAppThread()", claim="claimAppThread()",
         post="App.Post"),
    dict(name="java", path=JAVA, tx_scope="public final class Tx {",
         require="static void requireAppThread() {",
         alive="void alive() {",
         build="public <R> R build(java.util.function.Function<Tx, R> "
               "build) {",
         dispatch="public void dispatchLoop() {",
         call="requireAppThread()", claim="claimAppThread()",
         post="App.post"),
    dict(name="csharp", path=CS, tx_scope="sealed class Tx",
         require="internal static void RequireAppThread()",
         alive="internal void Alive()",
         build="public void Build(Action<Tx> build)",
         dispatch="void DispatchLoop()",
         call="RequireAppThread()", claim="ClaimAppThread()",
         post="App.Post"),
    dict(name="swift", path=SWIFT, tx_scope="final class KayaAppTx {",
         require="static func requireAppThread() {",
         alive="func alive() {",
         build="func build<R>(_ build: (KayaAppTx) throws -> R) rethrows "
               "-> R {",
         dispatch="private func dispatchLoop() {",
         call="requireAppThread()", claim="claimAppThread()",
         post="app.post"),
]


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


def thread_clause(texts):
    """texts: {path: text}. ('refused', msg) | ('bad', lines) |
    ('ok', sentence)."""
    bad, facts = [], 0
    for b in BINDINGS:
        path, call, claim, post = b["path"], b["call"], b["claim"], b["post"]
        text = texts[path]
        tx_scope = text if b["tx_scope"] is None else body(text,
                                                          b["tx_scope"])
        if tx_scope is None:
            return "refused", (
                f"{path}: the transaction type is gone ({b['tx_scope']!r}) "
                f"— this census cannot find the surface it reads")

        facts += 1
        req = body(text, b["require"])
        if req is None:
            bad.append(f"{path}: no {call} — the handle bindings check the "
                       f"THREAD as well as `closed`, and nothing here does")
        else:
            facts += 1
            if "belongs to the app thread" not in req or post not in req:
                bad.append(f"{path}: the wrong-thread refusal must say what "
                           f"the rule is and name {post} as the way out — "
                           f"the ambient bindings' sentence, one observable "
                           f"semantics in all of them")

        for what, hdr, where in (
                ("the write chokepoint", b["alive"], tx_scope),
                ("the build entry", b["build"], text)):
            facts += 1
            got = body(where, hdr)
            if got is None:
                bad.append(f"{path}: {what} is gone ({hdr!r}) — this gate "
                           f"cannot see the rule it holds")
            elif call not in got:
                bad.append(f"{path}: {what} does not call {call}. An OPEN "
                           f"transaction used from another thread is "
                           f"accepted there, and the write races the app "
                           f"thread's model with no error")

        facts += 1
        at = text.find(b["dispatch"])
        if at < 0:
            bad.append(f"{path}: the dispatch loop is gone "
                       f"({b['dispatch']!r})")
        elif b["claim"] not in "\n".join(text[at:].split("\n")[:9]):
            bad.append(f"{path}: the dispatch loop does not {claim} on the "
                       f"way in — unclaimed, every wrong-thread check above "
                       f"is inert")

    # A census that read nothing agrees with everything.
    want = 5 * len(BINDINGS)
    if facts != want:
        return "refused", (f"read {facts} facts, expected {want} — the "
                           f"census table and this walk disagree")
    if bad:
        return "bad", bad
    return "ok", f"{facts} thread facts across {len(BINDINGS)} handle " \
                 f"bindings"


REAL = {GO: go_text, JAVA: java_text, CS: cs_text, SWIFT: swift_text}
verdict, payload = thread_clause(REAL)
if verdict == "refused":
    print(f"check-tx-liveness: REFUSED A VERDICT: {payload}",
          file=sys.stderr)
    sys.exit(2)
if verdict == "bad":
    print("check-tx-liveness: the wrong-thread half of the rule:",
          file=sys.stderr)
    print("\n".join(payload), file=sys.stderr)
    fail = 1


# Every clause above watched failing, each perturbation applied in memory
# to the real bytes.
def selftest(label, site, pattern, repl, expect):
    doctored = gate.doctor(label, REAL[site], pattern, repl)
    v, p = thread_clause({**REAL, site: doctored})
    drift = "\n".join(p) if v == "bad" else str(p)
    if expect in drift:
        print(f"check-tx-liveness: self-test {label}, 1 substitution(s), "
              f"red as demanded")
    else:
        print(f'check-tx-liveness: SELF-TEST {label} FAIL — wanted '
              f'"{expect}" in: {drift}', file=sys.stderr)
        sys.exit(1)


# N1: the call gone from a write chokepoint — the OPEN-transaction hole.
selftest("N1", GO, r"\n\trequireAppThread\(\)\n\}", "\n}",
         "the write chokepoint does not call")
# N2: the call gone from a build entry — the background-Build hole.
selftest("N2", CS, r"\{\n        RequireAppThread\(\);\n", "{\n",
         "the build entry does not call")
# N3: the dispatch loop stops claiming — every check above goes inert.
selftest("N3", JAVA, r"\n        claimAppThread\(\);", "",
         "does not claimAppThread() on the way in")
# N4: the refusal stops naming the way out.
selftest("N4", SWIFT, r'"app\.post, which runs', '"something, which runs',
         "name app.post as the way out")

if fail != 0:
    print("check-tx-liveness: FAILURES ABOVE", file=sys.stderr)
    sys.exit(1)
print(f"check-tx-liveness: OK (10 tiers: 5 handle, 4 ambient, 1 floor with "
      f"no transaction; {payload})")
