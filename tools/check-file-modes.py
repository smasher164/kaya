#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# A FILE MODE IS A NUMBER THAT CROSSES THREE ABIs, AND THE SPEC OWNS IT.
#
# `kaya_open_picked(handle, mode, …)` takes an integer whose meaning
# crates/kaya/src/spec.rs declares. Every GENERATED surface moves when
# that numbering moves; five HAND-WRITTEN sites do not — protocol.rs's
# picked_mode_code, the SwiftUI interpreter's POSIX flags, the C# and
# python bindings' FileAccess and fdopen spellings. Renumber and the
# guest asks to READ while the backend opens O_WRONLY|O_TRUNC, with no
# error anywhere (docs/save-plan.md D3).
#
# So this gate reads the numbers OUT OF THE SPEC and carries only the
# SEMANTICS; the numbers are never written down here:
#
#   read        opens for reading and MUST NOT truncate
#   write       opens for writing and MUST truncate
#   read_write  opens for both and MUST NOT truncate
#
# Creation is deliberately NOT pinned (D1 puts it in the core), but no
# mode may swap its ACCESS or its TRUNCATION.
#
# THE CENSUS is the half that survives someone adding a site: every
# file naming a redemption entry point is in SITES (its arms are
# checked) or in PASSTHROUGH (it hands the number on, WITH A REASON —
# and that claim is checked, by refusing any branch on `mode` in it).
# Generated surfaces are excluded: gen-bindings/gen-header diff them
# already.
#
# NOT IN SCOPE: guests/, which all name the constant rather than a
# digit. A guest that writes a bare integer is a rule this can grow.

import os
import re

g = Gate("check-file-modes")

SPEC = "crates/kaya/src/spec.rs"
WIRE = "crates/kaya/src/wire.rs"
PROTOCOL = "crates/kaya/src/protocol.rs"
SWIFTUI = "swift/KayaSwiftUI.swift"
CSHARP = "bindings/csharp/Kaya.cs"
PYRUNTIME = "bindings/python/kaya/runtime.py"

# What each mode MEANS, which is all this gate knows. The numbers come
# from the spec, every time, and appear nowhere below.
ACCESS = {"read": "O_RDONLY", "write": "O_WRONLY",
          "read_write": "O_RDWR"}
TRUNCATES = {"read": False, "write": True, "read_write": False}
FILE_ACCESS = {"read": "Read", "write": "Write",
               "read_write": "ReadWrite"}
FDOPEN = {"read": "rb", "write": "wb", "read_write": "r+b"}

ROOTS = ["crates/kaya/src", "swift",
         "android/kaya/src/main/kotlin/dev/kaya", "bindings"]


def camel(name):
    return "".join(part.capitalize() for part in name.split("_"))


def span(text, i, opener="{", closer="}"):
    """From the bracket at `i` to its match, with comments and string
    literals skipped so a bracket inside either cannot end it early."""
    depth, j, n = 0, i, len(text)
    while j < n:
        c = text[j]
        if c == "/" and j + 1 < n and text[j + 1] == "/":
            j = text.find("\n", j)
            if j < 0:
                break
            continue
        if c == "/" and j + 1 < n and text[j + 1] == "*":
            j = text.find("*/", j)
            if j < 0:
                break
            j += 2
            continue
        if c == '"':
            j += 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            j += 1
            continue
        if c == opener:
            depth += 1
        elif c == closer:
            depth -= 1
            if depth == 0:
                return text[i:j + 1]
        j += 1
    return None


def body(text, pattern):
    """The braced body of the first function matching `pattern`, or
    None — and None is a FAILURE at every callsite below, never a pass:
    a gate that stops finding what it reads reports a clean bill about
    nothing."""
    m = re.search(pattern, text)
    if not m:
        return None
    i = text.find("{", m.end() - 1)
    if i < 0:
        return None
    return span(text, i)


COMMENTS = [
    re.compile(r"/\*.*?\*/", re.S), re.compile(r"\(\*.*?\*\)", re.S),
    re.compile(r"(?m)//.*$"), re.compile(r"(?m)#.*$"),
    re.compile(r"(?m)--.*$"),
]


def code(text):
    """The file with its comments blanked. The census reads this and
    not the raw bytes: gtk.rs, winui/mod.rs and KayaCompose.kt each
    NAME the redemption in a sentence — "so kaya_open_picked redeems a
    pasted file identically" — while registering a PathSource and never
    seeing a mode. Reading prose as code put all three in this gate's
    tables, and a table entry for a file with no mode in it is an entry
    that can only ever be wrong.

    Newlines survive so the line numbers this gate prints are the
    file's own."""
    for pattern in COMMENTS:
        text = pattern.sub(lambda m: "\n" * m.group(0).count("\n"),
                           text)
    return text


def literal_arms(text, head):
    """A switch/match on the mode whose ARMS are bare integers, or
    None.

    Branching on the mode is fine — Java does it, and so does the
    core's own decoder — as long as the arms name constants. What may
    not happen outside the SITES is a DIGIT standing for a mode."""
    m = re.search(head, text)
    if not m:
        return None
    opener = "{" if "{" in text[m.end():m.end() + 40] else None
    if opener is None:
        return None
    block = span(text, text.find("{", m.end()))
    if block is None:
        return None
    hit = re.search(r"(?m)^\s*(?:case\s+)?(\d+)\s*(?::|->|=>)", block)
    return m.start() if hit else None


def interpreting(text):
    """Where this file writes a mode number down, or None."""
    m = re.search(r"(?<![A-Za-z0-9_])mode\s*(?:==|!=|>=|<=|<|>)\s*[0-9]",
                  text)
    if m:
        return m.start(), "compares the mode with a number"
    m = re.search(r"\[\s*mode\s*\]", text)
    if m:
        return m.start(), "subscripts a table by the mode"
    for head in (r"(?<![A-Za-z0-9_])mode\s+switch\b",
                 r"switch\s*\(?\s*mode(?![A-Za-z0-9_])",
                 r"match\s+mode(?![A-Za-z0-9_])",
                 r"when\s*\(\s*mode\s*\)"):
        at = literal_arms(text, head)
        if at is not None:
            return at, "switches on the mode with bare numbers for arms"
    return None


# Generated surfaces are excluded because gen-bindings.sh/gen-header.sh
# regenerate and diff them: they cannot drift from the spec, and
# listing them here would be a second, weaker copy of that gate.
GENERATED = {
    "bindings/c/kaya_wire.h", "bindings/csharp/KayaWire.cs",
    "bindings/go/kaya_wire.go", "bindings/haskell/KayaWire.hs",
    "bindings/java/dev/kaya/KayaWire.java",
    "bindings/ocaml/kaya_wire.ml", "bindings/python/kaya/wire.py",
    "bindings/swift/KayaWire.swift", "bindings/js/kaya/wire.ts",
}
SITES = {SPEC, WIRE, PROTOCOL, SWIFTUI, CSHARP, PYRUNTIME}
# Files that redeem a handle WITHOUT writing a mode number down: they
# hand it on, or branch on it through the NAMED constants. The reason
# is required and the claim is CHECKED below.
#
# The rule underneath the whole gate: a numeric mode literal belongs
# only where a number arrives over an ABI and there is no name to use —
# the four SITES above. Everywhere else the name must be used.
PASSTHROUGH = {
    "bindings/go/runtime.go":
        "os.NewFile over the raw handle; the number goes to C",
    "bindings/java/dev/kaya/KayaApp.java":
        "switches on the mode through KayaWire's named constants",
    "bindings/java-desktop/dev/kaya/KayaRing.java":
        "the native declaration only",
    "bindings/haskell/KayaRuntime.hs":
        "fdToHandle over the raw fd; the Word32 goes to C",
    "bindings/haskell/KayaApp.hs": "re-exports openPicked",
    "bindings/ocaml/kaya_runtime.ml": "Ctypes hands the int to C",
    "bindings/swift/KayaApp.swift":
        "defaults to FILE_MODE_READ and passes it on",
    "bindings/python/kaya/__init__.py":
        "defaults to wire.FILE_MODE_READ and passes it on",
    "bindings/js/kaya/index.ts":
        "defaults to wire.FILE_MODE_READ and passes it on",
    "bindings/js/kaya/runtime.ts":
        "hands the number to the addon; refuses win32 by name",
    "crates/kaya/src/node.rs":
        "casts the JS number to u32 and calls the core",
    "crates/kaya/src/capi.rs":
        "decodes with the wire.rs CONSTANTS, never a literal",
    "crates/kaya/src/jvm.rs":
        "the JNI shim casts jint to u32 and calls the core",
    "crates/kaya/src/android.rs":
        "turns the FileMode into a mode STRING (r/wt/rw); "
        "no number crosses to Kotlin",
    "crates/kaya/src/swiftui_host.rs":
        "calls picked_mode_code and passes the result",
    "android/kaya/src/main/kotlin/dev/kaya/KayaPresent.kt":
        "openPickedUri takes the mode as a STRING from android.rs",
    "android/kaya/src/main/kotlin/dev/kaya/KayaRing.kt":
        "the external declaration only",
}
REDEEMS = re.compile(r"kaya_open_picked|open_picked|openPicked|"
                     r"OpenPicked")


def check(root):
    """Findings for one tree — a shadow root in the self-tests, the
    real one at the end. What makes every clause testable against a
    doctored real file rather than a fixture (docs/traps.md, the
    wayland seat guard)."""
    bad = []

    def read(rel):
        return (root / rel).read_text(encoding="utf-8")

    def gone(path, what, anchor):
        bad.append(
            f"{path}: {what} ({anchor}) is not where this gate looks — "
            f"the site moved and the check went vacuous, which is worse "
            f"than a failure because it reads as a pass")

    # --- 0. THE ROOT: the spec's numbering. ---------------------------
    text = read(SPEC)
    m = re.search(r'name:\s*"file_mode"\s*,\s*variants:\s*&\[([^\]]*)\]',
                  text)
    if not m:
        return [f"{SPEC}: no file_mode EnumSpec — the numbering moved "
                f"and this gate has nothing to check against"]
    MODES = {name: int(value) for name, value in
             re.findall(r'\(\s*"([a-z_]+)"\s*,\s*(\d+)\s*\)',
                        m.group(1))}
    if not MODES:
        return [f"{SPEC}: the file_mode EnumSpec declares no variants"]
    # A MODE THIS GATE HAS NO SEMANTICS FOR IS A MODE NOBODY PINNED.
    # That is the wall under D1's rejection of a fourth mode: adding
    # one to the spec fails here until every site below is taught what
    # it means.
    for name in MODES:
        if name not in ACCESS:
            bad.append(
                f'{SPEC}: file_mode declares "{name}", which '
                f"tools/check-file-modes.sh has no semantics for — a "
                f"new mode must be given its access and truncation "
                f"rule HERE and then pinned at every site, or it ships "
                f"meaning one thing in the core and another in each "
                f"backend")
    known = {name: number for name, number in MODES.items()
             if name in ACCESS}

    # --- 1. wire.rs: the C ABI's names. -------------------------------
    text = read(WIRE)
    declared = {name: int(value) for name, value in
                re.findall(r"pub(?:\(crate\))? const FILE_MODE_([A-Z_]+)\s*:\s*u32"
                           r"\s*=\s*(\d+)\s*;", text)}
    if not declared:
        gone(WIRE, "the FILE_MODE constants",
             "pub(crate) const FILE_MODE_*: u32")
    for name, number in known.items():
        have = declared.get(name.upper())
        if have is None:
            bad.append(f"{WIRE}: no FILE_MODE_{name.upper()} constant, "
                       f"though the spec declares the mode")
        elif have != number:
            bad.append(f"{WIRE}: FILE_MODE_{name.upper()} = {have} but "
                       f"the spec says {number} ({SPEC})")
    for name in declared:
        if name.lower() not in MODES:
            bad.append(f"{WIRE}: FILE_MODE_{name} is a mode the spec "
                       f"does not declare — the C ABI would carry a "
                       f"number nothing else knows")

    # --- 2. protocol.rs: the number the core SENDS. -------------------
    # picked_mode_code's arms are bare literals pinned by a unit test
    # that hard-codes the same literals — the pair agrees with itself
    # while both disagree with the spec, which is why a `cargo test`
    # cannot do this.
    text = read(PROTOCOL)
    fn = body(text, r"\bfn +picked_mode_code\b")
    if fn is None:
        gone(PROTOCOL, "the function that turns a FileMode into the "
                       "ABI number", "fn picked_mode_code")
    else:
        arms = {name: int(value) for name, value in
                re.findall(r"FileMode::(\w+)\s*=>\s*(\d+)", fn)}
        for name, number in known.items():
            have = arms.get(camel(name))
            if have is None:
                bad.append(f"{PROTOCOL}: picked_mode_code has no arm "
                           f"for FileMode::{camel(name)}")
            elif have != number:
                bad.append(
                    f"{PROTOCOL}: picked_mode_code sends {have} for "
                    f"FileMode::{camel(name)} but the spec numbers "
                    f'"{name}" {number} ({SPEC}) — the interpreter '
                    f"would open in the wrong mode with nothing to say "
                    f"so")

    # --- 3. KayaSwiftUI.swift: the number an interpreter RECEIVES. ----
    text = read(SWIFTUI)
    fn = body(text, r"\bfunc +kayaSwiftUIOpenPicked\b")
    if fn is None:
        gone(SWIFTUI, "the picked-file opener",
             "func kayaSwiftUIOpenPicked")
    else:
        i = fn.find("switch mode")
        sw = span(fn, fn.find("{", i)) if i >= 0 else None
        if sw is None:
            gone(SWIFTUI, "the switch over the mode number",
                 "switch mode { … }")
        else:
            arms = {int(number): flags for number, flags in
                    re.findall(r"case\s+(\d+)\s*:\s*flags\s*=\s*"
                               r"([^\n]*)", sw)}
            for name, number in known.items():
                flags = arms.get(number)
                if flags is None:
                    bad.append(
                        f"{SWIFTUI}: kayaSwiftUIOpenPicked has no "
                        f'`case {number}:` for "{name}", which is the '
                        f"number the spec gives it ({SPEC}) — the "
                        f"guest's mode would fall to the default and "
                        f"be refused")
                    continue
                tokens = set(re.findall(r"O_[A-Z]+", flags))
                want = ACCESS[name]
                others = {a for a in ACCESS.values() if a != want}
                if want not in tokens:
                    bad.append(
                        f'{SWIFTUI}: case {number} is the spec\'s '
                        f'"{name}" but opens '
                        f"{' | '.join(sorted(tokens)) or '<nothing>'} "
                        f"— it must carry {want}. A renumbered mode "
                        f"opens the user's file the wrong way and says "
                        f"nothing")
                if tokens & others:
                    bad.append(
                        f'{SWIFTUI}: case {number} is the spec\'s '
                        f'"{name}" but also carries '
                        f"{' '.join(sorted(tokens & others))}")
                truncates = "O_TRUNC" in tokens
                if truncates != TRUNCATES[name]:
                    bad.append(
                        f'{SWIFTUI}: case {number} is the spec\'s '
                        f'"{name}", which must '
                        f"{'truncate' if TRUNCATES[name] else 'NOT truncate'}, "
                        f"and it {'does' if truncates else 'does not'} "
                        f"— truncation is the difference between write "
                        f"and read_write, and getting it backwards "
                        f"destroys the file the guest meant to read")

    # --- 4. Kaya.cs: a binding that switches on the number. -----------
    text = read(CSHARP)
    fn = body(text, r"\bOpenPicked\s*\(\s*ulong\b")
    if fn is None:
        gone(CSHARP, "the picked-file opener", "OpenPicked(ulong …)")
    else:
        arms = {int(number): access for number, access in
                re.findall(r"(\d+)\s*=>\s*FileAccess\.(\w+)", fn)}
        fallback = re.search(r"_\s*=>\s*FileAccess\.(\w+)", fn)
        if not arms and not fallback:
            gone(CSHARP, "the mode switch", "N => FileAccess.X")
        for name, number in known.items():
            have = arms.get(number) or (fallback.group(1) if fallback
                                        else None)
            if have != FILE_ACCESS[name]:
                bad.append(
                    f'{CSHARP}: mode {number} is the spec\'s "{name}" '
                    f"but OpenPicked gives it FileAccess.{have} rather "
                    f"than FileAccess.{FILE_ACCESS[name]} — the "
                    f"FileStream would refuse the operation the guest "
                    f"asked for")

    # --- 5. runtime.py: the other binding that switches on it. --------
    text = read(PYRUNTIME)
    m = re.search(r"(?m)^def open_picked\b.*?(?=^\S|\Z)", text, re.S)
    fn = m.group(0) if m else None
    if fn is None:
        gone(PYRUNTIME, "the picked-file opener", "def open_picked")
    else:
        m = re.search(r"modes\s*=\s*\{([^}]*)\}", fn)
        if not m:
            gone(PYRUNTIME, "the fdopen mode table", "modes = { … }")
        else:
            table = {int(number): spelling for number, spelling in
                     re.findall(r"(\d+)\s*:\s*[\"']([^\"']+)[\"']",
                                m.group(1))}
            for name, number in known.items():
                have = table.get(number)
                if have != FDOPEN[name]:
                    bad.append(
                        f'{PYRUNTIME}: mode {number} is the spec\'s '
                        f'"{name}" but open_picked fdopens it {have!r} '
                        f"rather than {FDOPEN[name]!r}")
        # The Windows half: msvcrt.open_osfhandle takes CRT flags, and
        # the ONE mode that gets the read-only ones must be read.
        m = re.search(r"O_RDONLY\s+if\s+mode\s*==\s*(\d+)", fn)
        if not m:
            gone(PYRUNTIME, "the CRT flag choice",
                 "os.O_RDONLY if mode == …")
        elif int(m.group(1)) != known.get("read"):
            bad.append(
                f"{PYRUNTIME}: the CRT descriptor is opened read-only "
                f"for mode {m.group(1)}, but the spec's \"read\" is "
                f"{known.get('read')} ({SPEC}) — on Windows every "
                f"other mode would get a read-only fd")

    # --- 6. THE CENSUS: nobody redeems a handle unseen. ---------------
    seen = []
    for r in ROOTS:
        for f in sorted((root / r).rglob("*")):
            if not f.is_file() or "__pycache__" in f.parts:
                continue
            rel = f.relative_to(root).as_posix()
            if rel in GENERATED:
                continue
            try:
                raw = f.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            # The cheap test first, on raw bytes: blanking comments
            # across these roots costs 5s a pass and the census runs
            # twelve times.
            if not REDEEMS.search(raw):
                continue
            text = code(raw)
            if not REDEEMS.search(text):
                continue
            seen.append(rel)
            if rel in SITES:
                continue
            if rel not in PASSTHROUGH:
                bad.append(
                    f"{rel}: redeems a picked file but is in neither "
                    f"table of tools/check-file-modes.sh — say whether "
                    f"it INTERPRETS the mode number (then pin its arms "
                    f"against the spec, like {SWIFTUI} is) or takes it "
                    f"BY NAME and passes it through (then say so here, "
                    f"with a reason)")
                continue
            found = interpreting(text)
            if found:
                at, what = found
                bad.append(
                    f"{rel}:{text.count(chr(10), 0, at) + 1}: is "
                    f"listed as never writing a mode number down "
                    f"({PASSTHROUGH[rel]}) but {what} — either use the "
                    f"named constant, or move this file into SITES and "
                    f"pin its arms against the spec")
    for rel in sorted(PASSTHROUGH):
        if rel not in seen:
            bad.append(
                f"{rel}: is named by tools/check-file-modes.sh but no "
                f"longer redeems a picked file at all — either it "
                f"moved (fix the table) or the entry is dead (delete "
                f"it)")

    return bad


# THE GUARD GUARDS ITSELF, on DOCTORED COPIES OF THE REAL FILES. Each
# perturbation prints its substitution count and is REFUSED if it did
# not apply, and every refusal is checked for its REASON.
#
# A shadow root: every file this gate reads, as a symlink. Doctoring
# one means REPLACING a symlink with a real file, so the tree is never
# written through.
def fresh(name):
    dst = g.scratch() / name
    n = 0
    for r in ROOTS:
        for f in sorted((ROOT / r).rglob("*")):
            if not f.is_file() or "__pycache__" in f.parts:
                continue
            out = dst / f.relative_to(ROOT)
            out.parent.mkdir(parents=True, exist_ok=True)
            os.symlink(f, out)
            n += 1
    if n == 0:
        g.refuse("SELF-TEST FAIL (the shadow root is empty)")
    return dst


def doctor_shadow(label, shadow_root, rel, pattern, repl, want=1):
    p = shadow_root / rel
    text = g.doctor(label, p.read_text(encoding="utf-8"), pattern,
                    repl, want=want, flags=re.S)
    p.unlink()  # never write through the symlink into the real tree
    p.write_text(text, encoding="utf-8")


# N0 — the shadow root itself must pass, or every refusal below could
# be an artifact of the copy. It mirrors the live tree, so a refusal
# HERE is a real finding and says so.
base = fresh("base")
out = check(base)
if out:
    print("\n".join(out))
    print("check-file-modes: FAIL — refused before any perturbation, "
          "so this is the tree and not the self-test", file=sys.stderr)
    raise SystemExit(1)

# N1 — THE DEFECT ITSELF: renumber the spec's modes and watch every
# consumer disagree. This is the edit that used to be silent.
s = fresh("renumbered")
doctor_shadow("the spec renumbering", s, "crates/kaya/src/spec.rs",
              r'\("read", 0\), \("write", 1\)',
              '("read", 1), ("write", 0)')
renumbered = check(s)
for want, label in (
    ('swift/KayaSwiftUI.swift: case 1 is the spec\'s "read"',
     "a renumbered spec against the SwiftUI interpreter"),
    ("crates/kaya/src/protocol.rs: picked_mode_code sends",
     "a renumbered spec against picked_mode_code"),
    ("crates/kaya/src/wire.rs: FILE_MODE_READ = 0 but the spec says 1",
     "a renumbered spec against wire.rs"),
    ('bindings/csharp/Kaya.cs: mode 1 is the spec\'s "read"',
     "a renumbered spec against the C# binding"),
    ('bindings/python/kaya/runtime.py: mode 1 is the spec\'s "read"',
     "a renumbered spec against the python binding"),
):
    g.negative(label, lambda: renumbered, want=want)

# N2 — THE PAIRING, which the old three-line clause could not see: swap
# the two write-ish arms in the interpreter and keep every token
# present.
s = fresh("swapped")
doctor_shadow("the swapped-arms perturbation", s,
              "swift/KayaSwiftUI.swift",
              r"case 1: flags = O_WRONLY \| O_CREAT \| O_TRUNC\n"
              r"        case 2: flags = O_RDWR",
              "case 1: flags = O_RDWR\n"
              "        case 2: flags = O_WRONLY | O_CREAT | O_TRUNC")
g.negative("a SwiftUI interpreter whose write and read_write arms are "
           "swapped", lambda: check(s),
           want="which must truncate, and it does not")

# N3 — the vacuity half: an anchor that moved must be loud rather than
# quiet. A gate that stops finding its site reports a clean bill.
s = fresh("moved")
doctor_shadow("the anchor-rename perturbation", s,
              "swift/KayaSwiftUI.swift", r"func kayaSwiftUIOpenPicked",
              "func kayaSwiftUIRedeemPicked")
g.negative("a SwiftUI opener whose name moved", lambda: check(s),
           want="is not where this gate looks")

# N4 — a binding that switches on the number and gets one arm wrong.
s = fresh("csharp")
doctor_shadow("the C# access perturbation", s,
              "bindings/csharp/Kaya.cs", r"0 => FileAccess\.Read",
              "0 => FileAccess.Write")
g.negative("a C# binding that opens read mode for writing",
           lambda: check(s), want="rather than FileAccess.Read")

# N5 — the same, in the python binding's fdopen table.
s = fresh("python")
doctor_shadow("the python fdopen perturbation", s,
              "bindings/python/kaya/runtime.py",
              r'modes = \{0: "rb", 1: "wb", 2: "r\+b"\}',
              'modes = {0: "wb", 1: "rb", 2: "r+b"}')
g.negative("a python binding whose read and write spellings are "
           "swapped", lambda: check(s),
           want="fdopens it 'wb' rather than 'rb'")

# N6 — the producer half: picked_mode_code sending the wrong number is
# the same defect from the other end of the ABI.
s = fresh("producer")
doctor_shadow("the picked_mode_code perturbation", s,
              "crates/kaya/src/protocol.rs", r"FileMode::Write => 1,",
              "FileMode::Write => 2,")
g.negative("a core that sends the wrong mode number to an interpreter",
           lambda: check(s),
           want="picked_mode_code sends 2 for FileMode::Write")

# N7 — THE CENSUS: a new redemption site in neither table must fail.
s = fresh("census")
(s / "crates/kaya/src/zz-invented-by-selftest.rs").write_text(
    "fn f() { kaya_open_picked(); }\n", encoding="utf-8")
g.negative("a new file that redeems a handle and is in no table",
           lambda: check(s),
           want="is in neither table of tools/check-file-modes.sh")

# N8 — a PASS-THROUGH claim that stopped being true must fail. Go is
# the victim because it is the plainest of them: one call, no branch.
s = fresh("interprets")
doctor_shadow("the pass-through perturbation", s,
              "bindings/go/runtime.go", r"rc := C\.kaya_open_picked",
              "if mode == 1 { _ = mode }\n\t"
              "rc := C.kaya_open_picked")
g.negative("a binding that started interpreting the mode number",
           lambda: check(s), want="compares the mode with a number")

# N9 — A FOURTH MODE, which is the wall under D1's rejection of
# FILE_MODE_CREATE: a mode the sites do not know must not ship.
s = fresh("fourth")
doctor_shadow("the fourth-mode perturbation", s,
              "crates/kaya/src/spec.rs", r'\("read_write", 2\)\]',
              '("read_write", 2), ("create", 3)]')
g.negative("a fourth file mode nobody pinned", lambda: check(s),
           want='declares "create", which tools/check-file-modes.sh '
                'has no semantics for')

# N10 — a table entry whose file stopped redeeming anything must fail,
# so an entry cannot quietly become decorative.
s = fresh("dead")
doctor_shadow("the dead-entry perturbation", s,
              "bindings/go/runtime.go", r"kaya_open_picked",
              "kaya_open_something")
g.negative("a table entry whose file stopped redeeming",
           lambda: check(s),
           want="no longer redeems a picked file at all")

g.negatives_ran(14)

offenders = check(ROOT)
if offenders:
    print("\n".join(offenders))
    print("check-file-modes: FAIL")
    raise SystemExit(1)
g.verdict()
