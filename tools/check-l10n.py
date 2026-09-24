#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()


import re

# THE CATALOG'S COVERAGE (docs/compliance-plan.md §2.4): every message a
# guest names exists in every catalog the app ships, every catalog parses
# as far as this reader can see, and a message's arguments agree across
# locales. NO SCENE CAN FAIL THIS: a leg runs under ONE locale and reads the
# messages its script visits; a key missing from the Arabic file alone, or
# an `$argument` a translator dropped, is a panic on the lane that runs
# that locale and that screen, and the everyday matrix runs neither. The
# core panics at run time naming the key; this refuses before any lane.

L10N = "guests/assets/l10n"
MANIFEST = "guests/assets/identity.toml"
# (directory, pattern): the walk is rooted UNDER each guest tree, because a
# bare `guests/ocaml/*.ml` pattern also reads dune's `_build/.../*.pp.ml`
# preprocessor output, which is not UTF-8 (measured 2026-09-23).
GUEST_TREES = (("guests/rust", "*.rs"), ("guests/python", "*.py"), ("guests/js", "*.ts"),
               ("guests/go", "*.go"), ("guests/csharp", "*.cs"), ("guests/java", "*.java"),
               ("guests/swift", "*.swift"), ("guests/ocaml", "*.ml"), ("guests/haskell", "*.hs"),
               ("guests/c", "*.c"))
# The lookup's spelling per language (docs/compliance-plan.md §1.4), one
# alternation: Rust's `tr!(`, Python's and JS's `kaya.tr(`, Go's `kaya.Tr(`,
# C#'s `Kaya.Tr(`, Java's and Swift's `KayaApp.tr(`, OCaml's and Haskell's
# bare `tr "`, and on the C floor the `tr_ask` literal `{"key", &args, n}`
# that guests/c/format.c hands kaya_tr (the floor asks through a buffer
# helper, so the key is never on the call's own line).
KEY = r'([a-z][a-z0-9-]*)'
CALL = re.compile(
    rf'\btr!\(\s*"{KEY}"|\bl10n::tr\(\s*"{KEY}"|\bkaya\.tr\(\s*"{KEY}"|\bkaya\.Tr\(\s*"{KEY}"|'
    rf'\bKaya\.Tr\(\s*"{KEY}"|\bKayaApp\.tr\(\s*"{KEY}"|(?<![\w.])tr\s+"{KEY}"|'
    rf'\bkaya_tr\(\s*"{KEY}"|\{{"{KEY}", &\w+, \d+\}}')
CATALOG_CALL = re.compile(
    rf'\b(?:catalog|Catalog|kaya_catalog)\(\s*"{KEY}"\s*\)|(?<![\w.])catalog\s+"{KEY}"')
MESSAGE = re.compile(r"^([a-zA-Z][a-zA-Z0-9_-]*)\s*=", re.M)
ARG = re.compile(r"\$([a-zA-Z][a-zA-Z0-9_-]*)")

gate = Gate("check-l10n")


def parse_catalog(text, name):
    """Messages -> their argument sets. A brace that never closes is a
    refusal: fluent-bundle would refuse the whole file, and this reader
    must not read past what the core would load."""
    if text.count("{") != text.count("}"):
        opens, closes = text.count("{"), text.count("}")
        return None, f"{name}: braces do not balance ({opens} open, {closes} close)"
    messages = {}
    starts = list(MESSAGE.finditer(text))
    for i, m in enumerate(starts):
        end = starts[i + 1].start() if i + 1 < len(starts) else len(text)
        body = text[m.end():end]
        # Comments between messages are not the body.
        body = "\n".join(
            line for line in body.split("\n") if not line.lstrip().startswith("#"))
        messages[m.group(1)] = set(ARG.findall(body))
    if not messages:
        return None, f"{name}: no messages"
    return messages, ""


def default_locale(manifest):
    m = re.search(r'^default_locale\s*=\s*"([^"]*)"', manifest, re.M)
    return m.group(1) if m else "en"


def census(catalogs, guests, manifest):
    """catalogs: {relpath: text}; guests: {relpath: text}. Findings as strings."""
    out = []
    default = default_locale(manifest)
    apps = {}
    for rel, text in sorted(catalogs.items()):
        stem = pathlib.Path(rel).name
        if not stem.endswith(".ftl"):
            continue
        parts = stem[:-4].split(".")
        if len(parts) != 2:
            out.append(f"{rel}: the name is <app>.<locale>.ftl, one flat family")
            continue
        app, locale = parts
        messages, why = parse_catalog(text, rel)
        if messages is None:
            out.append(why)
            continue
        apps.setdefault(app, {})[locale] = messages
    for app, locales in sorted(apps.items()):
        if default not in locales:
            out.append(f"{app}: no {default} catalog, the manifest's default_locale — the last "
                       f"file in the fallback chain, the one an app must ship")
            continue
        base = locales[default]
        for locale, messages in sorted(locales.items()):
            if locale == default:
                continue
            for key in sorted(set(base) - set(messages)):
                out.append(f"{app}.{locale}.ftl lacks {key!r}, which {app}.{default}.ftl has")
            for key in sorted(set(messages) - set(base)):
                out.append(f"{app}.{locale}.ftl has {key!r}, which {app}.{default}.ftl lacks")
            for key in sorted(set(base) & set(messages)):
                if base[key] != messages[key]:
                    out.append(
                        f"{app}.{locale}.ftl's {key!r} takes {sorted(messages[key])}, "
                        f"the default's takes {sorted(base[key])}")
    # Every key a guest names exists in its app's default catalog.
    for rel, text in sorted(guests.items()):
        named = [next(g for g in m if g) for m in CATALOG_CALL.findall(text)]
        keys = [next(g for g in m if g) for m in CALL.findall(text)]
        if not keys:
            continue
        if not named:
            out.append(f"{rel} calls tr but names no catalog(...)")
            continue
        app = named[0]
        if app not in apps:
            out.append(f"{rel} names catalog {app!r}, and no {app}.*.ftl is under {L10N}")
            continue
        base = apps[app][default_locale(manifest)] if default_locale(manifest) in apps[app] else {}
        for key in sorted(set(keys)):
            if key not in base:
                out.append(f"{rel} asks for {key!r}, which {app}.{default}.ftl does not have")
    return out


catalog_paths = [str(p) for p in gate.walk("*.ftl", under=L10N)]
gate.counted("catalogs", catalog_paths, floor=3)
catalogs = {p: gate.read(p) for p in catalog_paths}
guest_paths = [str(pathlib.Path(p).resolve().relative_to(ROOT))
               for under, pattern in GUEST_TREES for p in gate.walk(pattern, under=under)]
gate.counted("guest sources", guest_paths, floor=300)
guests = {p: gate.read(p) for p in guest_paths}
manifest = gate.read(MANIFEST)

keys_read = sum(len(MESSAGE.findall(t)) for t in catalogs.values())
gate.counted("messages", range(keys_read), floor=6)
for line in census(catalogs, guests, manifest):
    gate.finding(line)

# --- The watched negatives, each on a doctored COPY in memory. ------------
en = next(p for p in catalog_paths if p.endswith("format.en.ftl"))
ar = next(p for p in catalog_paths if p.endswith("format.ar.ftl"))
guest = next(p for p in guest_paths if p.endswith("format.rs"))
ran = 0

# N1: a message the Arabic file lacks.
doctored = dict(catalogs)
doctored[ar] = gate.doctor("N1 the ar catalog loses greeting", catalogs[ar],
                           r"^greeting = .*\n", "", flags=re.M)
gate.negative("N1 a key missing from one locale", lambda: census(doctored, guests, manifest),
              want="format.ar.ftl lacks 'greeting'")
ran += 1

# N2: an argument the translation dropped.
doctored = dict(catalogs)
doctored[ar] = gate.doctor("N2 the ar greeting drops $name", catalogs[ar],
                           r"\{ \$name \}", "")
gate.negative("N2 an argument that disagrees across locales",
              lambda: census(doctored, guests, manifest),
              want="'greeting' takes []")
ran += 1

# N3: a guest asking for a key no catalog has — once per language's
# spelling, so a pattern that reads nothing in some binding is a failed test.
for rel, pattern, repl in (
    (guest, r'tr!\("greeting"', 'tr!("farewell"'),
    ("guests/python/format.py", r'kaya\.tr\("greeting"', 'kaya.tr("farewell"'),
    ("guests/js/format.ts", r'kaya\.tr\("greeting"', 'kaya.tr("farewell"'),
    ("guests/go/format/format.go", r'kaya\.Tr\("greeting"', 'kaya.Tr("farewell"'),
    ("guests/csharp/FormatScene.cs", r'Kaya\.Tr\("greeting"', 'Kaya.Tr("farewell"'),
    ("guests/java/dev/kaya/guests/Format.java", r'KayaApp\.tr\("greeting"',
     'KayaApp.tr("farewell"'),
    ("guests/swift/format.swift", r'KayaApp\.tr\("greeting"', 'KayaApp.tr("farewell"'),
    ("guests/ocaml/format.ml", r'tr "greeting"', 'tr "farewell"'),
    ("guests/haskell/format.hs", r'tr "greeting"', 'tr "farewell"'),
    ("guests/c/format.c", r'\{"greeting", &name, 1\}', '{"farewell", &name, 1}'),
):
    doctored_guests = dict(guests)
    doctored_guests[rel] = gate.doctor(f"N3 {rel} asks for a missing key", guests[rel],
                                       pattern, repl)
    gate.negative(f"N3 a guest key the catalog lacks ({rel})",
                  lambda d=doctored_guests: census(catalogs, d, manifest),
                  want="asks for 'farewell'")
    ran += 1

# N4: a catalog that no longer parses.
doctored = dict(catalogs)
doctored[en] = gate.doctor("N4 an unbalanced brace", catalogs[en],
                           r"\*\[other\] \{ \$count \} items", "*[other] { $count items")
gate.negative("N4 a catalog that does not parse", lambda: census(doctored, guests, manifest),
              want="braces do not balance")
ran += 1

# N5: the default catalog gone.
doctored = dict(catalogs)
del doctored[en]
gate.negative("N5 the default locale's file missing", lambda: census(doctored, guests, manifest),
              want="no en catalog")
ran += 1

gate.negatives_ran(ran)
gate.verdict(
    f"{len(catalogs)} catalogs, {keys_read} messages, {len(guest_paths)} guest sources read")
