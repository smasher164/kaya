#!/usr/bin/env bash

# Everything runs inside the dev shell: the flake pins every toolchain.
# A shell entered before the flake last changed is a bystander
# toolchain, so the marker carries the fingerprint of
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
# THE SOLE-BRANCH GATE. A diagnostic — a function whose whole job is to
# answer "why did that fail?" — is believed. Whatever sentence it prints
# is what the next reader chases, so a sentence it cannot NOT print is a
# sentence that will be chased for every cause it does not name.
#
# That is not hypothetical here. `kayaOpenPanelWhyNot()` shipped with an
# arm reading `!NSApplication.shared.isActive`, which is ALWAYS true for
# kaya's `.accessory` guests, printing a confident story about a
# fullscreen application and XPC-hosted NSOpenPanel. Every load-bearing
# claim in it was false and the branch below it was dead. It cost half
# an hour when it was written, and months later it misdirected an entire
# session onto macOS cooperative activation while the real cause was the
# panel's view mode — a machine-wide preference. The rule that came out
# of it is `docs/traps.md`, "The diagnostic that named a cause nobody
# had measured": A DIAGNOSTIC MAY ONLY PRINT WHAT IT MEASURED. This is
# that rule, mechanized as far as a script honestly can.
#
# TWO CLAUSES.
#
#   SOLE-ANSWER   A diagnostic that can return exactly one string
#                 distinguishes nothing: every failure gets that
#                 sentence, and the caller consults it as if it had
#                 chosen. This is the degenerate shape, and the one
#                 people write first.
#
#   FIXED-PROSE   An answer that interpolates NOTHING is the same
#                 sentence for every state that reaches it — the
#                 mechanical form of "unconditionally the answer". A
#                 diagnostic gets exactly ONE of those and it must be
#                 its first clause: the early-out, which fires before
#                 the function has looked at anything and whose entire
#                 content is the guard it just tested (`kayaLiveOpenPanel
#                 == nil` -> "no panel was requested"). Every clause
#                 after it stands on the failure path and must print at
#                 least one value this process went and got.
#
# FIXED-PROSE is the clause that fails the real defect; SOLE-ANSWER does
# not (the pre-fix body had three answers, one of them dead). Both are
# here because they are different mistakes.
#
# WHAT THIS GATE DOES NOT DO. It does not read English. A causal-claim
# regex over "probably"/"must be"/"is not frontmost" was costed and
# REJECTED: on 220k lines of heavily commented Rust, Swift and Kotlin
# its false-positive rate would be high, and a noisy gate gets muted,
# which is worse than the prose rule alone. It also cannot tell a
# measurement from a constant — a clause interpolating a hardcoded
# identifier satisfies it. What it enforces is the shape: every answer
# on the failure path had to go and look at something.
#
# HOW A NEW DIAGNOSTIC OPTS IN — by its NAME, and there is nothing to
# register. Any function whose name ends in WhyNot, whyNot, why_not,
# Reason or reason is read as a diagnostic from the next run. That is
# the convention: if a function's job is to answer why, say so in its
# name and this gate holds it to the rule.
#
# ONE LANGUAGE, DELIBERATELY. The clause analysis is Swift only, because
# the tree's diagnostics live in the SwiftUI interpreter and an arm no
# source exercises is an arm that rots — this repo has been burned twice
# by guards that passed vacuously because their pattern matched nothing.
# A diagnostic named in any other language FAILS this gate naming the
# extension point rather than being skipped: a loud gap, never a silent
# one. Same reason the census below fails when it is EMPTY — a gate that
# reads zero functions must not print OK.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

# The source roots that can hold a diagnostic. Explicit rather than "the
# whole tree" so build output and vendored checkouts cannot join by
# accident — tools/kaya-swift-gen/.build alone carries 112 functions
# with "diagnos" in the name, none of them ours.
ROOTS=(swift crates bindings android guests tools cmd)

# The defect this gate was built from, and its repair. The self-test
# splices the FIRST one over the current body and requires a red.
PREFIX_REV=45e6fb8   # "refuse a file_choose that names nothing, and say why a panel is missing"
FIXED_REV=4f40e59    # the rewrite that made it answer in facts

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# $1: subcommand. audit ROOT... [--override REAL=DOCTORED ...]
#     splice PREFIX_FILE OUT | sole OUT
run_py() {
    python3 - "$@" <<'PY'
import os
import re
import sys

# ------------------------------------------------------------- lexing
# String and comment spans, so that neither brace counting nor the
# convention's name match can be fooled by a brace, a `func` or a
# `return` inside a message or a doc comment. A \(…) interpolation
# belongs to the literal that contains it: `joined(separator: "/")`
# inside one is part of that answer, not a second answer.
CONTINUE_TAIL = ("+", "-", "*", "/", "%", ",", "(", "[", "{", "?", ":",
                 "=", "&", "|", ".", "!", "<", ">")
CONTINUE_HEAD = ("+", "-", "*", "/", "%", ",", ")", "]", "}", "?", ":",
                 "=", "&", "|", ".")


def spans_of(text, path):
    spans = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "/" and text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            spans.append((i, j, "comment", False))
            i = j
            continue
        if c == "/" and text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            if depth:
                return None, f"{path}: unterminated /* comment at offset {i}"
            spans.append((i, j, "comment", False))
            i = j
            continue
        if c == "#" and re.match(r'#+"', text[i:]):
            hashes = len(text[i:]) - len(text[i:].lstrip("#"))
            close = '"' + "#" * hashes
            j = text.find(close, i + hashes + 1)
            if j < 0:
                return None, f"{path}: unterminated raw string at offset {i}"
            j += len(close)
            spans.append((i, j, "string", "\\" + "#" * hashes + "(" in text[i:j]))
            i = j
            continue
        if c == '"':
            multi = text.startswith('"""', i)
            quote = '"""' if multi else '"'
            j, interp = i + len(quote), False
            while True:
                if j >= n:
                    return None, f"{path}: unterminated string at offset {i}"
                if text[j] == "\\":
                    if text.startswith("\\(", j):
                        interp, depth, j = True, 1, j + 2
                        while j < n and depth:
                            if text[j] == "(":
                                depth += 1
                            elif text[j] == ")":
                                depth -= 1
                            elif text[j] == '"':
                                k = j + 1
                                while k < n and text[k] != '"':
                                    k += 2 if text[k] == "\\" else 1
                                j = k
                            j += 1
                        continue
                    j += 2
                    continue
                if text.startswith(quote, j):
                    j += len(quote)
                    break
                if not multi and text[j] == "\n":
                    return None, f"{path}: newline inside a string at offset {i}"
                j += 1
            spans.append((i, j, "string", interp))
            i = j
            continue
        i += 1
    return spans, None


def masked(text, spans):
    out = list(text)
    for start, end, _kind, _interp in spans:
        for k in range(start, end):
            if out[k] != "\n":
                out[k] = " "
    return "".join(out)


def close_brace(code, open_at):
    depth = 0
    for i in range(open_at, len(code)):
        if code[i] == "{":
            depth += 1
        elif code[i] == "}":
            depth -= 1
            if depth == 0:
                return i
    return -1


# The convention. A function whose name ENDS in any of these is a
# diagnostic; the prefix is optional, so a bare `whyNot()` counts too.
# Measured over swift/ crates/ bindings/ android/ guests/ tools/ cmd/
# on 2026-08-07: exactly one function in the tree matches, and widening
# the pattern this far adds no other hit — so the convention costs
# nothing today and catches the next one by its name alone.
NAME = r"(?:[A-Za-z_][A-Za-z0-9_]*)?(?:WhyNot|whyNot|why_not|Reason|reason)"
SWIFT_FUNC = re.compile(r"\bfunc\s+(" + NAME + r")\s*\(")
# Every other language's definition keyword, for the refusal below.
OTHER_FUNC = re.compile(r"\b(?:fun|fn|def|func|sub)\s+(" + NAME + r")\s*[(<]")
SWIFT_EXT = ".swift"
CODE_EXT = (".swift", ".rs", ".kt", ".kts", ".java", ".cs", ".go", ".py",
            ".ml", ".mli", ".hs", ".c", ".h", ".m")
SKIP_DIRS = {"target", "target-linux", "_build", "_build-linux", "build",
             ".build", ".git", ".gradle", "node_modules", "__pycache__",
             "dist-newstyle", "DerivedData", "obj", "bin", "third_party",
             "checkouts", "Pods"}


def find_func(code, name):
    """(sig_start, body_open, body_close) of a named Swift func."""
    m = re.search(r"\bfunc\s+" + re.escape(name) + r"\s*\(", code)
    if not m:
        return None
    open_at = code.find("{", m.end())
    if open_at < 0:
        return None
    end = close_brace(code, open_at)
    if end < 0:
        return None
    return m.start(), open_at, end


def answers(code, spans, body_start, body_end):
    """Each `return` in the body with the literals it can print.

    A clause's answers are the literals at paren depth 0 of the returned
    expression, so `"a " + "b"` is ONE answer in two pieces and a
    literal passed to a call is not an answer at all. The expression
    ends at a newline that neither continues nor is continued — the
    shape `return\\n  "x"\\n  + "y"` is written in the tree today.
    """
    out = []
    for m in re.finditer(r"\breturn\b", code[body_start:body_end]):
        start, depth, i = body_start + m.end(), 0, body_start + m.end()
        while i < body_end:
            c = code[i]
            if c in "([{":
                depth += 1
            elif c in ")]}":
                if depth == 0 and c == "}":
                    break
                depth -= 1
            elif c == "\n" and depth == 0:
                sofar = code[start:i].strip()
                nxt = next((ln.strip() for ln in code[i + 1:body_end].split("\n")
                            if ln.strip()), "")
                if sofar and not sofar.endswith(CONTINUE_TAIL) \
                        and not nxt.startswith(CONTINUE_HEAD):
                    break
            i += 1
        found, depth, pos = [], 0, start
        for s0, s1, kind, interp in spans:
            if s0 < start or s1 > i or kind != "string":
                continue
            for c in code[pos:s0]:
                if c in "([{":
                    depth += 1
                elif c in ")]}":
                    depth -= 1
            pos = s1
            if depth == 0:
                found.append((s0, s1, interp))
        if found:
            out.append((start, found))
    return out


def audit_text(path, text):
    """(findings, census) for one Swift source."""
    bad, census = [], []
    spans, err = spans_of(text, path)
    if err:
        return [err + " — this gate could not read the file, so it is not "
                      "reporting on it"], census
    code = masked(text, spans)

    def line(off):
        return text[:off].count("\n") + 1

    for m in SWIFT_FUNC.finditer(code):
        name = m.group(1)
        open_at = code.find("{", m.end())
        end = close_brace(code, open_at) if open_at >= 0 else -1
        if open_at < 0 or end < 0:
            bad.append(f"{path}:{line(m.start())}: {name}: this gate cannot find "
                       "the function body — the parse is wrong, fix the gate")
            continue
        cl = answers(code, spans, open_at + 1, end)
        prose = "String" in code[m.end():open_at]
        census.append((path, line(m.start()), name, len(cl),
                       sum(1 for _s, a in cl if any(x[2] for x in a))))
        if not cl:
            if prose:
                bad.append(
                    f"{path}:{line(m.start())}: {name} returns a String this gate "
                    "cannot see: no `return` in it carries a literal, so its "
                    "answers are built somewhere else and the sole-branch rule "
                    "cannot be checked. Write the answers as returns, or teach "
                    "tools/check-diagnostics.sh to follow this shape.")
            continue
        if len(cl) == 1:
            bad.append(
                f"{path}:{line(m.start())}: {name} has exactly ONE answer "
                f"({text[cl[0][1][0][0]:cl[0][1][0][1]][:70]}) — SOLE-ANSWER. "
                "It is consulted as a diagnosis but distinguishes nothing: "
                "every cause gets that sentence, and the reader believes it. "
                "Give it a clause per condition it can observe.")
        for idx, (_start, found) in enumerate(cl):
            if any(interp for _a, _b, interp in found) or idx == 0:
                continue
            first = text[found[0][0]:found[0][1]]
            bad.append(
                f"{path}:{line(found[0][0])}: {name} answer {idx + 1} of {len(cl)} "
                f"is FIXED PROSE: {first[:80]}… "
                "— it interpolates nothing, so it prints the same sentence for "
                "every state that reaches it, whatever the real cause was. "
                "Print what this branch MEASURED (the value it tested, the "
                "things it actually found), or delete the branch. The one fixed "
                "answer a diagnostic may keep is its FIRST — the early-out that "
                "fires before it has looked at anything. See docs/traps.md, "
                "\"The diagnostic that named a cause nobody had measured\".")
    return bad, census


def walk(roots):
    for r in roots:
        if os.path.isfile(r):
            yield r
            continue
        for dirpath, dirs, files in os.walk(r):
            dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
            for f in sorted(files):
                if os.path.splitext(f)[1] in CODE_EXT:
                    yield os.path.join(dirpath, f)


cmd, rest = sys.argv[1], sys.argv[2:]

if cmd == "audit":
    roots, override = [], {}
    for a in rest:
        if "=" in a and a.split("=", 1)[0].endswith(SWIFT_EXT):
            k, v = a.split("=", 1)
            override[os.path.normpath(k)] = v
        else:
            roots.append(a)
    bad, census = [], []
    for path in walk(roots):
        real = override.get(os.path.normpath(path), path)
        with open(real, encoding="utf-8") as fh:
            text = fh.read()
        if path.endswith(SWIFT_EXT):
            b, c = audit_text(path, text)
            bad += b
            census += c
            continue
        # Every other language: named, not read. Refuse loudly.
        for m in OTHER_FUNC.finditer(text):
            bad.append(
                f"{path}:{text[:m.start()].count(chr(10)) + 1}: {m.group(1)} is a "
                "diagnostic by the naming convention, but this gate reads Swift "
                "only, so nothing is checking it. Add this language to "
                "tools/check-diagnostics.sh (a lexer and an interpolation rule, "
                "~30 lines) — do not rename the function to hide from the gate.")
    for path, ln, name, n, measured in census:
        print(f"census {path}:{ln} {name} answers={n} measured={measured}")
    if not census:
        bad.append(
            "no diagnostic functions found at all under " + " ".join(roots) +
            " — this gate is now reading NOTHING. Either the convention "
            "(*WhyNot/*whyNot/*why_not/*Reason/*reason) moved, or the roots "
            "did. A gate that checks zero functions must not print OK.")
    for b in bad:
        print("check-diagnostics: " + b, file=sys.stderr)
    sys.exit(1 if bad else 0)

if cmd in ("splice", "sole"):
    # Both doctor a COPY OF THE REAL FILE, and both print what they
    # changed: a perturbation that did not apply is a failed self-test,
    # not a passed one.
    target = "swift/KayaSwiftUI.swift"
    name = "kayaOpenPanelWhyNot"
    with open(target, encoding="utf-8") as fh:
        text = fh.read()
    spans, err = spans_of(text, target)
    if err:
        sys.exit("check-diagnostics: self-test: " + err)
    here = find_func(masked(text, spans), name)
    if not here:
        sys.exit(f"check-diagnostics: self-test: no {name} in {target} — the "
                 "function this gate was built from is gone; re-point the "
                 "self-test at whatever replaced it, do not delete it")
    if cmd == "splice":
        src, out = rest[0], rest[1]
        with open(src, encoding="utf-8") as fh:
            old = fh.read()
        ospans, oerr = spans_of(old, src)
        if oerr:
            sys.exit("check-diagnostics: self-test: " + oerr)
        there = find_func(masked(old, ospans), name)
        if not there:
            sys.exit(f"check-diagnostics: self-test: no {name} in the "
                     "historical file")
        body = old[there[0]:there[2] + 1]
        new = text[:here[0]] + body + text[here[2] + 1:]
        note = (f"spliced the pre-fix body over the current one: "
                f"{here[2] + 1 - here[0]} bytes out, {len(body)} bytes in")
    else:
        body = ('func ' + name + '() -> String {\n'
                '        return "the panel could not be read"\n    }')
        new = text[:here[0]] + body + text[here[2] + 1:]
        note = (f"replaced the body with a single fixed answer: "
                f"{here[2] + 1 - here[0]} bytes out, {len(body)} bytes in")
        out = rest[0]
    if new == text:
        sys.exit("check-diagnostics: self-test: the perturbation changed "
                 "NOTHING — 0 substitutions is a failed self-test")
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(new)
    print(f"check-diagnostics: self-test: {note} (1 substitution)")
    sys.exit(0)

sys.exit(f"check-diagnostics: unknown subcommand {cmd!r}")
PY
}

# ---------------------------------------------------------------------
# THE SELF-TESTS, first, because a gate that has never been seen failing
# is not a guard. Both doctor a COPY of the real file — the pattern
# check-universal-props.sh uses — so what is proven is that the rule
# still bites on the source as it is actually written today.

if ! git show "$PREFIX_REV:swift/KayaSwiftUI.swift" >"$TMP/prefix.swift" 2>"$TMP/git.log"; then
    cat "$TMP/git.log" >&2
    echo "check-diagnostics: cannot read $PREFIX_REV from git — the self-test's" \
        "fixture is the real pre-fix body and there is no substitute. Fetch the" \
        "history (a shallow clone will not do) rather than skipping the test." >&2
    exit 1
fi

# 1. FIXED-PROSE, against the body that actually shipped the defect:
#    kayaOpenPanelWhyNot as of 45e6fb8, whose second arm printed a
#    fullscreen story with nothing measured in it.
if ! run_py splice "$TMP/prefix.swift" "$TMP/spliced.swift"; then
    echo "check-diagnostics: self-test: could not build the spliced copy" >&2
    exit 1
fi
if run_py audit swift "swift/KayaSwiftUI.swift=$TMP/spliced.swift" \
        >"$TMP/st1.out" 2>"$TMP/st1.err"; then
    echo "check-diagnostics: SELF-TEST FAILED — the pre-fix kayaOpenPanelWhyNot" \
        "body (from $PREFIX_REV, fixed in $FIXED_REV) PASSED this gate. The" \
        "sentence about a fullscreen application interpolates nothing and is" \
        "the shape this gate exists for; if it no longer trips FIXED-PROSE the" \
        "rule has stopped working." >&2
    exit 1
fi
if ! grep -q "kayaOpenPanelWhyNot answer 2 of 3 is FIXED PROSE" "$TMP/st1.err"; then
    echo "check-diagnostics: SELF-TEST FAILED — the spliced pre-fix body was" \
        "rejected, but NOT for being fixed prose in answer 2 of 3. A negative" \
        "test that fails for the wrong reason proves nothing. What it said:" >&2
    cat "$TMP/st1.err" >&2
    exit 1
fi

# 2. SOLE-ANSWER, against the same function reduced to one sentence —
#    the degenerate shape, which the pre-fix body was NOT (it had three
#    answers, one of them unreachable, which is why the count clause
#    alone could never have caught the real defect).
if ! run_py sole "$TMP/sole.swift"; then
    echo "check-diagnostics: self-test: could not build the one-answer copy" >&2
    exit 1
fi
if run_py audit swift "swift/KayaSwiftUI.swift=$TMP/sole.swift" \
        >"$TMP/st2.out" 2>"$TMP/st2.err"; then
    echo "check-diagnostics: SELF-TEST FAILED — a kayaOpenPanelWhyNot with one" \
        "single fixed answer PASSED this gate." >&2
    exit 1
fi
if ! grep -q "kayaOpenPanelWhyNot has exactly ONE answer" "$TMP/st2.err"; then
    echo "check-diagnostics: SELF-TEST FAILED — the one-answer copy was" \
        "rejected, but not for SOLE-ANSWER. What it said:" >&2
    cat "$TMP/st2.err" >&2
    exit 1
fi

echo "check-diagnostics: self-test: the pre-fix body ($PREFIX_REV) fails" \
    "FIXED-PROSE and a one-answer body fails SOLE-ANSWER"

# ---------------------------------------------------------------------
# The tree as it stands.
if ! run_py audit "${ROOTS[@]}" >"$TMP/census.out" 2>"$TMP/census.err"; then
    cat "$TMP/census.err" >&2
    echo "check-diagnostics: FAIL" >&2
    exit 1
fi
while IFS= read -r line; do
    echo "check-diagnostics: ${line#census }"
done <"$TMP/census.out"
echo "check-diagnostics: OK"
