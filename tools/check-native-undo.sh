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
# THE TWO NATIVE-TIER GUARDS NO SCENE CAN FAIL.
#
# The undo milestone put two guards in every backend, and the Compose arm
# then proved — by breaking each one and watching the lane stay green —
# that NO shared scene can observe either (scratchpad/compose-undo-arm.md
# §3.3/§3.4, 2026-08-05). The reasoning is core-side and therefore true of
# all five arms, not a Compose accident:
#
#   Observing either guard needs TWO CONSECUTIVE NATIVE WALKS. The first
#   walk reaches the frontier episode's before-image, `note_native_undo`
#   spends the episode (crates/kaya/src/scene.rs), and the frontier
#   becomes the GROUP underneath — so the next Edit>Undo routes CORE by
#   construction. Everything A1's clear protects (a native stack reaching
#   back past the episode's start) and everything the ledger-quiet
#   bracket protects (a second report of a walk the core already banked)
#   lives strictly inside that second walk.
#
# And the scene cannot be reshaped to reach it: doing so would assert
# FRONTIER GRANULARITY — how many keystrokes one native undo takes back —
# which tools/scenes/undo.steps refuses in its own header because
# keystroke coalescing differs per platform, and which invariant 6 (one
# script, byte-compared on five lanes) makes decisive.
#
# So this is the only wall available, and it is a static one. It reads
# the two-line pairing out of each backend file:
#
#   1. A backend that takes the core's native-undo SAMPLE must also mark
#      the emission its own walk provokes LEDGER-QUIET — otherwise the
#      same walk is banked twice, the second report restates the walk's
#      position as a new high-water, and the redo side loses the run.
#   2. That mark must be CONSUMED where the edit is reported, not merely
#      written: the read and the report are one block.
#   3. A backend that handles the ClearUndo apply op must call the
#      platform's clear in that arm — A1's keystone, which is what makes
#      "ask the focused text first" the same question as "ask the most
#      recent first".
#
# WHAT IT DOES NOT PIN, said plainly: a call that is present but disabled
# (`if (false)`) satisfies clause 3, and no text gate can do better. What
# it pins is that the arm and the clear are ONE UNIT — which is the shape
# a new backend arm, or a refactor, actually breaks.
#
# THE ORDERING ARGUMENT THAT MAKES CLAUSE 1 LOOK OPTIONAL, and why it is
# not: the core's `note_text_changed` opens with a no-change return, so on
# a backend whose sample lands BEFORE the echo (Compose, mac) the core
# already knows the field's text and drops the unbracketed echo on the
# floor. That is the core's guard, not this one, and it holds only while
# the core's record of the field is current — the bracket is the guard
# for the ordering where the echo LEADS. Uniform semantics (invariant 1)
# decides the rest: mac and iOS carry it, the plan specifies it as the
# mechanism, and its cost is one map entry per routed undo.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

GTK=crates/kaya/src/gtk.rs
WINUI=crates/kaya/src/winui/mod.rs
SWIFTUI=swift/KayaSwiftUI.swift
COMPOSE=android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt

check() {
    # $1..$4: gtk.rs, winui/mod.rs, KayaSwiftUI.swift, KayaCompose.kt.
    # Prints offenders on stdout, returns 1 on any.
    python3 - "$@" <<'PY'
import re
import sys

gtk, winui, swiftui, compose = sys.argv[1:5]
read = lambda p: open(p, encoding="utf-8").read()
bad = []

# Each backend's pairing, in its own vocabulary. Five backends, four
# files: KayaSwiftUI.swift serves mac AND iOS, whose brackets differ in
# spelling (a text match on the sampled text there, a scope counter here)
# and not in rule — so the mark is a LIST, and any one of them satisfies
# the file.
#
# ANCHORS ARE CALL SHAPES, not bare names: a bare `note_native_undo`
# matches gtk.rs's own local helper DEFINITION as well as the core call,
# and a gate that matches a definition is a gate that passes when the
# call is deleted. That failure class has already cost this repo three
# vacuous clauses (CLAUDE.md, invariant 3).
BACKENDS = [
    dict(
        path=gtk, name="gtk",
        sample=r"core\.scene\.note_native_undo\(",
        mark=[r"ledger_quiet\.set\(true\)"],
        readback=r"ledger_quiet\.get\(\)",
        bank=r"bank_text_changed\(",
        arm=r"ApplyOp::ClearUndo\b",
        clear=r"clear_native_undo\(",
    ),
    dict(
        path=winui, name="winui",
        sample=r"core\.scene\.note_native_undo\(",
        mark=[r"core\.ledger_quiet\.insert\("],
        readback=r"core\.ledger_quiet\.get\(",
        bank=r"\.note_text_changed\(",
        arm=r"ApplyOp::ClearUndo\b",
        clear=r"clear_native_undo\(",
    ),
    dict(
        path=swiftui, name="swiftui",
        sample=r"api\.note_native_undo\(",
        mark=[r"kayaNoteNativeUndoEcho\(", r"kayaRoutedNativeUndoDepth \+= 1"],
        readback=r"kayaTakeNativeUndoEcho\(",
        bank=r"api\.emit_text_changed\(",
        arm=r"case applyClearUndo:",
        clear=r"kayaClearUndoForGroup\(",
    ),
    dict(
        path=compose, name="compose",
        sample=r"KayaPresent\.noteNativeUndo\(",
        mark=[r"kayaNativeUndoEcho\[[^\]]*\] = "],
        readback=r"kayaTakeNativeUndoEcho\(",
        bank=r"KayaPresent\.emitTextChanged\(",
        arm=r"APPLY_CLEAR_UNDO ->",
        clear=r"kayaClearUndoForGroup\(",
    ),
]

DECL = re.compile(r"(?:func|fun|fn)\s+$")

# How far a ClearUndo arm's body may reach before the pairing stops
# being one.
ARM_LINES = 25


def hits(text, pattern):
    """Every occurrence of `pattern` that is a USE rather than a
    DECLARATION. Reading a function's own definition as a call is how a
    clause goes vacuous the moment the call is deleted."""
    out = []
    for m in re.finditer(pattern, text):
        head = re.match(r"[A-Za-z_][A-Za-z0-9_]*", text[m.start():])
        before = text[:m.start()]
        if head and DECL.search(before[-24:]):
            continue
        out.append(m)
    return out


def skip_string(text, j):
    """Past the string literal starting at `j`, INTERPOLATIONS AND ALL.

    The naive version — scan to the next quote — desynced this reader on
    both interpreted files, and the balance check below is what caught
    it: Kotlin's `"…(${list.joinToString("; ")})"` and Swift's
    `"can\\(redo ? "Redo" : "Undo")"` each nest a string inside an
    expression inside a string, so the next quote is the START of the
    inner one and everything after it is read as code."""
    n = len(text)
    j += 1
    while j < n:
        c = text[j]
        if c == "\\" and not text.startswith("\\(", j):
            j += 2
            continue
        if c == '"':
            return j + 1
        # Kotlin `${…}` and Swift `\(…)`: a code region inside a string.
        opener = "${" if text.startswith("${", j) else (
            "\\(" if text.startswith("\\(", j) else None)
        if opener:
            close = "}" if opener == "${" else ")"
            open_ch = "{" if opener == "${" else "("
            depth = 0
            j += len(opener) - 1
            while j < n:
                if text[j] == '"':
                    j = skip_string(text, j)
                    continue
                if text[j] == open_ch:
                    depth += 1
                elif text[j] == close:
                    depth -= 1
                    if depth == 0:
                        j += 1
                        break
                j += 1
            continue
        j += 1
    return j


def blocks(text, path):
    """Every {..} block in the file, comments and string literals
    skipped. Returns None if the scan lost sync — an unbalanced result
    means this gate's reader stopped understanding the file, and a
    reader that is lost must fail rather than report a clean bill."""
    stack, out, j, n = [], [], 0, len(text)
    while j < n:
        c = text[j]
        if c == "/" and text.startswith("//", j):
            j = text.find("\n", j)
            if j < 0:
                break
            continue
        if c == "/" and text.startswith("/*", j):
            j = text.find("*/", j)
            if j < 0:
                break
            j += 2
            continue
        if text.startswith('r#"', j):
            j = text.find('"#', j)
            if j < 0:
                break
            j += 2
            continue
        if text.startswith('"""', j):
            j = text.find('"""', j + 3)
            if j < 0:
                break
            j += 3
            continue
        if c == '"':
            j = skip_string(text, j)
            continue
        # A CHARACTER LITERAL, and only a real one: `'"'` in Kotlin's
        # quoted-argument parser was reading as the START of a string
        # here, and everything after it as prose — the balance check is
        # what found that. The pattern deliberately does not match a Rust
        # LIFETIME (`&'a str`), which has no closing quote and would eat
        # the rest of the file.
        if c == "'":
            lit = re.match(r"'(?:\\.|[^\\'])'", text[j:])
            if lit:
                j += lit.end()
                continue
        if c == "{":
            stack.append(j)
        elif c == "}":
            if not stack:
                return None
            out.append((stack.pop(), j))
        j += 1
    return None if stack else out


def innermost(spans, at):
    """The smallest block containing `at`, or None at file scope."""
    best = None
    for a, b in spans:
        if a < at < b and (best is None or (b - a) < (best[1] - best[0])):
            best = (a, b)
    return best


def line(text, at):
    return text.count("\n", 0, at) + 1


for be in BACKENDS:
    path, name = be["path"], be["name"]
    text = read(path)
    spans = blocks(text, path)
    if spans is None:
        bad.append(f"{path}: this gate's block reader lost sync with the file "
                   "(unbalanced braces after skipping comments and strings) — "
                   "every clause below would be guesswork")
        continue

    # 0. VACUITY. Every anchor must still match. A clause whose anchor
    #    stopped matching reports a clean bill about nothing, which is
    #    the failure mode this repo has hit twice.
    missing = [what for what in ("sample", "readback", "bank", "arm", "clear")
               if not hits(text, be[what])]
    if not any(hits(text, m) for m in be["mark"]):
        missing.append("mark")
    if missing:
        bad.append(
            f"{path}: this gate looks for {', '.join(sorted(missing))} in the "
            f"{name} arm and no longer finds {'it' if len(missing) == 1 else 'them'} "
            "— either the native-undo tier left this backend (say so here) or its "
            "spelling moved and the clause went vacuous")
        continue

    # 1. SAMPLE ⇒ MARK. A backend that reports a walk to the core must
    #    also mark the emission that walk provokes, or the core banks the
    #    same change twice.
    if not any(hits(text, m) for m in be["mark"]):
        bad.append(
            f"{path}: the {name} arm calls the core's native-undo sample but marks "
            "no emission ledger-quiet — the ordinary text_changed its own walk "
            "provokes is banked a second time, which restates the walk's position "
            "as a new high-water and loses the run the redo side needs")

    # 2. THE MARK IS CONSUMED WHERE THE EDIT IS REPORTED. Not "the token
    #    appears somewhere": the read and the report are ONE BLOCK, which
    #    is the two-line pairing this gate is named for. A read that
    #    drifts away from the report is a bracket that decides nothing.
    for m in hits(text, be["readback"]):
        span = innermost(spans, m.start())
        where = text[span[0]:span[1]] if span else ""
        if not hits(where, be["bank"]):
            bad.append(
                f"{path}:{line(text, m.start())}: the ledger-quiet read is not in the "
                f"block that reports the edit ({be['bank']}) — a bracket read away "
                "from the report suppresses nothing, and the walk is banked twice")

    # 3. THE CLEAR ARM CLEARS. A1's keystone: the core drives the clear
    #    as an apply op because only the backend knows what is focused.
    #
    #    THE ARM'S BODY IS A WINDOW, not a block, and deliberately: the
    #    three languages spell an arm three ways — Rust's `=> { … }` (whose
    #    first brace after the head is the PATTERN's, `{ window }`, not the
    #    body's), Kotlin's `-> { … }`, and Swift's `case x:` with no braces
    #    at all. A window bounded by the enclosing block and by ARM_LINES
    #    is the one reading all three, and the bound is the rule this gate
    #    is named for: a clear that has drifted twenty-five lines from the
    #    arm it belongs to is no longer a pairing anybody can read.
    for m in hits(text, be["arm"]):
        span = innermost(spans, m.start())
        stop = len(text) if span is None else span[1]
        cut = text.find("\n", m.start())
        for _ in range(ARM_LINES):
            if cut < 0:
                break
            cut = text.find("\n", cut + 1)
        if cut >= 0:
            stop = min(stop, cut)
        where = text[m.start():stop]
        if not hits(where, be["clear"]):
            bad.append(
                f"{path}:{line(text, m.start())}: the ClearUndo arm does not call the "
                f"platform's clear ({be['clear']}) — A1's keystone is what makes every "
                "episode begin with an empty native stack, so without it a native undo "
                "can reach back past the frontier episode's start and the ledger stops "
                "being ordered")

print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
}

# THE GUARD GUARDS ITSELF, on DOCTORED COPIES OF THE REAL FILES rather
# than on synthetic samples: a fixture only ever proves the pattern
# matches the fixture, which is how the wayland seat guard passed
# VACUOUSLY TWICE (docs/traps.md). Every perturbation prints its
# substitution count and is refused if it did not apply — an unchanged
# copy is a FAILED self-test, not a passed one — and every refusal is
# checked for its REASON, since an exit code alone is satisfied by any
# unrelated finding.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# <source> <regex> <replacement> <destination> -> substitution count
perturb() {
    python3 -c '
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
out, n = re.subn(sys.argv[2], sys.argv[3], text, flags=re.S)
open(sys.argv[4], "w", encoding="utf-8").write(out)
print(n)
' "$@"
}

applied() { # count label
    if [ "$1" -ge 1 ]; then
        return 0
    fi
    echo "check-native-undo: SELF-TEST FAIL ($2 applied $1 times, want at least 1 —" \
        "an unchanged copy cannot prove the rule fires)" >&2
    exit 1
}

# <gtk> <winui> <swiftui> <compose> <want-fragment> <label>
refuses() {
    local out
    out="$(check "$1" "$2" "$3" "$4")" && {
        echo "check-native-undo: SELF-TEST FAIL ($6 passed)" >&2
        exit 1
    }
    case "$out" in
        *"$5"*) ;;
        *)
            echo "check-native-undo: SELF-TEST FAIL ($6 failed for another reason: $out)" >&2
            exit 1
            ;;
    esac
    # SAID OUT LOUD ON EVERY RUN, not just in the session that wrote it:
    # these four lines are this gate watching its own clauses fail, which
    # is the difference between a guard and a decoration.
    echo "check-native-undo: watched failing: $6" >&2
}

# 1. THE BRACKET DELETED — the Compose arm's N1 perturbation, which its
#    whole lane could not fail (§3.3). Here it is a two-second red.
hits="$(perturb "$COMPOSE" 'val quiet = kayaTakeNativeUndoEcho\([^)]*\)' \
    'val quiet = false' "$T/compose-no-bracket.kt")"
applied "$hits" "the compose bracket-deletion perturbation"
refuses "$GTK" "$WINUI" "$SWIFTUI" "$T/compose-no-bracket.kt" \
    "no longer finds" "a Compose arm whose ledger-quiet read is gone"

# 2. THE BRACKET DRIFTED AWAY FROM THE REPORT — present, and deciding
#    nothing. This is the shape a refactor produces, and the one a
#    presence check would pass. Two substitutions, because the read has
#    to LEAVE the emission and land somewhere real: an "unused" read
#    left in place would still sit in the block it belongs to.
hits="$(perturb "$SWIFTUI" \
    'let quiet = kayaTakeNativeUndoEcho\(node\.id, text\)' \
    'let quiet = false' "$T/swiftui-quiet-false.swift")"
applied "$hits" "the swiftui bracket-deletion half"
hits="$(perturb "$T/swiftui-quiet-false.swift" \
    'func kayaCoreUndo\(_ window: UInt64\) \{' \
    'func kayaCoreUndo(_ window: UInt64) {\n    _ = kayaTakeNativeUndoEcho(window, "")' \
    "$T/swiftui-stranded.swift")"
applied "$hits" "the swiftui stranded-read half"
refuses "$GTK" "$WINUI" "$T/swiftui-stranded.swift" "$COMPOSE" \
    "is not in the block that reports the edit" \
    "a SwiftUI arm whose bracket read drifted off the emission"

# 3. A1'S CLEAR DROPPED FROM THE APPLY ARM — the Compose arm's F2
#    perturbation, the other guard no lane can fail (§3.4).
hits="$(perturb "$GTK" \
    'ApplyOp::ClearUndo \{ window \} => \{\n            if let Some\(id\) = focused_text_in\(core, window\) \{\n                core\.clear_native_undo\(id\);\n            \}' \
    'ApplyOp::ClearUndo { window } => {\n            let _ = window;' \
    "$T/gtk-no-clear.rs")"
applied "$hits" "the gtk clear-arm perturbation"
refuses "$T/gtk-no-clear.rs" "$WINUI" "$SWIFTUI" "$COMPOSE" \
    "does not call the platform's clear" "a GTK ClearUndo arm that clears nothing"

# 4. THE SAMPLE'S OWN ANCHOR MOVED — the vacuity direction, which is what
#    turns a gate into a decoration. A backend that stops calling the
#    core seam must SAY so here rather than quietly satisfy every clause.
hits="$(perturb "$WINUI" 'core\.scene\.note_native_undo\(' \
    'core.scene.note_native_undo_renamed(' "$T/winui-moved.rs")"
applied "$hits" "the winui anchor-rename perturbation"
refuses "$GTK" "$T/winui-moved.rs" "$SWIFTUI" "$COMPOSE" \
    "no longer finds" "a WinUI backend whose core seam moved"

if ! offenders="$(check "$GTK" "$WINUI" "$SWIFTUI" "$COMPOSE")"; then
    echo "$offenders"
    echo "check-native-undo: FAIL"
    exit 1
fi
echo "check-native-undo: OK"
