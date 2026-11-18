#!/usr/bin/env python3
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import Gate, dev_shell_or_die

dev_shell_or_die()

# docs/restoration-plan.md §4: the facet table in spec.rs, the core's
# session::Facet variants and every backend's report are one census.

SPEC = "crates/kaya/src/spec.rs"
SESSION = "crates/kaya/src/session.rs"
SCENE = "crates/kaya/src/scene.rs"
SWIFTUI = "swift/KayaSwiftUI.swift"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"
GTK = "crates/kaya/src/gtk.rs"
WINUI = "crates/kaya/src/winui/mod.rs"

# facet -> the core's variant and its scene arm.
CORE = {
    "caret": ("Caret {", "crate::session::Facet::Caret { start, stop } =>"),
    "row": ("Row {", "crate::session::Facet::Row { key } =>"),
}

# (backend, facet) -> the call its report makes.
REPORTS = {
    (SWIFTUI, "caret"): "KayaHost.sessionCaret(",
    (SWIFTUI, "row"): "KayaHost.sessionTopRow(",
}

# (backend, facet) -> why it does not report yet. Each row is open work.
DEFERRED = {
    (COMPOSE, "caret"): "the fan-out (docs/restoration-plan.md §5 step 4)",
    (COMPOSE, "row"): "the fan-out (docs/restoration-plan.md §5 step 4)",
    (GTK, "caret"): "the fan-out (docs/restoration-plan.md §5 step 4)",
    (GTK, "row"): "the fan-out (docs/restoration-plan.md §5 step 4)",
    (WINUI, "caret"): "the fan-out (docs/restoration-plan.md §5 step 4)",
    (WINUI, "row"): "the fan-out (docs/restoration-plan.md §5 step 4)",
}

BACKENDS = (SWIFTUI, COMPOSE, GTK, WINUI)

g = Gate("check-restore")


def table(text):
    m = re.search(r"pub const RESTORE_FACETS: &\[\(&str, &str\)\] = &\[(.*?)\];", text, re.S)
    if not m:
        return None
    return re.findall(r'\("([a-z_]+)", "([a-z_]+)"\)', m.group(1))


def census(files):
    out = []
    rows = table(files[SPEC])
    if rows is None:
        return ["spec.rs has no RESTORE_FACETS table"]
    facets = {f for _, f in rows}
    for kind, facet in rows:
        if kind == "secure_field":
            out.append(f"spec.rs gives secure_field the facet {facet!r}: a secure field saves nothing, ever (SR7)")
    variants = set(re.findall(r"^\s{4}([A-Z][a-z]+) \{", files[SESSION].split("pub(crate) enum Facet {", 1)[-1].split("}\n", 1)[0], re.M))
    for facet, (variant, arm) in CORE.items():
        if variant.rstrip(" {") in variants and facet not in facets:
            out.append(f"session::Facet::{variant.rstrip(' {')} restores the {facet!r} facet, which spec.rs's RESTORE_FACETS does not list")
        if facet in facets and arm not in files[SCENE]:
            out.append(f"scene.rs has no restore arm for the {facet!r} facet ({arm})")
    for facet in sorted(facets):
        if facet not in CORE:
            out.append(f"spec.rs lists the facet {facet!r}, which this gate's CORE table does not know")
        for backend in BACKENDS:
            call = REPORTS.get((backend, facet))
            if call is not None:
                if call not in files[backend]:
                    out.append(f"{backend} does not report the {facet!r} facet ({call} is gone)")
            elif (backend, facet) not in DEFERRED:
                out.append(f"{backend} neither reports the {facet!r} facet nor states why in DEFERRED")
    return out


files = {p: g.read(p) for p in (SPEC, SESSION, SCENE, *BACKENDS)}
rows = table(files[SPEC]) or []
g.counted("facet rows", rows, 2)
g.counted("reporting arms", [k for k in REPORTS if REPORTS[k] in files[k[0]]], 2)
for line in census(files):
    g.finding(line)


def cut(label, rel, pattern, repl, want):
    doctored = dict(files)
    doctored[rel] = g.doctor(label, files[rel], pattern, repl)
    g.negative(label, lambda: census(doctored), want=want)


cut("a facet row cut from spec.rs", SPEC, r', \("textarea", "caret"\)|\("textarea", "caret"\), ', "",
    "restores the 'caret' facet, which spec.rs's RESTORE_FACETS does not list")
cut("SwiftUI's row report cut", SWIFTUI, r"KayaHost\.sessionTopRow\(container\.id", "_ = (container.id",
    "does not report the 'row' facet")
cut("secure_field given a facet", SPEC, r'\("textarea", "caret"\)', '("secure_field", "caret")',
    "a secure field saves nothing")
cut("the scene's caret arm cut", SCENE, r"crate::session::Facet::Caret \{ start, stop \} =>", "_ =>",
    "no restore arm for the 'caret' facet")
g.negatives_ran(4)
for (backend, facet), why in sorted(DEFERRED.items()):
    print(f"check-restore: deferred: {backend} {facet}: {why}")
g.verdict(f"{len(rows)} facet(s) across {len(BACKENDS)} backends")
