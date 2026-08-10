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
# A FILE MODE IS A NUMBER THAT CROSSES THREE ABIs, AND THE SPEC OWNS IT.
#
# `kaya_open_picked(handle, mode, …)` takes an integer. The spec declares
# what the integers mean — `EnumSpec { name: "file_mode", variants:
# &[("read", 0), ("write", 1), ("read_write", 2)] }` in
# crates/kaya/src/spec.rs — and from there the number travels:
#
#   the guest        -> the generated wire constant  (gen-bindings holds it)
#   crates/kaya/src/wire.rs      the C ABI's names
#   crates/kaya/src/protocol.rs  picked_mode_code, which SENDS the number
#                                on to an interpreter backend
#   swift/KayaSwiftUI.swift      kayaSwiftUIOpenPicked, which RECEIVES it
#                                and picks POSIX open flags from bare
#                                literals: `case 0: flags = O_RDONLY`
#   bindings/csharp/Kaya.cs      picks a FileAccess from bare literals
#   bindings/python/kaya/runtime.py  picks an fdopen mode string likewise
#
# NOTHING HELD THOSE TOGETHER. Renumber the enum — swap read and write,
# insert a mode in the middle — and every generated surface moves in
# lockstep while the five hand-written sites keep their old literals. The
# guest asks to READ and the backend opens O_WRONLY|O_TRUNC: the file the
# user picked is emptied, no error is raised anywhere, and the read comes
# back blank. That is docs/save-plan.md D3's second defect, found while
# probing the save milestone (scratchpad/save-probe-{mac,windows}.md).
#
# WHY NOT THE CLAUSE THAT ALREADY EXISTED. tools/check-steps.sh grew a
# three-line version of this (its clause 3, now deleted in favour of
# this file), and it was weak in four ways that are worth recording
# because they are the ways this kind of gate is usually weak:
#
#   1. its window was `swift[swift.index("kaya_swiftui_open_picked"):]`
#      — the whole REST of a ten-thousand-line file, so "case 0" and
#      "O_RDONLY" satisfied it from anywhere below;
#   2. it tested EXISTENCE, not PAIRING: swapping case 1's flags with
#      case 2's kept every string present and passed;
#   3. it hard-coded 0/1/2 IN THE GATE, so renumbering the spec — the
#      one edit the clause names in its own comment — left it green;
#   4. it knew one site. Not picked_mode_code, which produces the very
#      number Swift consumes, and not the two bindings that switch on it.
#
# So this gate reads the numbers OUT OF THE SPEC and carries only the
# SEMANTICS: what each named mode must mean at each site. The numbers are
# never written down here.
#
# WHAT "MEANS" MEANS, per site, and why it is stated this loosely:
#
#   read        opens for reading and MUST NOT truncate
#   write       opens for writing and MUST truncate
#   read_write  opens for both and MUST NOT truncate
#
# Creation is deliberately NOT pinned. D1 puts creation in the CORE (a
# save destination creates; a picked file does not), so an interpreter is
# free to pass O_CREAT or not as its platform requires — but no mode may
# ever swap its ACCESS or its TRUNCATION, which is exactly what a
# renumbering does silently.
#
# THE CENSUS is the half that survives someone adding a site. Every file
# under the source roots that names a redemption entry point must be in
# one of two tables here: SITES (it interprets the number, and its arms
# are checked) or PASSTHROUGH (it hands the number on untouched, WITH A
# REASON — and that claim is checked too, by refusing any comparison,
# subscript or switch on `mode` in it). A file in neither fails. The
# generated surfaces are excluded by name: gen-bindings.sh and
# gen-header.sh regenerate and diff them, so they cannot drift.
#
# NOT IN SCOPE, on purpose: guests/. Every guest names the constant
# (`kaya::FileMode::Read`, `FILE_MODE_READ`, `file_mode_read` — checked
# by hand when this gate was written, 2026-08-09), so there is nothing
# there to pin yet; a guest that ever writes a bare integer is a rule
# this gate can grow.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

# The checker takes ONE argument: a root to read the tree out of. That is
# what makes every clause below testable — a self-test builds a shadow
# root of symlinks, swaps one file for a doctored copy, and runs the real
# checker over it. A fixture would only ever prove the patterns match the
# fixture, which is how the wayland seat guard passed vacuously twice
# (docs/traps.md).
check() {
    python3 - "$1" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
bad = []


def read(rel):
    return (root / rel).read_text(encoding="utf-8")


SPEC = "crates/kaya/src/spec.rs"
WIRE = "crates/kaya/src/wire.rs"
PROTOCOL = "crates/kaya/src/protocol.rs"
SWIFTUI = "swift/KayaSwiftUI.swift"
CSHARP = "bindings/csharp/Kaya.cs"
PYRUNTIME = "bindings/python/kaya/runtime.py"

# What each mode MEANS, which is all this gate knows. The numbers come
# from the spec, every time, and appear nowhere below.
ACCESS = {"read": "O_RDONLY", "write": "O_WRONLY", "read_write": "O_RDWR"}
TRUNCATES = {"read": False, "write": True, "read_write": False}
FILE_ACCESS = {"read": "Read", "write": "Write", "read_write": "ReadWrite"}
FDOPEN = {"read": "rb", "write": "wb", "read_write": "r+b"}


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
    """The braced body of the first function matching `pattern`, or None
    — and None is a FAILURE at every callsite below, never a pass: a gate
    that stops finding what it reads reports a clean bill about nothing."""
    m = re.search(pattern, text)
    if not m:
        return None
    i = text.find("{", m.end() - 1)
    if i < 0:
        return None
    return span(text, i)


def gone(path, what, anchor):
    bad.append(
        f"{path}: {what} ({anchor}) is not where this gate looks — the site "
        f"moved and the check went vacuous, which is worse than a failure "
        f"because it reads as a pass")


# --- 0. THE ROOT: the spec's numbering. ------------------------------
text = read(SPEC)
m = re.search(r'name:\s*"file_mode"\s*,\s*variants:\s*&\[([^\]]*)\]', text)
if not m:
    print(f"{SPEC}: no file_mode EnumSpec — the numbering moved and this gate "
          f"has nothing to check against", file=sys.stdout)
    sys.exit(1)
MODES = {name: int(value)
         for name, value in re.findall(r'\(\s*"([a-z_]+)"\s*,\s*(\d+)\s*\)', m.group(1))}
if not MODES:
    print(f"{SPEC}: the file_mode EnumSpec declares no variants")
    sys.exit(1)
# A MODE THIS GATE HAS NO SEMANTICS FOR IS A MODE NOBODY PINNED. That is
# the wall under D1's rejection of a fourth mode: adding one to the spec
# fails here until every site below is taught what it means.
for name in MODES:
    if name not in ACCESS:
        bad.append(
            f'{SPEC}: file_mode declares "{name}", which tools/check-file-modes.sh '
            f"has no semantics for — a new mode must be given its access and "
            f"truncation rule HERE and then pinned at every site, or it ships "
            f"meaning one thing in the core and another in each backend")
known = {name: number for name, number in MODES.items() if name in ACCESS}

# --- 1. wire.rs: the C ABI's names. ----------------------------------
text = read(WIRE)
declared = {name: int(value) for name, value in
            re.findall(r"pub const FILE_MODE_([A-Z_]+)\s*:\s*u32\s*=\s*(\d+)\s*;", text)}
if not declared:
    gone(WIRE, "the FILE_MODE constants", "pub const FILE_MODE_*: u32")
for name, number in known.items():
    have = declared.get(name.upper())
    if have is None:
        bad.append(f"{WIRE}: no FILE_MODE_{name.upper()} constant, though the spec "
                   f"declares the mode")
    elif have != number:
        bad.append(f"{WIRE}: FILE_MODE_{name.upper()} = {have} but the spec says "
                   f"{number} ({SPEC})")
for name in declared:
    if name.lower() not in MODES:
        bad.append(f"{WIRE}: FILE_MODE_{name} is a mode the spec does not declare — "
                   f"the C ABI would carry a number nothing else knows")

# --- 2. protocol.rs: the number the core SENDS. ----------------------
# picked_mode_code is what crosses to an interpreter backend, and its
# arms are bare literals pinned by a unit test that hard-codes the same
# literals — so the pair agrees with itself while both disagree with the
# spec. This is the one clause a `cargo test` could never make.
text = read(PROTOCOL)
fn = body(text, r"\bfn +picked_mode_code\b")
if fn is None:
    gone(PROTOCOL, "the function that turns a FileMode into the ABI number",
         "fn picked_mode_code")
else:
    arms = {name: int(value) for name, value in
            re.findall(r"FileMode::(\w+)\s*=>\s*(\d+)", fn)}
    for name, number in known.items():
        have = arms.get(camel(name))
        if have is None:
            bad.append(f"{PROTOCOL}: picked_mode_code has no arm for "
                       f"FileMode::{camel(name)}")
        elif have != number:
            bad.append(f"{PROTOCOL}: picked_mode_code sends {have} for "
                       f"FileMode::{camel(name)} but the spec numbers "
                       f'"{name}" {number} ({SPEC}) — the interpreter would open '
                       f"in the wrong mode with nothing to say so")

# --- 3. KayaSwiftUI.swift: the number an interpreter RECEIVES. -------
text = read(SWIFTUI)
fn = body(text, r"\bfunc +kayaSwiftUIOpenPicked\b")
if fn is None:
    gone(SWIFTUI, "the picked-file opener", "func kayaSwiftUIOpenPicked")
else:
    i = fn.find("switch mode")
    sw = span(fn, fn.find("{", i)) if i >= 0 else None
    if sw is None:
        gone(SWIFTUI, "the switch over the mode number", "switch mode { … }")
    else:
        arms = {int(number): flags for number, flags in
                re.findall(r"case\s+(\d+)\s*:\s*flags\s*=\s*([^\n]*)", sw)}
        for name, number in known.items():
            flags = arms.get(number)
            if flags is None:
                bad.append(
                    f'{SWIFTUI}: kayaSwiftUIOpenPicked has no `case {number}:` for '
                    f'"{name}", which is the number the spec gives it ({SPEC}) — '
                    f"the guest's mode would fall to the default and be refused")
                continue
            tokens = set(re.findall(r"O_[A-Z]+", flags))
            want = ACCESS[name]
            others = {a for a in ACCESS.values() if a != want}
            if want not in tokens:
                bad.append(
                    f'{SWIFTUI}: case {number} is the spec\'s "{name}" but opens '
                    f"{' | '.join(sorted(tokens)) or '<nothing>'} — it must carry "
                    f"{want}. A renumbered mode opens the user's file the wrong "
                    f"way and says nothing")
            if tokens & others:
                bad.append(
                    f'{SWIFTUI}: case {number} is the spec\'s "{name}" but also '
                    f"carries {' '.join(sorted(tokens & others))}")
            truncates = "O_TRUNC" in tokens
            if truncates != TRUNCATES[name]:
                bad.append(
                    f'{SWIFTUI}: case {number} is the spec\'s "{name}", which must '
                    f"{'truncate' if TRUNCATES[name] else 'NOT truncate'}, and it "
                    f"{'does' if truncates else 'does not'} — truncation is the "
                    f"difference between write and read_write, and getting it "
                    f"backwards destroys the file the guest meant to read")

# --- 4. Kaya.cs: a binding that switches on the number. --------------
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
        have = arms.get(number) or (fallback.group(1) if fallback else None)
        if have != FILE_ACCESS[name]:
            bad.append(
                f'{CSHARP}: mode {number} is the spec\'s "{name}" but OpenPicked '
                f"gives it FileAccess.{have} rather than "
                f"FileAccess.{FILE_ACCESS[name]} — the FileStream would refuse "
                f"the operation the guest asked for")

# --- 5. runtime.py: the other binding that switches on it. -----------
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
                 re.findall(r"(\d+)\s*:\s*[\"']([^\"']+)[\"']", m.group(1))}
        for name, number in known.items():
            have = table.get(number)
            if have != FDOPEN[name]:
                bad.append(
                    f'{PYRUNTIME}: mode {number} is the spec\'s "{name}" but '
                    f"open_picked fdopens it {have!r} rather than "
                    f"{FDOPEN[name]!r}")
    # The Windows half: msvcrt.open_osfhandle takes CRT flags, and the
    # ONE mode that gets the read-only ones must be read.
    m = re.search(r"O_RDONLY\s+if\s+mode\s*==\s*(\d+)", fn)
    if not m:
        gone(PYRUNTIME, "the CRT flag choice", "os.O_RDONLY if mode == …")
    elif int(m.group(1)) != known.get("read"):
        bad.append(
            f"{PYRUNTIME}: the CRT descriptor is opened read-only for mode "
            f"{m.group(1)}, but the spec's \"read\" is {known.get('read')} "
            f"({SPEC}) — on Windows every other mode would get a read-only fd")

# --- 6. THE CENSUS: nobody redeems a handle unseen. ------------------
# Generated surfaces are excluded because gen-bindings.sh/gen-header.sh
# regenerate and diff them: they cannot drift from the spec, and listing
# them here would be a second, weaker copy of that gate.
GENERATED = {
    "bindings/c/kaya_wire.h", "bindings/csharp/KayaWire.cs",
    "bindings/go/kaya_wire.go", "bindings/haskell/KayaWire.hs",
    "bindings/java/dev/kaya/KayaWire.java", "bindings/ocaml/kaya_wire.ml",
    "bindings/python/kaya/wire.py", "bindings/swift/KayaWire.swift",
}
SITES = {SPEC, WIRE, PROTOCOL, SWIFTUI, CSHARP, PYRUNTIME}
# Files that redeem a handle WITHOUT writing a mode number down: they
# hand the number on, or they branch on it through the NAMED constants,
# which is the form that cannot drift. The reason is required and the
# claim is CHECKED below.
#
# That is the rule underneath this whole gate, stated once: a numeric
# mode literal belongs only where a number arrives over an ABI and there
# is no name to use — the four SITES above. Everywhere else there IS a
# name (KayaWire.FILE_MODE_READ, wire::FILE_MODE_READ, fileModeRead …)
# and it must be used. bindings/java/dev/kaya/KayaApp.java is the model:
# it switches on the mode and never writes a digit.
PASSTHROUGH = {
    "bindings/go/runtime.go": "os.NewFile over the raw handle; the number goes to C",
    "bindings/java/dev/kaya/KayaApp.java":
        "switches on the mode through KayaWire's named constants",
    "bindings/java-desktop/dev/kaya/KayaRing.java": "the native declaration only",
    "bindings/haskell/KayaRuntime.hs": "fdToHandle over the raw fd; the Word32 goes to C",
    "bindings/haskell/KayaApp.hs": "re-exports openPicked",
    "bindings/ocaml/kaya_runtime.ml": "Ctypes hands the int to C",
    "bindings/swift/KayaApp.swift": "defaults to FILE_MODE_READ and passes it on",
    "bindings/python/kaya/__init__.py": "defaults to wire.FILE_MODE_READ and passes it on",
    "crates/kaya/src/capi.rs": "decodes with the wire.rs CONSTANTS, never a literal",
    "crates/kaya/src/jvm.rs": "the JNI shim casts jint to u32 and calls the core",
    "crates/kaya/src/android.rs": "turns the FileMode into a mode STRING (r/wt/rw); "
                                  "no number crosses to Kotlin",
    "crates/kaya/src/swiftui_host.rs": "calls picked_mode_code and passes the result",
    "android/kaya/src/main/kotlin/dev/kaya/KayaPresent.kt":
        "openPickedUri takes the mode as a STRING from android.rs",
    "android/kaya/src/main/kotlin/dev/kaya/KayaRing.kt": "the external declaration only",
}
REDEEMS = re.compile(r"kaya_open_picked|open_picked|openPicked|OpenPicked")

COMMENTS = [
    re.compile(r"/\*.*?\*/", re.S), re.compile(r"\(\*.*?\*\)", re.S),
    re.compile(r"(?m)//.*$"), re.compile(r"(?m)#.*$"), re.compile(r"(?m)--.*$"),
]


def code(text):
    """The file with its comments blanked. The census reads this and not
    the raw bytes: gtk.rs, winui/mod.rs and KayaCompose.kt each NAME the
    redemption in a sentence — "so kaya_open_picked redeems a pasted file
    identically" — while registering a PathSource and never seeing a
    mode. Reading prose as code put all three in this gate's tables, and
    a table entry for a file with no mode in it is an entry that can only
    ever be wrong.

    Newlines survive so the line numbers this gate prints are the file's
    own."""
    for pattern in COMMENTS:
        text = pattern.sub(lambda m: "\n" * m.group(0).count("\n"), text)
    return text


def literal_arms(text, head):
    """A switch/match on the mode whose ARMS are bare integers, or None.

    Branching on the mode is fine — Java does it, and so does the core's
    own decoder — as long as the arms name constants. What may not
    happen outside the SITES is a DIGIT standing for a mode."""
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
    m = re.search(r"(?<![A-Za-z0-9_])mode\s*(?:==|!=|>=|<=|<|>)\s*[0-9]", text)
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


ROOTS = ["crates/kaya/src", "swift", "android/kaya/src/main/kotlin/dev/kaya",
         "bindings"]
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
        # The cheap test first, on the raw bytes: blanking comments in
        # all 13 MB of these roots costs 5s a pass and this gate runs its
        # own census twelve times (once per self-test). Only a file that
        # names the redemption AT ALL is worth stripping.
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
                f"{rel}: redeems a picked file but is in neither table of "
                f"tools/check-file-modes.sh — say whether it INTERPRETS the mode "
                f"number (then pin its arms against the spec, like "
                f"{SWIFTUI} is) or takes it BY NAME and passes it through (then "
                f"say so here, with a reason)")
            continue
        found = interpreting(text)
        if found:
            at, what = found
            bad.append(
                f"{rel}:{text.count(chr(10), 0, at) + 1}: is listed as never "
                f"writing a mode number down ({PASSTHROUGH[rel]}) but {what} — "
                f"either use the named constant, or move this file into SITES "
                f"and pin its arms against the spec")
for rel in sorted(PASSTHROUGH):
    if rel not in seen:
        bad.append(
            f"{rel}: is named by tools/check-file-modes.sh but no longer redeems a "
            f"picked file at all — either it moved (fix the table) or the entry "
            f"is dead (delete it)")

print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
}

# THE GUARD GUARDS ITSELF, on DOCTORED COPIES OF THE REAL FILES. Each
# perturbation prints its substitution count and is REFUSED if it did not
# apply — an unchanged copy is a failed self-test, not a passed one — and
# every refusal is checked for its REASON, because an exit code alone is
# satisfied by any unrelated finding.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# A shadow root: every file this gate reads, as a symlink. Doctoring one
# means REPLACING a symlink with a real file, so the tree is never
# written through.
shadow() { # <destination>
    python3 -c '
import os
import pathlib
import sys

root, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
ROOTS = ["crates/kaya/src", "swift", "android/kaya/src/main/kotlin/dev/kaya",
         "bindings"]
n = 0
for r in ROOTS:
    for f in sorted((root / r).rglob("*")):
        if not f.is_file() or "__pycache__" in f.parts:
            continue
        out = dst / f.relative_to(root)
        out.parent.mkdir(parents=True, exist_ok=True)
        os.symlink(f, out)
        n += 1
if n == 0:
    sys.exit("check-file-modes: SELF-TEST FAIL (the shadow root is empty)")
print(n)
' "$ROOT" "$1"
}

# <shadow> <relative path> <regex> <replacement> -> substitution count
doctor() {
    python3 -c '
import os
import pathlib
import re
import sys

shadow, rel, pattern, repl = sys.argv[1:5]
path = pathlib.Path(shadow) / rel
text = path.read_text(encoding="utf-8")
out, n = re.subn(pattern, repl, text, flags=re.S)
os.remove(path)
path.write_text(out, encoding="utf-8")
print(n)
' "$@"
}

applied() { # count label
    if [ "$1" -ge 1 ]; then
        return 0
    fi
    echo "check-file-modes: SELF-TEST FAIL ($2 applied $1 times, want at least 1" \
        "— an unchanged copy cannot prove the rule fires)" >&2
    exit 1
}

refuses() { # <shadow> <want-fragment> <label>
    local out
    out="$(check "$1")" && {
        echo "check-file-modes: SELF-TEST FAIL ($3 passed)" >&2
        exit 1
    }
    case "$out" in
        *"$2"*) ;;
        *)
            echo "check-file-modes: SELF-TEST FAIL ($3 failed for another reason:" >&2
            echo "$out" >&2
            exit 1
            ;;
    esac
}

fresh() { # <name> -> path to a new shadow root
    local dir="$T/$1"
    shadow "$dir" >/dev/null
    echo "$dir"
}

# N0 — the shadow root itself must pass, or every refusal below could be
# an artifact of the copy rather than of the perturbation. It is a mirror
# of the live tree, so a refusal HERE is a real finding and says so: the
# reader must not have to decide whether the gate or the tree is broken.
base="$(fresh base)"
if ! out="$(check "$base")"; then
    echo "$out"
    echo "check-file-modes: FAIL — refused before any perturbation, so this is" \
        "the tree and not the self-test" >&2
    exit 1
fi

# N1 — THE DEFECT ITSELF: renumber the spec's modes and watch every
# consumer disagree. This is the edit that used to be silent.
s="$(fresh renumbered)"
hits="$(doctor "$s" crates/kaya/src/spec.rs \
    '\("read", 0\), \("write", 1\)' '("read", 1), ("write", 0)')"
applied "$hits" "the spec renumbering"
refuses "$s" "swift/KayaSwiftUI.swift: case 1 is the spec's \"read\"" \
    "a renumbered spec against the SwiftUI interpreter"
refuses "$s" "crates/kaya/src/protocol.rs: picked_mode_code sends" \
    "a renumbered spec against picked_mode_code"
refuses "$s" "crates/kaya/src/wire.rs: FILE_MODE_READ = 0 but the spec says 1" \
    "a renumbered spec against wire.rs"
refuses "$s" "bindings/csharp/Kaya.cs: mode 1 is the spec's \"read\"" \
    "a renumbered spec against the C# binding"
refuses "$s" "bindings/python/kaya/runtime.py: mode 1 is the spec's \"read\"" \
    "a renumbered spec against the python binding"

# N2 — THE PAIRING, which the old three-line clause could not see: swap
# the two write-ish arms in the interpreter and keep every token present.
s="$(fresh swapped)"
hits="$(doctor "$s" swift/KayaSwiftUI.swift \
    'case 1: flags = O_WRONLY \| O_CREAT \| O_TRUNC\n        case 2: flags = O_RDWR' \
    'case 1: flags = O_RDWR\n        case 2: flags = O_WRONLY | O_CREAT | O_TRUNC')"
applied "$hits" "the swapped-arms perturbation"
refuses "$s" "which must truncate, and it does not" \
    "a SwiftUI interpreter whose write and read_write arms are swapped"

# N3 — the vacuity half: an anchor that moved must be loud rather than
# quiet. A gate that stops finding its site reports a clean bill.
s="$(fresh moved)"
hits="$(doctor "$s" swift/KayaSwiftUI.swift \
    'func kayaSwiftUIOpenPicked' 'func kayaSwiftUIRedeemPicked')"
applied "$hits" "the anchor-rename perturbation"
refuses "$s" "is not where this gate looks" \
    "a SwiftUI opener whose name moved"

# N4 — a binding that switches on the number and gets one arm wrong.
s="$(fresh csharp)"
hits="$(doctor "$s" bindings/csharp/Kaya.cs \
    '0 => FileAccess\.Read' '0 => FileAccess.Write')"
applied "$hits" "the C# access perturbation"
refuses "$s" "rather than FileAccess.Read" \
    "a C# binding that opens read mode for writing"

# N5 — the same, in the python binding's fdopen table.
s="$(fresh python)"
hits="$(doctor "$s" bindings/python/kaya/runtime.py \
    'modes = \{0: "rb", 1: "wb", 2: "r\+b"\}' \
    'modes = {0: "wb", 1: "rb", 2: "r+b"}')"
applied "$hits" "the python fdopen perturbation"
refuses "$s" "fdopens it 'wb' rather than 'rb'" \
    "a python binding whose read and write spellings are swapped"

# N6 — the producer half: picked_mode_code sending the wrong number is
# the same defect from the other end of the ABI.
s="$(fresh producer)"
hits="$(doctor "$s" crates/kaya/src/protocol.rs \
    'FileMode::Write => 1,' 'FileMode::Write => 2,')"
applied "$hits" "the picked_mode_code perturbation"
refuses "$s" "picked_mode_code sends 2 for FileMode::Write" \
    "a core that sends the wrong mode number to an interpreter"

# N7 — THE CENSUS: a new redemption site in neither table must fail.
s="$(fresh census)"
printf 'fn f() { kaya_open_picked(); }\n' > "$s/crates/kaya/src/zz-invented-by-selftest.rs"
refuses "$s" "is in neither table of tools/check-file-modes.sh" \
    "a new file that redeems a handle and is in no table"

# N8 — a PASS-THROUGH claim that stopped being true must fail. Go is the
# victim because it is the plainest of them: one call, no branch.
s="$(fresh interprets)"
hits="$(doctor "$s" bindings/go/runtime.go \
    'rc := C\.kaya_open_picked' 'if mode == 1 { _ = mode }\n\trc := C.kaya_open_picked')"
applied "$hits" "the pass-through perturbation"
refuses "$s" "compares the mode with a number" \
    "a binding that started interpreting the mode number"

# N9 — A FOURTH MODE, which is the wall under D1's rejection of
# FILE_MODE_CREATE: a mode the sites do not know must not ship.
s="$(fresh fourth)"
hits="$(doctor "$s" crates/kaya/src/spec.rs \
    '\("read_write", 2\)\]' '("read_write", 2), ("create", 3)]')"
applied "$hits" "the fourth-mode perturbation"
refuses "$s" 'declares "create", which tools/check-file-modes.sh has no semantics for' \
    "a fourth file mode nobody pinned"

# N10 — a table entry whose file stopped redeeming anything must fail,
# so an entry cannot quietly become decorative.
s="$(fresh dead)"
hits="$(doctor "$s" bindings/go/runtime.go 'kaya_open_picked' 'kaya_open_something')"
applied "$hits" "the dead-entry perturbation"
refuses "$s" "no longer redeems a picked file at all" \
    "a table entry whose file stopped redeeming"

if ! offenders="$(check "$ROOT")"; then
    echo "$offenders"
    echo "check-file-modes: FAIL"
    exit 1
fi
echo "check-file-modes: OK"
