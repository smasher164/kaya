#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# THE SOLE-BRANCH GATE. A DIAGNOSTIC MAY ONLY PRINT WHAT IT MEASURED
# (CLAUDE.md invariant 3; docs/traps.md, "The diagnostic that named a
# cause nobody had measured"). A sentence a why-not cannot NOT print is
# a sentence that will be chased for every cause it does not name.
#
# TWO CLAUSES.
#
#   SOLE-ANSWER   A diagnostic that can return exactly one string
#                 distinguishes nothing.
#   FIXED-PROSE   An answer that interpolates NOTHING is the same
#                 sentence for every state that reaches it. A
#                 diagnostic gets exactly ONE of those and it must be
#                 its first clause: the early-out, whose entire content
#                 is the guard it just tested. Every clause after it
#                 stands on the failure path and must print at least
#                 one value this process went and got.
#
# WHAT THIS GATE DOES NOT DO: it does not read English. A causal-claim
# regex was costed and REJECTED — over 220k lines its false-positive
# rate would mute the gate. It also cannot tell a measurement from a
# constant. What it enforces is the shape.
#
# HOW A NEW DIAGNOSTIC OPTS IN: by its NAME, with nothing to register.
# Any function ending in WhyNot, whyNot, why_not, Reason or reason is
# read as a diagnostic from the next run.
#
# TWO LANGUAGES, EACH WITH ITS OWN ANSWER RULE — Swift and Rust, where
# the tree's diagnostics are. An arm no source exercises rots, so a
# language joins when a diagnostic in it lands and not before; a
# diagnostic named in a language still unread FAILS this gate naming
# the extension point rather than being skipped. Same reason the census
# fails when EMPTY.
#
# WHAT AN ANSWER IS, IN SWIFT: the string literals at paren depth 0 of
# a `return` expression, interpolating when one carries a \(…).
#
# WHAT AN ANSWER IS, IN RUST — necessarily a different rule, because a
# Rust answer is `return format!("… {x} …")` and every literal sits one
# bracket down from where Swift's rule looks:
#
#   THE VALUE POSITIONS of a body are (1) every `return E`, (2) every
#   match arm `P => E`, and (3) the body's own tail expression. The
#   value of a BLOCK is whatever follows its last top-level `;`; a
#   block whose statements all end in `;` contributes nothing, its
#   `return`s having been counted by (1).
#
#   THE ANSWER LITERALS of a value position are the string literals at
#   bracket depth 0, plus those at depth 1 when the bracket belongs to
#   a prose builder — `format!`, `panic!`, `concat!`, `String::from`.
#   (`.to_owned()`/`.to_string()` need no rule: their literal is the
#   RECEIVER, already at depth 0.) Several literals in one position are
#   ONE answer in pieces.
#
#   INTERPOLATION is a format placeholder — a `{` that is not the `{{`
#   escape — in a format!/panic! format string. A `concat!` or
#   `String::from` argument is a constant however many braces it has.
#
# TAIL EXPRESSIONS ARE READ rather than a `return` demanded: demanding
# `return` would have been blind to exactly the arms that go to the
# filesystem. NOT read: an answer built by an if/else tail, a `?`
# chain, a helper, or a `write!` into a buffer. A prose-returning
# function whose answers are ALL invisible fails, naming what to
# write; one whose answers are PARTLY invisible is under-read in
# silence, which is why neither rule may be widened without a
# self-test that watches it bite.
#
# TRANSPORT IS NOT AUTHORSHIP, and the SHAPE says which is which — no
# name list, no exemption. `kaya_asset_why_not` and
# `ring_asset_why_not` match the naming convention and author no word:
# they return a `usize` and a `JByteArray`, and no value position in
# either carries a string literal. They are CENSUSED and raise
# nothing.

import os
import re
import subprocess

g = Gate("check-diagnostics")

# The source roots that can hold a diagnostic. Explicit rather than
# "the whole tree" so build output and vendored checkouts cannot join
# by accident — tools/kaya-swift-gen/.build alone carries 112 functions
# with "diagnos" in the name, none of them ours.
ROOTS = ["swift", "crates", "bindings", "android", "guests", "tools",
         "cmd"]

# The defect this gate was built from, and its repair. The self-test
# splices the FIRST one over the current body and requires a red.
PREFIX_REV = "45e6fb8"   # refuse a file_choose that names nothing
FIXED_REV = "4f40e59"    # the rewrite that made it answer in facts

# The Rust arm's subject: the core's asset diagnostic, whose sentence
# is the one every binding raises. Named once, here, so the two
# negatives below cannot drift onto two paths.
RUST_TARGET = "crates/kaya/src/assets.rs"

# ------------------------------------------------------------- lexing
# String and comment spans, so that neither brace counting nor the
# convention's name match can be fooled by a brace, a `func` or a
# `return` inside a message or a doc comment. A \(…) interpolation
# belongs to the literal that contains it: `joined(separator: "/")`
# inside one is part of that answer, not a second answer.
#
# ONE LEXER PER LANGUAGE, because the differences are not cosmetic: a
# Swift string may not contain a raw newline while a Rust one may,
# Rust spells its raw strings `r#"…"#` where Swift spells them
# `#"…"#`, and Rust has char literals that would derail a reader
# written for the other language. Both return the same span shape.
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
                return None, (f"{path}: unterminated /* comment at "
                              f"offset {i}")
            spans.append((i, j, "comment", False))
            i = j
            continue
        if c == "#" and re.match(r'#+"', text[i:]):
            hashes = len(text[i:]) - len(text[i:].lstrip("#"))
            close = '"' + "#" * hashes
            j = text.find(close, i + hashes + 1)
            if j < 0:
                return None, (f"{path}: unterminated raw string at "
                              f"offset {i}")
            j += len(close)
            spans.append((i, j, "string",
                          "\\" + "#" * hashes + "(" in text[i:j]))
            i = j
            continue
        if c == '"':
            multi = text.startswith('"""', i)
            quote = '"""' if multi else '"'
            j, interp = i + len(quote), False
            while True:
                if j >= n:
                    return None, (f"{path}: unterminated string at "
                                  f"offset {i}")
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
                    return None, (f"{path}: newline inside a string at "
                                  f"offset {i}")
                j += 1
            spans.append((i, j, "string", interp))
            i = j
            continue
        i += 1
    return spans, None


# Rust's lexer. `//` and `///` line comments, NESTED `/* */`, `"…"`
# with backslash escapes and raw newlines allowed (a `\` at end of line
# is Rust's line continuation and the escape rule eats it), the raw
# forms `r"…"` / `r#"…"#` / `r##"…"##` with their byte and c prefixes,
# and CHAR LITERALS, which are lexed only so they cannot derail the
# reader: `'"'` would otherwise open a string that never closes and
# `'{'` would be counted as a bracket. A `'` that is not a well-formed
# char literal is a lifetime (`&'static str`) and is left alone. Rust
# has no `\(…)` interpolation — placeholders live INSIDE the literal
# and are read later, by `placeholder()`.
IDENT = re.compile(r"[A-Za-z0-9_]")
RUST_RAW = re.compile(r'(?:b|c)?r(#*)"')
RUST_CHAR = re.compile(r"b?'(?:\\u\{[0-9a-fA-F_]+\}|\\.|[^'\\\n])'")


def rust_spans_of(text, path):
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
                return None, (f"{path}: unterminated /* comment at "
                              f"offset {i}")
            spans.append((i, j, "comment", False))
            i = j
            continue
        # A prefix only counts at the START of a token: an identifier
        # that happens to end in `r` or `b` is not a raw string's, and
        # `r#type` is a raw IDENTIFIER, which the `"` this pattern
        # requires already excludes.
        fresh = i == 0 or not IDENT.match(text[i - 1])
        m = RUST_RAW.match(text, i) if fresh else None
        if m:
            close = '"' + "#" * len(m.group(1))
            j = text.find(close, m.end())
            if j < 0:
                return None, (f"{path}: unterminated raw string at "
                              f"offset {i}")
            spans.append((i, j + len(close), "string", False))
            i = j + len(close)
            continue
        if c == '"':
            j = i + 1
            while True:
                if j >= n:
                    return None, (f"{path}: unterminated string at "
                                  f"offset {i}")
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"':
                    j += 1
                    break
                j += 1
            spans.append((i, j, "string", False))
            i = j
            continue
        m = RUST_CHAR.match(text, i) if fresh else None
        if m:
            spans.append((i, m.end(), "char", False))
            i = m.end()
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


def close_paren(code, open_at):
    depth = 0
    for i in range(open_at, len(code)):
        if code[i] == "(":
            depth += 1
        elif code[i] == ")":
            depth -= 1
            if depth == 0:
                return i
    return -1


# The convention. A function whose name ENDS in any of these is a
# diagnostic; the prefix is optional, so a bare `whyNot()` counts too.
NAME = (r"(?:[A-Za-z_][A-Za-z0-9_]*)?"
        r"(?:WhyNot|whyNot|why_not|Reason|reason)")
SWIFT_FUNC = re.compile(r"\bfunc\s+(" + NAME + r")\s*\(")
# The name is followed by `(` or `<` — a generic parameter list comes
# first on a JNI entry (`fn ring_asset_why_not<'a>(…)`) — and the
# lookahead leaves the match end sitting on it, where rust_body starts.
RUST_FN = re.compile(r"\bfn\s+(" + NAME + r")\s*(?=[(<])")
# Every STILL-UNREAD language's definition keyword, for the refusal
# below. `fn` came off this list when the Rust arm landed: Rust is read
# now, and a pattern kept for a language nothing can reach is the
# vacuous guard this repo has been bitten by twice.
OTHER_FUNC = re.compile(r"\b(?:fun|def|func|sub)\s+(" + NAME + r")\s*[(<]")
SWIFT_EXT = ".swift"
RUST_EXT = ".rs"
# The extensions with a clause analysis behind them. Everything else in
# CODE_EXT gets the refusal, and an override may only redirect a file
# this gate actually reads.
READ_EXT = (SWIFT_EXT, RUST_EXT)
CODE_EXT = (".swift", ".rs", ".kt", ".kts", ".java", ".cs", ".go",
            ".py", ".ml", ".mli", ".hs", ".c", ".h", ".m")
# "assets" joined 2026-08-28: an assets directory holds packaged
# payload, not source — the android python suite stages CPython's own
# stdlib under android/pyhost/src/main/assets/python (gitignored), and
# urllib.error's `reason` property is not a kaya diagnostic.
SKIP_DIRS = {"target", "target-linux", "_build", "_build-linux",
             "build", ".build", ".git", ".gradle", "node_modules",
             "__pycache__", "dist-newstyle", "DerivedData", "obj",
             "bin", "third_party", "checkouts", "Pods", "assets"}


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

    A clause's answers are the literals at paren depth 0 of the
    returned expression, so `"a " + "b"` is ONE answer in two pieces
    and a literal passed to a call is not an answer at all. The
    expression ends at a newline that neither continues nor is
    continued — the shape `return\\n  "x"\\n  + "y"` is written in the
    tree today.
    """
    out = []
    for m in re.finditer(r"\breturn\b", code[body_start:body_end]):
        start = body_start + m.end()
        depth, i = 0, body_start + m.end()
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
                nxt = next((ln.strip()
                            for ln in code[i + 1:body_end].split("\n")
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


# ------------------------------------------------------ the rust rule
# The header states this rule in prose; what follows is the same thing
# in code. FMT builders can interpolate, PROSE builders cannot: their
# argument is a constant, braces and all.
FMT_CALLEE = re.compile(r"(?:\bformat!|\bpanic!)\s*$")
PROSE_CALLEE = re.compile(r"(?:\bconcat!|\bString::from)\s*$")


def block_value(code, open_at, close_at):
    """A Rust block's value: what follows its last top-level `;`.

    None when every statement ends in `;` — such a block evaluates to
    `()`, has no answer of its own, and its `return`s are counted
    where every other `return` is.
    """
    depth, last = 0, open_at
    for i in range(open_at + 1, close_at):
        c = code[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == ";" and depth == 0:
            last = i
    if not code[last + 1:close_at].strip():
        return None
    return last + 1, close_at


def expr_end(code, start, stop, terminator):
    """Where an expression ends: its terminator at depth 0, or the
    bracket that closes the construct around it. No newline heuristic
    is needed the way Swift's rule needs one — Rust punctuates."""
    i, depth = start, 0
    while i < stop:
        c = code[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                break
            depth -= 1
        elif c == terminator and depth == 0:
            break
        i += 1
    return i


def rust_sites(code, spans, body_start, body_end):
    """Every VALUE POSITION in a Rust fn body, as (start, end)."""
    # Where a literal or char begins. The masked code writes SPACES
    # over both, so "skip the whitespace after `=>` and look for a
    # block" steps straight over `=> "third".to_owned()` and reads the
    # answer as `.to_owned()`, with no literal in it.
    lit = {s0 for s0, _s1, kind, _i in spans
           if kind in ("string", "char")}
    sites = []
    for m in re.finditer(r"\breturn\b", code[body_start:body_end]):
        s = body_start + m.end()
        sites.append((s, expr_end(code, s, body_end, ";")))
    for m in re.finditer(r"=>", code[body_start:body_end]):
        s = body_start + m.end()
        j = s
        while j < body_end and code[j].isspace() and j not in lit:
            j += 1
        if j < body_end and code[j] == "{" and j not in lit:
            close = close_brace(code, j)
            if close < 0 or close >= body_end:
                continue
            tail = block_value(code, j, close)
            if tail:
                sites.append(tail)
            continue
        sites.append((s, expr_end(code, s, body_end, ",")))
    tail = block_value(code, body_start - 1, body_end)
    if tail:
        sites.append(tail)
    return sorted(set(sites))


def site_literals(code, spans, start, end):
    """One value position's literals, with whether each MAY
    interpolate.

    Depth 0 always; depth 1 when the bracket that opened it belongs to
    a prose builder. A literal handed to anything else — `.expect(…)`,
    `push_str(…)`, a comparison — is not this function's answer.
    """
    strings = [s for s in spans
               if s[2] == "string" and s[0] >= start and s[1] <= end]
    found, stack, si, i = [], [], 0, start
    while i < end:
        if si < len(strings) and i == strings[si][0]:
            s0, s1, _k, _x = strings[si]
            if not stack:
                found.append((s0, s1, False))
            elif len(stack) == 1 and stack[0]:
                found.append((s0, s1, stack[0] == "fmt"))
            si += 1
            i = s1
            continue
        c = code[i]
        if c in "([{":
            before = code[max(0, i - 60):i]
            stack.append("fmt" if FMT_CALLEE.search(before) else
                         ("prose" if PROSE_CALLEE.search(before)
                          else None))
        elif c in ")]}":
            if stack:
                stack.pop()
        i += 1
    return found


def placeholder(lit):
    """A format placeholder: a `{` that is not the `{{` escape. `{}`,
    `{name}` and `{shown:?}` are all this function went and got a
    value; `{{` is a printed brace and measures nothing."""
    i = 0
    while i < len(lit):
        if lit[i] == "{":
            if lit[i + 1:i + 2] == "{":
                i += 2
                continue
            return True
        if lit[i] == "}" and lit[i + 1:i + 2] == "}":
            i += 2
            continue
        i += 1
    return False


def rust_answers(code, spans, text, body_start, body_end):
    """Each value position that carries literals, with what it
    prints."""
    out = []
    for s, e in rust_sites(code, spans, body_start, body_end):
        found = [(s0, s1, may and placeholder(text[s0:s1]))
                 for s0, s1, may in site_literals(code, spans, s, e)]
        if found:
            out.append((s, found))
    return out


def rust_body(code, at):
    """(kind, body_open, body_close, return_type) for a Rust fn.

    `at` sits on the `(` or `<` after the name. The argument list is
    matched first so that a `{` in a return type or a where clause
    cannot be mistaken for the body, and so that a bound with parens in
    it (`F: Fn(u8)`) costs nothing. A `;` before any `{` is a signature
    with no body — a trait method — whose answers live in the impls,
    each of which this gate reads on its own.
    """
    par = code.find("(", at)
    if par < 0:
        return "broken", -1, -1, ""
    close = close_paren(code, par)
    if close < 0:
        return "broken", -1, -1, ""
    open_at = code.find("{", close)
    semi = code.find(";", close)
    if open_at < 0 or 0 <= semi < open_at:
        return "decl", -1, -1, ""
    end = close_brace(code, open_at)
    if end < 0:
        return "broken", -1, -1, ""
    return "body", open_at, end, code[close + 1:open_at]


def find_rust_fn(code, name):
    """(sig_start, body_open, body_close) of a named Rust fn."""
    m = re.search(r"\bfn\s+" + re.escape(name) + r"\s*(?=[(<])", code)
    if not m:
        return None
    kind, open_at, end, _ret = rust_body(code, m.end())
    if kind != "body":
        return None
    return m.start(), open_at, end


# ---------------------------------------------------------- the rules
# ONE REPORTER, TWO FRONT ENDS: SOLE-ANSWER and FIXED-PROSE are stated
# once, so the two languages cannot drift into enforcing two different
# rules. A front end says only what a function's answers are in its
# language, and what to print when it can see none of them.
def report(path, text, line, name, cl, prose, cannot_see):
    bad = []
    census = (path, line, name, len(cl),
              sum(1 for _s, a in cl if any(x[2] for x in a)))
    if not cl:
        if prose:
            bad.append(cannot_see)
        return bad, census
    if len(cl) == 1:
        bad.append(
            f"{path}:{line}: {name} has exactly ONE answer "
            f"({text[cl[0][1][0][0]:cl[0][1][0][1]][:70]}) — "
            "SOLE-ANSWER. It is consulted as a diagnosis but "
            "distinguishes nothing: every cause gets that sentence, "
            "and the reader believes it. Give it a clause per "
            "condition it can observe.")
    for idx, (_start, found) in enumerate(cl):
        if any(interp for _a, _b, interp in found) or idx == 0:
            continue
        first = text[found[0][0]:found[0][1]]
        bad.append(
            f"{path}:{text[:found[0][0]].count(chr(10)) + 1}: {name} "
            f"answer {idx + 1} of {len(cl)} "
            f"is FIXED PROSE: {first[:80]}… "
            "— it interpolates nothing, so it prints the same sentence "
            "for every state that reaches it, whatever the real cause "
            "was. Print what this branch MEASURED (the value it "
            "tested, the things it actually found), or delete the "
            "branch. The one fixed answer a diagnostic may keep is its "
            "FIRST — the early-out that fires before it has looked at "
            "anything. See docs/traps.md, \"The diagnostic that named "
            "a cause nobody had measured\".")
    return bad, census


def audit_swift(path, text):
    """(findings, census) for one Swift source."""
    bad, census = [], []
    spans, err = spans_of(text, path)
    if err:
        return [err + " — this gate could not read the file, so it is "
                      "not reporting on it"], census
    code = masked(text, spans)

    def line(off):
        return text[:off].count("\n") + 1

    for m in SWIFT_FUNC.finditer(code):
        name = m.group(1)
        open_at = code.find("{", m.end())
        end = close_brace(code, open_at) if open_at >= 0 else -1
        if open_at < 0 or end < 0:
            bad.append(f"{path}:{line(m.start())}: {name}: this gate "
                       f"cannot find the function body — the parse is "
                       f"wrong, fix the gate")
            continue
        b, c = report(
            path, text, line(m.start()), name,
            answers(code, spans, open_at + 1, end),
            "String" in code[m.end():open_at],
            f"{path}:{line(m.start())}: {name} returns a String this "
            "gate cannot see: no `return` in it carries a literal, so "
            "its answers are built somewhere else and the sole-branch "
            "rule cannot be checked. Write the answers as returns, or "
            "teach tools/check-diagnostics.sh to follow this shape.")
        bad += b
        census.append(c)
    return bad, census


def audit_rust(path, text):
    """(findings, census) for one Rust source."""
    bad, census = [], []
    spans, err = rust_spans_of(text, path)
    if err:
        return [err + " — this gate could not read the file, so it is "
                      "not reporting on it"], census
    code = masked(text, spans)

    def line(off):
        return text[:off].count("\n") + 1

    for m in RUST_FN.finditer(code):
        name = m.group(1)
        kind, open_at, end, ret = rust_body(code, m.end())
        if kind == "decl":
            continue
        if kind == "broken":
            bad.append(f"{path}:{line(m.start())}: {name}: this gate "
                       f"cannot find the function body — the parse is "
                       f"wrong, fix the gate")
            continue
        # PROSE IS THE RETURN TYPE, read after the argument list so a
        # `-> String` inside a closure parameter cannot claim to be
        # one. This is the transport rule from the header: no String,
        # no str, no Cow, no sentence to believe.
        b, c = report(
            path, text, line(m.start()), name,
            rust_answers(code, spans, text, open_at + 1, end),
            bool(re.search(r"\bString\b|\bstr\b|\bCow\b", ret)),
            f"{path}:{line(m.start())}: {name} returns prose this gate "
            "cannot see: no `return`, no match arm and no tail "
            "expression in it carries a string literal, so its answers "
            "are built somewhere else and the sole-branch rule cannot "
            "be checked. Write each answer as `return format!(…)`, or "
            "as the value of a match arm (a format!/panic!/concat!/"
            "String::from, or a literal with `.to_owned()` on it), or "
            "teach tools/check-diagnostics.sh to follow this shape.")
        bad += b
        census.append(c)
    return bad, census


def code_files(roots):
    for r in roots:
        base = ROOT / r
        if base.is_file():
            yield r
            continue
        for dirpath, dirs, files in os.walk(base):
            dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
            for f in sorted(files):
                if os.path.splitext(f)[1] in CODE_EXT:
                    yield str((pathlib.Path(dirpath) / f)
                              .relative_to(ROOT))


def audit(roots, override=None):
    """(findings, census lines) over the given roots, with any path in
    `override` read from its doctored copy instead."""
    override = override or {}
    bad, census = [], []
    for path in code_files(roots):
        real = override.get(os.path.normpath(path), ROOT / path)
        text = pathlib.Path(real).read_text(encoding="utf-8")
        if path.endswith(SWIFT_EXT):
            b, c = audit_swift(path, text)
            bad += b
            census += c
            continue
        if path.endswith(RUST_EXT):
            b, c = audit_rust(path, text)
            bad += b
            census += c
            continue
        # Every language with no clause analysis yet: named, not read.
        # Refuse loudly.
        for m in OTHER_FUNC.finditer(text):
            bad.append(
                f"{path}:{text[:m.start()].count(chr(10)) + 1}: "
                f"{m.group(1)} is a diagnostic by the naming "
                f"convention, but this gate reads Swift and Rust only, "
                f"so nothing is checking it. Add this language to "
                f"tools/check-diagnostics.sh (a lexer and an "
                f"interpolation rule, ~30 lines) — do not rename the "
                f"function to hide from the gate.")
    if not census:
        bad.append(
            "no diagnostic functions found at all under "
            + " ".join(roots)
            + " — this gate is now reading NOTHING. Either the "
              "convention (*WhyNot/*whyNot/*why_not/*Reason/*reason) "
              "moved, or the roots did. A gate that checks zero "
              "functions must not print OK.")
    return bad, census


# ---------------------------------------------------------------------
# THE SELF-TESTS, first, because a gate that has never been seen
# failing is not a guard. Every perturbation goes to a COPY of the real
# file, located by PARSING, never by offset — this tree moves.
T = g.scratch()
SWIFT_TARGET = "swift/KayaSwiftUI.swift"
SWIFT_NAME = "kayaOpenPanelWhyNot"

show = subprocess.run(["git", "show",
                       f"{PREFIX_REV}:{SWIFT_TARGET}"], cwd=ROOT,
                      capture_output=True, check=False)
if show.returncode != 0:
    print(show.stderr.decode("utf-8", errors="replace"),
          file=sys.stderr)
    print(f"check-diagnostics: cannot read {PREFIX_REV} from git — the "
          f"self-test's fixture is the real pre-fix body and there is "
          f"no substitute. Fetch the history (a shallow clone will not "
          f"do) rather than skipping the test.", file=sys.stderr)
    raise SystemExit(1)
prefix_text = show.stdout.decode("utf-8")

swift_text = (ROOT / SWIFT_TARGET).read_text(encoding="utf-8")
swift_spans, err = spans_of(swift_text, SWIFT_TARGET)
if err:
    g.refuse("self-test: " + err)
here = find_func(masked(swift_text, swift_spans), SWIFT_NAME)
if not here:
    g.refuse(f"self-test: no {SWIFT_NAME} in {SWIFT_TARGET} — the "
             f"function this gate was built from is gone; re-point the "
             f"self-test at whatever replaced it, do not delete it")


def perturbed_copy(new_text, out_name, note):
    if new_text == swift_text:
        g.refuse("self-test: the perturbation changed NOTHING — 0 "
                 "substitutions is a failed self-test")
    out = T / out_name
    out.write_text(new_text, encoding="utf-8")
    print(f"check-diagnostics: self-test: {note} (1 substitution)")
    return out


# 1. FIXED-PROSE, against the body that actually shipped the defect:
#    kayaOpenPanelWhyNot as of 45e6fb8, whose second arm printed a
#    fullscreen story with nothing measured in it.
old_spans, oerr = spans_of(prefix_text, PREFIX_REV)
if oerr:
    g.refuse("self-test: " + oerr)
there = find_func(masked(prefix_text, old_spans), SWIFT_NAME)
if not there:
    g.refuse(f"self-test: no {SWIFT_NAME} in the historical file")
spliced_body = prefix_text[there[0]:there[2] + 1]
spliced = perturbed_copy(
    swift_text[:here[0]] + spliced_body + swift_text[here[2] + 1:],
    "spliced.swift",
    f"spliced the pre-fix body over the current one: "
    f"{here[2] + 1 - here[0]} bytes out, {len(spliced_body)} bytes in")
bad1, _ = audit(["swift"],
                {os.path.normpath(SWIFT_TARGET): spliced})
if not bad1:
    print(f"check-diagnostics: SELF-TEST FAILED — the pre-fix "
          f"{SWIFT_NAME} body (from {PREFIX_REV}, fixed in "
          f"{FIXED_REV}) PASSED this gate. The sentence about a "
          f"fullscreen application interpolates nothing and is the "
          f"shape this gate exists for; if it no longer trips "
          f"FIXED-PROSE the rule has stopped working.", file=sys.stderr)
    raise SystemExit(1)
if not any(f"{SWIFT_NAME} answer 2 of 3 is FIXED PROSE" in b
           for b in bad1):
    print("check-diagnostics: SELF-TEST FAILED — the spliced pre-fix "
          "body was rejected, but NOT for being fixed prose in answer "
          "2 of 3. A negative test that fails for the wrong reason "
          "proves nothing. What it said:", file=sys.stderr)
    print("\n".join(bad1), file=sys.stderr)
    raise SystemExit(1)

# 2. SOLE-ANSWER, against the same function reduced to one sentence —
#    the degenerate shape, which the pre-fix body was NOT (it had three
#    answers, one of them unreachable, which is why the count clause
#    alone could never have caught the real defect).
sole_body = ("func " + SWIFT_NAME + "() -> String {\n"
             '        return "the panel could not be read"\n    }')
sole = perturbed_copy(
    swift_text[:here[0]] + sole_body + swift_text[here[2] + 1:],
    "sole.swift",
    f"replaced the body with a single fixed answer: "
    f"{here[2] + 1 - here[0]} bytes out, {len(sole_body)} bytes in")
bad2, _ = audit(["swift"], {os.path.normpath(SWIFT_TARGET): sole})
if not bad2:
    print(f"check-diagnostics: SELF-TEST FAILED — a {SWIFT_NAME} with "
          f"one single fixed answer PASSED this gate.", file=sys.stderr)
    raise SystemExit(1)
if not any(f"{SWIFT_NAME} has exactly ONE answer" in b for b in bad2):
    print("check-diagnostics: SELF-TEST FAILED — the one-answer copy "
          "was rejected, but not for SOLE-ANSWER. What it said:",
          file=sys.stderr)
    print("\n".join(bad2), file=sys.stderr)
    raise SystemExit(1)

# 3 and 4. THE SAME TWO CLAUSES, ON THE RUST ARM. The Rust front end
#    finds its answers by a completely different route, so nothing the
#    Swift pair proves carries over. Both perturbations go to a COPY,
#    through the same override; the real file is never written.
RUST_NAME = "asset_why_not"
rust_text = (ROOT / RUST_TARGET).read_text(encoding="utf-8")
rust_spans, rerr = rust_spans_of(rust_text, RUST_TARGET)
if rerr:
    g.refuse("self-test: " + rerr)
rust_code = masked(rust_text, rust_spans)
rust_here = find_rust_fn(rust_code, RUST_NAME)
if not rust_here:
    g.refuse(f"self-test: no {RUST_NAME} in {RUST_TARGET} — the "
             f"function the Rust arm was built for is gone; re-point "
             f"the self-test at whatever replaced it, do not delete it")

rust_sole_body = ("fn " + RUST_NAME + "(name: &str) -> String {\n"
                  "    let _ = name;\n"
                  '    return format!("the asset could not be read");'
                  "\n}")
rust_sole_text = (rust_text[:rust_here[0]] + rust_sole_body
                  + rust_text[rust_here[2] + 1:])
if rust_sole_text == rust_text:
    g.refuse("self-test: the perturbation changed NOTHING — 0 "
             "substitutions is a failed self-test")
rust_sole = T / "sole.rs"
rust_sole.write_text(rust_sole_text, encoding="utf-8")
print(f"check-diagnostics: self-test: replaced the body with a single "
      f"answer: {rust_here[2] + 1 - rust_here[0]} bytes out, "
      f"{len(rust_sole_body)} bytes in (1 substitution)")
bad3, _ = audit([RUST_TARGET],
                {os.path.normpath(RUST_TARGET): rust_sole})
if not bad3:
    print(f"check-diagnostics: SELF-TEST FAILED — an {RUST_NAME} "
          f"reduced to one single answer PASSED this gate. SOLE-ANSWER "
          f"is not biting in Rust, so the core's diagnostic — the one "
          f"sentence nine bindings raise — is held to nothing.",
          file=sys.stderr)
    raise SystemExit(1)
if not any(f"{RUST_NAME} has exactly ONE answer" in b for b in bad3):
    print("check-diagnostics: SELF-TEST FAILED — the one-answer rust "
          "copy was rejected, but not for SOLE-ANSWER. A negative test "
          "that fails for the wrong reason proves nothing. What it "
          "said:", file=sys.stderr)
    print("\n".join(bad3), file=sys.stderr)
    raise SystemExit(1)

# FIXED-PROSE: the SECOND answer made to interpolate nothing, the
# second because the first is the early-out the rule allows. Which
# answer that is is asked of the gate's own reader, so the perturbation
# lands on the right clause however the file moves.
cl = rust_answers(rust_code, rust_spans, rust_text, rust_here[1] + 1,
                  rust_here[2])
if len(cl) < 2:
    g.refuse(f"self-test: {RUST_NAME} has {len(cl)} answers, so there "
             f"is no SECOND one to perturb — either the function "
             f"collapsed (which the tree audit below will say in its "
             f"own words) or this gate stopped reading it")
pieces = cl[1][1]
fixed = '"that asset name cannot be used"'
rust_prose_text = (rust_text[:pieces[0][0]] + fixed
                   + rust_text[pieces[-1][1]:])
if rust_prose_text == rust_text:
    g.refuse("self-test: the perturbation changed NOTHING — 0 "
             "substitutions is a failed self-test")
rust_prose = T / "prose.rs"
rust_prose.write_text(rust_prose_text, encoding="utf-8")
print(f"check-diagnostics: self-test: answer 2 of {len(cl)} rewritten "
      f"to interpolate nothing: {pieces[-1][1] - pieces[0][0]} bytes "
      f"out, {len(fixed)} bytes in (1 substitution)")
bad4, _ = audit([RUST_TARGET],
                {os.path.normpath(RUST_TARGET): rust_prose})
if not bad4:
    print(f"check-diagnostics: SELF-TEST FAILED — an {RUST_NAME} whose "
          f"SECOND answer interpolates nothing PASSED this gate. That "
          f"is the shape the whole file exists for: a sentence printed "
          f"for every state that reaches it, believed by the next "
          f"reader.", file=sys.stderr)
    raise SystemExit(1)
if not any(f"{RUST_NAME} answer 2 of " in b for b in bad4):
    print("check-diagnostics: SELF-TEST FAILED — the fixed-prose rust "
          "copy was rejected, but NOT for being fixed prose in its "
          "second answer. What it said:", file=sys.stderr)
    print("\n".join(bad4), file=sys.stderr)
    raise SystemExit(1)

print(f"check-diagnostics: self-test: the pre-fix body ({PREFIX_REV}) "
      f"fails FIXED-PROSE and a one-answer body fails SOLE-ANSWER, in "
      f"Swift; a one-answer {RUST_TARGET} fails SOLE-ANSWER and a "
      f"fixed second answer fails FIXED-PROSE, in Rust")

# ---------------------------------------------------------------------
# The tree as it stands. THE CENSUS PRINTS ON BOTH PATHS: the first
# question a refusal raises is what this gate actually read, and a gate
# reporting a failure may only print what it measured.
g.counted("code files under the roots",
          sum(1 for _ in code_files(ROOTS)), floor=200)
bad, census = audit(ROOTS)
for path, ln, name, n, measured in census:
    print(f"check-diagnostics: {path}:{ln} {name} answers={n} "
          f"measured={measured}")
if bad:
    for b in bad:
        print("check-diagnostics: " + b, file=sys.stderr)
    print("check-diagnostics: FAIL", file=sys.stderr)
    raise SystemExit(1)
g.verdict()
