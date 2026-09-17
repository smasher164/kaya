#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# pyright over the python binding and every python guest — the checker the
# guests never otherwise meet, since python runs whatever it is handed
# (docs/deferred.md's idiom entry, ruling R3). tools/js-typecheck.py is its
# twin one binding over.
#
# THE PUBLIC SURFACE'S COMPLETENESS is the second half: `--verifytypes`
# scores every exported symbol whose type a guest's checker can read, and
# a hint that goes missing drops that number where nothing else would.

import json
import os
import shutil
import subprocess

g = Gate("py-typecheck")

BINDING = "bindings/python"
GUESTS = "guests/python"
# Both project configs sit under bindings/python: pyright IGNORES an
# absolute path in a config's `include` array, so a config has to sit
# where its sources are relative to, and guests/python holds guests.
BINDING_PROJECT = "bindings/python/pyrightconfig.json"
GUEST_PROJECT = "bindings/python/pyrightconfig-guests.json"

#: What `--verifytypes kaya` must report for the EXPORTED surface. 100.0
#: is what this tree measures: every symbol a guest can reach has a known
#: type. A hint removed from one public def drops it (self-test N2).
COMPLETENESS_FLOOR = 100.0

#: THE GUEST DIAGNOSTICS THAT ARE NOT ABOUT KAYA, named one by one with
#: the count they stand for — a NEW one of the same rule in the same file
#: changes the count and is a finding, and so is one that goes away
#: (a stale exemption is the next stale audit; tools/check-assets.py's
#: convention). Nothing here is a kaya-surface mistake: a wrong keyword,
#: a wrong argument type or a misspelled row field anywhere else is red.
EXEMPT = {
    ("guests/python/menus.py", "reportPossiblyUnboundVariable"): (
        1,
        "a For's template body runs EXACTLY ONCE (the tracer), so the "
        "collection declared inside `for _g in groups:` and seeded after "
        "the block IS bound; pyright reads the same text as a loop that "
        "may not run, which no annotation can answer",
    ),
    ("guests/python/varied.py", "reportPossiblyUnboundVariable"): (
        1,
        "the same For-body binding, one scene over (the nested `lines` "
        "collection, seeded after the window block)",
    ),
    ("guests/python/richrows.py", "reportOptionalMemberAccess"): (
        4,
        "`get()` answers `T | None` — the keyed-read convention every "
        "binding follows — and this scene reads back the two keys its own "
        "window block inserted, so it writes no None arm",
    ),
    ("guests/python/portfolio.py", "reportArgumentType"): (
        1,
        "a one-entry dict used as a mutable cell (`view = {'sort': None}`), "
        "whose value type the initial None fixes; guest-local Python with "
        "no kaya surface in it",
    ),
    ("guests/python/portfolio.py", "reportGeneralTypeIssues"): (
        1,
        "the same cell, read back: pyright narrows `dict[str, None]` to "
        "Never past the `is not None` guard",
    ),
    ("guests/python/table.py", "reportArgumentType"): (
        1,
        "the same mutable-cell dict, one scene over",
    ),
}


def env_for(root):
    """PYTHONPATH PINNED AT THE TREE BEING READ. The dev shell exports
    `$PWD/bindings/python`, and pyright resolves `import kaya` through it —
    so a run over a SHADOW copy silently read the REAL binding and scored
    it (measured while writing N2 below: a doctored copy came back 100%).
    """
    return dict(os.environ, PYTHONPATH=str(pathlib.Path(root) / BINDING))


def diagnostics(project, root=ROOT):
    """pyright over one project, as a list of (file, line, rule, message)."""
    out = subprocess.run(
        ["pyright", "-p", str(project), "--outputjson"],
        cwd=root, capture_output=True, text=True, encoding="utf-8",
        env=env_for(root), check=False)
    try:
        report = json.loads(out.stdout)
    except json.JSONDecodeError:
        g.refuse(
            f"pyright -p {project} printed no JSON report — it said:\n"
            f"{out.stdout.strip()[:600]}\n{out.stderr.strip()[:600]}")
    found = []
    base = pathlib.Path(root).resolve()
    for d in report["generalDiagnostics"]:
        if d["severity"] != "error":
            continue
        rel = pathlib.Path(d["file"])
        if rel.is_relative_to(base):
            rel = rel.relative_to(base)
        found.append((str(rel), d["range"]["start"]["line"] + 1,
                      d.get("rule") or "error",
                      d["message"].splitlines()[0]))
    return report["summary"]["filesAnalyzed"], found


def completeness(root=ROOT):
    """`--verifytypes kaya`'s score for the EXPORTED symbols, as a percent."""
    out = subprocess.run(
        ["pyright", "--verifytypes", "kaya", "--ignoreexternal",
         "--outputjson"],
        cwd=pathlib.Path(root) / BINDING, capture_output=True, text=True,
        encoding="utf-8", env=env_for(root), check=False)
    try:
        report = json.loads(out.stdout)
    except json.JSONDecodeError:
        g.refuse(
            "pyright --verifytypes printed no JSON report — it said:\n"
            f"{out.stdout.strip()[:600]}\n{out.stderr.strip()[:600]}")
    done = report.get("typeCompleteness")
    if done is None or "completenessScore" not in done:
        g.refuse("pyright --verifytypes answered no completeness score — "
                 "bindings/python/kaya/py.typed is what makes it read the "
                 "package as typed")
    # WHICH PACKAGE IT ACTUALLY READ. A score over the wrong tree is the
    # vacuous green this gate's own N2 produced before env_for existed.
    read = done.get("packageRootDirectory") or ""
    want = str((pathlib.Path(root) / BINDING / "kaya").resolve())
    if str(pathlib.Path(read).resolve() if read else "") != want:
        g.refuse(
            f"--verifytypes scored the package at {read!r}, and this run is "
            f"about {want!r} — the score would be somebody else's")
    return round(done["completenessScore"] * 100, 2), done["exportedSymbolCounts"]


def report(label, found, *, exempt):
    """Print each diagnostic, exempting only what EXEMPT names BY COUNT."""
    seen = {}
    for file, _line, rule, _msg in found:
        seen[(file, rule)] = seen.get((file, rule), 0) + 1
    excused = 0
    for file, line, rule, msg in found:
        key = (file, rule)
        if exempt and key in EXEMPT and seen[key] == EXEMPT[key][0]:
            excused += 1
            continue
        g.finding(f"{label}: {msg} [{rule}]", at=f"{file}:{line}")
    if exempt:
        for key, (want, why) in EXEMPT.items():
            got = seen.get(key, 0)
            print(f"{g.name}: exempt {key[0]} {key[1]}: {got} (declared "
                  f"{want}) — {why}")
            if got != want:
                g.finding(
                    f"the exemption for {key[0]} {key[1]} stands for {want} "
                    f"diagnostic(s) and the run found {got} — an exemption "
                    f"that has rotted is a skip, so it is a finding either "
                    f"way: fix the new one, or drop the entry")
    return excused


binding_files = sorted((ROOT / BINDING / "kaya").glob("*.py"))
guest_files = sorted((ROOT / GUESTS).glob("*.py"))
g.counted("binding sources", binding_files, floor=3)
g.counted("guest sources", guest_files, floor=40)

analyzed, found = diagnostics(BINDING_PROJECT)
print(f"{g.name}: binding project: {analyzed} file(s) analyzed, "
      f"{len(found)} error(s)")
report("binding", found, exempt=False)

analyzed, found = diagnostics(GUEST_PROJECT)
print(f"{g.name}: guests project: {analyzed} file(s) analyzed, "
      f"{len(found)} error(s)")
excused = report("guest", found, exempt=True)
print(f"{g.name}: {excused} guest diagnostic(s) excused by the EXEMPT "
      f"table, of {len(found)}")
if excused >= len(guest_files):
    g.refuse(
        f"{excused} exemptions against {len(guest_files)} guests — an "
        f"exemption table that outnumbers the population it exempts from "
        f"is a disabled gate with an interface")

score, counts = completeness()
print(f"{g.name}: public-surface completeness: {score}% "
      f"(floor {COMPLETENESS_FLOOR}%), {counts['withKnownType']} known / "
      f"{counts['withAmbiguousType']} ambiguous / "
      f"{counts['withUnknownType']} unknown exported symbols")
if score < COMPLETENESS_FLOOR:
    g.finding(
        f"--verifytypes scores the public surface at {score}%, below the "
        f"{COMPLETENESS_FLOOR}% floor — a guest's checker reads whatever "
        f"went missing as Unknown and stops refusing anything about it")


# ---------------------------------------------------------- self-tests
#
# BOTH ON SHADOW COPIES, never on the tree: a perturbation of a guest and
# a perturbation of the binding, each run through THIS gate's own readers.

def shadow_tree():
    """bindings/python + guests/python copied into scratch, configs and all."""
    return g.shadow(BINDING, GUESTS)


def n1_misspelled_keyword():
    """A guest keyword one letter wrong must be refused BY NAME."""
    tree = shadow_tree()
    guest = tree / GUESTS / "todos.py"
    guest.write_text(
        g.doctor("N1 a guest's on_click keyword misspelled",
                 guest.read_text(encoding="utf-8"),
                 r'on_click=on_add', "on_clik=on_add"),
        encoding="utf-8")
    _analyzed, found = diagnostics(tree / GUEST_PROJECT, root=tree)
    return [f"{file}:{line} {rule} {msg}" for file, line, rule, msg in found]


def n2_dropped_annotation():
    """One public return annotation gone must drop the completeness score."""
    tree = shadow_tree()
    src = tree / BINDING / "kaya" / "__init__.py"
    src.write_text(
        g.doctor("N2 one public parameter annotation removed",
                 src.read_text(encoding="utf-8"),
                 r'def heading\(text: str \| None = None,',
                 "def heading(text=None,"),
        encoding="utf-8")
    score, _counts = completeness(root=tree)
    print(f"{g.name}: N2 the doctored copy scores {score}% "
          f"(floor {COMPLETENESS_FLOOR}%)")
    if score < COMPLETENESS_FLOOR:
        return [f"completeness {score}% is below the floor"]
    return []


g.negative("N1 a guest calling kaya.button(on_clik=...)",
           n1_misspelled_keyword, want="on_clik")
g.negative("N2 the binding with one public parameter annotation removed",
           n2_dropped_annotation, want="below the floor")
g.negatives_ran(2)
shutil.rmtree(g.scratch(), ignore_errors=True)

g.verdict(f"{len(binding_files)} binding + {len(guest_files)} guest sources, "
          f"standard, public surface {score}% complete")
