#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# The sugar-surface guard: every widget kind in the spec must have a
# live-zone constructor in every binding's layer 3. The generator emits
# only the taste-free wire vocabulary; the constructors are
# hand-written per language — this check is what makes forgetting one
# structural rather than a matter of memory. Kinds come from the
# GENERATED python wire file, so the list tracks the spec by
# construction.
#
# Matching is by each binding's naming convention, prefix-loose so a
# language's flavor counts (Haskell's checkboxOn matches "checkbox",
# Go's Checkbox matches "checkbox"). C is exempt: it is the function
# floor on purpose.
#
# AND THE GUARD RUNS IN BOTH DIRECTIONS. Everything until the last
# clause is about what a BINDING OFFERS; the SCENE-TIER clause at the
# end is about what the EXAMPLES USE (invariant 5).

import atexit
import io
import os
import re
import shutil
import subprocess
import tempfile

os.chdir(ROOT)

# Line-buffered stdout: the probes below shell out (tpl-surfaces, ghc,
# git) and block-buffered prints would land AFTER output they preceded.
sys.stdout.reconfigure(line_buffering=True)

status = 0

_TEXT_CACHE = {}


def read_rel(rel):
    if rel not in _TEXT_CACHE:
        _TEXT_CACHE[rel] = (ROOT / rel).read_text(encoding="utf-8")
    return _TEXT_CACHE[rel]


def grep_e(pattern, text):
    """grep -qE: the pattern searched per line, so ^ and $ anchor at
    line boundaries (re.M) and the POSIX class the shell patterns carry
    becomes python's spelling."""
    return re.search(pattern.replace("[[:space:]]", "[ \\t]"), text,
                     re.M) is not None


def grep_file(pattern, rel):
    try:
        return grep_e(pattern, read_rel(rel))
    except OSError:
        return False


def sub_count(pattern, repl, text, flags=0):
    """re.sub with the number of applications (rule 6 routes re.subn
    through the prelude's doctor; these probes print their counts in
    their own historical words)."""
    n = 0

    def _apply(m):
        nonlocal n
        n += 1
        return m.expand(repl)

    return re.sub(pattern, _apply, text, flags=flags), n


def selftest_exit(msg):
    print(msg)
    raise SystemExit(1)


kinds = [m[5:].lower() for m in
         re.findall(r"^KIND_[A-Z_]+", read_rel("bindings/python/kaya/"
                                               "wire.py"), re.M)]
if not kinds:
    selftest_exit("check-sugar-surface: no kinds found in the "
                  "generated wire file")


def check(lang, rel, kind, pattern, findings=None):
    """One live-zone constructor pattern; `findings` collects instead
    of printing when a self-test drives it."""
    global status
    if not grep_file(pattern, rel):
        msg = (f"check-sugar-surface: {lang} has no live-zone "
               f"constructor for '{kind}' (wanted /{pattern}/ in {rel})")
        if findings is None:
            print(msg)
            status = 1
        else:
            findings.append(msg)


def check_kind(kind, findings=None):
    pascal = kind[:1].upper() + kind[1:]
    check("rust", "crates/kaya/src/app.rs", kind,
          f"pub fn {kind}[a-z_]*(<[^>]*>)?\\(", findings)
    check("python", "bindings/python/kaya/__init__.py", kind,
          f"^def {kind}[a-z_]*\\(", findings)
    check("go", "bindings/go/app.go", kind,
          f"func \\(tx \\*Tx\\) {pascal}[A-Za-z]*\\(", findings)
    check("csharp", "bindings/csharp/KayaApp.cs", kind,
          f"public Widget {pascal}[A-Za-z]*\\(", findings)
    check("java", "bindings/java/dev/kaya/KayaApp.java", kind,
          f"public Widget {kind}[A-Za-z]*\\(", findings)
    check("swift", "bindings/swift/KayaApp.swift", kind,
          f"func {kind}[A-Za-z]*\\(", findings)
    # Leading whitespace allowed: row/column are Declare-class methods.
    check("haskell", "bindings/haskell/KayaApp.hs", kind,
          f"^[[:space:]]*{kind}[A-Za-z]* ::", findings)
    check("ocaml", "bindings/ocaml/kaya_app.ml", kind,
          f"^let {kind}[a-z_]* ", findings)
    # Every kind is one lowercase word, so JS's camelCase IS the kind.
    check("js", "bindings/js/kaya/index.ts", kind,
          f"^export function {kind}[A-Za-z]*\\(", findings)


# --- THE TEXT-RANGE SURFACE, in all nine --------------------------
#
# The three primitives (docs/ranges-plan.md D1) plus `set_text`. This
# file's other sweeps cover widget CONSTRUCTORS and WINDOW props, and a
# widget-level verb is neither, so nothing else would demand these of
# the eight non-Rust bindings.
#
# RED BY DESIGN until the sweep lands (CLAUDE.md, sequencing).
def want_verb(lang, rel, verb, pattern, findings=None):
    global status
    if not grep_file(pattern, rel):
        msg = (f"check-sugar-surface: {lang} has no sugar for the "
               f"'{verb}' widget verb (wanted /{pattern}/ in {rel})")
        if findings is None:
            print(msg)
            status = 1
        else:
            findings.append(msg)


def check_range_verb(snake, pascal, camel, findings=None):
    want_verb("rust", "crates/kaya/src/app.rs", snake,
              f"pub fn {snake}\\(", findings)
    # THE AMBIENT BINDINGS PUT WIDGET-ADDRESSED VERBS ON THE HANDLE,
    # which is why python's pattern is keyed on `(self` and JS's on the
    # class-member indent where the other seven are keyed on a
    # transaction method taking a widget: an ambient transaction has no
    # handle to hang one on. The file's other handle-verb clauses
    # (a11y_id, accepts, on_paste) are keyed the same way for that
    # reason.
    want_verb("python", "bindings/python/kaya/__init__.py", snake,
              f"def {snake}\\(self", findings)
    want_verb("go", "bindings/go/app.go", snake,
              f"func \\(tx \\*Tx\\) {pascal}\\(", findings)
    want_verb("csharp", "bindings/csharp/KayaApp.cs", snake,
              f"public void {pascal}\\(", findings)
    want_verb("java", "bindings/java/dev/kaya/KayaApp.java", snake,
              f"public void {camel}\\(", findings)
    want_verb("swift", "bindings/swift/KayaApp.swift", snake,
              f"func {camel}\\(", findings)
    want_verb("haskell", "bindings/haskell/KayaApp.hs", snake,
              f"^[[:space:]]*{camel} ::", findings)
    want_verb("ocaml", "bindings/ocaml/kaya_app.ml", snake,
              f"^let {snake} ", findings)
    # JS IS PYTHON'S AMBIENT TWIN, so a widget-addressed one-shot is a
    # method on the handle here too, keyed on the class-member indent.
    want_verb("js", "bindings/js/kaya/index.ts", snake,
              f"^  {camel}\\(", findings)


check_range_verb("highlight_ranges", "HighlightRanges",
                 "highlightRanges")
check_range_verb("select_range", "SelectRange", "selectRange")
check_range_verb("reveal_range", "RevealRange", "revealRange")
check_range_verb("set_text", "SetText", "setText")

# THE BUILT-IN NEGATIVE TEST FOR THIS SWEEP, the same shape as the
# fake-kind one below: a verb that exists in no binding must fail in
# all nine, or the nine patterns have rotted into a rule that can
# only pass. Collected instead of printed, so the fake's failures die
# with the list (the shell ran it in a subshell for the same reason).
fake = []
check_range_verb("kaya_fake_verb", "KayaFakeVerb", "kayaFakeVerb",
                 findings=fake)
range_fake = sum(1 for m in fake if "has no sugar for" in m)
if range_fake != 9:
    selftest_exit(f"check-sugar-surface: self-test failed "
                  f"({range_fake}/9 range-verb patterns fired for a "
                  f"verb that exists nowhere)")

# --- THE CAPABILITIES SURFACE, in all nine -------------------------
#
# `kaya_capabilities()` is a C export every binding must wrap, or a
# guest derives the answer from its OWN platform predicate instead —
# copies of a rule the core already holds, keyed on the platform
# rather than on the capability.
#
# TWO CLAUSES, because either alone passes for the wrong reason: a
# binding can offer the QUERY and hand back the raw u64, and it can
# name a FLAG that nothing computes.
def cap_want(lang, rel, what, pattern, findings=None):
    global status
    if not grep_file(pattern, rel):
        msg = (f"check-sugar-surface: {lang} has no capabilities "
               f"{what} (wanted /{pattern}/ in {rel})")
        if findings is None:
            print(msg)
            status = 1
        else:
            findings.append(msg)


def check_cap_query(snake, pascal, camel, findings=None):
    cap_want("rust", "crates/kaya/src/app.rs", "query",
             f"^pub fn {snake}\\(\\)", findings)
    cap_want("python", "bindings/python/kaya/__init__.py", "query",
             f"^def {snake}\\(", findings)
    cap_want("go", "bindings/go/app.go", "query",
             f"^func {pascal}\\(\\)", findings)
    cap_want("csharp", "bindings/csharp/KayaApp.cs", "query",
             f"public static [A-Za-z]+ {pascal}\\(", findings)
    cap_want("java", "bindings/java/dev/kaya/KayaApp.java", "query",
             f"public static [A-Za-z]+ {camel}\\(", findings)
    cap_want("swift", "bindings/swift/KayaApp.swift", "query",
             f"static func {camel}\\(", findings)
    cap_want("haskell", "bindings/haskell/KayaApp.hs", "query",
             f"^{camel} :: IO", findings)
    cap_want("ocaml", "bindings/ocaml/kaya_app.ml", "query",
             f"^let {snake} ", findings)
    cap_want("js", "bindings/js/kaya/index.ts", "query",
             f"^export function {camel}\\(", findings)


check_cap_query("capabilities", "Capabilities", "capabilities")


def check_cap_flag(snake, pascal, camel, findings=None):
    """ONE named boolean, in every binding's own
    record/struct/dataclass. This is the line that grows when the core
    grows a bit: one call here, and nine bindings are held to it."""
    cap_want("rust", "crates/kaya/src/app.rs", f"flag '{snake}'",
             f"pub {snake}: bool", findings)
    cap_want("python", "bindings/python/kaya/__init__.py",
             f"flag '{snake}'", f"^    {snake}: bool", findings)
    cap_want("go", "bindings/go/app.go", f"flag '{snake}'",
             f"^\t{pascal} bool", findings)
    cap_want("csharp", "bindings/csharp/KayaApp.cs", f"flag '{snake}'",
             f"bool {pascal}[,)]", findings)
    cap_want("java", "bindings/java/dev/kaya/KayaApp.java",
             f"flag '{snake}'", f"boolean {camel}[,)]", findings)
    cap_want("swift", "bindings/swift/KayaApp.swift",
             f"flag '{snake}'", f"let {camel}: Bool", findings)
    cap_want("haskell", "bindings/haskell/KayaApp.hs",
             f"flag '{snake}'", f"{camel} :: Bool", findings)
    cap_want("ocaml", "bindings/ocaml/kaya_app.ml", f"flag '{snake}'",
             f"{snake} : bool", findings)
    cap_want("js", "bindings/js/kaya/index.ts", f"flag '{snake}'",
             f"readonly {camel}: boolean", findings)


check_cap_flag("aux_windows", "AuxWindows", "auxWindows")

# THEIR BUILT-IN NEGATIVE TESTS, one per clause and for the same reason
# the range verbs have one: sixteen patterns that can only pass are
# sixteen patterns nobody will notice have rotted.
fake = []
check_cap_query("kaya_fake_query", "KayaFakeQuery", "kayaFakeQuery",
                findings=fake)
cap_fake = sum(1 for m in fake if "has no capabilities" in m)
if cap_fake != 9:
    selftest_exit(f"check-sugar-surface: self-test failed "
                  f"({cap_fake}/9 capability-query patterns fired for "
                  f"a query that exists nowhere)")
fake = []
check_cap_flag("kaya_fake_cap", "KayaFakeCap", "kayaFakeCap",
               findings=fake)
cap_fake = sum(1 for m in fake if "has no capabilities" in m)
if cap_fake != 9:
    selftest_exit(f"check-sugar-surface: self-test failed "
                  f"({cap_fake}/9 capability-flag patterns fired for a "
                  f"bit that exists nowhere)")


# AND THE BIT NUMBERS AGREE WITH THE CORE'S (the check-file-modes
# lesson). Five bindings have no header to read `KAYA_CAP_AUX_WINDOWS`
# out of and write the number themselves; renumber the bit in the core
# and each goes on testing the old one, which reads as a host that
# lost a capability. Three DO read the core's own name and cannot
# drift, so for them the check is that they still name it rather than
# quietly becoming copiers. Two tables, and the second table's claim
# is itself checked.
def cap_numbers():
    """(output lines, ok). The authority: the scene core owns the bit
    (capi.rs's exported constant is static-asserted equal to it, and
    the header's #define is cbindgen's copy of capi.rs's)."""
    out = []
    scene = read_rel("crates/kaya/src/scene.rs")
    found = re.search(r"const CAP_AUX_WINDOWS: u64 = (\d+);", scene)
    if not found:
        out.append("check-sugar-surface: crates/kaya/src/scene.rs "
                   "declares no CAP_AUX_WINDOWS — the capability bit "
                   "has no authority to check the bindings against")
        return out, False
    truth = int(found.group(1))

    COPIERS = {
        "python": ("bindings/python/kaya/runtime.py",
                   r"^CAP_AUX_WINDOWS = (\d+)$"),
        "csharp": ("bindings/csharp/Kaya.cs",
                   r"CAP_AUX_WINDOWS = (\d+);"),
        "java": ("bindings/java/dev/kaya/KayaApp.java",
                 r"CAP_AUX_WINDOWS = (\d+);"),
        "haskell": ("bindings/haskell/KayaRuntime.hs",
                    r"^capAuxWindows = (\d+)$"),
        "ocaml": ("bindings/ocaml/kaya_runtime.ml",
                  r"^let cap_aux_windows = (\d+)L$"),
        "js": ("bindings/js/kaya/runtime.ts",
               r"^export const CAP_AUX_WINDOWS = (\d+);$"),
    }
    READERS = {
        "rust": ("crates/kaya/src/app.rs", "KAYA_CAP_AUX_WINDOWS"),
        "go": ("bindings/go/runtime.go", "C.KAYA_CAP_AUX_WINDOWS"),
        "swift": ("bindings/swift/KayaApp.swift",
                  "KAYA_CAP_AUX_WINDOWS"),
    }

    def audit(number):
        """Every copier's written bit, against `number`."""
        bad = []
        for lang, (path, pattern) in COPIERS.items():
            text = read_rel(path)
            wrote = [int(g) for g in re.findall(pattern, text, re.M)]
            if not wrote:
                bad.append(f"{lang} writes no capability bit at all "
                           f"({path} wanted /{pattern}/)")
            elif any(v != number for v in wrote):
                bad.append(f"{lang} writes CAP_AUX_WINDOWS={wrote} "
                           f"where the core says {number} ({path}) — "
                           f"the guest would test a bit the core no "
                           f"longer sets")
        return bad

    fails = audit(truth)
    for lang, (path, name) in READERS.items():
        if name not in read_rel(path):
            fails.append(f"{lang} no longer names {name} ({path}) — "
                         f"it read the core's own constant, and "
                         f"anything else here is a number that drifts")

    # THE WATCHED NEGATIVE: move the authority under them and EVERY
    # copier must notice. A reader that silently found nothing agrees
    # with any number at all, which is the census defect one file over
    # (tools/tpl-surfaces.py refuses a verdict for the same reason).
    missed = len(COPIERS) - len(audit(truth + 41))
    if missed:
        out.append(f"check-sugar-surface: self-test failed ({missed} "
                   f"of {len(COPIERS)} capability-number readers did "
                   f"not notice a renumbered bit)")
        return out, False

    out.extend("check-sugar-surface: " + line for line in fails)
    return out, not fails


cap_lines, cap_ok = cap_numbers()
if not cap_ok:
    print("\n".join(cap_lines))
    status = 1

# --- THE TABLE SURFACE, in all nine --------------------------------
#
# A TABLE IS NOT A KIND — it is a For with a header — so neither the
# constructor sweep above nor the window-prop sweep below can see it,
# and the wire records (TX 45 set_column_headers, occurrence 19
# sort_requested) reach every binding through the GENERATOR whether or
# not a guest has any way to spell them. That gap is what this clause
# closes: `columns` declares the header at the For, `on_sort` answers
# its clicks with the 0-based column (docs/tables-plan.md).
#
# PYTHON'S on_sort IS A KEYWORD, not a registration call: its ambient
# transaction has no app-level handler surface, so `columns(...,
# on_sort=f)` carries it. OCAML'S IS A LABELLED ARGUMENT on that same
# declaration, for the reason its click is one (`button ?on_click ()`):
# a binding registers a handler where its OWN click convention does
# (the maintainer's ruling, 2026-08-24), so its pattern reads
# `columns`' header and there is no `let on_sort` to find. Same
# observable semantics, different spelling — which is why the nine
# patterns are written out rather than derived from one casing rule.
def want_table(lang, rel, what, pattern, findings=None):
    global status
    if not grep_file(pattern, rel):
        msg = (f"check-sugar-surface: {lang} has no sugar for the "
               f"table's '{what}' (wanted /{pattern}/ in {rel})")
        if findings is None:
            print(msg)
            status = 1
        else:
            findings.append(msg)


def check_table_columns(snake, pascal, camel, findings=None):
    want_table("rust", "crates/kaya/src/app.rs", snake,
               f"pub fn {snake}\\(", findings)
    want_table("python", "bindings/python/kaya/__init__.py", snake,
               f"def {snake}\\(self", findings)
    want_table("go", "bindings/go/app.go", snake,
               f"func \\(tx \\*Tx\\) {pascal}\\(", findings)
    want_table("csharp", "bindings/csharp/KayaApp.cs", snake,
               f"public void {pascal}\\(", findings)
    want_table("java", "bindings/java/dev/kaya/KayaApp.java", snake,
               f"public void {camel}\\(", findings)
    want_table("swift", "bindings/swift/KayaApp.swift", snake,
               f"func {camel}\\(", findings)
    # HASKELL'S IS A CLASS METHOD, indented: `columnsNode` died when
    # the module's header rule reached the table, and one name now
    # dispatches over the zone through 'Declare'. Keyed on the whole
    # SIGNATURE, since `El m -> … -> m ()` is the half that says it
    # stands in both zones — a live-only `Widget -> … -> Build ()`
    # under the same name is exactly what this must not accept.
    want_table("haskell", "bindings/haskell/KayaApp.hs", snake,
               f"^  {camel} :: El m -> \\[String\\] -> Sort -> m \\(\\)",
               findings)
    want_table("ocaml", "bindings/ocaml/kaya_app.ml", snake,
               f"^let {snake} ", findings)
    # A METHOD ON THE COLLECTION, python's shape: the ambient transaction
    # has nothing else to hang it on. Keyed past `setColumns`, the keyed
    # re-declaration one class over, by the first parameter.
    want_table("js", "bindings/js/kaya/index.ts", snake,
               f"^  {snake}\\(titles", findings)


check_table_columns("columns", "Columns", "columns")


def check_table_on_sort(snake, pascal, camel, findings=None):
    # Rust's is the For builder's, whose generic parameter sits between
    # the name and the arguments.
    want_table("rust", "crates/kaya/src/app.rs", snake,
               f"pub fn {snake}(<[^>]*>)?\\(", findings)
    want_table("python", "bindings/python/kaya/__init__.py", snake,
               f"def columns\\(self.*{snake}=", findings)
    want_table("go", "bindings/go/app.go", snake,
               f"func \\(a \\*App\\) {pascal}\\(", findings)
    want_table("csharp", "bindings/csharp/KayaApp.cs", snake,
               f"public void {pascal}\\(", findings)
    want_table("java", "bindings/java/dev/kaya/KayaApp.java", snake,
               f"public void {camel}\\(", findings)
    want_table("swift", "bindings/swift/KayaApp.swift", snake,
               f"func {camel}\\(", findings)
    # ALSO A CLASS METHOD, and the handler's own type is the class's
    # associated family: the zone decides what a click hands the
    # handler, so `Keyed e` in the signature is what makes one name
    # serve both (bindings/haskell/KayaApp.hs, class HandlerTarget —
    # one class for all six registrars, so a verb missing from a zone
    # is a -Werror=missing-methods red rather than an absent instance).
    want_table("haskell", "bindings/haskell/KayaApp.hs", snake,
               f"^  {camel} :: App -> e -> Keyed e \\(Int -> IO "
               f"\\(\\)\\) -> IO \\(\\)", findings)
    # The LIVE zone's, keyed on the whole labelled argument: the type
    # is what separates it from the template zone's own `?(on_sort :
    # (Kaya_wire.value list -> int -> unit) option)` one module over.
    want_table("ocaml", "bindings/ocaml/kaya_app.ml", snake,
               f"^let columns \\?\\({snake} : \\(int -> unit\\) "
               f"option\\)", findings)
    # AN OPTION ON THE DECLARATION, python's keyword one language over:
    # read out of the options TYPE, which is where JS declares it.
    want_table("js", "bindings/js/kaya/index.ts", snake,
               f"ColumnsOptions = .*{camel}\\?:", findings)


check_table_on_sort("on_sort", "OnSort", "onSort")

# THEIR BUILT-IN NEGATIVE TESTS, one per clause and for the reason the
# range verbs have one: sixteen patterns that can only pass are sixteen
# patterns nobody will notice have rotted.
fake = []
check_table_columns("kaya_fake_cols", "KayaFakeCols", "kayaFakeCols",
                    findings=fake)
table_fake = sum(1 for m in fake
                 if "has no sugar for the table's" in m)
if table_fake != 9:
    selftest_exit(f"check-sugar-surface: self-test failed "
                  f"({table_fake}/9 table-columns patterns fired for a "
                  f"declaration that exists nowhere)")
fake = []
check_table_on_sort("on_kaya_fake", "OnKayaFake", "onKayaFake",
                    findings=fake)
table_fake = sum(1 for m in fake
                 if "has no sugar for the table's" in m)
if table_fake != 9:
    selftest_exit(f"check-sugar-surface: self-test failed "
                  f"({table_fake}/9 table-on_sort patterns fired for a "
                  f"handler that exists nowhere)")


# --- THE ROLE SUGAR: heading() and caption(), BOTH ZONES --------------
#
# One word for label+role (docs/styling-plan.md D4; ratified
# 2026-08-30). Neither is a KIND, so the kind census cannot see them —
# the table surface's problem one clause up, and the same answer: the
# patterns written out per binding, both construction zones each.
# Python is ONE pattern for both zones (its ambient _widget serves
# whichever zone is open — the live-only sentence does not apply, both
# zones are real). Go spells the live pair Text/Signal and the
# template pair Text/Bound, so it carries four patterns; Swift's LIVE
# constructor breaks its argument list after the paren, which is what
# the end-of-line anchor pins against the template overloads.
def want_role(lang, rel, what, pattern, findings=None):
    global status
    if not grep_file(pattern, rel):
        msg = (f"check-sugar-surface: {lang} has no '{what}' role "
               f"sugar (wanted /{pattern}/ in {rel})")
        if findings is None:
            print(msg)
            status = 1
        else:
            findings.append(msg)


def check_role_sugar(snake, pascal, camel, findings=None):
    want_role("rust-live", "crates/kaya/src/app.rs", snake,
              f"pub fn {snake}\\(&mut self, signal: SignalId\\)",
              findings)
    want_role("rust-tpl", "crates/kaya/src/app.rs", snake,
              f"pub fn {snake}\\(&mut self, src: impl "
              f"Into<TplSource<StrKind>>\\)", findings)
    want_role("python", "bindings/python/kaya/__init__.py", snake,
              f"^def {snake}\\(text=None, bind=None, grow=None\\)",
              findings)
    want_role("go-live", "bindings/go/app.go", snake,
              f"func \\(tx \\*Tx\\) {pascal}Text\\(text string\\) "
              f"Widget", findings)
    want_role("go-live", "bindings/go/app.go", snake,
              f"func \\(tx \\*Tx\\) {pascal}\\(s Signal\\[string\\]\\) "
              f"Widget", findings)
    want_role("go-tpl", "bindings/go/app.go", snake,
              f"func \\(t \\*Tpl\\) {pascal}Text\\(", findings)
    want_role("go-tpl", "bindings/go/app.go", snake,
              f"func \\(t \\*Tpl\\) {pascal}Bound\\[", findings)
    want_role("csharp-live", "bindings/csharp/KayaApp.cs", snake,
              f"public Widget {pascal}\\(string text = null", findings)
    want_role("csharp-tpl", "bindings/csharp/KayaApp.cs", snake,
              f"public Node {pascal}\\(string text\\)", findings)
    want_role("java-live", "bindings/java/dev/kaya/KayaApp.java",
              snake, f"public Widget {camel}\\(String text\\)",
              findings)
    want_role("java-tpl", "bindings/java/dev/kaya/KayaApp.java",
              snake, f"public Node {camel}\\(String text\\)", findings)
    want_role("swift-live", "bindings/swift/KayaApp.swift", snake,
              f"func {camel}\\($", findings)
    want_role("swift-tpl", "bindings/swift/KayaApp.swift", snake,
              f"func {camel}\\(_ text: String\\) -> KayaNodeHandle",
              findings)
    want_role("ocaml-live", "bindings/ocaml/kaya_app.ml", snake,
              f"^let {snake} \\?grow \\?a11y_id \\?a11y_label \\?text "
              f"\\?bind \\(\\)", findings)
    want_role("ocaml-tpl", "bindings/ocaml/kaya_app.ml", snake,
              f"^  let {snake} \\?grow \\?a11y_id \\?a11y_id_bind",
              findings)
    want_role("haskell-live", "bindings/haskell/KayaApp.hs", snake,
              f"^{camel}Text :: \\(LeafArgs r\\) => String -> r",
              findings)
    want_role("haskell-tpl", "bindings/haskell/KayaApp.hs", snake,
              f"^{camel} :: TplStrSource s => s -> Tpl Node", findings)
    # ONE pattern for both zones, python's reason: the ambient
    # constructor serves whichever zone is open. Keyed on the overload
    # DECLARATION, which is where the string form is spelled.
    want_role("js", "bindings/js/kaya/index.ts", snake,
              f"^export function {snake}\\(text: string, opts\\?: "
              f"LabelOptions\\): Widget;", findings)


check_role_sugar("heading", "Heading", "heading")
check_role_sugar("caption", "Caption", "caption")

fake = []
check_role_sugar("kaya_fake_role", "KayaFakeRole", "kayaFakeRole",
                 findings=fake)
role_fake = sum(1 for m in fake
                if "has no 'kaya_fake_role' role sugar" in m)
if role_fake != 18:
    selftest_exit(f"check-sugar-surface: self-test failed "
                  f"({role_fake}/18 role-sugar patterns fired for a "
                  f"constructor that exists nowhere)")


# --- THE SIZE-POLICY SURFACE, in all nine ---------------------------
#
# WHAT A CANVAS DOES WITH A TRACK THAT IS NOT ITS VIEWBOX
# (docs/canvas-plan.md §3.2.1). Invisible to every sweep above for the
# table's reason one surface over: `size_policy` is not a KIND and not
# a WINDOW PROP, and TX 47 plus occurrences 20/21 reach all nine
# bindings through the GENERATOR whether or not a guest can spell any
# of them — which is exactly the state this wave found (the records
# generated, nothing above them).
#
# `scale` HAS NO SPELLING ANYWHERE, deliberately: it is what a canvas
# that declares nothing gets, so there is nothing here to check for
# it. The other three are one semantics in nine idioms, each riding
# where that binding's OWN handler convention rides (the 2026-08-24
# ruling `on_sort` was decided by): chained on
# rust/go/csharp/java/swift, KEYWORD arguments on python's `canvas`,
# LABELLED arguments on ocaml's, and on haskell a Build action for the
# property beside two App-registered handlers. Written out rather than
# derived from a casing rule for that reason.
def want_policy(lang, rel, what, pattern, findings=None):
    global status
    if not grep_file(pattern, rel):
        msg = (f"check-sugar-surface: {lang} has no sugar for the "
               f"canvas's '{what}' (wanted /{pattern}/ in {rel})")
        if findings is None:
            print(msg)
            status = 1
        else:
            findings.append(msg)


def check_policy_fixed(snake, pascal, camel, findings=None):
    want_policy("rust", "crates/kaya/src/app.rs", snake,
                f"pub fn {snake}\\(self\\) -> Self", findings)
    # The keyword on the constructor, WITH its default: `fixed` alone
    # would match the parameter list of anything.
    want_policy("python", "bindings/python/kaya/__init__.py", snake,
                f"def canvas\\(viewbox.*{snake}=None", findings)
    want_policy("go", "bindings/go/app.go", snake,
                f"func \\(w Widget\\) {pascal}\\(\\) Widget", findings)
    want_policy("csharp", "bindings/csharp/KayaApp.cs", snake,
                f"public Widget {pascal}\\(\\)", findings)
    want_policy("java", "bindings/java/dev/kaya/KayaApp.java", snake,
                f"public Widget {camel}\\(\\)", findings)
    want_policy("swift", "bindings/swift/KayaApp.swift", snake,
                f"func {camel}\\(\\) -> KayaWidget", findings)
    # A PROPERTY IS A Build ACTION HERE, which is where every other
    # live prop in this binding stands — and it takes a Widget, which
    # is the template zone's refusal (a Node cannot be passed).
    want_policy("haskell", "bindings/haskell/KayaApp.hs", snake,
                f"^{camel} :: Widget -> Build \\(\\)", findings)
    want_policy("ocaml", "bindings/ocaml/kaya_app.ml", snake,
                f"\\?\\({snake} = false\\)", findings)
    # An option on the canvas constructor, python's keyword one language
    # over — read out of the options TYPE, WITH its `?:`, since a bare
    # name would match the body that reads it.
    want_policy("js", "bindings/js/kaya/index.ts", snake,
                f"CanvasOptions = .*\\b{camel}\\?:", findings)


check_policy_fixed("fixed", "Fixed", "fixed")


def check_policy_handler(snake, pascal, camel, hsarg, findings=None):
    want_policy("rust", "crates/kaya/src/app.rs", snake,
                f"pub fn {snake}<M>\\(", findings)
    want_policy("python", "bindings/python/kaya/__init__.py", snake,
                f"def canvas\\(viewbox.*{snake}=None", findings)
    want_policy("go", "bindings/go/app.go", snake,
                f"func \\(w Widget\\) {pascal}\\(fn func\\(d \\*Draw, "
                f"size Viewbox", findings)
    want_policy("csharp", "bindings/csharp/KayaApp.cs", snake,
                f"public Widget {pascal}\\(Action<Draw, Viewbox",
                findings)
    want_policy("java", "bindings/java/dev/kaya/KayaApp.java", snake,
                f"public Widget {camel}\\(", findings)
    want_policy("swift", "bindings/swift/KayaApp.swift", snake,
                f"func {camel}\\(_ handler: @escaping \\(KayaDraw, "
                f"KayaViewbox", findings)
    # APP-REGISTERED, like this binding's other handlers, and typed on
    # Widget: the live zone is the only one a policy may be declared
    # in.
    want_policy("haskell", "bindings/haskell/KayaApp.hs", snake,
                f"^{camel} :: App -> Widget -> \\({hsarg}\\) -> IO "
                f"\\(\\)", findings)
    want_policy("ocaml", "bindings/ocaml/kaya_app.ml", snake,
                f"\\?\\({snake} : \\(draw -> viewbox", findings)
    want_policy("js", "bindings/js/kaya/index.ts", snake,
                f"CanvasOptions = .*\\b{camel}\\?:", findings)


check_policy_handler("on_draw", "OnDraw", "onDraw",
                     "Viewbox -> \\[DrawOp\\]")
check_policy_handler("on_tick", "OnTick", "onTick",
                     "Viewbox -> Double -> \\[DrawOp\\]")


# AND THE TEMPLATE ZONE IS REFUSED, all nine, which is the half a
# spelling census cannot see: the size policy is a LIVE-ZONE
# declaration in this slice and a canvas inside a row template keeps
# `scale` (docs/deferred.md). Six bindings refuse it with a TYPE — the
# template zone hands out its own handle and the three declarations do
# not exist on it — so what is checked there is that the template
# constructor carries no policy argument and the node type no policy
# method. The THREE whose one handle serves both zones raise, and their
# sentence is frozen BYTE FOR BYTE, because an app reads it and two
# spellings of one refusal is the divergence invariant 1 forbids.
#
# COMPARED FLATTENED, and that is not a convenience: python splices
# the sentence across adjacent string literals and ocaml across a
# backslash-continued one, so the bytes an app sees are one line while
# the bytes on disk are three. check-verbs' `expect_ax` clause reads
# its three harnesses the same way and for the same reason.
def policy_sentence():
    SENTENCE = ("kaya: the size policy is a LIVE-ZONE declaration in "
                "this slice — a canvas inside a row template keeps "
                "`scale` (docs/deferred.md, the template-zone size "
                "policy entry)")

    def flat(text):
        # Python's adjacent-literal splice, then OCaml's
        # backslash-newline one.
        text = re.sub(r'"\s*\n\s*"', "", text)
        text = re.sub(r"\\\s*\n\s*", "", text)
        return re.sub(r"\s+", " ", text)

    AMBIENT = ["bindings/python/kaya/__init__.py",
               "bindings/ocaml/kaya_app.ml",
               "bindings/js/kaya/index.ts"]
    out = []
    fails = []
    want = re.sub(r"\s+", " ", SENTENCE)
    for name in AMBIENT:
        if want not in flat(read_rel(name)):
            fails.append(f"{name} serves both zones with ONE handle "
                         f"but does not refuse a template-node size "
                         f"policy in the frozen words: \"{want}\"")
    # THE CLAUSE'S OWN NEGATIVE, watched on every run AND ONCE PER FILE:
    # a copy with the sentence perturbed must stop matching, or this is a
    # grep nobody has seen fail. Per file rather than once, because each
    # is read through its own splice rule and a clause that had stopped
    # reading ONE of them would be invisible to a single probe.
    for name in AMBIENT:
        doctored, n = sub_count("LIVE-ZONE declaration",
                                "live-zone declaration", read_rel(name))
        out.append(f"check-sugar-surface: template-zone sentence "
                   f"perturbation applied {n} substitution(s) in {name}")
        if n < 1:
            fails.append(f"the template-zone sentence self-test perturbed "
                         f"NOTHING in {name} — a negative that did not "
                         f"perturb is a failed test")
        elif want in flat(doctored):
            fails.append(f"the template-zone sentence self-test stayed "
                         f"GREEN against a doctored copy of {name} — the "
                         f"clause reads something else")
    out.extend("check-sugar-surface: " + line for line in fails)
    return out, not fails


policy_lines, policy_ok = policy_sentence()
print("\n".join(policy_lines))
if not policy_ok:
    status = 1

# The typed refusals: a template constructor that grew a policy
# argument would be a second, unrefusable spelling of the same thing.
policy_typed_fail = 0
if grep_file(r"func \(t \*Tpl\) Canvas\(.*(fixed|onDraw|onTick)",
             "bindings/go/app.go"):
    print("check-sugar-surface: go's Tpl.Canvas takes a size policy — "
          "the template zone is refused BY TYPE in this slice "
          "(docs/deferred.md)")
    policy_typed_fail = 1
if grep_file(r"public Node Canvas\(.*(Fixed|OnDraw|OnTick)",
             "bindings/csharp/KayaApp.cs"):
    print("check-sugar-surface: c#'s Tpl.Canvas takes a size policy — "
          "the template zone is refused BY TYPE in this slice "
          "(docs/deferred.md)")
    policy_typed_fail = 1
if grep_file(r"public Node canvas\(.*(fixed|onDraw|onTick)",
             "bindings/java/dev/kaya/KayaApp.java"):
    print("check-sugar-surface: java's Tpl.canvas takes a size policy "
          "— the template zone is refused BY TYPE in this slice "
          "(docs/deferred.md)")
    policy_typed_fail = 1
if grep_file(r"^canvasOf :: Viewbox -> \[DrawOp\] -> "
             r".*(Bool|DrawOp\] -> \()",
             "bindings/haskell/KayaApp.hs"):
    print("check-sugar-surface: haskell's canvasOf takes a size policy "
          "— the template zone is refused BY TYPE in this slice "
          "(docs/deferred.md)")
    policy_typed_fail = 1
if policy_typed_fail:
    status = 1

# THEIR BUILT-IN NEGATIVE TESTS, the table clause's discipline: a
# pattern that can only pass is a pattern nobody notices has rotted.
fake = []
check_policy_fixed("kaya_fake_fixed", "KayaFakeFixed", "kayaFakeFixed",
                   findings=fake)
policy_fake = sum(1 for m in fake
                  if "has no sugar for the canvas's" in m)
if policy_fake != 9:
    selftest_exit(f"check-sugar-surface: self-test failed "
                  f"({policy_fake}/9 size-policy 'fixed' patterns "
                  f"fired for a declaration that exists nowhere)")
fake = []
check_policy_handler("on_kaya_fake", "OnKayaFake", "onKayaFake",
                     "Nope", findings=fake)
policy_fake = sum(1 for m in fake
                  if "has no sugar for the canvas's" in m)
if policy_fake != 9:
    selftest_exit(f"check-sugar-surface: self-test failed "
                  f"({policy_fake}/9 size-policy handler patterns "
                  f"fired for a handler that exists nowhere)")

# The built-in negative test: a kind that exists nowhere must fail in
# every binding, or the patterns themselves have rotted. Collected
# rather than printed, so the fake's failures die with the list — no
# status reset, deliberately: a reset is how the menus self-test below
# used to erase every failure the clauses above it had already found
# (caught 2026-07-25 by two real ocaml failures printing under a PASS
# verdict).
fake = []
check_kind("kayafakewidget", findings=fake)
fake_failures = sum(1 for m in fake
                    if "no live-zone constructor" in m)
if fake_failures != 9:
    selftest_exit(f"check-sugar-surface: self-test failed "
                  f"({fake_failures}/9 patterns fired for a fake kind)")

for kind in kinds:
    check_kind(kind)

# --- THE TEMPLATE ZONE, the same sweep one zone over ----------------
#
# kaya has TWO construction zones (CLAUDE.md's gate list). The LIVE
# zone is what an app builds in its build closure; the TEMPLATE zone
# is the prototype inside a collection, stamped once per row. They are
# different surfaces handing out different handles, so a constructor
# in one is not a constructor in the other.
#
# THE SWEEP IS tools/tpl-surfaces.py, NOT seven more `check` lines,
# and that is forced: three bindings namespace the template zone by
# SCOPE rather than by name (Rust's `Tpl` methods are `pub fn entry`
# exactly like `Tx`'s, OCaml's live in `module Tpl = struct`), so a
# line-oriented pattern would be satisfied by the LIVE constructor and
# report a zone it never read. tools/tpl-surfaces.py locates each zone
# by its structure and REFUSES A VERDICT from a reader that found
# implausibly few. It also holds Rust's two surfaces level: `Tpl` is
# the zone, `Row` is the for-statement façade that forwards by hand.
#
# Kinds come from the generated wire file, so the list tracks the spec
# by construction.
def tpl_surfaces(*args, cwd=None):
    return subprocess.run(
        [sys.executable, str(ROOT / "tools" / "tpl-surfaces.py"),
         *args], cwd=cwd or ROOT, capture_output=True, text=True,
        check=False)


tpl = tpl_surfaces("--kinds", ",".join(kinds))
if tpl.returncode != 0:
    print((tpl.stdout + tpl.stderr).rstrip("\n"))
    status = 1

# ITS NEGATIVE TEST, in both directions.
#
# (a) A KIND THAT EXISTS NOWHERE must be reported missing by every
#     zone reader, or the readers have rotted into a census that can
#     only pass.
tpl_fake = tpl_surfaces("--kinds", "kayafakewidget")
fake_count = (tpl_fake.stdout + tpl_fake.stderr).count(
    "no TEMPLATE-zone constructor")
if fake_count != 7:
    print(f"check-sugar-surface: template self-test failed "
          f"({fake_count}/7 zone readers reported a kind that exists "
          f"nowhere as missing)", file=sys.stderr)
    raise SystemExit(1)

# (b) AND A KIND EVERY BINDING HAS must be reported by none. Seven
#     readers keyed on block headers are exactly the shape that goes
#     vacuous when a binding renames its template type, and a reader
#     that finds nothing is indistinguishable from a zone with nothing
#     missing. `label` is in every template zone, so a complaint about
#     it means a reader has stopped reading.
tpl_real = tpl_surfaces("--kinds", "label")
real_count = (tpl_real.stdout + tpl_real.stderr).count(
    "no TEMPLATE-zone constructor")
if real_count != 0:
    print(f"check-sugar-surface: template self-test failed "
          f"({real_count} zone readers could not find 'label', which "
          f"every template zone has — those readers have stopped "
          f"matching the files they read and can no longer fail)",
          file=sys.stderr)
    raise SystemExit(1)


# The staging helpers every tpl probe below shares: a temp repo root
# where exactly the named files differ and everything else symlinks
# the real tree.
def link_children(source, destination, skip):
    os.makedirs(destination, exist_ok=True)
    for name in os.listdir(source):
        if name != skip:
            os.symlink(os.path.abspath(f"{source}/{name}"),
                       f"{destination}/{name}")


def stage_app(app_text):
    """crates/kaya/src/app.rs swapped; bindings, tools and guests
    linked whole. `guests` too, since the census reads C#'s GENERATED
    `<Rec>Row` façades out of the guest tree: without it that clause
    reports a reader it cannot locate, and a probe would pass on the
    wrong failure."""
    root = tempfile.mkdtemp()
    os.makedirs(f"{root}/crates/kaya/src", exist_ok=True)
    for rel in ("bindings", "tools", "guests"):
        os.symlink(os.path.abspath(rel), f"{root}/{rel}")
    with open(f"{root}/crates/kaya/src/app.rs", "w",
              encoding="utf-8") as fh:
        fh.write(app_text)
    return root


def stage_binding(app_text, chain, leaf_text):
    """stage_app plus ONE binding file swapped: `chain` is the list of
    (parent, kept-child) hops down to the leaf."""
    root = stage_app(app_text)
    os.unlink(f"{root}/bindings")
    for parent, keep in chain[:-1]:
        link_children(parent, f"{root}/{parent}", keep)
    parent, leaf = chain[-1]
    link_children(parent, f"{root}/{parent}", leaf)
    with open(f"{root}/{parent}/{leaf}", "w", encoding="utf-8") as fh:
        fh.write(leaf_text)
    return root


def scoped(src, start, stop, old, new):
    if src.count(start) != 1:
        return None, src.count(start)
    at = src.index(start)
    end = src.index(stop, at)
    block = src[at:end]
    n = block.count(old)
    if n == 1:
        src = src[:at] + block.replace(old, new) + src[end:]
    return src, n


# (c) RUST'S TWO-SURFACE CLAUSE IS WATCHED, by deleting one forward
#     from a copy of the real file. The perturbation count is printed
#     and checked: a substitution that did not apply is a FAILED test,
#     not a passed one (invariant 3).
def tpl_row_probe():
    src = read_rel("crates/kaya/src/app.rs")
    victim = ("    pub fn entry(&mut self) -> TemplateNodeId {\n"
              "        self.tpl().entry()\n"
              "    }\n"
              "\n")
    n = src.count(victim)
    if n != 1:
        return (f"SELFTEST-BROKEN: perturbation matched {n} times, "
                f"expected 1")
    root = stage_app(src.replace(victim, ""))
    out = subprocess.run(
        [sys.executable, str(ROOT / "tools" / "tpl-surfaces.py"),
         root], cwd=ROOT, capture_output=True, text=True, check=False)
    shutil.rmtree(root)
    hit = "does not forward: entry" in out.stdout
    return f"applied=1 rc={out.returncode} named_entry={hit}"


row_probe = tpl_row_probe()
if row_probe != "applied=1 rc=1 named_entry=True":
    print(f"check-sugar-surface: SELF-TEST FAIL (deleting Row's "
          f"'entry' forward was not caught by tools/tpl-surfaces.py: "
          f"{row_probe})", file=sys.stderr)
    raise SystemExit(1)


# (c2) THE DYNAMIC-TABLE READERS ARE WATCHED at every implemented
#      point. Each deletion is scoped to the block it claims to read;
#      the same names elsewhere stay in place.
def tpl_table_probe():
    lines = []

    def run_root(name, root, want):
        r = subprocess.run(
            [sys.executable, str(ROOT / "tools" / "tpl-surfaces.py"),
             root], cwd=ROOT, capture_output=True, text=True,
            check=False)
        shutil.rmtree(root)
        lines.append(f"{name}=applied:1 rc:{r.returncode} "
                     f"named:{want in r.stdout}")

    def run(name, text, count, want):
        if count != 1:
            lines.append(f"{name}=SELFTEST-BROKEN(matched {count}, "
                         f"expected 1)")
            return
        run_root(name, stage_app(text), want)

    def run_leaf(name, app_text, chain, text, count, want):
        if count != 1:
            lines.append(f"{name}=SELFTEST-BROKEN(matched {count}, "
                         f"expected 1)")
            return
        run_root(name, stage_binding(app_text, chain, text), want)

    PY_CHAIN = [("bindings", "python"), ("bindings/python", "kaya"),
                ("bindings/python/kaya", "__init__.py")]
    GO_CHAIN = [("bindings", "go"), ("bindings/go", "app.go")]
    CS_CHAIN = [("bindings", "csharp"),
                ("bindings/csharp", "KayaApp.cs")]
    SW_CHAIN = [("bindings", "swift"),
                ("bindings/swift", "KayaApp.swift")]
    ML_CHAIN = [("bindings", "ocaml"),
                ("bindings/ocaml", "kaya_app.ml")]
    HS_CHAIN = [("bindings", "haskell"),
                ("bindings/haskell", "KayaApp.hs")]
    JS_CHAIN = [("bindings", "js"), ("bindings/js", "kaya"),
                ("bindings/js/kaya", "index.ts")]

    src = read_rel("crates/kaya/src/app.rs")
    text, n = scoped(src,
                     "impl<I: for_scope::Id> Rows<'_, '_, I> {",
                     "impl Rows<'_, '_, WidgetId> {",
                     "    pub fn columns(",
                     "    pub fn columns_removed(")
    run("rust-columns", text or src, n,
        "rust's TEMPLATE-zone table cannot spell columns")

    text, n = scoped(src,
                     "impl Rows<'_, '_, TemplateNodeId> {",
                     "/// The header bar's sort indicator",
                     "        f: impl Fn(Path, u32) -> M + 'static,",
                     "        f: impl Fn(u32) -> M + 'static,")
    run("rust-sort", text or src, n,
        "rust's TEMPLATE-zone table cannot spell on_sort")

    old = "    pub fn columns_at("
    n = src.count(old)
    run("rust-keyed",
        src.replace(old, "    pub fn columns_at_removed(")
        if n == 1 else src, n,
        "rust's TEMPLATE-zone table cannot spell keyed re-declaration")

    # GO. The zone marker is the RECEIVER — `func (r *Rows) Columns`
    # and `func (r *NodeRows) Columns` are two surfaces spelled the
    # same — so every needle below carries one, and each is unique in
    # the file.
    go = read_rel("bindings/go/app.go")
    go_points = (
        ("go-columns", "columns",
         "func (r *NodeRows) Columns(titles []string, sort Sort) "
         "*NodeRows {",
         "func (r *NodeRows) ColumnsRemoved(titles []string, sort "
         "Sort) *NodeRows {"),
        ("go-columns-path", "columns",
         "\t\ttx.emit(TxSetColumnHeaders(st.id, st.bar.sort.sorted, "
         "st.bar.sort.direction,\n"
         "\t\t\tuint32(len(st.bar.titles)), 0, "
         "titleValues(st.bar.titles)))",
         "\t\ttx.emit(TxSetColumnHeaders(st.id, st.bar.sort.sorted, "
         "st.bar.sort.direction,\n"
         "\t\t\tuint32(len(st.bar.titles)), 1, "
         "titleValues(st.bar.titles)))"),
        ("go-nested-for", "columns",
         "func (t *Tpl) Rows(c Collection) *NodeRows {",
         "func (t *Tpl) RowsRemoved(c Collection) *NodeRows {"),
        ("go-sort", "on_sort",
         "func (a *App) OnSortNode(n Node, fn func(*Tx, []any, "
         "uint32)) {",
         "func (a *App) OnSortNode(n Node, fn func(*Tx, uint32)) {"),
        ("go-sort-chain", "on_sort",
         "\tr.st.tx.app.OnSortNode(r.Node(), fn)",
         "\tr.st.tx.app.OnSortNode(Node{}, fn)"),
        ("go-sort-dispatch", "on_sort",
         "a.dispatch(func(tx *Tx) { fn(tx, keys, column) })",
         "a.dispatch(func(tx *Tx) { fn(tx, nil, column) })"),
        ("go-node-handle", "keyed re-declaration",
         "func (r *NodeRows) Node() Node {",
         "func (r *NodeRows) NodeRemoved() Node {"),
        ("go-keyed", "keyed re-declaration",
         "func (tx *Tx) ColumnsAt(n Node, keys []any, titles "
         "[]string, sort Sort) {",
         "func (tx *Tx) ColumnsAtRemoved(n Node, keys []any, titles "
         "[]string, sort Sort) {"),
        ("go-keyed-order", "keyed re-declaration",
         "\tvalues = append(values, keys...)\n"
         "\tfor _, title := range titles {\n\t\tvalues = "
         "append(values, title)\n\t}\n",
         "\tfor _, title := range titles {\n\t\tvalues = "
         "append(values, title)\n\t}\n"
         "\tvalues = append(values, keys...)\n"),
        ("go-keyed-pathlen", "keyed re-declaration",
         "\t\tuint32(len(titles)), uint32(len(keys)), values))",
         "\t\tuint32(len(titles)), 0, values))"),
    )
    for name, point, old, new in go_points:
        n = go.count(old)
        run_leaf(name, src, GO_CHAIN,
                 go.replace(old, new, 1) if n == 1 else go, n,
                 f"go's TEMPLATE-zone table cannot spell {point}")

    # And the reader itself: with the dispatch switch's own function
    # gone it must report a zone it could not READ, never an empty
    # one.
    old = "func (a *App) Serve() {"
    n = go.count(old)
    run_leaf("go-reader", src, GO_CHAIN,
             go.replace(old, "func (a *App) ServeRemoved() {", 1)
             if n == 1 else go, n,
             "cannot find go's dynamic-table zones")

    # C# spells both zones as OVERLOADS, so every deletion below is
    # scoped to one class block and the live Columns/OnSort stay where
    # they are.
    cs = read_rel("bindings/csharp/KayaApp.cs")

    text, n = scoped(cs, "sealed class Tpl", "sealed class CopyRef",
                     "    public void Columns(",
                     "    public void ColumnsRemoved(")
    run_leaf("csharp-columns", src, CS_CHAIN, text or cs, n,
             "csharp's TEMPLATE-zone table cannot spell columns")

    text, n = scoped(
        cs, "sealed class KayaApp", "sealed class Tx",
        "    public void OnSort(Node n, Action<Tx, List<object>, "
        "uint> handler) =>",
        "    public void OnSortRemoved(Node n, Action<Tx, "
        "List<object>, uint> handler) =>")
    run_leaf("csharp-sort", src, CS_CHAIN, text or cs, n,
             "csharp's TEMPLATE-zone table cannot spell on_sort")

    # The half a signature census cannot see, twice: drop the live
    # arm's guard and every stamped copy's request is answered by the
    # live table instead; drop the keys from the node arm's call and
    # the handler can no longer say which copy fired.
    text, n = scoped(
        cs, "sealed class KayaApp", "sealed class Tx",
        "kind == KayaWire.OccKindSortRequested && keys.Count == 0)",
        "kind == KayaWire.OccKindSortRequested)")
    run_leaf("csharp-sort-arm", src, CS_CHAIN, text or cs, n,
             "csharp's TEMPLATE-zone table cannot spell on_sort")

    text, n = scoped(cs, "sealed class KayaApp", "sealed class Tx",
                     "fn(tx, keys, column)", "fn(tx, column)")
    run_leaf("csharp-sort-keys", src, CS_CHAIN, text or cs, n,
             "csharp's TEMPLATE-zone table cannot spell on_sort")

    text, n = scoped(
        cs, "sealed class Tx", "sealed class Tpl",
        "    public void Columns(Node n, IReadOnlyList<object> keys,",
        "    public void ColumnsAt(Node n, IReadOnlyList<object> "
        "keys,")
    run_leaf("csharp-keyed", src, CS_CHAIN, text or cs, n,
             "csharp's TEMPLATE-zone table cannot spell keyed "
             "re-declaration")

    text, n = scoped(cs, "sealed class Tx", "sealed class Tpl",
                     "(uint)titles.Length, (uint)keys.Count,",
                     "(uint)titles.Length, 0,")
    run_leaf("csharp-keyed-len", src, CS_CHAIN, text or cs, n,
             "csharp's TEMPLATE-zone table cannot spell keyed "
             "re-declaration")

    old = "sealed class Tpl"
    n = cs.count(old)
    run_leaf("csharp-reader", src, CS_CHAIN,
             cs.replace(old, "sealed class TplRemoved")
             if n == 1 else cs, n,
             "cannot find csharp's dynamic-table zones")

    # OCaml namespaces the template zone by SCOPE, so each half is
    # deleted on the side it must live on: the declaration AND its
    # ~on_sort inside `module Tpl`, the keyed re-declaration outside
    # it. The handler is a LABELLED ARGUMENT on the declaration since
    # 2026-08-24 (the binding spells a click that way), so the sort
    # clauses perturb the same block the bar's do — never the name,
    # which the live `columns` also carries.
    ml = read_rel("bindings/ocaml/kaya_app.ml")
    TPL = ("module Tpl = struct", "let on_click app (Widget id)")
    columns_want = "ocaml's TEMPLATE-zone table cannot spell columns"
    sort_want = "ocaml's TEMPLATE-zone table cannot spell on_sort"
    keyed_want = ("ocaml's TEMPLATE-zone table cannot spell keyed "
                  "re-declaration")

    text, n = scoped(ml, *TPL, "  let columns\n      ?(on_sort :",
                     "  let columns_removed\n      ?(on_sort :")
    run_leaf("ocaml-columns", src, ML_CHAIN, text or ml, n,
             columns_want)

    text, n = scoped(ml, *TPL, "         (List.length titles) 0",
                     "         (List.length titles) 1")
    run_leaf("ocaml-columns-pathlen", src, ML_CHAIN, text or ml, n,
             columns_want)

    # menu_selected_node is the one table with the same value type, so
    # it is the only wrong table the compiler would let through.
    text, n = scoped(ml, *TPL,
                     "Hashtbl.replace tx.app.node_sorts id handler",
                     "Hashtbl.replace tx.app.menu_selected_node id "
                     "handler")
    run_leaf("ocaml-sort-table", src, ML_CHAIN, text or ml, n,
             sort_want)

    # And the argument itself: a `columns` that takes no handler
    # declares a bar nothing can answer, which is precisely the
    # surface this zone had before the labelled argument arrived.
    text, n = scoped(ml, *TPL,
                     "  let columns\n      ?(on_sort : "
                     "(Kaya_wire.value list -> int -> unit) option)\n"
                     "      (Node id) titles sort =",
                     "  let columns (Node id) titles sort =")
    run_leaf("ocaml-sort-arg", src, ML_CHAIN, text or ml, n, sort_want)

    text, n = scoped(ml,
                     "if kind = Kaya_wire.occ_kind_sort_requested "
                     "then",
                     "else if kind = Kaya_wire.occ_kind_text_changed "
                     "then",
                     "Hashtbl.find_opt app.node_sorts id",
                     "Hashtbl.find_opt app.node_handlers id")
    run_leaf("ocaml-sort-dispatch", src, ML_CHAIN, text or ml, n,
             sort_want)

    KEYED = ("let columns_at (Node id) keys titles sort =",
             "(* Sums: a variant type")
    text, n = scoped(ml, *KEYED,
                     "       (keys @ List.map (fun t -> "
                     "Kaya_wire.Str t) titles))",
                     "       (List.map (fun t -> Kaya_wire.Str t) "
                     "titles @ keys))")
    run_leaf("ocaml-keyed-order", src, ML_CHAIN, text or ml, n,
             keyed_want)

    text, n = scoped(ml, *KEYED,
                     "       (List.length titles) (List.length keys)",
                     "       (List.length titles) 0")
    run_leaf("ocaml-keyed-len", src, ML_CHAIN, text or ml, n,
             keyed_want)

    old = "module Tpl = struct"
    n = ml.count(old)
    run_leaf("ocaml-reader", src, ML_CHAIN,
             ml.replace(old, "module TplRemoved = struct")
             if n == 1 else ml, n,
             "cannot find ocaml's dynamic-table zones")

    # PYTHON. The rows probes also drive kaya_app_checks against the
    # staged root, since the open-For edge is theirs to hold.
    py = read_rel("bindings/python/kaya/__init__.py")
    row_points = (
        ("grow", "_grow", "grow",
         "wire.tx_set_grow(self._template.handle.id, "
         "float(self._grow))",
         "wire.tx_removed_set_grow(self._template.handle.id, "
         "float(self._grow))",
         "ordinary For grow", "FAIL rows(grow=) reaches its For"),
        ("align", "_align", "align",
         "wire.tx_set_align(self._template.handle.id, "
         "_align_value(self._align))",
         "wire.tx_removed_set_align(self._template.handle.id, "
         "_align_value(self._align))",
         "ordinary For align", "FAIL rows(align=) reaches its For"),
        # The handle setter, not a const emitter: `rows(a11y_id=
        # row.key)` must reach the ELEMENT arm (tools/tpl-surfaces.py
        # says why).
        ("a11y", "_a11y_id", "a11y_id",
         "self._template.handle.a11y_id(self._a11y_id)",
         "self._template.handle.a11y_removed_id(self._a11y_id)",
         "ordinary For a11y id", "FAIL rows(a11y_id=) reaches its For"),
    )
    for name, field, arg, emitter, broken, point, check_want \
            in row_points:
        surface_want = (f"python's TEMPLATE-zone table cannot spell "
                        f"{point}")
        text, n = scoped(
            py, "class Collection(_BoundCollection):", "class _Scope:",
            f"        trace.{field} = {arg}",
            f"        trace.{field} = None")
        if n != 1:
            lines.append(f"python-rows-{name}=SELFTEST-BROKEN(matched "
                         f"{n}, expected 1)")
        else:
            root = stage_binding(src, PY_CHAIN, text)
            surface = subprocess.run(
                [sys.executable,
                 str(ROOT / "tools" / "tpl-surfaces.py"), root],
                cwd=ROOT, capture_output=True, text=True, check=False)
            env = dict(os.environ,
                       PYTHONPATH=f"{root}/bindings/python")
            checks = subprocess.run(
                [sys.executable, "-m", "kaya_app_checks"],
                cwd=root, env=env, capture_output=True, text=True,
                check=False)
            shutil.rmtree(root)
            lines.append(
                f"python-rows-{name}=applied:1 "
                f"surface-rc:{surface.returncode} "
                f"surface-named:{surface_want in surface.stdout} "
                f"checks-rc:{checks.returncode} "
                f"checks-named:{check_want in checks.stdout}")
        text, n = scoped(py, "class _ForTrace:",
                         "def _alloc_widget_or_node", emitter, broken)
        run_leaf(f"python-rows-{name}-emitter", src, PY_CHAIN,
                 text or py, n, surface_want)

    text, n = scoped(py, "class Collection(_BoundCollection):",
                     "class _Scope:", "    def columns(",
                     "    def columns_removed(")
    run_leaf("python-columns", src, PY_CHAIN, text or py, n,
             "python's TEMPLATE-zone table cannot spell columns")

    text, n = scoped(
        py, "class _ColumnsTrace:", "class PickedFile:",
        "                _app._register(handle, "
        "wire.OCC_SORT_REQUESTED, self._on_sort)",
        "                _app._register(handle, wire.OCC_SORT_REMOVED, "
        "self._on_sort)")
    run_leaf("python-sort", src, PY_CHAIN, text or py, n,
             "python's TEMPLATE-zone table cannot spell on_sort")

    text, n = scoped(py, "    def set_columns(", "    def _absorb_key(",
                     "len(self._path)", "0")
    run_leaf("python-keyed-len", src, PY_CHAIN, text or py, n,
             "python's TEMPLATE-zone table cannot spell keyed "
             "re-declaration")

    text, n = scoped(py, "    def set_columns(", "    def _absorb_key(",
                     "[*self._path, *titles]", "[*titles, *self._path]")
    run_leaf("python-keyed-order", src, PY_CHAIN, text or py, n,
             "python's TEMPLATE-zone table cannot spell keyed "
             "re-declaration")

    old = "class _BoundCollection:"
    n = py.count(old)
    run_leaf("python-reader", src, PY_CHAIN,
             py.replace(old, "class _BoundCollectionRemoved:")
             if n == 1 else py, n,
             "cannot find python's dynamic-table zones")

    # SWIFT. Every point here is an OVERLOAD of a name the live zone
    # also has (`columns` on two classes, `onSort` twice on one), so
    # each perturbation leaves the live spelling untouched: a clause
    # that came back green would be reading the wrong one.
    sw = read_rel("bindings/swift/KayaApp.swift")
    tpl_bar = ("    func columns(_ n: KayaNodeHandle, _ titles: "
               "[String], _ sort: KayaSort) {")
    n = sw.count(tpl_bar)
    run_leaf("swift-columns", src, SW_CHAIN,
             sw.replace(tpl_bar,
                        tpl_bar.replace("func columns(",
                                        "func columnsRemoved("))
             if n == 1 else sw, n,
             "swift's TEMPLATE-zone table cannot spell columns")

    text, n = scoped(sw, tpl_bar,
                     "    func forEach<R>(_ c: KayaCollection, _ "
                     "body: (KayaTpl) -> R)",
                     "UInt32(titles.count), 0,",
                     "UInt32(titles.count), 1,")
    run_leaf("swift-columns-pathlen", src, SW_CHAIN, text or sw, n,
             "swift's TEMPLATE-zone table cannot spell columns")

    old = ("        _ n: KayaNodeHandle, "
           "_ handler: @escaping (KayaAppTx, [KayaValue], UInt32) "
           "throws -> Void")
    n = sw.count(old)
    run_leaf("swift-sort-keys", src, SW_CHAIN,
             sw.replace(old, old.replace("[KayaValue], ", ""))
             if n == 1 else sw, n,
             "swift's TEMPLATE-zone table cannot spell on_sort")

    old = ("            case "
           "(UInt16(KAYA_OCCURRENCE_SORT_REQUESTED), false):")
    n = sw.count(old)
    run_leaf("swift-sort-dispatch", src, SW_CHAIN,
             sw.replace(old, old.replace("SORT_REQUESTED",
                                         "SORT_REMOVED"))
             if n == 1 else sw, n,
             "swift's TEMPLATE-zone table cannot spell on_sort")

    keyed = "    func columns(\n        _ n: KayaNodeHandle, at path:"
    n = sw.count(keyed)
    run_leaf("swift-keyed", src, SW_CHAIN,
             sw.replace(keyed,
                        keyed.replace("func columns(",
                                      "func columnsRemoved("))
             if n == 1 else sw, n,
             "swift's TEMPLATE-zone table cannot spell keyed "
             "re-declaration")

    text, n = scoped(sw, keyed, "    func bindText(",
                     "UInt32(path.count)", "0")
    run_leaf("swift-keyed-len", src, SW_CHAIN, text or sw, n,
             "swift's TEMPLATE-zone table cannot spell keyed "
             "re-declaration")

    text, n = scoped(sw, keyed, "    func bindText(",
                     "path + titles.map { .str($0) })",
                     "titles.map { .str($0) } + path)")
    run_leaf("swift-keyed-order", src, SW_CHAIN, text or sw, n,
             "swift's TEMPLATE-zone table cannot spell keyed "
             "re-declaration")

    # count and path_len are BOTH UInt32 — the compiler cannot see
    # them swapped, so this clause is the only reader that can.
    text, n = scoped(sw, keyed, "    func bindText(",
                     "UInt32(titles.count), UInt32(path.count),",
                     "UInt32(path.count), UInt32(titles.count),")
    run_leaf("swift-keyed-swap", src, SW_CHAIN, text or sw, n,
             "swift's TEMPLATE-zone table cannot spell keyed "
             "re-declaration")

    old = "final class KayaTpl {"
    n = sw.count(old)
    run_leaf("swift-reader", src, SW_CHAIN,
             sw.replace(old, "final class KayaTplRemoved {")
             if n == 1 else sw, n,
             "cannot find swift's dynamic-table zones")

    # HASKELL'S ZONE IS ITS TYPE (KayaApp.hs is one flat namespace),
    # and since the module's header rule reached every paired
    # registrar — the `*Node` twins are gone, one name dispatches on
    # the handle — the zone is WHICH SCOPE the arm sits in. So the
    # first perturbation of each pair takes the signature's zone away
    # with the NAME LEFT ALONE: a reader that keyed on the name, or
    # one that read the LIVE arm one scope up, would stay green there,
    # which is the defect tools/tpl-surfaces.py exists to avoid.
    hs = read_rel("bindings/haskell/KayaApp.hs")
    haskell_want = "haskell's TEMPLATE-zone table cannot spell "

    # `columns` back to a live-only signature inside `Declare` itself:
    # the name still stands in the class, and both instances still
    # spell it.
    text, n = scoped(hs, "class Monad m => Declare m where",
                     "instance Declare Build where",
                     "  columns :: El m -> [String] -> Sort -> m ()",
                     "  columns :: Widget -> [String] -> Sort -> "
                     "Build ()")
    run_leaf("haskell-columns-zone", src, HS_CHAIN, text or hs, n,
             haskell_want + "columns")

    # The TEMPLATE instance's arm deleted outright — the shape the
    # live arm hides, since `instance Declare Build` keeps spelling
    # `columns`.
    text, n = scoped(hs, "instance Declare Tpl where",
                     "-- Live-zone-only vocabulary.",
                     "  -- pathLen 0 against a TEMPLATE NODE: every "
                     "copy's bar.\n"
                     "  columns (Node n) titles sort =\n",
                     "  columnsRemoved (Node n) titles sort =\n")
    run_leaf("haskell-columns-tpl", src, HS_CHAIN, text or hs, n,
             haskell_want + "columns")

    text, n = scoped(hs, "instance Declare Tpl where",
                     "-- Live-zone-only vocabulary.",
                     "(fromIntegral (length titles))\n          0\n",
                     "(fromIntegral (length titles))\n          1\n")
    run_leaf("haskell-columns-path", src, HS_CHAIN, text or hs, n,
             haskell_want + "columns")

    text, n = scoped(hs, "instance HandlerTarget Node where",
                     "representationOf :: Maybe W.ClipValues",
                     "(appNodeSorts app)", "(appSortHandlers app)")
    run_leaf("haskell-sort-registrar", src, HS_CHAIN, text or hs, n,
             haskell_want + "on_sort")

    # The SORT ARM alone taken out of the node instance, with the
    # other five registrars and appNodeSorts' neighbours left
    # standing: one class holds all six now, so a clause that only
    # asked whether the instance exists would read green here.
    text, n = scoped(hs, "instance HandlerTarget Node where",
                     "representationOf :: Maybe W.ClipValues",
                     "  onSort app (Node n) handler =\n"
                     "    modifyIORef' (appNodeSorts app) "
                     "(Map.insert n handler)\n",
                     "")
    run_leaf("haskell-sort-arm", src, HS_CHAIN, text or hs, n,
             haskell_want + "on_sort")

    # The copy's keys taken out of the ASSOCIATED TYPE: the node
    # instance still exists, still registers in appNodeSorts, and now
    # promises the live zone's handler — for every verb at once, since
    # `Keyed` states that rule ONCE for all six.
    text, n = scoped(hs, "instance HandlerTarget Node where",
                     "representationOf :: Maybe W.ClipValues",
                     "  type Keyed Node p = [W.Value] -> p",
                     "  type Keyed Node p = p")
    run_leaf("haskell-sort-handler", src, HS_CHAIN, text or hs, n,
             haskell_want + "on_sort")

    text, n = scoped(
        hs, "| kind == W.occKindSortRequested -> do",
        "| kind == W.occKindTextChanged -> do",
        "            _ -> do\n"
        "              handlers <- readIORef (appNodeSorts app)\n"
        "              dispatch (mapM_ (\\h -> h keys column) "
        "(Map.lookup ident handlers))\n",
        "            _ -> return ()\n")
    run_leaf("haskell-sort-dispatch", src, HS_CHAIN, text or hs, n,
             haskell_want + "on_sort")

    text, n = scoped(hs, "columnsAt :: Node",
                     "-- Sums: the data declaration is the sum.",
                     "(fromIntegral (length keys))", "0")
    run_leaf("haskell-keyed-len", src, HS_CHAIN, text or hs, n,
             haskell_want + "keyed re-declaration")

    text, n = scoped(hs, "columnsAt :: Node",
                     "-- Sums: the data declaration is the sum.",
                     "(keys ++ map W.VStr titles)",
                     "(map W.VStr titles ++ keys)")
    run_leaf("haskell-keyed-order", src, HS_CHAIN, text or hs, n,
             haskell_want + "keyed re-declaration")

    old = "dispatchLoop :: App -> IO ()"
    n = hs.count(old)
    run_leaf("haskell-reader", src, HS_CHAIN,
             hs.replace(old, "dispatchLoopRemoved :: App -> IO ()")
             if n == 1 else hs, n,
             "cannot find haskell's dynamic-table zones")

    # JS, PYTHON'S AMBIENT TWIN: one `rows(opts)` configures the ordinary
    # For and one `columns(titles, opts)` the table, so its census carries
    # python's six points and its perturbations are python's, one language
    # over. Every needle is unique in the file and every one leaves the
    # LIVE spelling standing.
    js = read_rel("bindings/js/kaya/index.ts")
    js_table = "js's TEMPLATE-zone table cannot spell "
    js_points = (
        ("js-columns", "columns",
         "    return new ColumnsTrace(this as Collection<unknown, "
         "unknown>, [...titles], opts) as unknown as Iterable<R>;",
         "    return new ColumnsTraceRemoved(this as Collection<unknown, "
         "unknown>, [...titles], opts) as unknown as Iterable<R>;"),
        ("js-columns-pathlen", "columns",
         "sort.direction, this._titles.length, 0, this._titles)",
         "sort.direction, this._titles.length, 1, this._titles)"),
        ("js-sort", "on_sort",
         "app()._register(handle, wire.OCC_SORT_REQUESTED, "
         "this._opts.onSort)",
         "app()._register(handle, wire.OCC_SORT_REMOVED, "
         "this._opts.onSort)"),
        ("js-keyed-len", "keyed re-declaration",
         "titles.length, this._path.length, [...keyPath(this._path), "
         "...titles]",
         "titles.length, 0, [...keyPath(this._path), ...titles]"),
        ("js-keyed-order", "keyed re-declaration",
         "[...keyPath(this._path), ...titles]",
         "[...titles, ...keyPath(this._path)]"),
        ("js-rows-grow", "ordinary For grow",
         "    trace._grow = opts.grow ?? null;",
         "    trace._grow = null;"),
        ("js-rows-align", "ordinary For align",
         "    trace._align = opts.align ?? null;",
         "    trace._align = null;"),
        ("js-rows-a11y", "ordinary For a11y id",
         "    trace._a11yId = opts.a11yId ?? null;",
         "    trace._a11yId = null;"),
        ("js-rows-grow-emitter", "ordinary For grow",
         "records().push(wire.tx_set_grow(handle.id, "
         "Number(this._grow)))",
         "records().push(wire.tx_removed_set_grow(handle.id, "
         "Number(this._grow)))"),
        # THE HANDLE SETTER, not a const emitter: `rows({a11yId:
        # row.key})` must reach the ELEMENT arm.
        ("js-rows-a11y-emitter", "ordinary For a11y id",
         "if (this._a11yId !== null) handle.a11yId(this._a11yId);",
         "if (this._a11yId !== null) handle.a11yRemovedId(this._a11yId);"),
    )
    for name, point, old, new in js_points:
        n = js.count(old)
        run_leaf(name, src, JS_CHAIN,
                 js.replace(old, new, 1) if n == 1 else js, n,
                 js_table + point)

    old = "export class BoundCollection<E, R> {"
    n = js.count(old)
    run_leaf("js-reader", src, JS_CHAIN,
             js.replace(old, "export class BoundCollectionRemoved<E, R> {")
             if n == 1 else js, n,
             "cannot find js's dynamic-table zones")

    return "\n".join(lines)


tpl_table = tpl_table_probe()
WANT_TABLE_PROBE = """rust-columns=applied:1 rc:1 named:True
rust-sort=applied:1 rc:1 named:True
rust-keyed=applied:1 rc:1 named:True
go-columns=applied:1 rc:1 named:True
go-columns-path=applied:1 rc:1 named:True
go-nested-for=applied:1 rc:1 named:True
go-sort=applied:1 rc:1 named:True
go-sort-chain=applied:1 rc:1 named:True
go-sort-dispatch=applied:1 rc:1 named:True
go-node-handle=applied:1 rc:1 named:True
go-keyed=applied:1 rc:1 named:True
go-keyed-order=applied:1 rc:1 named:True
go-keyed-pathlen=applied:1 rc:1 named:True
go-reader=applied:1 rc:1 named:True
csharp-columns=applied:1 rc:1 named:True
csharp-sort=applied:1 rc:1 named:True
csharp-sort-arm=applied:1 rc:1 named:True
csharp-sort-keys=applied:1 rc:1 named:True
csharp-keyed=applied:1 rc:1 named:True
csharp-keyed-len=applied:1 rc:1 named:True
csharp-reader=applied:1 rc:1 named:True
ocaml-columns=applied:1 rc:1 named:True
ocaml-columns-pathlen=applied:1 rc:1 named:True
ocaml-sort-table=applied:1 rc:1 named:True
ocaml-sort-arg=applied:1 rc:1 named:True
ocaml-sort-dispatch=applied:1 rc:1 named:True
ocaml-keyed-order=applied:1 rc:1 named:True
ocaml-keyed-len=applied:1 rc:1 named:True
ocaml-reader=applied:1 rc:1 named:True
python-rows-grow=applied:1 surface-rc:1 surface-named:True \
checks-rc:1 checks-named:True
python-rows-grow-emitter=applied:1 rc:1 named:True
python-rows-align=applied:1 surface-rc:1 surface-named:True \
checks-rc:1 checks-named:True
python-rows-align-emitter=applied:1 rc:1 named:True
python-rows-a11y=applied:1 surface-rc:1 surface-named:True \
checks-rc:1 checks-named:True
python-rows-a11y-emitter=applied:1 rc:1 named:True
python-columns=applied:1 rc:1 named:True
python-sort=applied:1 rc:1 named:True
python-keyed-len=applied:1 rc:1 named:True
python-keyed-order=applied:1 rc:1 named:True
python-reader=applied:1 rc:1 named:True
swift-columns=applied:1 rc:1 named:True
swift-columns-pathlen=applied:1 rc:1 named:True
swift-sort-keys=applied:1 rc:1 named:True
swift-sort-dispatch=applied:1 rc:1 named:True
swift-keyed=applied:1 rc:1 named:True
swift-keyed-len=applied:1 rc:1 named:True
swift-keyed-order=applied:1 rc:1 named:True
swift-keyed-swap=applied:1 rc:1 named:True
swift-reader=applied:1 rc:1 named:True
haskell-columns-zone=applied:1 rc:1 named:True
haskell-columns-tpl=applied:1 rc:1 named:True
haskell-columns-path=applied:1 rc:1 named:True
haskell-sort-registrar=applied:1 rc:1 named:True
haskell-sort-arm=applied:1 rc:1 named:True
haskell-sort-handler=applied:1 rc:1 named:True
haskell-sort-dispatch=applied:1 rc:1 named:True
haskell-keyed-len=applied:1 rc:1 named:True
haskell-keyed-order=applied:1 rc:1 named:True
haskell-reader=applied:1 rc:1 named:True
js-columns=applied:1 rc:1 named:True
js-columns-pathlen=applied:1 rc:1 named:True
js-sort=applied:1 rc:1 named:True
js-keyed-len=applied:1 rc:1 named:True
js-keyed-order=applied:1 rc:1 named:True
js-rows-grow=applied:1 rc:1 named:True
js-rows-align=applied:1 rc:1 named:True
js-rows-a11y=applied:1 rc:1 named:True
js-rows-grow-emitter=applied:1 rc:1 named:True
js-rows-a11y-emitter=applied:1 rc:1 named:True
js-reader=applied:1 rc:1 named:True""".replace("\\\n", "")
if tpl_table != WANT_TABLE_PROBE:
    print("check-sugar-surface: SELF-TEST FAIL (the dynamic-table "
          "census did not catch its watched deletions). Wanted:",
          file=sys.stderr)
    print(WANT_TABLE_PROBE, file=sys.stderr)
    print("Got:", file=sys.stderr)
    print(tpl_table, file=sys.stderr)
    raise SystemExit(1)
print("check-sugar-surface: dynamic-table perturbations applied:")
print(tpl_table)


# (c2b) AND THE HASKELL SPELLING IS COMPILED. The census above reads
#       text; Haskell states the zone and the copy's key path in
#       TYPES, so only a typecheck says the three surfaces fit
#       together. This is the compile_fail doc-test's shape in the one
#       form this binding has:
#       tools/checks/haskell-table/NestedTable.hs must compile, and
#       the three mistakes it exists to stop must not.
def hs_table_probe():
    lines = []
    FIXTURE = "tools/checks/haskell-table/NestedTable.hs"
    src = read_rel(FIXTURE)
    tmp = tempfile.mkdtemp()

    def typecheck(module, text):
        path = f"{tmp}/{module}.hs"
        with open(path, "w", encoding="utf-8") as out:
            out.write(text.replace("module NestedTable",
                                   f"module {module}"))
        r = subprocess.run(
            ["ghc", "-fno-code", "-XGHC2021", "-ibindings/haskell",
             "-hidir", f"{tmp}/hi", "-odir", f"{tmp}/hi", path],
            capture_output=True, text=True, check=False)
        return r.returncode, r.stdout + r.stderr

    rc, log = typecheck("NestedTable", src)
    lines.append(f"fixture=rc:{rc}")
    if rc != 0:
        lines.append(log)

    # Each is a mistake the types are the wall for: declaring the
    # nested bar in the parent's LIVE scope, a handler that drops the
    # copy's keys, and a re-declaration that drops them.
    for module, old, new in (
        # ONE NAME, TWO ZONES, so the zone wall is no longer a wrong
        # NAME — it is the same call moved out of the template scope,
        # where `m` is Build and `El Build` is Widget while the inner
        # For handed back a Node. The move is the mistake this is here
        # to stop: the core finds the For in the scope that is still
        # open.
        ("ZoneWall",
         '      columns t ["Symbol", "Shares"] sortNone\n'
         '      _ <- columnOf [label element, pure t]\n'
         '      return (t, positions)\n'
         '    root <- row [pure accountList]\n',
         '      _ <- columnOf [label element, pure t]\n'
         '      return (t, positions)\n'
         '    columns table ["Symbol", "Shares"] sortNone\n'
         '    root <- row [pure accountList]\n'),
        # The whole handler, so the perturbation is a TYPE error and
        # not a `keys` left dangling out of scope: dropping the copy's
        # keys binds the path where the column belongs.
        ("HandlerPath",
         '  onSort app table $ \\keys column ->\n'
         '    submitTx app (columnsAt table keys ["Symbol", "Shares"] '
         '(sortAsc column))\n',
         '  onSort app table $ \\column ->\n'
         '    submitTx app (columnsAt table [] ["Symbol", "Shares"] '
         '(sortAsc column))\n'),
        ("RedeclarePath",
         'columnsAt table keys ["Symbol", "Shares"]',
         'columnsAt table ["Symbol", "Shares"]'),
        # The rows go SCALAR: a nested plain `collection` reaches
        # forEach but not recordHandle, which is the shape this
        # fixture used to have (docs/deferred.md, the nested RECORD
        # collection entry).
        ("ScalarNested",
         "      positions <- collectionOf (Proxy :: Proxy Position)",
         "      positions <- collection"),
        # The key path taken on the UNTYPED handle: the copy is
        # addressed and the element type is gone with it, so no record
        # mutation can reach one stamped table's rows.
        ("UntypedInstance",
         "    insertRecord (positions ",
         "    insertRecord (recordHandle positions "),
    ):
        n = src.count(old)
        if n != 1:
            lines.append(f"{module}=SELFTEST-BROKEN(matched {n}, "
                         f"expected 1)")
            continue
        rc, log = typecheck(module, src.replace(old, new))
        lines.append(f"{module}=applied:1 rc:{rc} "
                     f"type-error:{'Couldn' in log}")

    shutil.rmtree(tmp)
    return "\n".join(lines)


hs_table = hs_table_probe()
WANT_HS_TABLE = """fixture=rc:0
ZoneWall=applied:1 rc:1 type-error:True
HandlerPath=applied:1 rc:1 type-error:True
RedeclarePath=applied:1 rc:1 type-error:True
ScalarNested=applied:1 rc:1 type-error:True
UntypedInstance=applied:1 rc:1 type-error:True"""
if hs_table != WANT_HS_TABLE:
    print("check-sugar-surface: SELF-TEST FAIL (the haskell "
          "dynamic-table typecheck). Wanted:", file=sys.stderr)
    print(WANT_HS_TABLE, file=sys.stderr)
    print("Got:", file=sys.stderr)
    print(hs_table, file=sys.stderr)
    raise SystemExit(1)
print("check-sugar-surface: haskell dynamic-table typecheck:")
print(hs_table)


# (c2c) THE ROW'S OWN FIELDS, watched from the BINDING side. A nested
#       table whose rows cannot carry record fields is the gap this
#       closes (docs/deferred.md, "GAP — Haskell cannot declare a
#       nested RECORD collection"): `collectionOf` must stand in the
#       TEMPLATE zone, since that is the only scope a nested
#       collection may be declared in, and narrowing the handle to one
#       stamped copy must keep the element type, since every record
#       mutation takes RecordCollection.
#
#       BOTH KINDS OF WALL ARE WATCHED, because neither sees the
#       other's failure: the census catches what a typecheck cannot (a
#       record collection born with the SCALAR schema, a key silently
#       dropped on the way to the copy — both compile), and ghc
#       catches what text cannot say (a Declare method left out of ONE
#       instance is a warning in GHC's default set; KayaApp.hs's
#       -Werror=missing-methods is what turns that into a red).
#
#       A block of its own, additive: these two files are merged by
#       hand across parallel worktrees.
def hs_record_probe():
    lines = []
    APP = "bindings/haskell/KayaApp.hs"
    FIXTURE = "tools/checks/haskell-table/NestedTable.hs"
    TABLE = "haskell's TEMPLATE-zone table cannot spell "
    app = read_rel(APP)
    fixture = read_rel(FIXTURE)
    tmp = tempfile.mkdtemp()

    def stage_hs(text):
        """A temp repo root where only KayaApp.hs differs."""
        root = tempfile.mkdtemp()
        for top in os.listdir("."):
            if top != "bindings":
                os.symlink(os.path.abspath(top), f"{root}/{top}")
        for parent, keep in (("bindings", "haskell"),
                             ("bindings/haskell", "KayaApp.hs")):
            os.makedirs(f"{root}/{parent}", exist_ok=True)
            for entry in os.listdir(parent):
                if entry != keep:
                    os.symlink(os.path.abspath(f"{parent}/{entry}"),
                               f"{root}/{parent}/{entry}")
        with open(f"{root}/{APP}", "w", encoding="utf-8") as fh:
            fh.write(text)
        return root

    def census(name, old, new, point):
        n = app.count(old)
        if n != 1:
            lines.append(f"{name}=SELFTEST-BROKEN(matched {n}, "
                         f"expected 1)")
            return
        root = stage_hs(app.replace(old, new))
        r = subprocess.run(
            [sys.executable, str(ROOT / "tools" / "tpl-surfaces.py"),
             root], cwd=ROOT, capture_output=True, text=True,
            check=False)
        shutil.rmtree(root)
        lines.append(f"{name}=applied:1 rc:{r.returncode} "
                     f"named:{TABLE + point in r.stdout}")

    def library(name, text):
        """The three-module binding with one doctored KayaApp.hs."""
        lib = f"{tmp}/{name}-lib"
        os.makedirs(lib, exist_ok=True)
        for module in ("KayaWire.hs", "KayaRuntime.hs"):
            shutil.copy(ROOT / "bindings" / "haskell" / module, lib)
        with open(f"{lib}/KayaApp.hs", "w", encoding="utf-8") as fh:
            fh.write(text)
        return lib

    def ghc(name, lib, target):
        out = f"{tmp}/{name}-out"
        os.makedirs(out, exist_ok=True)
        r = subprocess.run(
            ["ghc", "-fno-code", "-XGHC2021", "-i" + lib,
             "-hidir", out, "-odir", out, target],
            capture_output=True, text=True, check=False)
        return r.returncode, r.stdout + r.stderr

    def compiles(name, old, new, markers, through_fixture):
        """A red is only a red if it is the RIGHT error, so each row
        names substrings the log must carry — a module whose name is
        not a Haskell identifier also exits 1, and did while this was
        being written."""
        n = app.count(old)
        if n != 1:
            lines.append(f"{name}=SELFTEST-BROKEN(matched {n}, "
                         f"expected 1)")
            return
        module = "".join(part.capitalize()
                         for part in name.split("-"))
        lib = library(module, app.replace(old, new))
        target = f"{lib}/KayaApp.hs"
        if through_fixture:
            target = f"{tmp}/{module}.hs"
            with open(target, "w", encoding="utf-8") as fh:
                fh.write(fixture.replace("module NestedTable",
                                         f"module {module}"))
        rc, log = ghc(module, lib, target)
        lines.append(f"{name}=applied:1 rc:{rc} "
                     f"named:{all(m in log for m in markers)}")

    # The census half. Each is a shape that compiles and lies.
    census("haskell-record-zone",
           "  collectionOf :: KayaRecord a => Proxy a -> m "
           "(RecordCollection a)",
           "  collectionOf :: KayaRecord a => Proxy a -> Build "
           "(RecordCollection a)",
           "nested record collection")
    # Watched here AS WELL AS by the compiler below: this census runs
    # where no ghc does, so its own reading of the Tpl instance has to
    # be seen red.
    census("haskell-record-tpl",
           "  collection = Tpl (newCollection [[W.valueStr]])\n"
           "  collectionOf p = Tpl (newRecordCollection p)\n",
           "  collection = Tpl (newCollection [[W.valueStr]])\n",
           "nested record collection")
    census("haskell-record-schema",
           "  let (c, s') = newCollection [kayaSchema p] s in "
           "(RecordCollection c, s')",
           "  let (c, s') = newCollection [[W.valueStr]] s in "
           "(RecordCollection c, s')",
           "nested record collection")
    census("haskell-at-record",
           "  at (RecordCollection c) key = RecordCollection "
           "(at c key)",
           "  at (RecordCollection c) _ = RecordCollection c",
           "record instance addressing")

    # The compiler half. The first is the pre-fix state exactly: the
    # template zone without the record constructor.
    compiles("haskell-tpl-method-gone",
             "  collection = Tpl (newCollection [[W.valueStr]])\n"
             "  collectionOf p = Tpl (newRecordCollection p)\n",
             "  collection = Tpl (newCollection [[W.valueStr]])\n",
             ("Werror=missing-methods", "Declare Tpl"), False)
    compiles("haskell-record-at-gone",
             "instance CollectionHandle (RecordCollection a) where\n"
             "  at (RecordCollection c) key = RecordCollection "
             "(at c key)\n",
             "",
             ("No instance for", "CollectionHandle (RecordCollection"),
             True)

    shutil.rmtree(tmp)
    return "\n".join(lines)


hs_record = hs_record_probe()
WANT_HS_RECORD = """haskell-record-zone=applied:1 rc:1 named:True
haskell-record-tpl=applied:1 rc:1 named:True
haskell-record-schema=applied:1 rc:1 named:True
haskell-at-record=applied:1 rc:1 named:True
haskell-tpl-method-gone=applied:1 rc:1 named:True
haskell-record-at-gone=applied:1 rc:1 named:True"""
if hs_record != WANT_HS_RECORD:
    print("check-sugar-surface: SELF-TEST FAIL (the haskell "
          "nested-record walls did not catch their watched "
          "deletions). Wanted:", file=sys.stderr)
    print(WANT_HS_RECORD, file=sys.stderr)
    print("Got:", file=sys.stderr)
    print(hs_record, file=sys.stderr)
    raise SystemExit(1)
print("check-sugar-surface: haskell nested-record perturbations "
      "applied:")
print(hs_record)

# The one staging helper the remaining probes share: a temp repo root
# where exactly `perturb` (path -> text) differs from the tree. One
# helper rather than seven: the surfaces these blocks watch sit across
# five directory depths, and a per-language stager would be six copies
# of the same walk.
def stage_perturb(perturb):
    root = tempfile.mkdtemp()
    dirs = {}
    for path in perturb:
        parts = path.split("/")
        for i in range(1, len(parts)):
            dirs.setdefault("/".join(parts[:i]), True)
    for top in os.listdir("."):
        if top not in dirs:
            os.symlink(os.path.abspath(top), f"{root}/{top}")
    for d in sorted(dirs):
        os.makedirs(f"{root}/{d}", exist_ok=True)
        for entry in os.listdir(d):
            child = f"{d}/{entry}"
            if child not in dirs and child not in perturb:
                os.symlink(os.path.abspath(child), f"{root}/{child}")
    for path, text in perturb.items():
        with open(f"{root}/{path}", "w", encoding="utf-8") as fh:
            fh.write(text)
    return root


def tpl_over(perturb):
    root = stage_perturb(perturb)
    r = subprocess.run(
        [sys.executable, str(ROOT / "tools" / "tpl-surfaces.py"),
         root], cwd=ROOT, capture_output=True, text=True, check=False)
    shutil.rmtree(root)
    return r


# (c2e) THE ROW'S OWN FIELDS IN THE OTHER SEVEN. The Haskell block
#       above was written as a Haskell gap; the sweep that closed it
#       found the same two halves missing in five more bindings, and
#       the census reads all nine now (docs/deferred.md, closed
#       2026-08-25; js joined with the ninth binding).
#
#       EACH PERTURBATION IS A SHAPE THAT COMPILES AND LIES, which is
#       why a census earns its keep here and a typecheck cannot stand
#       in: a template-zone constructor that opens its own
#       transaction, a narrowing that hands back a typed handle
#       addressing the PARENT, and Python's collection born without
#       the open-For edge all build and run. Both points are watched
#       in every binding — fourteen reds, the four Haskell ones being
#       (c2c)'s.
def record_probe():
    lines = []

    def census(name, rel, old, new, lang, point):
        src = read_rel(rel)
        n = src.count(old)
        if n != 1:
            lines.append(f"{name}=SELFTEST-BROKEN(matched {n}, "
                         f"expected 1)")
            return
        r = tpl_over({rel: src.replace(old, new)})
        want = f"{lang}'s TEMPLATE-zone table cannot spell {point}"
        lines.append(f"{name}=applied:1 rc:{r.returncode} "
                     f"named:{want in r.stdout}")

    RUST = "crates/kaya/src/app.rs"
    GO = "bindings/go/records.go"
    CS = "bindings/csharp/KayaRecords.cs"
    JAVA = "bindings/java/dev/kaya/KayaRecords.java"
    SWIFT_APP = "bindings/swift/KayaApp.swift"
    SWIFT_REC = "bindings/swift/KayaRecords.swift"
    ML = "bindings/ocaml/kaya_app.ml"
    PY = "bindings/python/kaya/__init__.py"

    census("rust-record-zone", RUST,
           "    pub fn collection<T: KayaSum>(&mut self) -> "
           "Collection<T> {\n"
           "        let id = self.tx.ctx.alloc_collection();",
           "    pub fn collection_removed<T: KayaSum>(&mut self) -> "
           "Collection<T> {\n"
           "        let id = self.tx.ctx.alloc_collection();",
           "rust", "nested record collection")
    # The key DROPPED on the way to the copy: the handle stays
    # Collection<T> and every mutation through it addresses the
    # parent's table.
    census("rust-record-at", RUST,
           "        let mut path = self.path.clone();\n"
           "        path.push(key.into());",
           "        let path = self.path.clone();",
           "rust", "record instance addressing")

    # The zone handle IGNORED: a body that opens its own transaction
    # declares the collection outside the template scope and the core
    # refuses the nested For — at run time, on one platform, with the
    # guest already built.
    census("go-record-zone", GO,
           "func TplCollectionOf[K Key, T any](t *Tpl) "
           "RecordCollection[K, T] {\n"
           "\treturn newRecordCollection[K, T](t.tx)",
           "func TplCollectionOf[K Key, T any](t *Tpl) "
           "RecordCollection[K, T] {\n"
           "\treturn newRecordCollection[K, T](theTx())",
           "go", "nested record collection")
    census("go-record-at", GO,
           "\treturn RecordCollection[K, T]{c.Collection.At(key), "
           "c.info}",
           "\treturn RecordCollection[K, T]{c.Collection, c.info}",
           "go", "record instance addressing")

    census("csharp-record-zone", CS,
           "    public static RecordCollection<T> CollectionOf<T>"
           "(this Tpl t) => Declare<T>(t.Tx);",
           "",
           "csharp", "nested record collection")
    # The PRE-FIX state exactly: the promoted untyped narrowing, which
    # drops T and puts Insert/Patch/UpdateField out of reach.
    census("csharp-record-at", CS,
           "    public RecordCollection<T> At(object key) =>\n"
           "        new RecordCollection<T>(Collection.At(key), "
           "Info);",
           "    public Collection At(object key) => "
           "Collection.At(key);",
           "csharp", "record instance addressing")

    # The ROW SURFACE overload, which is the handle a Java scene
    # actually holds: with only the Tpl one, `tx.rows(c)`'s body
    # cannot spell it.
    census("java-record-zone", JAVA,
           "    public static <K, T> Collection<K, T> collectionOf"
           "(KayaApp.RowSurface row, Class<T> type) {",
           "    public static <K, T> Collection<K, T> collectionOfRow"
           "(KayaApp.RowSurface row, Class<T> type) {",
           "java", "nested record collection")
    census("java-record-at", JAVA,
           "            return new Collection<>(handle.at(key), "
           "info);",
           "            return new Collection<>(handle, info);",
           "java", "record instance addressing")

    census("swift-record-zone", SWIFT_APP,
           "    func collection<T: KayaRecord>(of type: T.Type) -> "
           "KayaRecordCollection<T> {\n"
           "        tx.collection(of: type)\n    }",
           "",
           "swift", "nested record collection")
    census("swift-record-at", SWIFT_REC,
           "        KayaRecordCollection(collection: "
           "collection.at(key))",
           "        KayaRecordCollection(collection: collection)",
           "swift", "record instance addressing")

    census("ocaml-record-zone", ML,
           "  let collection_of rt = collection_of rt\n",
           "",
           "ocaml", "nested record collection")
    census("ocaml-record-at", ML,
           "let record_at rc key = { rc with rc_handle = at "
           "rc.rc_handle key }",
           "let record_at rc _key = rc",
           "ocaml", "record instance addressing")

    # Python's constructor is AMBIENT, so the open-For edge is the
    # only thing that says a collection born inside a template belongs
    # to the copies rather than to the live tree.
    census("python-record-zone", PY,
           "        _for_collections[-1]._children.append(handle)",
           "        pass",
           "python", "nested record collection")
    census("python-record-at", PY,
           "        return _BoundCollection(self, list(path))",
           "        return _BoundCollection(_app._collections"
           "[self._id], list(path))",
           "python", "record instance addressing")

    # JS is python's twin here too: an ambient constructor, so the
    # open-For edge is the only thing that says a collection born inside a
    # template belongs to the copies rather than to the live tree, and a
    # narrowing that drops the key addresses the parent.
    JS = "bindings/js/kaya/index.ts"
    census("js-record-zone", JS,
           "if (enclosing !== undefined) enclosing._children.push(handle);",
           "if (enclosing !== undefined) void enclosing;",
           "js", "nested record collection")
    census("js-record-at", JS,
           "    return new BoundCollection(this, path);",
           "    return new BoundCollection(this, []);",
           "js", "record instance addressing")
    return "\n".join(lines)


record = record_probe()
WANT_RECORD = """rust-record-zone=applied:1 rc:1 named:True
rust-record-at=applied:1 rc:1 named:True
go-record-zone=applied:1 rc:1 named:True
go-record-at=applied:1 rc:1 named:True
csharp-record-zone=applied:1 rc:1 named:True
csharp-record-at=applied:1 rc:1 named:True
java-record-zone=applied:1 rc:1 named:True
java-record-at=applied:1 rc:1 named:True
swift-record-zone=applied:1 rc:1 named:True
swift-record-at=applied:1 rc:1 named:True
ocaml-record-zone=applied:1 rc:1 named:True
ocaml-record-at=applied:1 rc:1 named:True
python-record-zone=applied:1 rc:1 named:True
python-record-at=applied:1 rc:1 named:True
js-record-zone=applied:1 rc:1 named:True
js-record-at=applied:1 rc:1 named:True"""
if record != WANT_RECORD:
    print("check-sugar-surface: SELF-TEST FAIL (the nested-record "
          "census did not catch its watched perturbations). Wanted:",
          file=sys.stderr)
    print(WANT_RECORD, file=sys.stderr)
    print("Got:", file=sys.stderr)
    print(record, file=sys.stderr)
    raise SystemExit(1)
print("check-sugar-surface: nested-record perturbations applied "
      "(8 bindings):")
print(record)


# (c2d) THE ZONE-SPANNING SURFACES, watched from the COMPILER side.
#       Every `*Node` twin is gone — one name dispatches on the handle
#       (the module header's rule) — so what used to be a distinct
#       NAME per zone is now an arm inside a per-zone instance, and
#       the wall that keeps a template zone's arm from going missing
#       is KayaApp.hs's -Werror=missing-methods.
#
#       ALL SIX REGISTRARS SIT IN ONE CLASS for exactly that wall: a
#       verb in a class of its own could ship with the Node instance
#       absent and nothing here would compile red, because
#       missing-methods sees an incomplete instance and never a
#       missing one. So the watch is per zone rather than per verb —
#       one deleted arm on each side.
#
#       THE ASSOCIATED TYPE IS A DIFFERENT RED, and that is why it is
#       watched beside them: dropping `type Keyed Node p` is a plain
#       type error, NOT a missing-methods one, so a session that goes
#       looking for the missing-methods sentence would not find it.
def hs_zone_probe():
    lines = []
    app = read_rel("bindings/haskell/KayaApp.hs")
    tmp = tempfile.mkdtemp()

    TPL_COLUMNS = """  -- pathLen 0 against a TEMPLATE NODE: every copy's bar.
  columns (Node n) titles sort =
    emitT
      ( W.txSetColumnHeaders
          n
          (sortColumn sort)
          (sortDirection sort)
          (fromIntegral (length titles))
          0
          (map W.VStr titles)
      )
"""

    NODE_SORT = """  onSort app (Node n) handler =
    modifyIORef' (appNodeSorts app) (Map.insert n handler)
"""

    WIDGET_PASTE = """  onPaste app (Widget n) handler =
    modifyIORef' (appWidgetPastes app) (Map.insert n handler)
"""

    def compiles(name, old, new, markers):
        """A red is only a red if it is the RIGHT error, so each row
        names substrings the log must carry."""
        n = app.count(old)
        if n != 1:
            lines.append(f"{name}=SELFTEST-BROKEN(matched {n}, "
                         f"expected 1)")
            return
        module = "".join(part.capitalize()
                         for part in name.split("-"))
        lib = f"{tmp}/{module}-lib"
        out = f"{tmp}/{module}-out"
        os.makedirs(lib, exist_ok=True)
        os.makedirs(out, exist_ok=True)
        for module_file in ("KayaWire.hs", "KayaRuntime.hs"):
            shutil.copy(ROOT / "bindings" / "haskell" / module_file,
                        lib)
        with open(f"{lib}/KayaApp.hs", "w", encoding="utf-8") as fh:
            fh.write(app.replace(old, new))
        r = subprocess.run(
            ["ghc", "-fno-code", "-XGHC2021", "-i" + lib,
             "-hidir", out, "-odir", out, f"{lib}/KayaApp.hs"],
            capture_output=True, text=True, check=False)
        log = r.stdout + r.stderr
        lines.append(f"{name}=applied:1 rc:{r.returncode} "
                     f"named:{all(m in log for m in markers)}")

    # The header bar's TEMPLATE arm gone, with the live arm one scope
    # up still spelling the name: the pre-unification
    # `columnsNode`-only state.
    compiles("haskell-tpl-columns-gone", TPL_COLUMNS, "",
             ("Werror=missing-methods", "columns", "Declare Tpl"))
    # The node registrar gone, with the live one still there.
    compiles("haskell-node-sort-gone", NODE_SORT, "",
             ("Werror=missing-methods", "onSort",
              "HandlerTarget Node"))
    # AND THE OTHER DIRECTION, because the class spans both zones and
    # only a per-zone watch can say so: the LIVE arm of a different
    # verb gone, with the template arm still there.
    compiles("haskell-widget-paste-gone", WIDGET_PASTE, "",
             ("Werror=missing-methods", "onPaste",
              "HandlerTarget Widget"))
    # The handler's SHAPE gone: not missing-methods, a stuck family.
    compiles("haskell-keyed-node-gone",
             "  type Keyed Node p = [W.Value] -> p\n", "",
             ("Couldn", "Keyed Node"))

    shutil.rmtree(tmp)
    return "\n".join(lines)


hs_zone = hs_zone_probe()
WANT_HS_ZONE = """haskell-tpl-columns-gone=applied:1 rc:1 named:True
haskell-node-sort-gone=applied:1 rc:1 named:True
haskell-widget-paste-gone=applied:1 rc:1 named:True
haskell-keyed-node-gone=applied:1 rc:1 named:True"""
if hs_zone != WANT_HS_ZONE:
    print("check-sugar-surface: SELF-TEST FAIL (the haskell "
          "zone-spanning walls did not catch their watched "
          "deletions). Wanted:", file=sys.stderr)
    print(WANT_HS_ZONE, file=sys.stderr)
    print("Got:", file=sys.stderr)
    print(hs_zone, file=sys.stderr)
    raise SystemExit(1)
print("check-sugar-surface: haskell zone-spanning perturbations "
      "applied:")
print(hs_zone)


# (c3) JAVA'S DYNAMIC-TABLE READER, watched at each of its three
#      points and at the façade half that lets the for-statement form
#      reach them.
def java_table_probe():
    lines = []
    APP = "bindings/java/dev/kaya/KayaApp.java"
    TPL = "    public final class Tpl {"
    BUILD = "    public void build(Consumer<Tx> build) {"
    TABLE = "java's TEMPLATE-zone table cannot spell "
    src = read_rel(APP)

    def run(name, text, count, want):
        if count != 1:
            lines.append(f"{name}=SELFTEST-BROKEN(matched {count}, "
                         f"expected 1)")
            return
        r = tpl_over({APP: text})
        lines.append(f"{name}=applied:1 rc:{r.returncode} "
                     f"named:{want in r.stdout}")

    def scoped_java(name, old, new, want):
        """A perturbation confined to the Tpl class: the same spelling
        in RowSurface and in the LIVE Tx stays, so a reader satisfied
        by either of those passes and a zone-scoped one cannot."""
        if src.count(TPL) != 1:
            lines.append(f"{name}=SELFTEST-BROKEN(zone header matched "
                         f"{src.count(TPL)})")
            return
        at, end = src.index(TPL), src.index(BUILD, src.index(TPL))
        block = src[at:end]
        n = block.count(old)
        run(name,
            src[:at] + block.replace(old, new) + src[end:]
            if n == 1 else src, n, want)

    def whole(name, old, new, want):
        n = src.count(old)
        run(name, src.replace(old, new) if n == 1 else src, n, want)

    scoped_java("java-columns", "    public void columns(Node ",
                "    public void columnsRemoved(Node ",
                TABLE + "columns")
    scoped_java("java-columns-pathlen", "titles.length, 0, values)",
                "titles.length, 1, values)", TABLE + "columns")

    whole("java-sort-keys",
          "void accept(Tx tx, List<Object> keys, int column);",
          "void accept(Tx tx, int column);", TABLE + "on_sort")
    whole("java-sort-route", "nodeSorts.get(occ.id)",
          "nodeSortsRemoved.get(occ.id)", TABLE + "on_sort")

    whole("java-keyed-order",
          "System.arraycopy(titles, 0, values, keys.size(), "
          "titles.length);",
          "System.arraycopy(titles, 0, values, 0, titles.length);",
          TABLE + "keyed re-declaration")
    whole("java-keyed-len", "titles.length, keys.size(), values)",
          "titles.length, 0, values)", TABLE + "keyed re-declaration")

    # The façade half: a forward deleted from RowSurface leaves the
    # nested table unspellable from a row at all — `rows` is the only
    # For form. THE READER HAD TO LEARN THE RETURN TYPE FIRST: read
    # for Node and void alone it saw `rows` on NEITHER side and called
    # the façade level, which was measured passing with this exact
    # forward deleted (2026-08-24).
    whole("java-facade-columns",
          "        public void columns(Node n, String[] titles, Sort "
          "sort) {\n"
          "            t.columns(n, titles, sort);\n        }\n", "",
          "does not forward: columns(Node, String[], Sort)")
    whole("java-facade-rows",
          "        public Rows<Node, Row> rows(Collection c) {\n"
          "            return t.rows(c);\n        }\n", "",
          "does not forward: rows(Collection)")

    # And the refusal: a reader that can no longer find the zone must
    # say so rather than report a binding with nothing missing.
    whole("java-reader", TPL + "\n",
          "    public final class TplRenamed {\n",
          "cannot find java's dynamic-table zones")
    return "\n".join(lines)


java_table = java_table_probe()
WANT_JAVA_TABLE = """java-columns=applied:1 rc:1 named:True
java-columns-pathlen=applied:1 rc:1 named:True
java-sort-keys=applied:1 rc:1 named:True
java-sort-route=applied:1 rc:1 named:True
java-keyed-order=applied:1 rc:1 named:True
java-keyed-len=applied:1 rc:1 named:True
java-facade-columns=applied:1 rc:1 named:True
java-facade-rows=applied:1 rc:1 named:True
java-reader=applied:1 rc:1 named:True"""
if java_table != WANT_JAVA_TABLE:
    print("check-sugar-surface: SELF-TEST FAIL (the Java "
          "dynamic-table census did not catch its watched "
          "deletions). Wanted:", file=sys.stderr)
    print(WANT_JAVA_TABLE, file=sys.stderr)
    print("Got:", file=sys.stderr)
    print(java_table, file=sys.stderr)
    raise SystemExit(1)
print("check-sugar-surface: java dynamic-table perturbations applied:")
print(java_table)


# (c4) C#'S GENERATED FAÇADE AND ITS TWIN. Both halves are emitted by
#      tools/kaya-csgen into every guests/csharp/*Kaya.cs at once, so
#      a perturbation lands in ONE staged file and the census must
#      still name it: the nested-For vocabulary the façade forwards (a
#      row that cannot open a For cannot name the Node whose bar
#      Columns declares), and the `Each(Tpl, …)` twin without which a
#      nested typed For's body holds the raw zone. docs/deferred.md,
#      closed 2026-08-24.
def csharp_facade_probe():
    lines = []
    GEN = "guests/csharp/TableItemKaya.cs"
    src = read_rel(GEN)

    def run(name, text, count, want):
        if count != 1:
            lines.append(f"{name}=SELFTEST-BROKEN(matched {count}, "
                         f"expected 1)")
            return
        r = tpl_over({GEN: text})
        lines.append(f"{name}=applied:1 rc:{r.returncode} "
                     f"named:{want in r.stdout}")

    def cut(name, old, want):
        n = src.count(old)
        run(name, src.replace(old, "") if n == 1 else src, n, want)

    cut("csharp-facade-collection",
        "    public Collection Collection() => t.Collection();\n",
        "does not forward: Collection()")
    cut("csharp-facade-each",
        "    public Node Each(Collection c, System.Action<Tpl> body) "
        "=> t.Each(c, body);\n",
        "does not forward: Each(Collection, Action<Tpl>)")
    cut("csharp-facade-foreach",
        "    public Node ForEach(Collection c,\n"
        "        System.Action<Tpl> body) =>\n"
        "        t.ForEach(c, body);\n",
        "does not forward: ForEach(Collection, Action<Tpl>)")
    cut("csharp-facade-columns",
        "    public void Columns(Node n, string[] titles, Sort sort) "
        "=>\n"
        "        t.Columns(n, titles, sort);\n",
        "does not forward: Columns(Node, string[], Sort)")

    # The typed sugar's two zones, one at a time.
    cut("csharp-twin-nested",
        "    public static Node Each(Tpl t, "
        "RecordCollection<TableItem> c,\n"
        "        System.Action<TableItemRow> body) =>\n"
        "        t.Each(c.Collection, inner => body(new "
        "TableItemRow(inner)));\n",
        "has no Tpl-zone `Each` handing out `TableItemRow`")
    cut("csharp-twin-live",
        "    public static Widget Each(Tx tx, "
        "RecordCollection<TableItem> c,\n"
        "        System.Action<TableItemRow> body) =>\n"
        "        tx.Each(c.Collection, t => body(new "
        "TableItemRow(t)));\n",
        "has no Tx-zone `Each` handing out `TableItemRow`")

    # And the reader: with the row surface renamed, the twin census
    # must report that it read FEWER generated surfaces than the tree
    # carries rather than agreeing with a file it stopped seeing.
    n = src.count("sealed class TableItemRow\n")
    run("csharp-twin-reader",
        src.replace("sealed class TableItemRow\n",
                    "sealed class TableItemRowGone\n")
        if n == 1 else src, n, "typed-row reader found only 2")
    return "\n".join(lines)


csharp_facade = csharp_facade_probe()
WANT_CS_FACADE = """csharp-facade-collection=applied:1 rc:1 named:True
csharp-facade-each=applied:1 rc:1 named:True
csharp-facade-foreach=applied:1 rc:1 named:True
csharp-facade-columns=applied:1 rc:1 named:True
csharp-twin-nested=applied:1 rc:1 named:True
csharp-twin-live=applied:1 rc:1 named:True
csharp-twin-reader=applied:1 rc:1 named:True"""
if csharp_facade != WANT_CS_FACADE:
    print("check-sugar-surface: SELF-TEST FAIL (the C# "
          "generated-façade census did not catch its watched "
          "deletions). Wanted:", file=sys.stderr)
    print(WANT_CS_FACADE, file=sys.stderr)
    print("Got:", file=sys.stderr)
    print(csharp_facade, file=sys.stderr)
    raise SystemExit(1)
print("check-sugar-surface: csharp generated-façade perturbations "
      "applied:")
print(csharp_facade)

# (c2) AND THE GUEST THAT SPELLS THEM. The census above says Python
#      CAN spell the dynamic-table geometry; the portfolio guest is
#      what spells it, and invariant 5 is why the example is the
#      exerciser.
#
#      STRUCTURAL, over the guest's AST. Byte-exact needles carrying
#      newlines and indentation used to stand here, and a pure
#      reformat reddened them with a sentence naming a property that
#      was present (the review of 01dd633, D6). Every probe below
#      reformats the guest through ast.unparse, so each one
#      re-measures that: `reflow` removes nothing and must come back
#      GREEN, and the count of byte-exact declaration segments
#      surviving the reformat is printed beside it.
#
#      Watched exactly like (d) and (e): a staged tree where one file
#      differs, the REAL census re-run as a SUBPROCESS against that
#      root, rc AND the exact sentence demanded. The clause it
#      replaces perturbed its own helper's input and asked the SAME
#      helper — nothing else observed it, so only str.count could
#      fail.
PORTFOLIO_CENSUS = r'''
import ast
import sys

PATH = "guests/python/portfolio.py"
tree = ast.parse(open(f"{sys.argv[1]}/{PATH}", encoding="utf-8").read(), PATH)
bad = []


def is_call(node, attr):
    return (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
            and node.func.attr == attr)


def columns_with(node, holds=None):
    return [n for n in ast.walk(node) if isinstance(n, ast.With)
            and any(is_call(i.context_expr, "column") for i in n.items)
            and (holds is None or holds in n.body)]


def opener(with_node):
    return next(i.context_expr for i in with_node.items
                if is_call(i.context_expr, "column"))


def sole(what, shape, found):
    if len(found) == 1:
        return found[0]
    bad.append(f"check-sugar-surface: cannot find portfolio's {what} — {len(found)} "
               f"{shape} in {PATH}, wanted exactly 1. A reader that cannot find "
               "its subject agrees with anything.")
    return None


def declares(call, what, name, want=None):
    """`want=None`: present, any expression — a handler is not a literal."""
    node = next((k.value for k in call.keywords if k.arg == name), None)
    if node is None:
        bad.append(f"check-sugar-surface: portfolio's {what} does not declare "
                   f"`{name}` ({PATH})")
        return
    if want is None:
        return
    try:
        value = ast.literal_eval(node)
    except (ValueError, SyntaxError):
        value = None
    if value != want:
        bad.append(f"check-sugar-surface: portfolio's {what} declares {name}="
                   f"{value!r}, wanted {want!r} ({PATH})")


rows = sole("account-row For", "`for … in ….rows(…)` loops",
            [n for n in ast.walk(tree)
             if isinstance(n, ast.For) and is_call(n.iter, "rows")])
if rows is not None:
    declares(rows.iter, "account-row For", "align", "stretch")
    declares(rows.iter, "account-row For", "a11y_id", "accounts")
    detail = sole("detail column", "`with ….column(…)` statements holding it",
                  columns_with(tree, holds=rows))
    if detail is not None:
        declares(opener(detail), "detail column", "grow", 1)
        declares(opener(detail), "detail column", "align", "stretch")
    card = sole("account card", "`with ….column(…)` statements inside it",
                columns_with(rows))
    if card is not None:
        declares(opener(card), "account card", "align", "stretch")
        table = sole("positions table", "`for … in ….columns(…)` loops inside it",
                     [n for n in ast.walk(card)
                      if isinstance(n, ast.For) and is_call(n.iter, "columns")])
        if table is not None:
            declares(table.iter, "positions table", "on_sort")
            declares(table.iter, "positions table", "a11y_id", "positions")

if bad:
    print("\n".join(bad))
sys.exit(1 if bad else 0)
'''


def portfolio_probe():
    import ast as ast_mod
    PATH = "guests/python/portfolio.py"
    lines = []
    work = tempfile.mkdtemp()
    census_py = f"{work}/portfolio-census.py"
    with open(census_py, "w", encoding="utf-8") as fh:
        fh.write(PORTFOLIO_CENSUS)

    def census(root):
        return subprocess.run([sys.executable, census_py, root],
                              capture_output=True, text=True,
                              check=False)

    source = read_rel(PATH)
    real = census(os.getcwd())
    sys.stdout.write(real.stdout)
    if real.stderr:
        sys.stderr.write(real.stderr)

    def is_call(node, attr):
        return (isinstance(node, ast_mod.Call)
                and isinstance(node.func, ast_mod.Attribute)
                and node.func.attr == attr)

    def sites(tree):
        """The four declarations, by the structure the census reads
        them by."""
        found = {}
        rows = next((n for n in ast_mod.walk(tree)
                     if isinstance(n, ast_mod.For)
                     and is_call(n.iter, "rows")), None)
        if rows is None:
            return found
        found["rows"] = rows.iter
        withs = [n for n in ast_mod.walk(tree)
                 if isinstance(n, ast_mod.With)
                 and any(is_call(i.context_expr, "column")
                         for i in n.items)]
        inside = list(ast_mod.walk(rows))
        detail = next((n for n in withs if rows in n.body), None)
        card = next((n for n in withs if n in inside), None)
        if detail is not None:
            found["detail"] = next(i.context_expr for i in detail.items
                                   if is_call(i.context_expr,
                                              "column"))
        if card is not None:
            found["card"] = next(i.context_expr for i in card.items
                                 if is_call(i.context_expr, "column"))
            columns = next((n for n in ast_mod.walk(card)
                            if isinstance(n, ast_mod.For)
                            and is_call(n.iter, "columns")), None)
            if columns is not None:
                found["columns"] = columns.iter
        return found

    # THE EXACT BYTES of the declarations as the guest writes them
    # today — what a needle-based clause would have to carry. Counted
    # after each reformat, never asserted.
    declarations = [ast_mod.get_source_segment(source, node)
                    for node in
                    sites(ast_mod.parse(source, PATH)).values()]

    def reformatted(site=None, keyword=None):
        """The guest through ast.unparse, optionally with one keyword
        dropped from one declaration. Returns (text, keywords
        removed)."""
        tree = ast_mod.parse(source, PATH)
        removed = 0
        if site is not None:
            call = sites(tree).get(site)
            if call is None:
                return None, 0
            keep = [k for k in call.keywords if k.arg != keyword]
            removed = len(call.keywords) - len(keep)
            call.keywords = keep
        return ast_mod.unparse(tree), removed

    def probe(name, site, keyword, want):
        text, removed = reformatted(site, keyword)
        if text is None or removed != 1:
            lines.append(f"{name}=SELFTEST-BROKEN(removed {removed} "
                         f"`{keyword}` from {site})")
            return
        root = stage_perturb({PATH: text})
        r = census(root)
        shutil.rmtree(root)
        survivors = sum(1 for d in declarations if d and d in text)
        lines.append(f"{name}=removed:1 rc:{r.returncode} "
                     f"named:{want in r.stdout} "
                     f"byte-exact-declarations-surviving:"
                     f"{survivors}/{len(declarations)}")

    probe("p1-rows-align", "rows", "align",
          "portfolio's account-row For does not declare `align`")
    probe("p2-detail-grow", "detail", "grow",
          "portfolio's detail column does not declare `grow`")
    probe("p3-card-align", "card", "align",
          "portfolio's account card does not declare `align`")
    probe("p4-table-id", "columns", "a11y_id",
          "portfolio's positions table does not declare `a11y_id`")

    # The reader must REFUSE when it cannot find its subject, never
    # report a guest with no declarations as clean.
    refusal = "cannot find portfolio's account-row For"
    renamed = source.replace("accounts.rows(", "accounts.rowsRenamed(",
                             1)
    root = stage_perturb({PATH: renamed})
    r = census(root)
    shutil.rmtree(root)
    lines.append(f"p5-renamed-rows=removed:"
                 f"{source.count('accounts.rows(')} "
                 f"rc:{r.returncode} named:{refusal in r.stdout} "
                 f"byte-exact-declarations-surviving:-")

    # The D6 control, and the only one that must come back GREEN: the
    # guest reformatted, nothing removed.
    text, _ = reformatted()
    root = stage_perturb({PATH: text})
    r = census(root)
    shutil.rmtree(root)
    survivors = sum(1 for d in declarations if d and d in text)
    lines.append(
        f"reflow=removed:0 rc:{r.returncode} "
        f"findings:{len([ln for ln in r.stdout.splitlines() if ln])} "
        f"byte-exact-declarations-surviving:"
        f"{survivors}/{len(declarations)}")
    shutil.rmtree(work, ignore_errors=True)
    return "\n".join(lines), real.returncode


portfolio_out, portfolio_rc = portfolio_probe()
portfolio_watched = "\n".join(
    ln for ln in portfolio_out.splitlines()
    if re.match(r"^(p[0-9]|reflow)", ln))
WANT_PORTFOLIO = """p1-rows-align=removed:1 rc:1 named:True \
byte-exact-declarations-surviving:0/4
p2-detail-grow=removed:1 rc:1 named:True \
byte-exact-declarations-surviving:0/4
p3-card-align=removed:1 rc:1 named:True \
byte-exact-declarations-surviving:0/4
p4-table-id=removed:1 rc:1 named:True \
byte-exact-declarations-surviving:0/4
p5-renamed-rows=removed:1 rc:1 named:True \
byte-exact-declarations-surviving:-
reflow=removed:0 rc:0 findings:0 \
byte-exact-declarations-surviving:0/4""".replace("\\\n", "")
if portfolio_watched != WANT_PORTFOLIO:
    print("check-sugar-surface: SELF-TEST FAIL (the portfolio guest "
          "census did not catch a perturbation it must catch, or "
          "reddened on a pure reformat). Wanted:", file=sys.stderr)
    print(WANT_PORTFOLIO, file=sys.stderr)
    print("Got:", file=sys.stderr)
    print(portfolio_out, file=sys.stderr)
    raise SystemExit(1)
print(portfolio_out)
if portfolio_rc != 0:
    status = 1


# (d) THE PROP CENSUS IS WATCHED THE SAME WAY, in three perturbations.
#
#     d1 is a prop the LIVE zone has and the TEMPLATE zone does not,
#        in OCaml because its two zones spell the prop in the same
#        eleven characters. The live setter stays, so a census
#        satisfied by the live twin passes and a zone-scoped one
#        cannot.
#     d2 is a forward deleted from a GENERATED C# façade.
#     d3 renames the zone's own header: a reader that can no longer
#        find the zone must REFUSE, never report an empty zone as
#        clean.
def prop_probe():
    lines = []

    def probe(name, path, old, new, want):
        src = read_rel(path)
        n = src.count(old)
        if n != 1:
            lines.append(f"{name}=SELFTEST-BROKEN(matched {n}, "
                         f"expected 1)")
            return
        r = tpl_over({path: src.replace(old, new)})
        lines.append(f"{name}=applied:1 rc:{r.returncode} "
                     f"named:{want in r.stdout}")

    def probe_many(name, path, pairs, want):
        """probe with several substitutions, for the clause whose red
        needs more than one member gone."""
        text = read_rel(path)
        for old, new in pairs:
            n = text.count(old)
            if n != 1:
                lines.append(f"{name}=SELFTEST-BROKEN({old[:20]!r} "
                             f"matched {n}, expected 1)")
                return
            text = text.replace(old, new)
        r = tpl_over({path: text})
        lines.append(f"{name}=applied:{len(pairs)} rc:{r.returncode} "
                     f"named:{want in r.stdout}")

    probe("d1", "bindings/ocaml/kaya_app.ml",
          "    let set_role (Node id) r = emit (the_tx ()) "
          "(Kaya_wire.tx_set_role id (role_wire r))\n",
          "", "ocaml's TEMPLATE zone cannot spell role")
    probe("d2", "guests/csharp/ItemKaya.cs",
          "    public void SetRole(Node n, Role role) => "
          "t.SetRole(n, role);\n",
          "", "does not forward: SetRole")
    probe("d3", "bindings/ocaml/kaya_app.ml",
          "module Tpl = struct\n", "module TplRenamed = struct\n",
          "cannot find ocaml's template zone")
    # d4..d6 are the js zone's, which is TWO STRUCTURES (tpl-surfaces'
    # members_js): a chainable setter deleted off the shared base, the
    # option writer taught to ASK WHICH ZONE IT IS IN — the cut every
    # other link survives, python's `_set_inset` reading `_tpl_depth` one
    # language over — and the zone header renamed, which must REFUSE.
    JS = "bindings/js/kaya/index.ts"
    probe("d4", JS,
          "  role(role: RoleValue | RoleName): this {",
          "  roleRemoved(role: RoleValue | RoleName): this {",
          "js's TEMPLATE zone cannot spell role")
    probe("d5", JS,
          "function setGrow(handle: Handle, opts: GrowOption): void {",
          "function setGrow(handle: Handle, opts: GrowOption): void {\n"
          "  if ((handle as Widget).isNode) return;",
          "js's TEMPLATE zone cannot spell grow")
    probe("d6", JS, "export class Handle {", "export class HandleRenamed {",
          "cannot find js's template zone for the prop census")
    # d7 — THE REFUSE-FLOOR ITSELF, which no zone in this census had ever
    # been watched printing. THE PERTURBATION IS AN INDENT, not a rename:
    # a renamed member is still a member the reader counts, so the first
    # draft of this probe left the count at ten and reddened on the prop
    # clause instead — the floor branch stayed unseen. Shifting three
    # declarations out of the member column is what actually starves the
    # reader, and a census that has stopped seeing its surface must SAY
    # SO rather than agree with what is left.
    probe_many("d7", JS, [
        ("  onPaste(fn: Handler): this {",
         "    onPaste(fn: Handler): this {"),
        ("  draw(...args: [...Key[], (d: Draw) => void]): void {",
         "    draw(...args: [...Key[], (d: Draw) => void]): void {"),
        ("  accepts(...kinds: string[]): this {",
         "    accepts(...kinds: string[]): this {"),
    ], "js's prop reader found only 7 members")
    return "\n".join(lines)


prop = prop_probe()
WANT_PROP = """d1=applied:1 rc:1 named:True
d2=applied:1 rc:1 named:True
d3=applied:1 rc:1 named:True
d4=applied:1 rc:1 named:True
d5=applied:1 rc:1 named:True
d6=applied:1 rc:1 named:True
d7=applied:3 rc:1 named:True"""
if prop != WANT_PROP:
    print("check-sugar-surface: SELF-TEST FAIL (the template PROP "
          "census did not catch a perturbation it must catch). "
          "Wanted:", file=sys.stderr)
    print(WANT_PROP, file=sys.stderr)
    print("Got:", file=sys.stderr)
    print(prop, file=sys.stderr)
    raise SystemExit(1)


# (e) AND THE TAKES-A-SOURCE CENSUS asks what the two above
#     structurally cannot: not whether the kind has a constructor,
#     but whether that constructor can be handed the ROW.
#     `Tpl.Button(string)` satisfies the kind census exactly as
#     `Tpl.button(Signal<String>)` does (docs/deferred.md).
#
#     e1 splices the three bindings' files back in from git at
#        c9bb989, everything else the real tree; the census must come
#        back red naming exactly csharp, swift and python. The splice
#        is REFUSED if a file comes back byte-identical to the working
#        tree.
#     e2 deletes JAVA's field overload — a binding that slice never
#        touched — so a census keyed to the three that were fixed
#        cannot pass.
#     e3 renames Haskell's constructor: a reader that can no longer
#        find the point must REFUSE, never report a binding with no
#        sources.
def src_probe():
    lines = []
    LANGS = ("rust", "go", "csharp", "java", "swift", "ocaml",
             "haskell", "python")
    BASE = "c9bb989"  # the commit the drift was closed on top of

    # e1 — the historical shape, read out of git rather than re-typed
    # here.
    perturb = {}
    broken = False
    for path in ("bindings/csharp/KayaApp.cs",
                 "bindings/swift/KayaApp.swift",
                 "bindings/python/kaya/__init__.py"):
        old = subprocess.run(["git", "show", f"{BASE}:{path}"],
                             cwd=ROOT, capture_output=True, text=True,
                             check=False)
        if old.returncode != 0:
            lines.append(f"e1=SELFTEST-BROKEN(cannot read "
                         f"{BASE}:{path})")
            broken = True
            break
        if old.stdout == read_rel(path):
            lines.append(f"e1=SELFTEST-BROKEN({path} unchanged since "
                         f"{BASE})")
            broken = True
            break
        perturb[path] = old.stdout
    if not broken:
        r = tpl_over(perturb)
        named = [lang for lang in LANGS
                 if f"{lang}'s TEMPLATE-zone button caption"
                 in r.stdout]
        lines.append(f"e1=applied:{len(perturb)} rc:{r.returncode} "
                     f"named:{','.join(named)}")

    # e2 — an untouched sibling's field overload, deleted.
    JAVA = "bindings/java/dev/kaya/KayaApp.java"
    victim = ("        public Node button(KayaRecords.Field<String> "
              "f) {\n"
              "            Node n = widget(KayaWire.KIND_BUTTON);\n"
              "            bindTextField(n, 0, f);\n"
              "            return n;\n"
              "        }\n")
    src = read_rel(JAVA)
    n = src.count(victim)
    if n != 1:
        lines.append(f"e2=SELFTEST-BROKEN(matched {n}, expected 1)")
    else:
        r = tpl_over({JAVA: src.replace(victim, "")})
        hit = ("java's TEMPLATE-zone button caption takes no field"
               in r.stdout)
        lines.append(f"e2=applied:1 rc:{r.returncode} named:{hit}")

    # e3 — the reader must refuse, not report an empty set.
    HS = "bindings/haskell/KayaApp.hs"
    src = read_rel(HS)
    old = "buttonBound :: TplStrSource s => s -> Tpl Node\n"
    n = src.count(old)
    if n != 1:
        lines.append(f"e3=SELFTEST-BROKEN(matched {n}, expected 1)")
    else:
        r = tpl_over({HS: src.replace(
            old, "buttonRenamed :: TplStrSource s => s -> Tpl "
                 "Node\n")})
        hit = ("cannot find haskell's template button constructor"
               in r.stdout)
        lines.append(f"e3=applied:1 rc:{r.returncode} named:{hit}")

    # e4 — JS's `{bind}` left DECLARED and never handed to the binder:
    # the silent-nothing arm python has already shipped once, and the
    # shape a signature census cannot see.
    # e5 — and the reader must refuse, not report a binding with no
    # sources.
    JS = "bindings/js/kaya/index.ts"
    src = read_rel(JS)
    old = '    bindText("button", handle, opts.bind);\n'
    n = src.count(old)
    if n != 1:
        lines.append(f"e4=SELFTEST-BROKEN(matched {n}, expected 1)")
    else:
        r = tpl_over({JS: src.replace(old, "")})
        hit = ("js's TEMPLATE-zone button caption takes no signal or "
               "field source" in r.stdout)
        lines.append(f"e4=applied:1 rc:{r.returncode} named:{hit}")

    old = ("export function button(a: string | ButtonOptions, "
           "b?: ButtonOptions): Widget {")
    n = src.count(old)
    if n != 1:
        lines.append(f"e5=SELFTEST-BROKEN(matched {n}, expected 1)")
    else:
        r = tpl_over({JS: src.replace(
            old, "export function buttonRenamed(a: string | "
                 "ButtonOptions, b?: ButtonOptions): Widget {")})
        hit = ("cannot find js's template button constructor"
               in r.stdout)
        lines.append(f"e5=applied:1 rc:{r.returncode} named:{hit}")
    return "\n".join(lines)


src_out = src_probe()
WANT_SRC = """e1=applied:3 rc:1 named:csharp,swift,python
e2=applied:1 rc:1 named:True
e3=applied:1 rc:1 named:True
e4=applied:1 rc:1 named:True
e5=applied:1 rc:1 named:True"""
if src_out != WANT_SRC:
    print("check-sugar-surface: SELF-TEST FAIL (the template "
          "TAKES-A-SOURCE census did not catch a perturbation it must "
          "catch). Wanted:", file=sys.stderr)
    print(WANT_SRC, file=sys.stderr)
    print("Got:", file=sys.stderr)
    print(src_out, file=sys.stderr)
    raise SystemExit(1)

# THE SCALAR ELEMENT HAS A NAME, in all nine.
#
# A template constructor's element source is a FIELD addressed by
# index off a record. A SCALAR collection has no record — its element
# IS the value — so it needs a NAME for field 0; the wire record is
# identical either way, which is why the floor spelling worked and
# still taught the floor (invariant 5).
#
# Go keeps `Row.Value()`, scoped to a row surface no other binding
# has. Python's ambient `for_each` yields the element as `el`, so its
# "token" is the loop variable.
check("rust", "crates/kaya/src/app.rs", "scalar element",
      r"pub const fn element\(\)")
check("python", "bindings/python/kaya/__init__.py", "scalar element",
      r"class Element\b|def __enter__")
check("go", "bindings/go/app.go", "scalar element",
      r"func \(r Row\) Value\(\)")
check("csharp", "bindings/csharp/KayaRecords.cs", "scalar element",
      r"static Field<string> Element")
check("java", "bindings/java/dev/kaya/KayaRecords.java",
      "scalar element", r"static Field<String> element\(")
check("swift", "bindings/swift/KayaRecords.swift", "scalar element",
      r"static var element: KayaField<String>")
check("ocaml", "bindings/ocaml/kaya_app.ml", "scalar element",
      r"^let element : \('a, string\) field")
check("haskell", "bindings/haskell/KayaApp.hs", "scalar element",
      r"^element :: KField String")
# JS's ambient For yields the element as the loop variable, so its
# "token" is the class the tracer hands over.
check("js", "bindings/js/kaya/index.ts", "scalar element",
      r"^export class Element\b")

# THE TEMPLATE-NODE PROPS, in all nine (docs/tpl-props-plan.md
# P1/P2): the a11y pair + hint, accepts, and the node paste
# registrar. Every pattern is RECEIVER-KEYED on the template handle
# type — a bare-method-name pattern is satisfied by the LIVE twin
# every time. THE TWO AMBIENT BINDINGS ARE READ ELSEWHERE, because
# their zones share one surface and there is no receiver to key on:
# Python's is tools/checks/py-node-props.py, JS's is
# tools/tpl-surfaces.py's `members_js`.
check("rust", "crates/kaya/src/app.rs", "template a11y id",
      r"pub fn a11y_id\(&mut self, node: TemplateNodeId")
check("rust", "crates/kaya/src/app.rs", "template a11y label",
      r"pub fn a11y_label\(&mut self, node: TemplateNodeId")
check("rust", "crates/kaya/src/app.rs", "template a11y hint",
      r"pub fn a11y_hint\(&mut self, node: TemplateNodeId")
check("rust", "crates/kaya/src/app.rs", "template accepts",
      r"pub fn accepts\(&mut self, node: TemplateNodeId")
check("rust", "crates/kaya/src/app.rs", "node paste registrar",
      r"pub fn on_paste_node\(")
check("go", "bindings/go/app.go", "template a11y id",
      r"func \(t \*Tpl\) SetA11yID\(")
check("go", "bindings/go/app.go", "template a11y id (sourced)",
      r"func \(t \*Tpl\) BindA11yID\[")
check("go", "bindings/go/app.go", "template a11y label",
      r"func \(t \*Tpl\) SetA11yLabel\(")
check("go", "bindings/go/app.go", "template a11y label (sourced)",
      r"func \(t \*Tpl\) BindA11yLabel\[")
check("go", "bindings/go/app.go", "template a11y hint",
      r"func \(t \*Tpl\) SetA11yHint\(")
check("go", "bindings/go/app.go", "template accepts",
      r"func \(t \*Tpl\) SetAccepts\(")
check("csharp", "bindings/csharp/KayaApp.cs", "template a11y id",
      r"public void SetA11yId\(Node n, Field<string>")
check("csharp", "bindings/csharp/KayaApp.cs", "template a11y label",
      r"public void SetA11yLabel\(Node n, Field<string>")
check("csharp", "bindings/csharp/KayaApp.cs", "template a11y hint",
      r"public void SetA11yHint\(Node n, Field<string>")
check("csharp", "bindings/csharp/KayaApp.cs", "template accepts",
      r"public void SetAccepts\(Node")
check("csharp", "bindings/csharp/KayaApp.cs", "node paste registrar",
      r"public void OnPaste\(Node")
check("java", "bindings/java/dev/kaya/KayaApp.java",
      "template a11y id", r"public void setA11yId\(Node")
check("java", "bindings/java/dev/kaya/KayaApp.java",
      "template a11y label", r"public void setA11yLabel\(Node")
check("java", "bindings/java/dev/kaya/KayaApp.java",
      "template a11y hint", r"public void setA11yHint\(Node")
check("java", "bindings/java/dev/kaya/KayaApp.java",
      "template accepts", r"public void setAccepts\(Node")
check("swift", "bindings/swift/KayaApp.swift", "template a11y id",
      r"func setA11yId\(_ n: KayaNodeHandle")
check("swift", "bindings/swift/KayaApp.swift", "template a11y label",
      r"func setA11yLabel\(_ n: KayaNodeHandle")
check("swift", "bindings/swift/KayaApp.swift", "template a11y hint",
      r"func setA11yHint\(_ n: KayaNodeHandle")
check("swift", "bindings/swift/KayaApp.swift", "template accepts",
      r"func setAccepts\(_ n: KayaNodeHandle")
check("ocaml", "bindings/ocaml/kaya_app.ml", "template a11y id",
      r"let set_a11y_id \(Node id\)")
check("ocaml", "bindings/ocaml/kaya_app.ml", "template a11y label",
      r"let set_a11y_label \(Node id\)")
check("ocaml", "bindings/ocaml/kaya_app.ml", "template a11y hint",
      r"let set_a11y_hint \(Node id\)")
check("ocaml", "bindings/ocaml/kaya_app.ml", "template accepts",
      r"let set_accepts \(Node id\)")
check("ocaml", "bindings/ocaml/kaya_app.ml",
      "template a11y label (sourced)", r"let bind_a11y_label_field ")
check("ocaml", "bindings/ocaml/kaya_app.ml", "template each",
      r"^  let each c body \(\) =")
check("ocaml", "bindings/ocaml/kaya_app.ml", "node paste registrar",
      r"^let on_paste_node ")
check("haskell", "bindings/haskell/KayaApp.hs", "template a11y id",
      r"TplA11yId ::")
check("haskell", "bindings/haskell/KayaApp.hs", "template a11y label",
      r"TplA11yLabel ::")
check("haskell", "bindings/haskell/KayaApp.hs", "template a11y hint",
      r"TplA11yHint ::")
check("haskell", "bindings/haskell/KayaApp.hs", "template accepts",
      r"TplAccepts ::")
# HASKELL'S IS AN INSTANCE ARM, receiver-keyed on the Node pattern:
# `onPasteNode` died with the rest of the `*Node` twins, and a bare
# `onPaste` would be satisfied by the class signature and by the LIVE
# arm alike (bindings/haskell/KayaApp.hs, instance HandlerTarget
# Node). The arm's PRESENCE is also held by -Werror=missing-methods,
# which is the wall on the path nobody can avoid; this is the sweep's
# copy of it.
check("haskell", "bindings/haskell/KayaApp.hs", "node paste registrar",
      r"^  onPaste app \(Node n\) handler =")

# Python's, by CLASS STRUCTURE rather than grep — the reader walks
# `class Node` and its bases with `ast` and requires each prop method
# reachable. Its negative was watched by the fan-out (rename on the
# base -> exit 1 naming the prop; unhook the base -> exit 1 naming
# all of them).
#
# IT READS TWO STRUCTURES, because Python spells the zone's props in
# two ways. Most ride `_Handle`, the base `class Node` inherits.
# `inset` is a CONSTRUCTOR KEYWORD (`kaya.row(inset=8)`), so the
# reader holds the chain instead: the kwarg reaches `_set_inset`,
# which writes onto `_widget`, which is `_alloc_widget_or_node` and
# branches on `_tpl_depth`. NOTHING ON THAT PATH MAY ASK WHICH ZONE
# IT IS IN — a `_tpl_depth` read inside `_set_inset` or `_Handle.role`
# would make one zone quietly different from the other. It also
# refuses a verdict when it cannot find the allocator at all.
py_props = subprocess.run(
    [sys.executable, str(ROOT / "tools" / "checks" /
                         "py-node-props.py"),
     "bindings/python/kaya/__init__.py"],
    cwd=ROOT, capture_output=True, text=True, check=False)
if py_props.returncode != 0:
    print("check-sugar-surface: "
          + (py_props.stdout + py_props.stderr).strip())
    status = 1

# A TEMPLATE NODE'S GROW WEIGHT, in all nine.
#
# `scroll` needs a grow weight — an unconstrained viewport hugs its
# content and nothing ever overflows — so a binding shipping the
# scroll constructor WITHOUT grow is a divergence. Spacing and align
# remain floor-only on template containers, in every binding alike.
#
# NEW TEMPLATE PROPS DO NOT GO HERE. The prop sweep lives in
# tools/tpl-surfaces.py's PROP_MEMBERS table, which reads each
# spelling out of the template zone's OWN BLOCK — the thing a line
# pattern cannot do. The clauses above and below stay because they
# already pass; they are not the pattern to copy. Python is the
# census's one exemption (its two zones share a surface), covered by
# tools/checks/py-node-props.py.
check("rust", "crates/kaya/src/app.rs", "template grow",
      r"pub fn set\(&mut self, node: TemplateNodeId")
check("python", "bindings/python/kaya/__init__.py", "template grow",
      r"def _set_grow\(")
check("go", "bindings/go/app.go", "template grow",
      r"func \(t \*Tpl\) SetGrow\(")
check("csharp", "bindings/csharp/KayaApp.cs", "template grow",
      r"public void SetGrow\(Node")
check("java", "bindings/java/dev/kaya/KayaApp.java", "template grow",
      r"public void setGrow\(Node")
check("swift", "bindings/swift/KayaApp.swift", "template grow",
      r"func setGrow\(_ n: KayaNodeHandle")
# RECEIVER-KEYED, unlike the first draft of this line: `let set_grow `
# also matched the LIVE set_grow (Widget id) at kaya_app.ml:631, so
# the template setter could be deleted and this clause stayed green —
# proven by perturbation during the props survey (2026-08-10). The
# Node pattern is the part that makes it a claim about the template
# zone.
check("ocaml", "bindings/ocaml/kaya_app.ml", "template grow",
      r"let set_grow \(Node id\)")
check("haskell", "bindings/haskell/KayaApp.hs", "template grow",
      r"setGrow[A-Za-z]* ::")
# JS's is the zone-blind option writer, python's `_set_grow` one
# language over: `Widget.grow()` refuses a node, so the constructor
# option is the template zone's only spelling (tools/tpl-surfaces.py,
# members_js).
check("js", "bindings/js/kaya/index.ts", "template grow",
      r"^function setGrow\(handle: Handle")

# --- AND THE OTHER DIRECTION: WHAT THE EXAMPLES USE ------------------
#
# Everything above is about what a BINDING OFFERS. This is invariant
# 5: all example scenes use each language's sugar tier, and only the C
# guests keep the explicit floor.
#
# The scene-tier clause at the end of this file reads only the scenes
# in its `scene_guests` table, so a guest outside it could teach the
# floor indefinitely. The rule here has no per-scene table to forget:
# A SUGAR GUEST DOES NOT NAME A WIDGET KIND. tools/guest-floor.py
# sweeps every guest outside guests/c, STRIPS COMMENTS FIRST (the
# converted guests explain the old floor spelling in a comment above
# the new call, so a sweep that reads comments reports every file it
# just fixed), and carries its exemptions with reasons the way
# gates.sh does.
floor_run = subprocess.run(
    [sys.executable, str(ROOT / "tools" / "guest-floor.py")],
    cwd=ROOT, capture_output=True, text=True, check=False)
if floor_run.returncode != 0:
    print((floor_run.stdout + floor_run.stderr).rstrip("\n"))
    status = 1


# ITS NEGATIVE TEST: put a floor call back into the guest whose one
# line started the whole sugar pass, and require the sweep to name it.
# The substitution count is printed and checked — an unchanged file is
# a failed test, not a passed one.
def floor_probe():
    p = "guests/go/editor/editor.go"
    src = read_rel(p)
    old, new = "query = row.Entry()", "query = row.Widget(kaya.KindEntry)"
    n = src.count(old)
    if n != 1:
        return (f"SELFTEST-BROKEN: perturbation matched {n} times, "
                f"expected 1")
    root = tempfile.mkdtemp()
    try:
        # SOURCES ONLY: the matrix's sweep overlaps still-running
        # lanes, and a bare copytree of guests/ dies mid-walk when a
        # lane's build churns bin/obj inside it (measured 2026-08-24 —
        # the probe printed an EMPTY finding once under the five-lane
        # matrix). The prune set is the shadows'; the except keeps any
        # residual failure legible.
        shutil.copytree("guests", f"{root}/guests",
                        ignore=shutil.ignore_patterns(
                            "bin", "obj", ".build", "_build", "target",
                            "__pycache__", ".gradle", "build", "dist",
                            "dist-newstyle", "node_modules",
                            "DerivedData"))
        with open(f"{root}/{p}", "w", encoding="utf-8") as fh:
            fh.write(src.replace(old, new))
        r = subprocess.run(
            [sys.executable, str(ROOT / "tools" / "guest-floor.py"),
             root], cwd=ROOT, capture_output=True, text=True,
            check=False)
        return (f"applied=1 rc={r.returncode} "
                f"named={'editor.go' in r.stdout}")
    except OSError as e:
        return f"SELFTEST-BROKEN: staging failed mid-copy: {e}"
    finally:
        shutil.rmtree(root, ignore_errors=True)


floor_out = floor_probe()
if floor_out != "applied=1 rc=1 named=True":
    print(f"check-sugar-surface: SELF-TEST FAIL (a widget-kind floor "
          f"call put back into the editor guest was not caught by "
          f"tools/guest-floor.py: {floor_out})", file=sys.stderr)
    raise SystemExit(1)

# The grow prop's layer-3 spelling, per language idiom (a kwarg, a
# named setter, a combinator — decided 2026-07-20, see the ledger).
# Props are not kinds, so the constructor loop above cannot see them;
# without this, a binding shipping wire-only grow would pass every
# gate until a guest failed to compile.
check("rust", "crates/kaya/src/app.rs", "grow", r"fn grow\(self")
check("python", "bindings/python/kaya/__init__.py", "grow",
      r"def grow\(self, weight\)")
check("go", "bindings/go/app.go", "grow",
      r"func \(w Widget\) Grow\(")
check("csharp", "bindings/csharp/KayaApp.cs", "grow",
      r"public void SetGrow\(")
check("java", "bindings/java/dev/kaya/KayaApp.java", "grow",
      r"public Widget grow\(")
check("swift", "bindings/swift/KayaApp.swift", "grow",
      r"func setGrow\(")
check("haskell", "bindings/haskell/KayaApp.hs", "grow",
      r"Grow :: Double -> Attr")
check("ocaml", "bindings/ocaml/kaya_app.ml", "grow",
      r"let label \?grow ")
check("js", "bindings/js/kaya/index.ts", "grow", r"^  grow\(weight: number\)")

# The spacing prop's layer-3 spelling, same rule: a binding shipping
# wire-only spacing must fail here, not on a reviewer's eye.
check("rust", "crates/kaya/src/app.rs", "spacing",
      r"fn spacing\(self")
check("python", "bindings/python/kaya/__init__.py", "spacing",
      r"def spacing\(self, gap\)")
check("go", "bindings/go/app.go", "spacing",
      r"func \(w Widget\) Spacing\(")
check("csharp", "bindings/csharp/KayaApp.cs", "spacing",
      r"public void SetSpacing\(")
check("java", "bindings/java/dev/kaya/KayaApp.java", "spacing",
      r"public Widget spacing\(")
check("swift", "bindings/swift/KayaApp.swift", "spacing",
      r"func setSpacing\(")
check("haskell", "bindings/haskell/KayaApp.hs", "spacing",
      r"Spacing :: Double -> Attr")
check("ocaml", "bindings/ocaml/kaya_app.ml", "spacing",
      r"let row \?grow \?a11y_id \?a11y_label \?spacing ")
check("js", "bindings/js/kaya/index.ts", "spacing", r"^  spacing\(gap: number\)")

# The align prop's layer-3 spelling, same rule again.
check("rust", "crates/kaya/src/app.rs", "align", r"fn align\(self")
check("python", "bindings/python/kaya/__init__.py", "align",
      r"def align\(self, mode\)")
check("go", "bindings/go/app.go", "align",
      r"func \(w Widget\) Align\(")
check("csharp", "bindings/csharp/KayaApp.cs", "align",
      r"public void SetAlign\(")
check("java", "bindings/java/dev/kaya/KayaApp.java", "align",
      r"public Widget align\(")
check("swift", "bindings/swift/KayaApp.swift", "align",
      r"func setAlign\(")
check("haskell", "bindings/haskell/KayaApp.hs", "align",
      r"Align :: Align -> Attr")
check("ocaml", "bindings/ocaml/kaya_app.ml", "align",
      r"let row \?grow \?a11y_id \?a11y_label \?spacing \?align ")
check("js", "bindings/js/kaya/index.ts", "align", r"^  align\(mode: AlignValue")

# THE UNIVERSAL ACCESSIBILITY PROPS, same rule as grow/spacing/align.
# These two are the only props every KIND carries, so a binding that
# ships them wire-only leaves every widget in that language unnamed
# and unaddressable to assistive tech — and nothing else would notice
# until an app shipped. The C floor is exempt with the rest of C: the
# generated kaya_tx_set_a11y_id/_label ARE its surface.
check("rust", "crates/kaya/src/app.rs", "a11y_id",
      r"fn a11y_id\(self")
check("python", "bindings/python/kaya/__init__.py", "a11y_id",
      r"def a11y_id\(self, ident\)")
check("go", "bindings/go/app.go", "a11y_id",
      r"func \(w Widget\) A11yID\(")
check("csharp", "bindings/csharp/KayaApp.cs", "a11y_id",
      r"public void SetA11yId\(")
check("java", "bindings/java/dev/kaya/KayaApp.java", "a11y_id",
      r"public Widget a11yId\(")
check("swift", "bindings/swift/KayaApp.swift", "a11y_id",
      r"func setA11yId\(")
check("haskell", "bindings/haskell/KayaApp.hs", "a11y_id",
      r"A11yId :: String -> Attr")
check("ocaml", "bindings/ocaml/kaya_app.ml", "a11y_id",
      r"let set_a11y_id \(Widget id\)")
check("js", "bindings/js/kaya/index.ts", "a11y_id", r"^  a11yId\(ident:")

check("rust", "crates/kaya/src/app.rs", "a11y_label",
      r"fn a11y_label\(self")
check("python", "bindings/python/kaya/__init__.py", "a11y_label",
      r"def a11y_label\(self, label\)")
check("go", "bindings/go/app.go", "a11y_label",
      r"func \(w Widget\) A11yLabel\(")
check("csharp", "bindings/csharp/KayaApp.cs", "a11y_label",
      r"public void SetA11yLabel\(")
check("java", "bindings/java/dev/kaya/KayaApp.java", "a11y_label",
      r"public Widget a11yLabel\(")
check("swift", "bindings/swift/KayaApp.swift", "a11y_label",
      r"func setA11yLabel\(")
check("haskell", "bindings/haskell/KayaApp.hs", "a11y_label",
      r"A11yLabel :: String -> Attr")
check("ocaml", "bindings/ocaml/kaya_app.ml", "a11y_label",
      r"let set_a11y_label \(Widget id\)")
check("js", "bindings/js/kaya/index.ts", "a11y_label", r"^  a11yLabel\(label:")

# The HINT prop, same rule as the two universal ones — but note it is
# ACTIVATION-KINDS-ONLY by the root's own check (a hint needs
# something to activate; Android carries it as an action's label). The
# gate still demands a spelling per binding: a language that ships it
# wire-only leaves apps unable to author hints at all.
check("rust", "crates/kaya/src/app.rs", "a11y_hint",
      r"fn a11y_hint\(self")
check("python", "bindings/python/kaya/__init__.py", "a11y_hint",
      r"def a11y_hint\(self, hint\)")
check("go", "bindings/go/app.go", "a11y_hint",
      r"func \(w Widget\) A11yHint\(")
check("csharp", "bindings/csharp/KayaApp.cs", "a11y_hint",
      r"public void SetA11yHint\(")
check("java", "bindings/java/dev/kaya/KayaApp.java", "a11y_hint",
      r"public Widget a11yHint\(")
check("swift", "bindings/swift/KayaApp.swift", "a11y_hint",
      r"func setA11yHint\(")
check("haskell", "bindings/haskell/KayaApp.hs", "a11y_hint",
      r"A11yHint :: String -> Attr")
check("ocaml", "bindings/ocaml/kaya_app.ml", "a11y_hint",
      r"let set_a11y_hint \(Widget id\)")
check("js", "bindings/js/kaya/index.ts", "a11y_hint", r"^  a11yHint\(hint:")

# THE CLIPBOARD SURFACE (DESIGN.md, Clipboard). Four points, none of
# them a widget kind or a window prop: the copy record, the
# privileged read, the per-widget accept list, and the paste hook.
#
# THE SPELLINGS DIFFER AND THE SEMANTICS DO NOT: copy is a CHAIN where
# the language builds by chaining, keyword arguments where it has
# them, a record where that is the idiom — but at-most-one-per-kind is
# STRUCTURAL in all nine, never a duplicate check. `accepts` takes
# the kinds as VALUES and joins them to the wire's space-separated
# list.
check("rust", "crates/kaya/src/app.rs", "copy",
      r"pub fn copy\(&mut self")
check("python", "bindings/python/kaya/__init__.py", "copy",
      r"^def copy\(")
check("go", "bindings/go/app.go", "copy",
      r"func \(tx \*Tx\) Copy\(")
check("csharp", "bindings/csharp/KayaApp.cs", "copy",
      r"public CopyRef Copy\(")
check("java", "bindings/java/dev/kaya/KayaApp.java", "copy",
      r"public CopyRef copy\(")
check("swift", "bindings/swift/KayaApp.swift", "copy",
      r"func copy\(")
check("haskell", "bindings/haskell/KayaApp.hs", "copy", r"^copy ::")
check("ocaml", "bindings/ocaml/kaya_app.ml", "copy", r"^let copy ")
check("js", "bindings/js/kaya/index.ts", "copy", r"^export function copy\(")

check("rust", "crates/kaya/src/app.rs", "read_clipboard",
      r"pub fn read_clipboard\(&mut self")
check("python", "bindings/python/kaya/__init__.py", "read_clipboard",
      r"^def read_clipboard\(")
check("go", "bindings/go/app.go", "read_clipboard",
      r"func \(tx \*Tx\) ReadClipboard\(")
check("csharp", "bindings/csharp/KayaApp.cs", "read_clipboard",
      r"public ClipReadRef ReadClipboard\(")
check("java", "bindings/java/dev/kaya/KayaApp.java", "read_clipboard",
      r"public ClipReadRef readClipboard\(")
check("swift", "bindings/swift/KayaApp.swift", "read_clipboard",
      r"func readClipboard\(")
check("haskell", "bindings/haskell/KayaApp.hs", "read_clipboard",
      r"^readClipboard ::")
check("ocaml", "bindings/ocaml/kaya_app.ml", "read_clipboard",
      r"^let read_clipboard ")
check("js", "bindings/js/kaya/index.ts", "read_clipboard", r"^export function readClipboard\(")

check("rust", "crates/kaya/src/app.rs", "accepts",
      r"pub fn accepts\(self")
check("python", "bindings/python/kaya/__init__.py", "accepts",
      r"def accepts\(self, \*kinds\)")
check("go", "bindings/go/app.go", "accepts",
      r"func \(w Widget\) Accepts\(")
check("csharp", "bindings/csharp/KayaApp.cs", "accepts",
      r"public void SetAccepts\(")
check("java", "bindings/java/dev/kaya/KayaApp.java", "accepts",
      r"public Widget accepts\(")
check("swift", "bindings/swift/KayaApp.swift", "accepts",
      r"func setAccepts\(")
check("haskell", "bindings/haskell/KayaApp.hs", "accepts",
      r"Accepts :: \[String\] -> Attr")
check("ocaml", "bindings/ocaml/kaya_app.ml", "accepts",
      r"^let set_accepts ")
check("js", "bindings/js/kaya/index.ts", "accepts", r"^  accepts\(\.\.\.kinds: string\[\]\)")

check("rust", "crates/kaya/src/app.rs", "on_paste",
      r"pub fn on_paste\(")
check("python", "bindings/python/kaya/__init__.py", "on_paste",
      r"def on_paste\(self, fn\)")
check("go", "bindings/go/app.go", "on_paste",
      r"func \(a \*App\) OnPaste\(")
check("csharp", "bindings/csharp/KayaApp.cs", "on_paste",
      r"public void OnPaste\(")
check("java", "bindings/java/dev/kaya/KayaApp.java", "on_paste",
      r"public void onPaste\(")
# The LIVE ARM, not the class signature: an arm cannot exist without
# the method, so this reads the stronger half
# (bindings/haskell/KayaApp.hs, instance HandlerTarget Widget). The
# template arm is the "node paste registrar" clause above; both arms
# are also held by the file's own -Werror=missing-methods.
check("swift", "bindings/swift/KayaApp.swift", "on_paste",
      r"func onPaste\(")
check("haskell", "bindings/haskell/KayaApp.hs", "on_paste",
      r"^  onPaste app \(Widget n\) handler =")
check("ocaml", "bindings/ocaml/kaya_app.ml", "on_paste",
      r"^let on_paste ")
check("js", "bindings/js/kaya/index.ts", "on_paste", r"^  onPaste\(fn: Handler\)")

# The menu construction surface (DESIGN.md, Menus): menu items are
# not widget kinds, so the constructor loop above cannot see them —
# every binding must spell the whole item vocabulary (menu,
# item/action, toggle, radio_group, option, separator) plus BOTH
# context anchors (the live-widget attach and the free catalog for
# template nodes). A binding shipping wire-only menus would pass every
# other gate until a guest failed to compile
# (failures-become-guards).
def check_menus(lang, rel, points, findings=None):
    for point in points:
        name, _, pattern = point.partition("=")
        check(lang, rel, f"menus:{name}", pattern, findings)


# The menus clause's own negative test (guard-the-guard, the fake-kind
# pattern above): an item constructor that exists nowhere must fail in
# all 9 bindings THROUGH check_menus itself, or the clause's
# point-splitting has rotted.
fake = []
check_menus("rust", "crates/kaya/src/app.rs",
            [r"kayafakemenu=pub fn kayafakemenuitem\("], fake)
check_menus("python", "bindings/python/kaya/__init__.py",
            [r"kayafakemenu=^def kayafakemenuitem\("], fake)
check_menus("go", "bindings/go/app.go",
            [r"kayafakemenu=func \(m MenuItem\) Kayafakemenuitem\("],
            fake)
check_menus("csharp", "bindings/csharp/KayaApp.cs",
            [r"kayafakemenu=public MenuItem Kayafakemenuitem\("], fake)
check_menus("java", "bindings/java/dev/kaya/KayaApp.java",
            [r"kayafakemenu=public MenuItem kayafakemenuitem\("], fake)
check_menus("swift", "bindings/swift/KayaApp.swift",
            [r"kayafakemenu=func kayafakemenuitem\("], fake)
check_menus("haskell", "bindings/haskell/KayaApp.hs",
            [r"kayafakemenu=^kayafakemenuitem ::"], fake)
check_menus("ocaml", "bindings/ocaml/kaya_app.ml",
            [r"kayafakemenu=^let kayafakemenuitem "], fake)
check_menus("js", "bindings/js/kaya/index.ts",
            [r"kayafakemenu=^export function kayafakemenuitem\("], fake)
fake_menu_failures = sum(1 for m in fake
                         if "no live-zone constructor" in m)
if fake_menu_failures != 9:
    selftest_exit(f"check-sugar-surface: menus self-test failed "
                  f"({fake_menu_failures}/9 patterns fired for a fake "
                  f"item constructor)")

check_menus("rust", "crates/kaya/src/app.rs", [
    "menu=pub fn menu", r"item=pub fn item\(",
    r"toggle=pub fn toggle\(", "radio_group=pub fn radio_group",
    r"option=pub fn option\(", r"separator=pub fn separator\(",
    "context_menu=pub fn context_menu",
    "context_catalog=pub fn context_catalog"])
check_menus("python", "bindings/python/kaya/__init__.py", [
    r"menu=^def menu\(", r"item=^def item\(",
    r"toggle=^def toggle\(", r"radio_group=^def radio_group\(",
    r"option=^def option\(", r"separator=^def separator\(",
    r"context_menu=def context_menu\(self",
    r"context_catalog=^def context_catalog\("])
check_menus("go", "bindings/go/app.go", [
    r"menu=func \(w WindowRef\) Menu\(",
    r"item=func \(m MenuItem\) Item\(",
    r"toggle=func \(m MenuItem\) Toggle\(",
    r"radio_group=func \(w WindowRef\) RadioGroup\(",
    r"option=func \(m MenuItem\) Option\(",
    r"separator=func \(m MenuItem\) Separator\(",
    r"context_menu=func \(tx \*Tx\) ContextMenu\(",
    r"context_catalog=func \(tx \*Tx\) ContextCatalog\("])
check_menus("csharp", "bindings/csharp/KayaApp.cs", [
    r"menu=public MenuItem Menu\(", r"item=public MenuItem Item\(",
    r"toggle=public MenuItem Toggle\(",
    r"radio_group=public MenuItem RadioGroup\(",
    r"option=public MenuItem Option\(",
    r"separator=public MenuItem Separator\(",
    r"context_menu=public void ContextMenu\(",
    r"context_catalog=public ContextCatalog ContextCatalog\("])
check_menus("java", "bindings/java/dev/kaya/KayaApp.java", [
    r"menu=public MenuItem menu\(", r"item=public MenuItem item\(",
    r"toggle=public MenuItem toggle\(",
    r"radio_group=public MenuItem radioGroup\(",
    r"option=public MenuItem option\(",
    r"separator=public void separator\(",
    r"context_menu=public ContextRef contextMenu\(",
    r"context_catalog=public ContextCatalog contextCatalog\("])
check_menus("swift", "bindings/swift/KayaApp.swift", [
    r"menu=func menu\(", r"item=func item\(",
    r"toggle=func toggle\(", r"radio_group=func radioGroup\(",
    r"option=func option\(", r"separator=func separator\(",
    r"context_menu=func contextMenu\(",
    r"context_catalog=func contextCatalog\("])
check_menus("haskell", "bindings/haskell/KayaApp.hs", [
    "menu=^menu ::", "item=^item ::", "toggle=^toggle ::",
    "radio_group=^radioGroup ::", "option=^option ::",
    "separator=^separator ::", "context_menu=^contextMenu ::",
    "context_catalog=^contextCatalog ::"])
check_menus("ocaml", "bindings/ocaml/kaya_app.ml", [
    "menu=^let menu ", "item=^let item ", "toggle=^let toggle ",
    "radio_group=^let radio_group ", "option=^let option ",
    "separator=^let separator ", "context_menu=^let context_menu ",
    "context_catalog=^let context_catalog "])
# The context anchor is a HANDLE method here (python's shape); the rest
# are module-level, since the transaction is ambient and has no surface
# to hang them on.
check_menus("js", "bindings/js/kaya/index.ts", [
    r"menu=^export function menu\(", r"item=^export function item\(",
    r"toggle=^export function toggle\(",
    r"radio_group=^export function radioGroup\(",
    r"option=^export function option\(",
    r"separator=^export function separator\(",
    r"context_menu=^  contextMenu\(",
    r"context_catalog=^export function contextCatalog\("])

# EVERY WINDOW PROP NEEDS A SUGAR SPELLING TOO. Props come from the
# GENERATED wire file, so this tracks the spec by construction — a
# new WINDOW_PROPS entry lands here the moment the generators run. C
# is exempt for the reason it is above: the floor spells every window
# prop with one generic kaya_tx_set_window_prop call, on purpose.
#
# AND THE SPELLING HAS TO BE IN CODE. Measured 2026-08-19 while
# `panes` was fanning out: with Go's constructor renamed to `PanesXX`
# this loop still passed, because the doc comment above it opens
# "Panes is the CEILING …" and /\bPanes\b/ cannot tell prose from a
# declaration. Every prop in every binding carries such a comment, so
# the loop could only ever agree — the exact vacuity the \b
# tightening was meant to end, one layer further in. The patterns
# below are unchanged; they run against copies with comments and
# docstrings stripped.
def _c_like(s):
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    return "\n".join(re.sub(r"//.*", "", ln) for ln in s.split("\n"))


def _python_like(s):
    s = re.sub(r'"""(?:.|\n)*?"""', "", s)
    s = re.sub(r"'''(?:.|\n)*?'''", "", s)
    return "\n".join(re.sub(r"#.*", "", ln) for ln in s.split("\n"))


def _ocaml_like(s):
    """(* … *) nests, so this counts rather than matching."""
    keep, depth, i = [], 0, 0
    while i < len(s):
        if s.startswith("(*", i):
            depth += 1
            i += 2
        elif s.startswith("*)", i) and depth:
            depth -= 1
            i += 2
        else:
            if not depth:
                keep.append(s[i])
            i += 1
    return "".join(keep)


def _haskell_like(s):
    s = re.sub(r"\{-(?:.|\n)*?-\}", "", s)
    return "\n".join(re.sub(r"--.*", "", ln) for ln in s.split("\n"))


STRIP = {
    "python": _python_like, "go": _c_like, "csharp": _c_like,
    "java": _c_like, "swift": _c_like, "ocaml": _ocaml_like,
    "haskell": _haskell_like, "js": _c_like,
}

# A NONCE IN A COMMENT, PER LANGUAGE, and the whole point of the
# pass: the raw file must satisfy the token and the stripped one must
# not. It is planted rather than borrowed from a real prop so it
# cannot rot into a name some binding later spells in code, and it
# runs for all eight so a stripper that quietly strips nothing is
# caught where it lives.
NONCE = "KayaCommentOnlyNonce"
PLANT = {
    "python": (f"# {NONCE} rides in a comment\n"
               + f'"""{NONCE} rides in a docstring"""\n'),
    "go": f"// {NONCE} rides in a comment\n",
    "csharp": f"/// {NONCE} rides in a comment\n",
    "java": f"/** {NONCE} rides in a comment */\n",
    "swift": f"/* {NONCE} rides in a comment */\n",
    "ocaml": f"(* {NONCE} rides in a (* nested *) comment *)\n",
    "haskell": f"-- {NONCE} rides in a comment\n",
    "js": f"/** {NONCE} rides in a doc comment */\n",
}

WPROP_FILES = {
    "python": "bindings/python/kaya/__init__.py",
    "go": "bindings/go/app.go",
    "csharp": "bindings/csharp/KayaApp.cs",
    "java": "bindings/java/dev/kaya/KayaApp.java",
    "swift": "bindings/swift/KayaApp.swift",
    "ocaml": "bindings/ocaml/kaya_app.ml",
    "haskell": "bindings/haskell/KayaApp.hs",
    "js": "bindings/js/kaya/index.ts",
}

stripped_code = {}
nonce_applied = []
for lang, path in WPROP_FILES.items():
    text = read_rel(path)
    stripped = STRIP[lang](text)
    # A stripper that ate the whole file would redden everything; one
    # that ate nothing would restore the miss this replaces. Neither
    # is allowed to reach the loop below as a verdict.
    ratio = len(stripped) / len(text)
    if not 0.25 < ratio < 0.95:
        print(f"check-sugar-surface: stripping comments from {path} "
              f"left {len(stripped)}/{len(text)} bytes ({ratio:.2f}) "
              f"— the {lang} comment stripper is wrong",
              file=sys.stderr)
        raise SystemExit(1)
    planted = STRIP[lang](PLANT[lang] + text)
    if NONCE not in PLANT[lang] + text:
        print(f"check-sugar-surface: SELF-TEST FAIL ({lang}'s nonce "
              f"was not planted at all)", file=sys.stderr)
        raise SystemExit(1)
    if NONCE in planted:
        print(f"check-sugar-surface: SELF-TEST FAIL (a {lang} COMMENT "
              f"still satisfies the window-prop sweep — {path})",
              file=sys.stderr)
        raise SystemExit(1)
    nonce_applied.append(f" {lang}={PLANT[lang].count(NONCE)}")
    stripped_code[lang] = stripped

print("check-sugar-surface: window-prop comment-only nonces refused:"
      + "".join(nonce_applied), file=sys.stderr)

wprops = [m[6:].lower() for m in
          re.findall(r"^WPROP_[A-Z_]+",
                     read_rel("bindings/python/kaya/wire.py"), re.M)]
if not wprops:
    selftest_exit("check-sugar-surface: no window props in the "
                  "generated wire file")


def check_wprop(lang, rel, prop, pattern):
    global status
    if not grep_e(pattern, stripped_code[lang]):
        print(f"check-sugar-surface: {lang} has no window-prop sugar "
              f"for '{prop}' (wanted /{pattern}/ in {rel}, comments "
              f"stripped)")
        status = 1


def _camel(name):
    parts = name.split("_")
    return parts[0] + "".join(p.capitalize() for p in parts[1:])


def _pascal(name):
    return "".join(p.capitalize() for p in name.split("_"))


for wprop in wprops:
    # snake_case for python/ocaml, camelCase for the rest, and
    # Haskell's W-prefixed attribute constructor.
    camel = _camel(wprop)
    pascal = _pascal(wprop)
    # WHOLE TOKENS, NOT SUBSTRINGS. The first cut of this sweep
    # grepped the bare name, and the styling fan-out watched that go
    # vacuous in real time: a Haskell negative that renamed WInset to
    # WInsetXX still satisfied /WInset/, so the perturbation proved
    # nothing and had to be redone as an outright deletion. `\b` holds
    # both edges (`_` is a word character, so a generated
    # `tx_set_window_inset` cannot stand in for the sugar's own
    # `inset`).
    check_wprop("python", "bindings/python/kaya/__init__.py", wprop,
                rf"\b{wprop}\b")
    # Go folds width and height into ONE Size(w, h) chain method, the
    # same flavor as Haskell's WSize below — surfaced by the \b
    # tightening, which is the proof the old substring match was
    # passing on an accident (exactly one bare `Width` existed in the
    # file, and it was not a constructor).
    go_pat = (r"\bSize\b" if wprop in ("width", "height")
              else rf"\b{pascal}\b")
    check_wprop("go", "bindings/go/app.go", wprop, go_pat)
    check_wprop("csharp", "bindings/csharp/KayaApp.cs", wprop,
                rf"\b{camel}\b")
    check_wprop("java", "bindings/java/dev/kaya/KayaApp.java", wprop,
                rf"\b{camel}\b")
    check_wprop("swift", "bindings/swift/KayaApp.swift", wprop,
                rf"\b{camel}\b")
    check_wprop("ocaml", "bindings/ocaml/kaya_app.ml", wprop,
                rf"\b{wprop}\b")
    # Haskell carries width and height as ONE WSize constructor — a
    # language flavor, not a gap, exactly like the kind spellings
    # above.
    hs = "WSize" if wprop in ("width", "height") else f"W{pascal}"
    check_wprop("haskell", "bindings/haskell/KayaApp.hs", wprop,
                rf"\b{hs}\b")
    # JS carries width and height separately, so it needs no flavor row:
    # the camelCase name is the whole rule.
    check_wprop("js", "bindings/js/kaya/index.ts", wprop, rf"\b{camel}\b")

# ─────────────────────────────────────────────────────────────────────
# THE STYLING SURFACE (docs/styling-plan.md, slice 1). `inset` is a
# WINDOW_PROPS entry and the spec-derived loop above already demands
# it. The other two are neither widget kinds nor window props, so
# nothing else in this file can see them:
#
#   - `brand_accent` is a TRANSACTION verb, copy's shape. The
#     per-appearance override form rides the same base name, so the
#     patterns key on the base name.
#   - `role` rides the WIDGET chain the way grow does, with the
#     closed vocabulary as a real enum type wherever the language has
#     one. The root's declare-time wall refuses a misfit kind.
def check_styling_point(point, rust_re, python_re, go_re, csharp_re,
                        java_re, swift_re, haskell_re, ocaml_re, js_re,
                        findings=None):
    check("rust", "crates/kaya/src/app.rs", point, rust_re, findings)
    check("python", "bindings/python/kaya/__init__.py", point,
          python_re, findings)
    check("go", "bindings/go/app.go", point, go_re, findings)
    check("csharp", "bindings/csharp/KayaApp.cs", point, csharp_re,
          findings)
    check("java", "bindings/java/dev/kaya/KayaApp.java", point,
          java_re, findings)
    check("swift", "bindings/swift/KayaApp.swift", point, swift_re,
          findings)
    check("haskell", "bindings/haskell/KayaApp.hs", point, haskell_re,
          findings)
    check("ocaml", "bindings/ocaml/kaya_app.ml", point, ocaml_re,
          findings)
    check("js", "bindings/js/kaya/index.ts", point, js_re, findings)


# Its negative, the fake-kind pattern above: a point that exists
# nowhere must fail in all nine THROUGH check_styling_point itself,
# or its argument-splitting has rotted.
fake = []
check_styling_point(
    "kayafakestyling",
    r"pub fn kayafakestyling\(", r"^def kayafakestyling\(",
    r"func \(tx \*Tx\) Kayafakestyling\(",
    r"public void Kayafakestyling\(",
    r"public Widget kayafakestyling\(", r"func kayafakestyling\(",
    r"^kayafakestyling ::", r"^let kayafakestyling ",
    r"^export function kayafakestyling\(", findings=fake)
fake_styling = sum(1 for m in fake
                   if "no live-zone constructor" in m)
if fake_styling != 9:
    selftest_exit(f"check-sugar-surface: styling self-test failed "
                  f"({fake_styling}/9 patterns fired for a styling "
                  f"point that exists nowhere)")

check_styling_point(
    "brand_accent",
    r"pub fn brand_accent\(&mut self", r"^def brand_accent\(",
    r"func \(tx \*Tx\) BrandAccent\(", r"public void BrandAccent\(",
    r"public void brandAccent\(", r"func brandAccent\(",
    r"^brandAccent ::", r"^let brand_accent ",
    r"^export function brandAccent\(")

# THE BRAND TYPEFACE (Slice 2b), the accent's sibling: a transaction
# verb no other sweep can see. Same base-name rule as the accent — the
# per-platform/font-bytes form rides the base name, so one pattern per
# language.
check_styling_point(
    "brand_typeface",
    r"pub fn brand_typeface\(&mut self", r"^def brand_typeface\(",
    r"func \(tx \*Tx\) BrandTypeface\(",
    r"public void BrandTypeface\(", r"public void brandTypeface\(",
    r"func brandTypeface\(", r"^brandTypeface ::",
    r"^let brand_typeface ", r"^export function brandTypeface\(")

# THE APP IDENTITY (docs/app-identity-plan.md): a transaction verb no
# other sweep can see, so a binding shipping it wire-only strands
# apps in that language while every other gate passes. RED BY DESIGN
# until the eighth binding lands. Same base-name rule as the brand
# rows.
check_styling_point(
    "app_identity",
    r"pub fn app_identity\(&mut self", r"^def app_identity\(",
    r"func \(tx \*Tx\) AppIdentity\(", r"public void AppIdentity\(",
    r"public void appIdentity\(", r"func appIdentity\(",
    r"^appIdentity ::", r"^let app_identity ",
    r"^export function appIdentity\(")

# `asset(name)` (docs/assets-plan.md): a transaction-tier call no
# other sweep can see, so a binding shipping the core entry point
# without sugar strands apps in that language while every other gate
# passes.
#
# EIGHT PATTERNS, FOUR SHAPES, idiom rather than semantics (invariant
# 1). Rust, Go and C# hang it off the transaction; Python, OCaml and
# Haskell are ambient and it is a plain function; Java is static on
# the app surface; Swift spells it as a CLASS whose initializer opens
# the asset, that language's idiom for a handle with a lifetime.
#
# SWIFT'S PATTERN IS THE THROWING INITIALIZER AND NOT THE CLASS NAME:
# the class is already held by a compiler (three guests name it, so
# swift-typecheck reds if it goes), while the `throws` has no such
# wall — Swift answers a `try` with nothing to throw with a WARNING,
# and the guest pass is not -warnings-as-errors.
#
# KEYED PAST THE BARE NAME: `asset` is a short common word and a
# pattern matching it alone would be satisfied by a doc comment. Every
# pattern below carries its receiver, its keyword or its type
# signature.
check_styling_point(
    "asset",
    r"pub fn asset\(&self", r"^def asset\(",
    r"func \(tx \*Tx\) Asset\(", r"public Asset Asset\(",
    r"public static Asset asset\(",
    r"init\(_ name: String\) throws",
    r"^asset :: String -> IO Asset", r"^let asset = ",
    r"^export function asset\(name: string\)")

# The row above's other half: the sentence a miss WOULD raise,
# answered TOTALLY, without unwinding. A scene has to OBSERVE that
# sentence on five platforms in TEN languages — the nine bindings
# and the C floor — and "catch it" is not one semantics in ten,
# because C has no catch at all. A query is. The query also answers
# what no raise can: for a name that RESOLVES it says so, having
# opened nothing, which is the second half of what
# tools/scenes/assets.steps freezes.
#
# The bindings write no prose — every one returns
# crates/kaya/src/assets.rs's bytes unchanged.
#
# NAMED FOR CARRYING, NOT FOR DIAGNOSING: a `…WhyNot` here would opt
# into tools/check-diagnostics.sh by its name alone, and that gate
# reads a function so named as the AUTHOR of a sentence these only
# carry.
check_styling_point(
    "asset_miss_sentence",
    r"pub fn asset_miss_sentence\(&self",
    r"^def asset_miss_sentence\(",
    r"func \(tx \*Tx\) AssetMissSentence\(",
    r"public string AssetMissSentence\(",
    r"public static String assetMissSentence\(",
    r"static func missSentence\(",
    r"^assetMissSentence :: String -> IO String",
    r"^let asset_miss_sentence = ",
    r"^export function assetMissSentence\(")

# THREE ROWS ARE KEYED PAST THE MENU ITEM'S ROLE, which shares the
# bare name: a bare-name pattern is satisfied by Rust's
# `role(self, role: MenuRole)`, Python's `def role(self, name)` on
# the item class and OCaml's `let item … ?role …`. Rust keys on the
# widget enum's type, Python on the parameter name, OCaml on the
# constructor or setter receiver — none of which the menu item's line
# can supply.
check_styling_point(
    "role",
    r"pub fn role\(self, role: crate::Role\)",
    r"def role\(self, role\)", r"func \(w Widget\) Role\(",
    r"public void SetRole\(", r"public Widget role\(",
    r"func setRole\(", r"Role :: Role -> Attr",
    r"let (label|button) [^=]*\?role|let set_role \(Widget id\)",
    r"^  role\(role: RoleValue")

# A SECTION INTO A NAMED WINDOW, in all nine. Idiom decides the
# spelling — a second name where there are no optional arguments, a
# window argument where there are — and each pattern keys on the
# window-carrying form so the primary-only spelling cannot satisfy
# it. EXCEPT Swift's and Python's, whose signatures put the window
# parameter past a line break where a line-based grep cannot key on
# it: those rows pin the wrapped signature's own first line, and the
# GUESTS hold the parameter (both sections guests call with
# window=/window:).
check_styling_point(
    "sectioned aux window",
    r"pub fn add_section_in\(",
    r"def add_section\(self, section_id, title=None, symbol=None,",
    r"func \(tx \*Tx\) AddSectionIn\(", r"AddSection\([^)]*window",
    r"public SectionRef addSectionIn\(|addSectionIn\(",
    r"func addSection\(", r"^addSectionIn ::",
    r"add_section \?\(window",
    r"^export type SectionOptions = .*window\?: number")

# THE CONTAINER INSET (docs/styling-plan.md D3 one level down, landed
# 2026-08-12 — the prop the full-bleed editor forced). EVERY ROW IS
# KEYED PAST ITS WINDOW-INSET TWIN, which shares the bare name in all
# nine: the window's spelling rides the window construct and the
# container's rides the widget chain beside grow, so the receiver or
# the parameter is what tells them apart — the menu-role lesson, one
# prop over.
check_styling_point(
    "container inset",
    r"pub fn inset\(&mut self, widget: WidgetId",
    r"def inset\(self, pad\)", r"func \(w Widget\) Inset\(",
    r"public void SetInset\(", r"public Widget inset\(",
    r"func setInset\(", r"Inset :: Double -> Attr",
    r"let set_inset \(Widget id\)|let (row|column|grid) [^=]*\?inset",
    r"^  inset\(pad: number\)")

# EVERY WINDOW HANDLER NEEDS A CONSTRUCT SPELLING TOO — AND NO LOOSE
# ONE: NO WINDOW ATTRIBUTE LIVES AS A LOOSE FUNCTION OUTSIDE THE
# CONSTRUCT (DESIGN.md, Binding conventions). The sweep runs BOTH
# directions, because only the pair states the rule.
#
# WHERE THE LIST COMES FROM: two bindings declare the construct's
# attribute set as a CLOSED SYNTACTIC OBJECT — Haskell's
# `data WindowAttr` and OCaml's `let window` — so "what the construct
# carries" is a fact about a file rather than a judgement made here.
# The list is the UNION of the two.
#
# ADDING A NEW WINDOW HANDLER means spelling it in Haskell's
# WindowAttr or OCaml's window, at which point this sweep demands the
# other seven and refuses the loose one. Nobody edits a list here.
WH_PY = "bindings/python/kaya/__init__.py"
WH_GO = "bindings/go/app.go"
WH_CS = "bindings/csharp/KayaApp.cs"
WH_JA = "bindings/java/dev/kaya/KayaApp.java"
WH_SW = "bindings/swift/KayaApp.swift"
WH_HS = "bindings/haskell/KayaApp.hs"
WH_ML = "bindings/ocaml/kaya_app.ml"
WH_JS = "bindings/js/kaya/index.ts"


def derive_whandlers():
    def snake(name):
        return re.sub(r"(?<!^)([A-Z])", r"_\1", name).lower()

    # Haskell: the WOn* constructors of `data WindowAttr`, which runs
    # to the next column-0 line. A constructor is the first thing on
    # its line (the haddock comments between them start with --), so a
    # mention inside a comment cannot invent a handler.
    text = read_rel(WH_HS)
    m = re.search(r"^data WindowAttr\b.*?(?=\n\S)", text, re.S | re.M)
    if not m:
        return None, (f"{WH_HS}: no `data WindowAttr` block — the "
                      f"window construct's attribute set moved and "
                      f"this sweep would go vacuous")
    from_hs = [snake(c) for c in
               re.findall(r"^[ \t]*(?:[=|][ \t]*)?WOn([A-Za-z]+)\b",
                          m.group(0), re.M)]

    # OCaml: the ?on_* labelled arguments of `let window`, up to the
    # `=` that ends its header.
    text = read_rel(WH_ML)
    m = re.search(r"^let window\b.*?=\n", text, re.S | re.M)
    if not m:
        return None, (f"{WH_ML}: no `let window` construct — the "
                      f"window construct's attribute set moved and "
                      f"this sweep would go vacuous")
    from_ml = re.findall(r"\?on_([a-z_]+)", m.group(0))

    union = sorted(set(from_hs) | set(from_ml))
    # THE ANTI-VACUITY FLOOR. A derived list that goes empty sweeps
    # nothing and passes everything. The close pair is the floor: if
    # it ever leaves BOTH declarations, this gate is reading the wrong
    # thing and has to be re-derived rather than agree with what is
    # left.
    missing = [h for h in ("close_requested", "closed")
               if h not in union]
    if missing:
        return None, (f"the window construct no longer carries "
                      f"{missing} in either {WH_HS} or {WH_ML} — this "
                      f"sweep derives its list from that construct, "
                      f"so it has to be re-derived rather than pass "
                      f"on what is left")
    return union, None


whandlers, wh_err = derive_whandlers()
if whandlers is None:
    print(wh_err, file=sys.stderr)
    print("check-sugar-surface: FAIL (no window-handler list)")
    raise SystemExit(1)


# RUST'S CARVE-OUT IS PINNED POSITIVELY rather than left as a hole:
# `Messages::on_*(WindowId, …)` is the sanctioned Rust form, a
# MESSAGE VALUE in a table the transaction cannot reach. Pinning it
# means a future "fix" onto WindowRef goes red here and gets decided.
#
# The pin reads the `impl<M> Messages<M>` block with its signatures
# collapsed onto one line (rustfmt wraps them and grep is line-based)
# and its comments dropped, so a doc comment cannot satisfy it. A
# missing anchor FAILS rather than going quiet.
def rust_messages_text():
    text = read_rel("crates/kaya/src/app.rs")
    i = text.find("impl<M> Messages<M> {")
    if i < 0:
        return None
    j = text.find("\nimpl ", i + 1)
    region = text[i:j if j > 0 else len(text)]
    code = [ln for ln in region.split("\n")
            if not ln.strip().startswith("//")]
    return " ".join(" ".join(code).split()) + "\n"


rust_messages = rust_messages_text()
if rust_messages is None:
    print("crates/kaya/src/app.rs: no `impl<M> Messages<M>` block — "
          "Rust's sanctioned handler form moved and this pin went "
          "vacuous", file=sys.stderr)
    print("check-sugar-surface: FAIL (Rust's Messages block could not "
          "be read)")
    raise SystemExit(1)


# AND THE FOUR ARGUMENT-LIST BINDINGS ARE READ BY REGION, NOT BY
# FILE. Python, C#, Swift and OCaml spell a window's attributes as
# arguments TWICE — the primary window's construct and the
# auxiliary's — where DESIGN.md says the two take EXACTLY the same
# set. A whole-file grep cannot tell those apart: a handler dropped
# from `window` while `create_window` keeps it still matches
# somewhere in the file. So each construct's header is extracted and
# swept on its own.
#
# The other four need no extraction: their construct is a TYPE rather
# than an argument list, so one spelling serves both windows.
def paren_region(rel, anchor):
    """The construct's header: from the anchor to the matching close
    of its parameter list. Nested parens are counted, since a Swift
    closure parameter carries its own."""
    text = read_rel(rel)
    m = re.search(anchor, text, re.M)
    if not m:
        return None, (f"{rel}: no window construct matching "
                      f"/{anchor}/ — the construct moved and this "
                      f"sweep would go vacuous")
    i = text.index("(", m.start())
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "(":
            depth += 1
        elif text[j] == ")":
            depth -= 1
            if depth == 0:
                return text[m.start():j + 1], None
    return None, (f"{rel}: the construct's parameter list at "
                  f"/{anchor}/ never closes")


def brace_region(rel, anchor):
    """A TypeScript type literal: from the anchor to the brace that
    closes it. JS spells the construct's attribute set as ONE TYPE both
    windows take, so — like Go's, Java's and Haskell's — one spelling
    serves both; what it still needs is a REGION, because a loose
    `onUndone` elsewhere in the file would satisfy a whole-file grep."""
    text = read_rel(rel)
    m = re.search(anchor, text, re.M)
    if not m:
        return None, (f"{rel}: no window construct matching "
                      f"/{anchor}/ — the construct moved and this "
                      f"sweep would go vacuous")
    i = text.index("{", m.start())
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[m.start():j + 1], None
    return None, (f"{rel}: the construct's type literal at /{anchor}/ "
                  f"never closes")


def let_region(rel, anchor):
    """OCaml's labelled arguments have no brackets: the header runs to
    the `=` that ends its line."""
    text = read_rel(rel)
    m = re.search(anchor + r"\b.*?=\n", text, re.S | re.M)
    if not m:
        return None, (f"{rel}: no window construct matching "
                      f"/{anchor}/ — the construct moved and this "
                      f"sweep would go vacuous")
    return m.group(0), None


REGIONS = {}
for name, (fn, rel, anchor) in {
    "python-window": (paren_region, WH_PY, r"^    def window\(self"),
    "python-create-window": (paren_region, WH_PY,
                             r"^    def create_window\(self"),
    "csharp-window": (paren_region, WH_CS,
                      r"^    public void Window\("),
    "csharp-create-window": (paren_region, WH_CS,
                             r"^    public void CreateWindow\("),
    "swift-window": (paren_region, WH_SW, r"^    func window\("),
    "swift-create-window": (paren_region, WH_SW,
                            r"^    func createWindow\("),
    "ocaml-window": (let_region, WH_ML, r"^let window"),
    "ocaml-create-window": (let_region, WH_ML,
                            r"^let create_window"),
    "js-window-options": (brace_region, WH_JS,
                          r"^export type WindowOptions = WindowProps & "),
}.items():
    body, err = fn(rel, anchor)
    if body is None:
        print(err, file=sys.stderr)
        print("check-sugar-surface: FAIL (a window construct's header "
              "could not be read)")
        raise SystemExit(1)
    REGIONS[name] = body + "\n"


def want(lang, text, handler, pattern, shown, findings=None):
    global status
    if not grep_e(pattern, text):
        msg = (f"check-sugar-surface: {lang} has no window-construct "
               f"spelling for the '{handler}' handler (wanted "
               f"/{pattern}/ in {shown})")
        if findings is None:
            print(msg)
            status = 1
        else:
            findings.append(msg)


def deny(lang, text, handler, pattern, shown, findings=None):
    """want's mirror."""
    global status
    if grep_e(pattern, text):
        msg = (f"check-sugar-surface: {lang} spells the '{handler}' "
               f"window handler as a LOOSE app-global registration "
               f"(found /{pattern}/ in {shown}) — a window's "
               f"attributes ride its window construct (DESIGN.md, "
               f"Binding conventions)")
        if findings is None:
            print(msg)
            status = 1
        else:
            findings.append(msg)


def swift_one_door(construct_arg, registrar, text, shown,
                   findings=None):
    """SWIFT IS THE ONE BINDING WHERE "no such function exists" CANNOT
    BE THE RULE. KayaApp handler tables are `private`, so KayaAppTx
    cannot write them and the construct reaches them through a KayaApp
    method that DOES take a window id. So Swift is pinned as ONE DOOR:
    called exactly once, from the construct, with the construct own
    argument. A second callsite is a second door, and a guest holds
    the KayaApp."""
    global status
    doors = sum(1 for ln in text.split("\n")
                if re.search(rf"app\.{registrar}\(", ln))
    construct = sum(1 for ln in text.split("\n")
                    if re.search(rf"app\.{registrar}\(id, "
                                 rf"{construct_arg}\)", ln))
    if doors != 1 or construct != 1:
        msg = (f"check-sugar-surface: swift's app.{registrar} is not "
               f"the window construct's ONE DOOR ({doors} callsite(s) "
               f"in {shown}, {construct} of them the construct's — "
               f"want 1 and 1)")
        if findings is None:
            print(msg)
            status = 1
        else:
            findings.append(msg)


def _pascal_h(h):
    return "".join(p.capitalize() for p in h.split("_"))


def check_window_handler(h, findings=None):
    """The construct spells it, in all nine. ONE conversion, and
    every non-snake spelling is built from it: "close_requested" ->
    "CloseRequested", so the handler is `on` plus that in six bindings
    and `On` plus it in Go. A camelCase of the handler alone would
    read `onundone` for a one-word handler and `onCloseRequested` for
    a two-word one — the same pattern quietly right in one case and
    wrong in the other, which is what the perturbation self-test below
    caught when this was written."""
    pascal = _pascal_h(h)
    # Two spelling flavors get named here, the way width and height
    # share Haskell's one WSize constructor above — a language's
    # flavor, not a gap. Rust's Messages is app-global, so its closed
    # handler has to say WHICH kind of closed it means; Swift's
    # KayaApp-level plumbing follows the same name, while the
    # construct's argument is onClosed.
    if h == "closed":
        rust_name, swift_app = "on_window_closed", "onWindowClosed"
    else:
        rust_name, swift_app = f"on_{h}", f"on{pascal}"
    want("rust", rust_messages, h,
         rf"pub fn {rust_name}\( *&self, window: WindowId",
         "crates/kaya/src/app.rs (impl<M> Messages<M>)", findings)
    want("go", read_rel(WH_GO), h,
         rf"func \(w WindowRef\) On{pascal}\(", WH_GO, findings)
    want("java", read_rel(WH_JA), h,
         rf"public WindowRef on{pascal}\(", WH_JA, findings)
    # Haskell's constructor has to be in CONSTRUCTOR POSITION — first
    # on its line, after an optional = or | — so a haddock comment
    # naming one cannot stand in for declaring it.
    want("haskell", read_rel(WH_HS), h,
         rf"^[[:space:]]*([=|][[:space:]]*)?WOn{pascal} \(", WH_HS,
         findings)
    # The argument-list four, each construct read on its own: the
    # primary's set and the auxiliary's are the same set or one of
    # them is wrong (DESIGN.md, Binding conventions).
    want("python", REGIONS["python-window"], h,
         rf"[ (,]on_{h}=None", f"{WH_PY} (App.window)", findings)
    want("python", REGIONS["python-create-window"], h,
         rf"[ (,]on_{h}=None", f"{WH_PY} (App.create_window)",
         findings)
    want("csharp", REGIONS["csharp-window"], h,
         rf"\? on{pascal} = null", f"{WH_CS} (Tx.Window)", findings)
    want("csharp", REGIONS["csharp-create-window"], h,
         rf"\? on{pascal} = null", f"{WH_CS} (Tx.CreateWindow)",
         findings)
    want("swift", REGIONS["swift-window"], h,
         rf"^ +on{pascal}: \(\(KayaAppTx",
         f"{WH_SW} (KayaAppTx.window)", findings)
    want("swift", REGIONS["swift-create-window"], h,
         rf"^ +on{pascal}: \(\(KayaAppTx",
         f"{WH_SW} (KayaAppTx.createWindow)", findings)
    want("ocaml", REGIONS["ocaml-window"], h, rf"\?on_{h}[ )]",
         f"{WH_ML} (window)", findings)
    want("ocaml", REGIONS["ocaml-create-window"], h, rf"\?on_{h}[ )]",
         f"{WH_ML} (create_window)", findings)
    # ONE region, not two: `app.window` and `app.createWindow` take the
    # SAME type, so the two sets cannot drift by construction — which is
    # what the argument-list four need a region apiece to prove.
    want("js", REGIONS["js-window-options"], h, rf"^  on{pascal}\?:",
         f"{WH_JS} (WindowOptions)", findings)
    swift_one_door(f"on{pascal}", swift_app, read_rel(WH_SW), WH_SW,
                   findings)


def deny_loose(h, py_text, go_text, cs_text, ja_text, hs_text,
               ml_text, js_text, shown=None, findings=None):
    """The texts are ARGUMENTS rather than the constants above because
    the self-test runs this clause against DOCTORED COPIES OF THE REAL
    FILES; a rule about six fixed paths could never be watched
    failing, and a clause nobody has seen fail is worse than none — it
    stops you looking."""
    shown = shown or {}
    pascal = _pascal_h(h)
    # Each pattern is that language's shape of a registration THE APP
    # REACHES WITH A WINDOW ID IN HAND — what a construct-scoped
    # handler makes unnecessary. Python, OCaml and Haskell have the
    # simplest rule (the top-level definition itself, since a
    # construct spelling is a keyword/labelled argument or a
    # constructor there). Go's is a method on the app or the
    # transaction, or a package-level function. C# and Java key on the
    # DECLARATION rather than the window parameter, because a wrapped
    # signature puts the parameters on the next line: any `OnUndone(`
    # declaration is loose in C#, and in Java the construct returns
    # WindowRef to chain, so a `void onUndone(` is the loose one by
    # its return type.
    deny("python", py_text, h, rf"^ *def on_{h}\(",
         shown.get("python", WH_PY), findings)
    deny("go", go_text, h,
         rf"^func (\([a-z]+ \*(App|Tx)\) )?On{pascal}\(",
         shown.get("go", WH_GO), findings)
    deny("csharp", cs_text, h, rf"[A-Za-z>?] On{pascal}\(",
         shown.get("csharp", WH_CS), findings)
    deny("java", ja_text, h,
         rf"(void on{pascal}\(|[ .(]on{pascal}\(long )",
         shown.get("java", WH_JA), findings)
    deny("haskell", hs_text, h, rf"^on{pascal} ::",
         shown.get("haskell", WH_HS), findings)
    deny("ocaml", ml_text, h, rf"^let on_{h}[ (]",
         shown.get("ocaml", WH_ML), findings)
    # Python's rule, one language over: the DEFINITION itself, module
    # level or class member alike, since the construct spelling is a
    # field on the options type and never a definition of this name.
    deny("js", js_text, h, rf"^ *(export )?(function )?on{pascal}\(",
         shown.get("js", WH_JS), findings)


# The built-in negative test, the fake-kind pattern above: a handler
# that exists nowhere must fail in every binding, or the patterns have
# rotted.
fake = []
check_window_handler("kayafakehandler", findings=fake)
fake_wh_wants = sum(1 for m in fake
                    if "no window-construct spelling" in m)
fake_wh_doors = sum(1 for m in fake if "ONE DOOR" in m)
# Thirteen, not nine: the four argument-list bindings are read once per
# construct (the primary's and the auxiliary's), while JS's one shared
# type is read once.
if fake_wh_wants != 13 or fake_wh_doors != 1:
    selftest_exit(f"check-sugar-surface: window-handler self-test "
                  f"failed ({fake_wh_wants}/13 construct patterns and "
                  f"{fake_wh_doors}/1 door clause fired for a handler "
                  f"that exists nowhere)")


# AND THE LOOSE-SPELLING CLAUSE IS WATCHED FAILING, on DOCTORED COPIES
# OF THE REAL FILES (docs/traps.md: the wayland seat guard passed
# VACUOUSLY TWICE against a fixture). Every perturbation prints its
# substitution count and is refused if it did not apply, and every
# refusal is checked for its REASON.
wh_applied = []


def wh_perturb(rel, pattern, repl, label):
    doctored, n = sub_count(pattern, repl, read_rel(rel), flags=re.M)
    if n < 1:
        print(f"check-sugar-surface: SELF-TEST FAIL ({label} applied "
              f"{n} times, want at least 1 — an unchanged copy cannot "
              f"prove the rule fires)", file=sys.stderr)
        raise SystemExit(1)
    wh_applied.append(f" {label}={n}")
    return doctored


def refuses_loose(h, texts, fragment, label):
    got = []
    deny_loose(h, *texts, findings=got)
    if not any(fragment in m for m in got):
        print(f"check-sugar-surface: SELF-TEST FAIL ({label} was not "
              f"refused for its own reason: "
              f"{chr(10).join(got) or 'no output at all'})",
              file=sys.stderr)
        raise SystemExit(1)


PY_T, GO_T, CS_T = read_rel(WH_PY), read_rel(WH_GO), read_rel(WH_CS)
JA_T, HS_T, ML_T = read_rel(WH_JA), read_rel(WH_HS), read_rel(WH_ML)
JS_T = read_rel(WH_JS)

doc = wh_perturb(WH_PY, r"^class App:$",
                 "def on_undone(window_id, fn):\n    pass\n\n\n"
                 "class App:", "python")
refuses_loose("undone", (doc, GO_T, CS_T, JA_T, HS_T, ML_T, JS_T),
              "python spells the 'undone' window handler",
              "a python binding with a loose on_undone")

doc = wh_perturb(WH_GO, r"^package kaya$",
                 "package kaya\n\nfunc (a *App) OnUndone(window "
                 "uint64, fn func(*Tx, string, UndoDelta)) {}", "go")
refuses_loose("undone", (PY_T, doc, CS_T, JA_T, HS_T, ML_T, JS_T),
              "go spells the 'undone' window handler",
              "the Go shape the fan-out actually shipped")

# The same clause on a MULTI-WORD handler and on Go's OTHER shape: the
# pattern is built from the derived name, so one that came out wrong
# would still fire on `undone` and never on `close_requested` (that is
# not hypothetical — a camelCase slip did exactly this while the sweep
# was being written), and the receiver-less branch would never fire at
# all if only a method were ever planted.
doc = wh_perturb(WH_GO, r"^package kaya$",
                 "package kaya\n\nfunc OnCloseRequested(a *App, "
                 "window uint64, fn func(*Tx)) {}",
                 "go-close-requested")
refuses_loose("close_requested",
              (PY_T, doc, CS_T, JA_T, HS_T, ML_T, JS_T),
              "go spells the 'close_requested' window handler",
              "a Go binding with a loose OnCloseRequested")

doc = wh_perturb(WH_CS, r"^sealed class KayaApp\n\{$",
                 "sealed class KayaApp\n{\n    public void "
                 "OnUndone(ulong window, Action<Tx, string, "
                 "UndoDelta> fn) { undone[window] = fn; }", "csharp")
refuses_loose("undone", (PY_T, GO_T, doc, JA_T, HS_T, ML_T, JS_T),
              "csharp spells the 'undone' window handler",
              "a C# binding with a loose OnUndone")

doc = wh_perturb(WH_JA, r"^public final class KayaApp \{$",
                 "public final class KayaApp {\n    public void "
                 "onUndone(long window, UndoHandler handler) { "
                 "undone.put(window, handler); }", "java")
refuses_loose("undone", (PY_T, GO_T, CS_T, doc, HS_T, ML_T, JS_T),
              "java spells the 'undone' window handler",
              "the Java shape the fan-out actually shipped")

doc = wh_perturb(WH_HS,
                 r"^undoableTx :: App -> String -> Build a -> IO a$",
                 "onUndone :: App -> Word64 -> (String -> UndoDelta "
                 "-> IO ()) -> IO ()\nonUndone _ _ _ = return ()\n\n"
                 "undoableTx :: App -> String -> Build a -> IO a",
                 "haskell")
refuses_loose("undone", (PY_T, GO_T, CS_T, JA_T, doc, ML_T, JS_T),
              "haskell spells the 'undone' window handler",
              "the Haskell shape the fan-out actually shipped")

doc = wh_perturb(WH_ML, r"^let destroy_window id =",
                 "let on_undone _window _f = ()\n\n"
                 "let destroy_window id =", "ocaml")
refuses_loose("undone", (PY_T, GO_T, CS_T, JA_T, HS_T, doc, JS_T),
              "ocaml spells the 'undone' window handler",
              "an OCaml binding with a loose on_undone")

doc = wh_perturb(WH_JS, r"^export class App \{$",
                 "export function onUndone(windowId: number, fn: "
                 "Handler): void {}\n\nexport class App {", "js")
refuses_loose("undone", (PY_T, GO_T, CS_T, JA_T, HS_T, ML_T, doc),
              "js spells the 'undone' window handler",
              "a JS binding with a loose onUndone")

# The multi-word handler too, for the reason Go's second row exists: a
# pattern built wrong from the derived name fires on `undone` and never
# on `close_requested`.
doc = wh_perturb(WH_JS, r"^export class App \{$",
                 "export function onCloseRequested(windowId: number, "
                 "fn: Handler): void {}\n\nexport class App {",
                 "js-close-requested")
refuses_loose("close_requested",
              (PY_T, GO_T, CS_T, JA_T, HS_T, ML_T, doc),
              "js spells the 'close_requested' window handler",
              "a JS binding with a loose onCloseRequested")

# AND SWIFT'S ONE-DOOR CLAUSE FAILS ON A SECOND DOOR, not only on
# none: the fake handler above proves it fires at zero callsites,
# which is the same comparison from the other side but not the case it
# exists for.
doc = wh_perturb(
    WH_SW,
    r"^        if let onUndone \{ app\.onUndone\(id, onUndone\) \}$",
    "        if let onUndone { app.onUndone(id, onUndone) }\n"
    "        app.onUndone(1, onUndone!)", "swift-second-door")
door_got = []
swift_one_door("onUndone", "onUndone", doc, "-", findings=door_got)
if not any("ONE DOOR" in m for m in door_got):
    print(f"check-sugar-surface: SELF-TEST FAIL (a second Swift "
          f"callsite was not refused: "
          f"{chr(10).join(door_got) or 'no output at all'})",
          file=sys.stderr)
    raise SystemExit(1)
print("check-sugar-surface: window-handler perturbations applied:"
      + "".join(wh_applied), file=sys.stderr)

for whandler in whandlers:
    check_window_handler(whandler)
    deny_loose(whandler, PY_T, GO_T, CS_T, JA_T, HS_T, ML_T, JS_T)

# THE C FLOOR IS EXEMPT, AND THE EXEMPTION IS CHECKED — an exemption
# is not an implementation. C registers nothing: a guest reads the
# occurrence record head and matches on it. What makes that honest is
# that the header declares NO handler registrar of any kind, so a
# `kaya_app_on_undone` arriving one day fails here instead of quietly
# making C the ninth binding with a loose spelling.
deny("c", read_rel("bindings/c/kaya_wire.h"), "any window handler",
     r"kaya_[a-z_]*_on_[a-z_]+\(", "bindings/c/kaya_wire.h")

# ─────────────────────────────────────────────────────────────────────
# THE SCENE TIER: THE SAME RULE, READ FROM THE OTHER SIDE.
#
# Everything above asks whether a BINDING OFFERS the sugar; this asks
# whether the EXAMPLES USE IT (invariant 5). The carve-out for entry and
# milestone2 covers the EVENT-RECEIVING mechanism ONLY (DESIGN.md,
# "SCOPE, ratified 2026-08-05"); construction follows the same sugar
# rule as every other example.
#
# So this clause reads both halves, for BOTH carve-out scenes:
#   (a) no entry and no milestone2 guest spells CONSTRUCTION at the
#       floor, in any of the nine bindings; and
#   (b) both rust guests still spell their EVENTS as the raw
#       `ctx.next()` loop. THE CARVE-OUT IS CHECKED, NOT ASSUMED — a
#       later session "finishing the job" by folding them onto
#       kaya::Messages would delete the only guests that document the
#       tier Messages is built on.
#
# THE PATTERNS ARE DERIVED FROM WHAT EACH FILE ACTUALLY SAID: every
# regex below matched guests/<lang>/<scene>.* at that scene's
# pre-graduation revision and matches nothing in the graduated one.
#
# A THIRD SCENE JOINS BY ADDING ROWS AND NOTHING ELSE: one to
# scene_facts and one per language to scene_guests. Every loop below
# sweeps those two tables.

# <scene> <the expected string every guest carries> <its script> <the
# line the self-test plants its floor snippets after>
#
# THE EXPECTED STRING IS THE ANTI-VACUITY ANCHOR: frozen and
# byte-identical in all nine languages (invariant 6), so a guest that
# was renamed, moved or emptied fails loudly here instead of satisfying
# every denial below by having nothing in it.
scene_facts = [
    "entry", "nothing to add, ", "tools/scenes/entry.steps",
    r"^(.*no todos.*)$",
    "milestone2", '"step 0"', "tools/scenes/milestone2.steps",
    r'^(.*"step 0".*)$',
]

# <scene> <language> <the guest this clause reads>
#
# THE GO ROWS NAME <scene>/<scene>.go, which is the scene ITSELF: one
# directory per scene, package named for it, App() handing back a built
# app. The desktop TAILS live in guests/go/cmd and no scene row may name
# that directory — a row pointing at a tail reads a file that cannot
# spell the floor and passes for the emptiest possible reason.
scene_guests = [
    "entry", "rust", "guests/rust/entry.rs",
    "entry", "python", "guests/python/entry.py",
    "entry", "go", "guests/go/entry/entry.go",
    "entry", "csharp", "guests/csharp/EntryScene.cs",
    "entry", "java", "guests/java/dev/kaya/milestone2kt/Entry.java",
    "entry", "swift", "guests/swift/entry.swift",
    "entry", "haskell", "guests/haskell/entry.hs",
    "entry", "ocaml", "guests/ocaml/entry.ml",
    "entry", "js", "guests/js/entry.ts",

    "milestone2", "rust", "guests/rust/milestone2.rs",
    "milestone2", "python", "guests/python/milestone2.py",
    "milestone2", "go", "guests/go/milestone2/milestone2.go",
    "milestone2", "csharp", "guests/csharp/Milestone2Scene.cs",
    "milestone2", "java",
    "guests/java/dev/kaya/milestone2kt/Milestone2.java",
    "milestone2", "swift", "guests/swift/milestone2.swift",
    "milestone2", "haskell", "guests/haskell/milestone2.hs",
    "milestone2", "ocaml", "guests/ocaml/milestone2.ml",
    "milestone2", "js", "guests/js/milestone2.ts",
]


# scene_fact <scene> — that scene's three facts. (The shell kept these
# in globals because a $( ) subshell would have swallowed the exit; a
# return value has no such hazard.)
def scene_fact(scene):
    for i in range(0, len(scene_facts), 4):
        if scene_facts[i] == scene:
            return (scene_facts[i + 1], scene_facts[i + 2],
                    scene_facts[i + 3])
    print(f"check-sugar-surface: the scene table has no facts for "
          f"'{scene}' — a scene joins with ONE scene_facts row (its "
          f"expected string, its script, the line the self-test "
          f"plants after) and one scene_guests row per language",
          file=sys.stderr)
    raise SystemExit(1)


# HASKELL'S GENERIC CONSTRUCTOR IS DENIED PER KIND, and the kind list
# is the GENERATED one this file already reads at the top, so a kind
# added to the spec is denied here without anyone editing a list. The
# denial is total: no kind is exempt.
if not kinds:
    print("no widget kinds reached the haskell clause — it would be "
          "vacuous", file=sys.stderr)
    print("check-sugar-surface: FAIL (no haskell kind list for the "
          "scene clause)")
    raise SystemExit(1)
_hs_pascal = [k[0].upper() + k[1:] for k in kinds]
hs_alt = "|".join(_hs_pascal)
hs_first = _hs_pascal[0]

# THE FLOOR VOCABULARY, FIVE FIELDS PER ROW: the SCENES the row guards,
# the language, what the spelling IS, the regex that finds it, and A
# LINE OF THAT LANGUAGE'S FLOOR THAT MUST TRIP IT. The last field is not
# decoration: the self-test plants every snippet in a copy of its real
# guest, once per scene the row guards, and requires the clause to name
# every row. A pattern cannot be added without a line proving it fires.
#
# THE FIRST FIELD IS "*" FOR ALL SCENES, which is what a floor spelling
# normally is. One pair of rows is scene-specific, for a reason written
# where it stands.
scene_rules = [
    "*", "rust", "widget-kind construction", r"\.widget\(WidgetKind::",
    "        let column = tx.widget(WidgetKind::Column);",
    "*", "rust", "the add_child chain", r"\.add_child\(",
    "        tx.add_child(column, field);",
    "*", "rust", "generic prop writes", "Prop::",
    '        tx.set(add, Prop::Text, "add");',
    "*", "rust", "the for_each combinator", r"\.for_each\(",
    "        let (todo_list, ()) = tx.for_each(&todos, |t| {});",
    "*", "rust", "bind_element by index", r"\.bind_element\(",
    "        t.bind_element(label, Prop::Text, 0);",

    # PYTHON HAS NO WIDGET-KIND FLOOR TO LEAVE: its public surface is
    # the sugar (the kind constructors call a private _widget). The
    # clause is written anyway, as a rule about what must NOT ARRIVE.
    # `kaya.for_each` is real today and is the tier below the `for`
    # statement this scene traces with; the other two name spellings the
    # binding does not export.
    "*", "python", "the for_each combinator", r"kaya\.for_each\(",
    "    with kaya.for_each(todos) as todo:",
    "*", "python", "the add_child chain", r"\.add_child\(",
    "    column.add_child(field)",
    "*", "python", "bind_element by index", r"\.bind_element\(",
    "    label.bind_element(0)",

    "*", "go", "widget-kind construction", r"\.Widget\(",
    "        column := tx.Widget(kaya.KindColumn)",
    # NO SetText/setText/set_text ROW, and the reason is not an
    # oversight: in six languages the template PROP WRITE and the
    # set_text WIDGET VERB shared one name, so no pattern could fail the
    # floor use without failing the verb — the receiver TYPE decides and
    # no regex sees a type. Those six now hide the template write
    # (unexported/private, so the wall is the compiler) or rename it
    # (Haskell setTextProp, OCaml Tpl.Floor.*), and the renamed
    # spellings are swept repo-wide by tools/guest-floor.py
    # (docs/tpl-props-plan.md F3).
    "*", "go", "the generic BindText", r"\.BindText\(",
    "        tx.BindText(statusLabel, status)",
    # NO ForEach ROW: Go's callback For is gone (the idiom sweep,
    # 2026-08-24) — a For is a for statement over Rows.All(), and there
    # is no floor spelling of it left for a scene to fall back to.
    "*", "go", "BindTextElement by index", r"\.BindTextElement\(",
    "        t.BindTextElement(label, 0)",
    "*", "go", "the AddChild chain", r"\.AddChild\(",
    "        tx.AddChild(column, field)",

    "*", "csharp", "widget-kind construction", r"\.Widget\(",
    "            var column = tx.Widget(KayaWire.KindColumn);",
    "*", "csharp", "the generic BindText", r"\.BindText\(",
    "            tx.BindText(statusLabel, status);",
    "*", "csharp", "the ForEach combinator", r"\.ForEach\(",
    "            var todoList = tx.ForEach(todos, null);",
    "*", "csharp", "BindTextElement by index", r"\.BindTextElement\(",
    "            t.BindTextElement(label);",
    "*", "csharp", "the AddChild chain", r"\.AddChild\(",
    "            tx.AddChild(column, field);",

    "*", "java", "widget-kind construction", r"\.widget\(",
    "            KayaApp.Widget column = "
    "tx.widget(KayaWire.KIND_COLUMN);",
    "*", "java", "the generic bindText", r"\.bindText\(",
    "            tx.bindText(statusLabel, status);",
    # JAVA'S CALLBACK For DIED 2026-08-24 (the one form is the eager
    # `rows` Iterable), so `.forEach(` names nothing this binding
    # exports and the compiler is that wall. What is still reachable is
    # the tier BELOW the for statement: KayaRecords.rowTrace, public
    # because the generated surfaces call it from the guests' package.
    "*", "java", "the rowTrace machinery", r"KayaRecords\.rowTrace\(",
    "            KayaRecords.rowTrace(tx, todos, t -> t);",
    "*", "java", "bindTextElement by index", r"\.bindTextElement\(",
    "            t.bindTextElement(label, 0);",
    "*", "java", "the addChild chain", r"\.addChild\(",
    "            tx.addChild(column, field);",

    "*", "swift", "widget-kind construction", r"\.widget\(",
    "    let column = tx.widget(UInt32(KAYA_KIND_COLUMN))",
    "*", "swift", "the generic bindText", r"\.bindText\(",
    "    tx.bindText(statusLabel, status)",
    "*", "swift", "the forEach combinator", r"\.forEach\(",
    "    let (todoList, _) = tx.forEach(todos) { t in }",
    "*", "swift", "bindTextElement by index", r"\.bindTextElement\(",
    "        t.bindTextElement(label)",
    "*", "swift", "the addChild chain", r"\.addChild\(",
    "    tx.addChild(column, field)",

    "*", "haskell", "the addChild chain",
    r"(^|[^A-Za-z])addChild[[:space:]]",
    "    addChild column field",
    "*", "haskell", "bindTextElement by index",
    r"(^|[^A-Za-z])bindTextElement[[:space:]]",
    "      bindTextElement label 0",
    "*", "haskell", "the generic bindText",
    r"(^|[^A-Za-z])bindText[[:space:]]",
    "    bindText statusLabel status",

    "*", "ocaml", "widget-kind construction",
    r"(^|[^A-Za-z_])widget kind_",
    "       let column = widget kind_column in",
    "*", "ocaml", "the generic bind_text",
    r"(^|[^A-Za-z_])bind_text[[:space:]]",
    "       bind_text status_label status;",
    "*", "ocaml", "the add_child chain",
    r"(^|[^A-Za-z_])add_child[[:space:]]",
    "       add_child column field;",

    # JS HAS NO WIDGET-KIND FLOOR ON ITS OWN SURFACE — python's case —
    # but it RE-EXPORTS the generated wire module (`export { wire }`), so
    # the floor a guest can still reach is spelled through it. `forEach`
    # is real and is the tier below the `for` statement these scenes
    # trace with, exactly as python's `kaya.for_each` is.
    "*", "js", "the forEach combinator", r"kaya\.forEach\(",
    "  kaya.forEach(todos, (todo) => {});",
    "*", "js", "widget-kind construction", r"wire\.tx_create_widget\(",
    "  kaya.wire.tx_create_widget(1, kaya.wire.KIND_COLUMN);",
    "*", "js", "the add_child chain", r"wire\.tx_add_child\(",
    "  kaya.wire.tx_add_child(1, 2);",
    "*", "js", "bind_element by index",
    r"wire\.tx_bind_text_element\(",
    "  kaya.wire.tx_bind_text_element(1, 0, 0);",

    # THE FOR COMBINATOR IS THE FLOOR IN ENTRY AND THE SUGAR IN
    # MILESTONE2, in these two languages only: `each` IS the combinator
    # with the body's RESULT THROWN AWAY. entry's template body returns
    # () so `each` is its spelling; milestone2's body returns the two
    # handles its CENTRAL registration names, and a closure in these two
    # languages cannot assign an outer variable the way swift's and
    # java's do, so the result is the only way out.
    #
    # So milestone2 keeps the combinator and is denied the sin still
    # available to it: a For whose result is (), which is a For `each`
    # should have made. Both halves are watched firing.
    "entry", "haskell", "the forEach combinator",
    r"(^|[^A-Za-z])forEach[[:space:]]",
    "    forEach todos body",
    "milestone2", "haskell", "a For whose result it drops",
    r"\(\)\)[[:space:]]*<-[[:space:]]*forEach",
    "    (todoList, ()) <- forEach todos $ do",
    "entry", "ocaml", "the for_each combinator",
    r"(^|[^A-Za-z_])for_each[[:space:]]",
    "       for_each todos body;",
    "milestone2", "ocaml", "a For whose result it drops",
    r"^[[:space:]]*let [a-z_]+, \(\) =",
    "       let todo_list, () =",
]
scene_rules += ["*", "haskell", "widget-kind construction",
                f"widget kind({hs_alt})([^A-Za-z]|$)",
                f"    column <- widget kind{hs_first}"]

# EVERY ROW MUST GUARD AT LEAST ONE FILE. A scene scope or a language
# that names nothing — one typo, `mileston2` — is a row that is never
# read, never planted, and so NEVER SEEN FAILING: it would pass forever
# and take its rule with it. The loops below skip a row that does not
# apply, silently and by design (that is how "*" and a scene name share
# one table), so the table's own integrity is checked here.
for sr in range(0, len(scene_rules), 5):
    rule_files = 0
    for sg in range(0, len(scene_guests), 3):
        if scene_guests[sg + 1] != scene_rules[sr + 1]:
            continue
        if scene_rules[sr] in ("*", scene_guests[sg]):
            rule_files += 1
    if rule_files == 0:
        print(f"check-sugar-surface: SELF-TEST FAIL (the floor row "
              f"[{scene_rules[sr]} {scene_rules[sr + 1]} — "
              f"{scene_rules[sr + 2]}] guards no file at all: its "
              f"scene scope or its language names nothing in the "
              f"scene table, so the rule is never read and could "
              f"never be watched failing)", file=sys.stderr)
        raise SystemExit(1)


# floor <language> <scene> <text> <what> <regex> <file to name in the
# message> — deny's scene-side sibling.
def floor(lang, scene, text, what, regex, shown):
    global status
    if grep_e(regex, text):
        print(f"check-sugar-surface: {lang}'s {scene} guest still "
              f"spells {what} at the explicit floor (found /{regex}/ "
              f"in {shown}) — an example scene uses its language's "
              f"construction sugar (CLAUDE.md invariant 5), and "
              f"{scene}'s carve-out is its EVENT mechanism and "
              f"nothing else (DESIGN.md, scope ratified 2026-08-05)")
        status = 1


# scene_one <scene> <language> <file> — the clause over ONE guest.
def scene_one(scene, lang, f):
    global status
    fact_anchor, fact_steps, _plant = scene_fact(scene)
    shown = f
    try:
        raw = open(f, encoding="utf-8").read()
    except OSError:
        raw = None

    # THE ANTI-VACUITY FLOOR. A read that finds nothing in a file that
    # is not there is indistinguishable from a clean scene, so a
    # renamed or deleted guest would satisfy every denial below at
    # once. Each file therefore proves it IS the scene it is filed
    # under first, by carrying that scene script's own expected string
    # — frozen by invariant 6, and byte-identical in all nine
    # languages by invariant 6's whole point.
    if raw is None or fact_anchor not in raw:
        print(f"check-sugar-surface: {f} is not the {scene} scene — "
              f"it does not carry \"{fact_anchor}\", the scene "
              f"script's own expected string ({fact_steps}) — so this "
              f"clause reads it and passes vacuously about it")
        status = 1

    # RUST IS READ WITH ITS COMMENT LINES DROPPED, and only rust: both
    # its headers NAME `ctx.next()` in prose, so the positive pin below
    # would be satisfied by the sentence describing the loop rather than
    # by the loop. The other eight are read whole — a comment spelling a
    # floor call in a graduated scene teaches the floor.
    if lang == "rust":
        if raw is None:
            print(f"check-sugar-surface: {f} could not be read (this "
                  f"clause reads the rust guest with its comment "
                  f"lines dropped)")
            status = 1
            return
        text = "\n".join(ln for ln in raw.split("\n")
                         if not ln.lstrip().startswith("//"))
        shown = f"{f} (comments dropped)"
    else:
        text = raw or ""

    for i in range(0, len(scene_rules), 5):
        if scene_rules[i + 1] != lang:
            continue
        if scene_rules[i] not in ("*", scene):
            continue
        floor(lang, scene, text, scene_rules[i + 2],
              scene_rules[i + 3], shown)

    # (b) AND RUST'S RAW LOOP STAYS, IN EVERY SCENE THE CARVE-OUT NAMES.
    if lang == "rust" and not grep_e(r"ctx\.next\(\)", text):
        print(f"check-sugar-surface: rust's {scene} guest no longer "
              f"reads occurrences through the raw `ctx.next()` loop "
              f"({f}) — that loop IS this scene's carve-out and one "
              f"of the two guests documenting the tier kaya::Messages "
              f"is built on (DESIGN.md, scope ratified 2026-08-05). "
              f"Graduating it is the maintainer's decision, not a "
              f"cleanup")
        status = 1


# check_scene_sugar [<scene>:<language>=<path> ...] — the clause over
# the whole table, with any row's guest swapped for a doctored copy.
#
# The overrides exist for the reason deny_loose's path arguments do:
# the self-test runs this against DOCTORED COPIES OF THE REAL GUESTS,
# and a rule about sixteen fixed paths could never be watched failing.
# The real run passes none and reads the table.
def check_scene_sugar(*overrides):
    for i in range(0, len(scene_guests), 3):
        scene = scene_guests[i]
        lang = scene_guests[i + 1]
        file = scene_guests[i + 2]
        for o in overrides:
            prefix = f"{scene}:{lang}="
            if o.startswith(prefix):
                file = o[len(prefix):]
        scene_one(scene, lang, file)


# The shell ran the doctored sweeps inside `$( )`, where the status=1
# they set died with the subshell; this captures both streams and
# restores the verdict the same way. A SystemExit inside (a scene
# missing from the table) ends only the capture, as the subshell's
# exit did.
def scene_capture(*overrides):
    global status
    saved = status
    buf = io.StringIO()
    old_out, old_err = sys.stdout, sys.stderr
    sys.stdout = sys.stderr = buf
    try:
        check_scene_sugar(*overrides)
    except SystemExit:
        buf.write("(the doctored sweep exited early)\n")
    finally:
        sys.stdout, sys.stderr = old_out, old_err
    status = saved
    return buf.getvalue().rstrip("\n")


scene_applied = []


def applied_scene(count, label):
    if count >= 1:
        scene_applied.append(f" {label}={count}")
        return
    print(f"check-sugar-surface: SELF-TEST FAIL (scene perturbation "
          f"{label} applied {count} times, want at least 1 — an "
          f"unchanged copy cannot prove the rule fires)",
          file=sys.stderr)
    raise SystemExit(1)


# scene_block <scene> <language> — the floor snippets that language
# owes THIS scene, ready to be spliced in as a python replacement (a
# literal \n before each).
def scene_block(scene, lang):
    out = ""
    for i in range(0, len(scene_rules), 5):
        if scene_rules[i + 1] != lang:
            continue
        if scene_rules[i] in ("*", scene):
            out += "\\n" + scene_rules[i + 4]
    return out


# <source> <regex> <replacement> <destination> -> substitution count
def perturb_scene(src, pattern, repl, dst):
    text = open(src, encoding="utf-8").read()
    out, n = sub_count(pattern, repl, text, flags=re.M)
    open(dst, "w", encoding="utf-8").write(out)
    return n


T = tempfile.mkdtemp()
atexit.register(shutil.rmtree, T, ignore_errors=True)


# THE PERTURBATIONS, ON DOCTORED COPIES OF THE REAL GUESTS. One per
# SCENE PER LANGUAGE: every snippet a language owes a scene is planted
# after that scene's plant line, and the clause must then name EVERY
# rule the pair has, IN THAT SCENE NAME. A snippet the pattern misses
# is a pattern that would never have fired.
def scene_selftest(scene, lang, src):
    _anchor, _steps, fact_plant = scene_fact(scene)
    doctored = os.path.join(T, f"scene-floor-{scene}-{lang}.txt")
    hits = perturb_scene(src, fact_plant,
                         "\\g<1>" + scene_block(scene, lang), doctored)
    applied_scene(hits, f"{scene}/{lang}")
    out = scene_capture(f"{scene}:{lang}={doctored}")
    missing = ""
    for i in range(0, len(scene_rules), 5):
        if scene_rules[i + 1] != lang:
            continue
        if scene_rules[i] not in ("*", scene):
            continue
        what = scene_rules[i + 2]
        if f"{lang}'s {scene} guest still spells {what} " not in out:
            missing += f" [{what}]"
    if missing:
        print(f"check-sugar-surface: SELF-TEST FAIL ({lang} floor "
              f"patterns that did NOT fire on a doctored copy of the "
              f"real {scene} guest:{missing})", file=sys.stderr)
        raise SystemExit(1)


for sg in range(0, len(scene_guests), 3):
    scene_selftest(scene_guests[sg], scene_guests[sg + 1],
                   scene_guests[sg + 2])

# AND THE POSITIVE PIN IS WATCHED FAILING TOO, ONCE PER RUST GUEST: (b)
# is the half that says something must STAY, so the only way to see it
# work is to take it away. The prose in each header still names
# `ctx.next()` after this substitution, which is exactly why the clause
# reads rust with its comments dropped.
for sg in range(0, len(scene_guests), 3):
    if scene_guests[sg + 1] != "rust":
        continue
    scene_pin = scene_guests[sg]
    noloop = os.path.join(T, f"scene-noloop-{scene_pin}.rs")
    hits = perturb_scene(scene_guests[sg + 2], r"match ctx\.next\(\)",
                         "match ctx.peek()", noloop)
    applied_scene(hits, f"{scene_pin}/rust-raw-loop")
    scene_loop_out = scene_capture(f"{scene_pin}:rust={noloop}")
    if (f"rust's {scene_pin} guest no longer reads occurrences "
            f"through the raw") not in scene_loop_out:
        print(f"check-sugar-surface: SELF-TEST FAIL (rust's "
              f"{scene_pin} guest was not refused for losing its raw "
              f"occurrence loop: "
              f"{scene_loop_out or 'no output at all'})",
              file=sys.stderr)
        raise SystemExit(1)

# AND SO IS THE ANTI-VACUITY FLOOR, ONCE PER SCENE — the anchor is a
# per-scene fact, so each has to be watched refusing. A file this clause
# cannot recognise as the scene it is filed under has to fail LOUDLY
# rather than satisfy every denial by having nothing in it
# (docs/traps.md). What is under test is the anchor, not the language.
# (The anchors are data in a table and one of them will one day carry a
# `.` or a `(`, so the pattern is re.escape'd and the SHOUTED
# replacement has its backslashes doubled — a backslash in an anchor
# would otherwise read as a group reference.)
for sg in range(0, len(scene_guests), 3):
    if scene_guests[sg + 1] != "ocaml":
        continue
    scene_vac = scene_guests[sg]
    fact_anchor, _steps, _plant = scene_fact(scene_vac)
    notscene = os.path.join(T, f"scene-notscene-{scene_vac}.ml")
    hits = perturb_scene(scene_guests[sg + 2], re.escape(fact_anchor),
                         fact_anchor.upper().replace("\\", "\\\\"),
                         notscene)
    applied_scene(hits, f"{scene_vac}/ocaml-anchor")
    scene_vac_out = scene_capture(f"{scene_vac}:ocaml={notscene}")
    if f"is not the {scene_vac} scene" not in scene_vac_out:
        print(f"check-sugar-surface: SELF-TEST FAIL (a file that is "
              f"not the {scene_vac} scene was not refused: "
              f"{scene_vac_out or 'no output at all'})",
              file=sys.stderr)
        raise SystemExit(1)
print("check-sugar-surface: scene-tier perturbations applied:"
      + "".join(scene_applied), file=sys.stderr)

check_scene_sugar()

if status != 0:
    print("check-sugar-surface: FAIL")
    raise SystemExit(1)
print("check-sugar-surface: OK")
