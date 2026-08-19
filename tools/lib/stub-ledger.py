"""A depth stub is a SANCTIONED hole only while the ledger holds it open.

A stub buys silence from check-stubs and check-steps; the ledger entry is
what it costs. `git log -S 'depth_stub(' -- docs/deferred.md` was EMPTY
before this rule — not one stub in the project's history was ever tracked
— which is the measurement that says this is a real class and not a
hypothetical one.

THE ENTRY IS A LINE, NOT A PARAGRAPH: matching on prose would repeat the
free-form-sentence defect the CALL spelling was invented to kill
(docs/traps.md). The marker is fixed text, and the failure message spells
the exact line to paste.

OPEN MEANS NOT STRUCK THROUGH. docs/deferred.md wraps finished work in
`~~` and those spans run across several lines, so the strikethrough is
stripped from the WHOLE TEXT before the marker is looked for. A closed
entry sanctions nothing.
"""

import argparse
import pathlib
import re
import sys
import tempfile

LEDGER = "docs/deferred.md"

# Every backend, and the token an entry uses to name it. The Swift file
# serves two platforms, so it appears twice and its declarations carry a
# platform argument that nothing else does.
BACKENDS = [
    ("crates/kaya/src/gtk.rs", "gtk", ""),
    ("crates/kaya/src/winui/mod.rs", "winui", ""),
    ("android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt", "compose", ""),
    ("swift/KayaSwiftUI.swift", "swiftui/macos", "macos"),
    ("swift/KayaSwiftUI.swift", "swiftui/ios", "ios"),
]

# The three spellings of the declaration, suffix-matched. The bare
# pattern cannot match the platform-qualified Swift call, so the mac
# roster never reads an iOS declaration as its own.
DECL = re.compile(r'epth_?[Ss]tub\("([a-z0-9_]+)"(?:,\s*on:\s*"([a-z]+)")?\)')

# `DEPTH STUB: <scene> on <backend>`, tolerant of the markdown a ledger
# entry wears (bold, backticks) and nothing else.
def marker(scene: str, token: str) -> re.Pattern:
    return re.compile(
        r"DEPTH\s+STUB:\s*[`*]*" + re.escape(scene) + r"[`*]*\s+on\s+[`*]*"
        + re.escape(token) + r"[`*]*")


def strip_closed(text: str) -> str:
    """Drop every struck-through span. They cross line boundaries in this
    file, so this is a whole-text substitution and not a per-line one."""
    return re.sub(r"~~.*?~~", "", text, flags=re.S)


def open_marker(ledger_text: str, scene: str, token: str) -> bool:
    return marker(scene, token).search(strip_closed(ledger_text)) is not None


def declarations(text: str, platform: str):
    """(scene, line number) for every depth stub this backend declares
    that belongs to `platform` ("" = the file serves one platform)."""
    for n, line in enumerate(text.splitlines(), 1):
        for m in DECL.finditer(line):
            scene, on = m.group(1), m.group(2)
            if (on or "") != platform:
                continue
            yield scene, n


# Where a declaration could physically live. The roster above is five
# FILES; this is the tree those files sit in, so a stub written one
# module over cannot slip past it. Being unlisted IS the failure.
SEARCH = [("crates", (".rs",)), ("android", (".kt",)), ("swift", (".swift",))]
SKIP_PARTS = {"build", "target", "target-linux", ".git", "__pycache__"}


def unrostered(root: pathlib.Path) -> list:
    """Declarations outside the five rostered backend files.

    The roster is a hand-kept list, so it is the ALLOWED space and not
    the search space: a stub in an unlisted module would otherwise be
    invisible to every gate here.
    """
    rostered = {backend for backend, _, _ in BACKENDS}
    out = []
    for top, exts in SEARCH:
        base = root / top
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            if path.suffix not in exts or not path.is_file():
                continue
            rel = path.relative_to(root)
            if SKIP_PARTS & set(rel.parts) or str(rel) in rostered:
                continue
            for n, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
                for m in DECL.finditer(line):
                    out.append((str(rel), n, m.group(1)))
    return out


def audit(root: pathlib.Path) -> list:
    bad = []
    for rel, n, scene in unrostered(root):
        bad.append(f'{rel}:{n} declares a depth stub on "{scene}", but that '
                   f"file is not one of the backends this gate reads. A stub "
                   f"nobody reads is the whole defect — either move the "
                   f"declaration into the backend's own file, or add the file "
                   f"to BACKENDS in tools/lib/stub-ledger.py, "
                   f"tools/lib/hand-rolled-stubs.py and RUNNERS in "
                   f"tools/lib/scene-features.py together")
    ledger_path = root / LEDGER
    if not ledger_path.exists():
        return [f"{LEDGER} is missing — a depth stub has nowhere to be "
                f"tracked, so the sanction cannot be checked"]
    ledger = ledger_path.read_text()

    # An unbalanced `~~` would swallow the rest of the file and turn every
    # open entry into a closed one. Say so instead of guessing.
    if ledger.count("~~") % 2:
        bad.append(f"{LEDGER}: an odd number of `~~` markers — the ledger's "
                   f"open/closed state is unreadable, so no depth stub can be "
                   f"checked against it")
        return bad

    for backend, token, platform in BACKENDS:
        path = root / backend
        if not path.exists():
            bad.append(f"{backend} is missing — the depth-stub roster names a "
                       f"backend that is not there")
            continue
        text = path.read_text()
        for scene, n in declarations(text, platform):
            if not open_marker(ledger, scene, token):
                bad.append(
                    f"{backend}:{n} declares a depth stub on \"{scene}\" that "
                    f"{LEDGER} does not hold open. A stub buys silence from "
                    f"check-stubs and check-steps — the android undo legs sat "
                    f"out a whole milestone that way — so it costs a ledger "
                    f"entry. Add one line under an appropriate heading:\n"
                    f"    - **DEPTH STUB: {scene} on {token}** — why this "
                    f"backend has not got there yet, and what closes it.\n"
                    f"  Strike it through (`~~...~~`) when the stub goes, not "
                    f"before: a closed entry sanctions nothing")
    return bad


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    args = ap.parse_args()
    bad = audit(pathlib.Path(args.root))
    for b in bad:
        print(f"check-stubs: {b}", file=sys.stderr)
    if bad:
        return 1

    # THE GUARD GUARDS ITSELF, in every direction this rule could be true
    # and useless.
    open_entry = "- **DEPTH STUB: scroll on gtk** — the arm ran out of week.\n"
    closed = "- ~~**DEPTH STUB: scroll on gtk**~~ — LANDED 2026-08-05.\n"
    decls = list(declarations('    crate::depth_stub("scroll")', ""))
    kotlin = list(declarations('    depthStub("scroll")', ""))
    swift_ios = list(declarations('    kayaDepthStub("scroll", on: "ios")', "ios"))
    swift_mac = list(declarations('    kayaDepthStub("scroll", on: "ios")', "macos"))
    checks = [
        # the declaration is seen in all three languages...
        (decls == [("scroll", 1)], "the rust spelling was not read"),
        (kotlin == [("scroll", 1)], "the kotlin spelling was not read"),
        (swift_ios == [("scroll", 1)], "the swift spelling was not read"),
        # ...and one platform's declaration is not the other's
        (swift_mac == [], "an ios declaration was read as a macos one"),
        # an open entry sanctions, a closed one does not, absence does not
        (open_marker(open_entry, "scroll", "gtk"), "an open entry did not sanction"),
        (not open_marker(closed, "scroll", "gtk"), "a CLOSED entry sanctioned a live stub"),
        (not open_marker("", "scroll", "gtk"), "an empty ledger sanctioned a stub"),
        # ...and the entry has to name the right scene and the right backend
        (not open_marker(open_entry, "scroll", "compose"),
         "a gtk entry sanctioned a compose stub"),
        (not open_marker(open_entry, "menus", "gtk"),
         "a scroll entry sanctioned a menus stub"),
    ]
    for ok, why in checks:
        if not ok:
            print(f"check-stubs: SELF-TEST FAIL (stub ledger — {why})",
                  file=sys.stderr)
            return 1

    # ...and audit() ITSELF, against a synthetic root: a primitive can be
    # perfect while the loop that calls it is disabled, and with ZERO
    # depth stubs in the tree that would report OK either way.
    with tempfile.TemporaryDirectory() as tmp:
        fake = pathlib.Path(tmp)
        (fake / LEDGER).parent.mkdir(parents=True, exist_ok=True)
        for backend, _, _ in BACKENDS:
            (fake / backend).parent.mkdir(parents=True, exist_ok=True)
            (fake / backend).write_text("")
        (fake / "crates/kaya/src/gtk.rs").write_text(
            'fn x() -> ! {\n    crate::depth_stub("scroll")\n}\n')
        (fake / LEDGER).write_text("# ledger\n\nnothing here\n")
        untracked = audit(fake)
        (fake / LEDGER).write_text("# ledger\n\n" + open_entry)
        tracked = audit(fake)
        (fake / LEDGER).write_text("# ledger\n\n" + closed)
        struck = audit(fake)
        # ...and a declaration in a file the roster does not name. It gets
        # the OPEN entry too, so the only objection left is WHERE it is.
        (fake / "crates/kaya/src/elsewhere.rs").write_text(
            'fn y() -> ! { crate::depth_stub("scroll") }\n')
        (fake / LEDGER).write_text("# ledger\n\n" + open_entry)
        hidden = audit(fake)
    loop_checks = [
        (len(untracked) == 1 and 'on "scroll"' in untracked[0],
         "an untracked stub was not reported by audit()"),
        (tracked == [], "a tracked stub was reported by audit()"),
        (len(struck) == 1, "a CLOSED entry satisfied audit()"),
        (len(hidden) == 1 and "elsewhere.rs" in hidden[0],
         "a stub outside the rostered backend files was not reported"),
    ]
    for ok, why in loop_checks:
        if not ok:
            print(f"check-stubs: SELF-TEST FAIL (stub ledger — {why})",
                  file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
