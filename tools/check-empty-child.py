#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die, scratch_dir

dev_shell_or_die()

# ONE NODE IS ONE WIDGET, EVEN WHEN ITS CONTENT WILL NOT DECODE — and no
# layout indexes a child it has not checked for.
#
# The two WIDGET backends have the first half by construction. The two
# DECLARATIVE backends have to say it out loud, because "render nothing"
# there means the node LEAVES THE TREE and everything above it that
# counts children positionally reads the wrong child. The crash and the
# fix: docs/deferred.md, "swiftui, KayaCell, Layout, subviews".
#
# THE CLAUSES:
#
#   A  RUNTIME, macOS only — tools/checks/swiftui-empty-child.swift
#      compiled INTO the interpreter's own module and run in an
#      NSHostingView. SKIPPED AND SAID SO on any other host.
#   B  STATIC, all four backends: the image source's failure branch
#      still produces a widget, and cannot panic.
#   C  STATIC, SwiftUI only: KayaCell subscripts no subview collection
#      it has not checked (`subviews.first`, never `subviews[0]`).
#
# Deliberately not one clause: A needs a GUI toolkit, B and C run
# anywhere, and a lane that can only do B and C should still do them.

import os
import platform
import re
import subprocess

# Line-buffered stdout: clause A's subprocesses write to the same fd,
# and block-buffered prints would land AFTER output they preceded.
sys.stdout.reconfigure(line_buffering=True)

GTK = "crates/kaya/src/gtk.rs"
WINUI = "crates/kaya/src/winui/mod.rs"
SWIFTUI = "swift/KayaSwiftUI.swift"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"
PROBE = "tools/checks/swiftui-empty-child.swift"

gate = Gate("check-empty-child")


def span(text, i, opener="{", closer="}"):
    """From the bracket at `i` to its match, skipping comments and
    string literals so a bracket inside either cannot end it early."""
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


def strip(text):
    """Code only: line comments, block comments and string literals
    blanked out. Every search below runs on this, and the reason is
    measured — the fix for the crash this gate guards DESCRIBES the
    crash in a doc comment ("`subviews[0]` then traps"), and the first
    run of clause C matched that sentence and failed the file that had
    already been fixed. A gate that reads prose is a gate that fails on
    documentation."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i)
            j = n if j < 0 else j + 2
            out.append(" " * (j - i))
            i = j
            continue
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(" " * (j - i))
            i = j
            continue
        out.append(c)
        i += 1
    return "".join(out)


def braced(text, pattern, opener="{", closer="}"):
    """The braced body following the first match of `pattern`, or None.
    None is a FAILURE at every callsite below: a gate that stops finding
    what it reads reports a clean bill about nothing."""
    m = re.compile(pattern).search(text)
    if not m:
        return None
    i = text.find(opener, m.end() - 1)
    if i < 0:
        return None
    return span(text, i, opener, closer)


def check(raw):
    """raw: {site: unstripped text}. Offender sentences (clauses B+C)."""
    bad = []

    # --- B, GTK: the Err arm keeps the picture and cannot panic. -----
    text = strip(raw[GTK])
    arm = braced(text, r"\(NativeWidget::Image\(picture\), Prop::Source, "
                       r"Value::Blob\(blob\)\)\s*=>")
    if arm is None:
        bad.append(f"{GTK}: the image Prop::Source arm is not where this "
                   "gate looks — it moved or was renamed, and an unread "
                   "arm is not a checked one")
    else:
        if "Err(_) => picture.set_paintable" not in arm:
            bad.append(f"{GTK}: the image decode's Err arm must leave the "
                       "GtkPicture in place with its paintable cleared "
                       "(`Err(_) => picture.set_paintable"
                       "(gtk4::gdk::Paintable::NONE)`). A widget backend "
                       "keeps its widget: that is what the declarative "
                       "backends are held to.")
        for hazard in (".unwrap()", ".expect(", "panic!"):
            if hazard in arm:
                bad.append(f"{GTK}: the image Prop::Source arm contains "
                           f"`{hazard}` — a failed decode is the "
                           f"placeholder class, never a panic.")

    # --- B, WinUI: the error path logs and leaves the Image alone. ---
    text = strip(raw[WINUI])
    arm = braced(text, r"\(NativeWidget::Image\(image\), Prop::Source, "
                       r"Value::Blob\(blob\)\)\s*=>")
    if arm is None:
        bad.append(f"{WINUI}: the image Prop::Source arm is not where this "
                   "gate looks — it moved or was renamed, and an unread "
                   "arm is not a checked one")
    else:
        if "if let Err(e) = result" not in arm:
            bad.append(f"{WINUI}: the image Prop::Source arm must funnel "
                       "every failure (decode included) into one Err "
                       "branch that leaves the Image element in place with "
                       "no Source — image_size then reads 0x0.")
        for hazard in (".unwrap()", ".expect(", "panic!"):
            if hazard in arm:
                bad.append(f"{WINUI}: the image Prop::Source arm contains "
                           f"`{hazard}` — a failed decode is the "
                           f"placeholder class, never a panic.")

    # --- B, SwiftUI: the failed decode renders a view, not EmptyView.
    text = strip(raw[SWIFTUI])
    m = re.search(r"\n(\s*)case kindImage:\n", text)
    if not m:
        bad.append(f"{SWIFTUI}: no `case kindImage:` render arm — the kind "
                   "was renamed and this gate went vacuous")
    else:
        indent = m.group(1)
        rest = text[m.end():]
        nxt = re.search(r"\n" + indent + r"(case |default:)", rest)
        arm = rest[: nxt.start()] if nxt else rest
        if (re.search(r"\}\s*else\s*\{\s*EmptyView\(\)", arm)
                or "EmptyView()" in arm):
            bad.append(f"{SWIFTUI}: the kindImage arm renders `EmptyView()` "
                       "when the decode fails. An EmptyView contributes NO "
                       "subview, so the node leaves the view tree and "
                       "KayaCell traps on `subviews[0]` "
                       "(docs/deferred.md). The placeholder must be present "
                       "and empty — a 0x0 view — which is what GTK and "
                       "WinUI have by construction.")
        if not re.search(r"\}\s*else\s*\{", arm):
            bad.append(f"{SWIFTUI}: the kindImage arm has no `else` for "
                       "the failed decode. Every path through the arm must "
                       "produce a view.")

    # --- B, Compose: same rule, said in Kotlin. ----------------------
    text = strip(raw[COMPOSE])
    m = re.search(r"\n(\s*)KayaCompose\.KIND_IMAGE ->", text)
    if not m:
        bad.append(f"{COMPOSE}: no `KayaCompose.KIND_IMAGE ->` render arm "
                   "— the kind was renamed and this gate went vacuous")
    else:
        i = text.find("{", m.end() - 1)
        arm = span(text, i) if i >= 0 else None
        if arm is None:
            bad.append(f"{COMPOSE}: the KIND_IMAGE render arm has no "
                       "braced body. A bare `node.imageBitmap?.let { … }` "
                       "emits NOTHING when the bitmap is null, which "
                       "removes the node from the composition — the grid "
                       "arm then pairs `placeables[i]` with the wrong "
                       "`node.children[i]`.")
        elif not re.search(r"\}\s*else\s*\{", arm):
            bad.append(f"{COMPOSE}: the KIND_IMAGE arm has no `else` for a "
                       "null bitmap. The failed decode must still compose "
                       "something (a 0x0 Box), so the node keeps its slot "
                       "— GTK's and WinUI's behaviour, which the "
                       "declarative backends have to write down.")

    # --- C, SwiftUI: KayaCell checks before it subscripts. -----------
    text = strip(raw[SWIFTUI])
    cell = braced(text, r"struct KayaCell: Layout\s*")
    if cell is None:
        bad.append(f"{SWIFTUI}: no `struct KayaCell: Layout` — the cell "
                   "was renamed and this gate went vacuous")
    elif re.search(r"subviews\[", cell):
        bad.append(f"{SWIFTUI}: KayaCell subscripts `subviews[…]`. A cell "
                   "whose child rendered nothing has a Subviews collection "
                   "of COUNT ZERO — a kind this interpreter does not know "
                   "reaches that by itself — and the subscript TRAPS "
                   "(EXC_BREAKPOINT), killing the process during layout. "
                   "Use `subviews.first` with a zero fallback.")
    return bad


RAW = {p: gate.read(p) for p in (GTK, WINUI, SWIFTUI, COMPOSE)}


# --- The self-test: every clause above WATCHED GOING RED. ------------
# Perturbations run in memory through the prelude's doctor — the count
# printed, an unapplied perturbation refused — because "the negative
# test passed" and "it never touched the file" look identical otherwise.
def refuses(raw, fragment, what):
    out = check(raw)
    if not out:
        print(f"check-empty-child: SELF-TEST FAILED — {what} was ACCEPTED.",
              file=sys.stderr)
        sys.exit(1)
    if not any(fragment in line for line in out):
        print(f"check-empty-child: SELF-TEST FAILED — {what} was refused, "
              f"but not for the stated reason. Wanted a sentence "
              f"containing:", file=sys.stderr)
        print(f"  {fragment}", file=sys.stderr)
        print("got:", file=sys.stderr)
        print("\n".join(out), file=sys.stderr)
        sys.exit(1)


def negative(label, site, pattern, repl, fragment, what, *, want=1):
    doctored = gate.doctor(label, RAW[site], pattern, repl, want=want)
    refuses({**RAW, site: doctored}, fragment, what)


negative("the SwiftUI EmptyView perturbation", SWIFTUI,
         r"Color\.clear\.frame\(width: 0, height: 0\)", "EmptyView()",
         "renders `EmptyView()` when the decode fails",
         "a SwiftUI image arm that renders nothing", want=2)

# The cell measures at the width it was GIVEN (the 2026-08-29 wrapping
# ruling), so the line this perturbs is `sizeThatFits(probe)` — it used
# to read `.unspecified`, and that string still occurs elsewhere in the
# file, which is how this self-test went vacuous the day the cell
# changed: the substitution applied somewhere OUTSIDE KayaCell and the
# gate passed.
negative("the KayaCell subscript perturbation", SWIFTUI,
         r"let natural = subviews\.first\?\.sizeThatFits\(probe\) "
         r"\?\? \.zero",
         "let natural = subviews[0].sizeThatFits(probe)",
         "KayaCell subscripts", "a KayaCell that indexes an unchecked "
         "child")

negative("the KayaCell rename perturbation", SWIFTUI,
         r"struct KayaCell: Layout", "struct KayaTrack: Layout",
         "the cell was renamed and this gate went vacuous",
         "a KayaCell this gate can no longer find")

negative("the Compose else-drop perturbation", COMPOSE,
         r"\} else \{\n(\s*)Box\(modifier = a11yTag\)\n\s*\}\n", "}\n",
         "has no `else` for a null bitmap",
         "a Compose image arm that composes nothing", want=2)

negative("the GTK paintable-drop perturbation", GTK,
         r"Err\(_\) => picture\.set_paintable", "Err(_) => drop_paintable",
         "must leave the GtkPicture in place",
         "a GTK arm that loses its picture")

negative("the WinUI unwrap perturbation", WINUI,
         r"if let Err\(e\) = result", "let _ = result.unwrap(); if false",
         "never a panic", "a WinUI arm that panics on a failed decode")

# --- Clause A: the runtime negative, where a GUI toolkit exists. -----
if platform.system() == "Darwin":
    if not (ROOT / "target/debug/libkaya.dylib").is_file():
        print("check-empty-child: target/debug/libkaya.dylib is not built "
              "— the probe links against it. Run tools/gates.py, which "
              "builds what its gates read.", file=sys.stderr)
        sys.exit(1)
    with scratch_dir("check-empty-child-") as tmp:
        # The probe compiles the interpreter's OWN source, so there is
        # no interpreter artifact in this path to go stale. The
        # toolchain resolution stays in tools/lib/swift-toolchain.sh —
        # ONE copy; shell launches, python decides.
        build = subprocess.run(
            ["bash", "-c",
             'source "$1/tools/lib/swift-toolchain.sh" && cd "$1" && '
             "kaya_swiftc "
             "-import-objc-header crates/kaya/include/kaya.h "
             '"$2" "$3" -L target/debug -lkaya '
             "-framework AppKit -framework Foundation -o \"$4\"",
             "swift-toolchain", str(ROOT), SWIFTUI, PROBE,
             str(tmp / "swiftui-empty-child")],
            check=False)
        if build.returncode != 0:
            print("check-empty-child: the layout probe did not compile",
                  file=sys.stderr)
            sys.exit(1)
        run = subprocess.run(
            [str(tmp / "swiftui-empty-child")],
            env=dict(os.environ,
                     DYLD_LIBRARY_PATH=str(ROOT / "target/debug")),
            check=False)
        rc = run.returncode
        if rc != 0:
            print(f"check-empty-child: FAIL — the SwiftUI layout probe "
                  f"exited {rc}.", file=sys.stderr)
            if rc < 0:
                print(f"  Signal {-rc}: the process was KILLED during "
                      f"layout, which is the crash this gate exists for. "
                      f"The last line above names the case that reached "
                      f"it.", file=sys.stderr)
            sys.exit(1)
else:
    print("check-empty-child: clause A (the SwiftUI layout probe) SKIPPED "
          "— it needs macOS and AppKit. Clauses B and C ran.")

offenders = check(RAW)
if offenders:
    print("\n".join(offenders))
    print("check-empty-child: FAIL")
    sys.exit(1)
print("check-empty-child: OK")
