#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# THE ASSET ROOT'S DRIFT GATE (docs/assets-plan.md A6, gates 2 and 3;
# CLAUDE.md's gate list). `asset(name)` holds one rule in one Rust
# module, true only while nothing else resolves an asset and every lane
# carries the WHOLE root — neither checkable by the core.
#
# THE CONTRACT.
#   C1 PROVENANCE   every family under the root carries a README saying
#                   what the files are, where they came from, their
#                   licence, and how to regenerate them.
#   C2 CENSUS       the listing is printed with its count, every name is
#                   legal, and the count may not fall below a floor.
#   C3 ONE RESOLVER nothing outside the core resolves an asset path for
#                   itself; an exemption carries a reason, and the
#                   reason must be about a file that still exists.
#   C4 EVERY LANE   each lane stages the root or says why it needs
#                   nothing, BOTH halves stated rather than inferred.
#   C5 WHAT ARRIVED the staging lanes verify what they staged by HASH.
#   C6 THE FROZEN   tools/scenes/assets.steps freezes the miss
#      CENSUS       sentence's first line, the one run-time observation
#                   that a lane staged the WHOLE root — so adding an
#                   asset is ONE gate failure naming the .steps file.
#   C7 THE APK'S    three files spell Android's `assets/<prefix>/` and
#      PREFIX       this holds them equal; THE BYTES are checked by
#                   `apk_assets_verify` in run-emulator.py.
#   C8-C11          the market family: artifacts DERIVED and regenerated
#                   into scratch to compare, the ledger netting to the
#                   guest's BOOK, the history ending on it, and the
#                   scene's frozen lines re-derived from the artifact.
#   C12 THE WEIGHTS every weight kaya asks a vendored VARIABLE font for
#                   is a named instance of it: the GTK sheet's wishes go
#                   through weight_css_for's clamp, and any literal left
#                   is one every such font carries. A miss is not a
#                   fallback — pango aborts the process.
# NO FIXTURE ANYWHERE: every negative doctors a shadow of the REAL tree
# (CLAUDE.md invariant 3: the wayland seat guard passed vacuously twice).

import ast as ast_mod
import os
import re
import struct
import shutil
import subprocess
import tempfile

g = Gate("check-assets")

ASSET_ROOT = "guests/assets"

SHADOW_ROOTS = ["guests", "tools", "android", "swift", "crates",
                "bindings"]
PRUNE = {".git", ".gradle", ".build", "build", "target", "target-linux",
         "_build", "_build-linux", "obj", "bin", "node_modules",
         "__pycache__", "DerivedData", "dist", "dist-newstyle"}

# The floor. Not "some number": the families this tree is known to
# carry, so a walk that lost one says which.
FLOOR = 6
KNOWN = ["fonts/sora-wght.ttf", "icons/kaya-mark.png", "identity.toml"]

LEGAL = re.compile(
    r"^[A-Za-z0-9][A-Za-z0-9._-]*(?:/[A-Za-z0-9][A-Za-z0-9._-]*)*$")

WANTS = [("what the files are", ("bytes", "byte", "is —", "—")),
         ("where they came from", ("came from", "upstream", "provenance",
                                   "vendored", "written by",
                                   "committed")),
         ("the licence", ("licence", "license", "OFL", "no licence",
                          "no upstream")),
         ("how to regenerate them", ("regenerate", "regeneration",
                                     "makepri", "reproduce",
                                     "nobody knows"))]

# One resolver. Nothing outside the core may spell an asset's path or
# read an asset environment variable for itself.
#
# Each exemption names a file and a reason, and a stale one — file
# gone, or no longer matching — is itself a failure.
EXEMPT = {
    "crates/kaya/src/assets.rs":
        "the core's own resolver — this is the one place the rule "
        "lives",
    "crates/kaya/src/winui/mod.rs":
        "the harness-only include_bytes! of the vendored font, so the "
        "DirectWrite name-table tests measure a real font on whatever "
        "machine runs them; a test fixture, never a runtime read",
    "android/build.gradle.kts":
        "the APK's BUILD reads guests/assets/identity.toml, which is "
        "the declaration's second reader by ruling 4 and not a runtime "
        "asset resolution — no program has started when it runs",
    "bindings/python/kaya_app_checks.py":
        "a tier-1 check that asserts what the bindings emit; the path "
        "it names is test input, and the core is never entered",
}
SEARCH_ROOTS = ["guests", "bindings", "crates", "swift", "android"]
CODE = (".rs", ".py", ".go", ".cs", ".java", ".swift", ".ml", ".mli",
        ".hs", ".c", ".h", ".kt", ".kts")
ASSET_PATH = re.compile(r"guests/assets/")
ASSET_ENV = re.compile(r"KAYA_(?:FONT_FILE|ICON_FILE|ASSET_DIR)")

# THIS CLAUSE READS CODE AND NOT PROSE: a header explaining what a file
# USED to do is exactly the sentence a naive grep calls a violation,
# and a gate that fires on its own subject's documentation gets muted.
LINE_COMMENT = {".rs": "//", ".go": "//", ".cs": "//", ".java": "//",
                ".swift": "//", ".kt": "//", ".kts": "//", ".c": "//",
                ".h": "//", ".py": "#", ".hs": "--"}
DOCSTRING = re.compile(r'"""(?:.|\n)*?"""')


def code_only(text, ext):
    """The file with its comments and its docstring prose removed.

    LINE COMMENTS ONLY, PLUS PYTHON'S TRIPLE QUOTES, and the omission
    is the interesting part. A naive `/* ... */` stripper was written
    first and this gate's own stale-exemption clause caught it inside
    ten minutes: crates/kaya/src/winui/mod.rs stopped matching, because
    a `/*` somewhere in 15000 lines of Windows code opened a region the
    stripper ate to the next `*/`, taking the real `include_bytes!`
    with it. A clause that reads LESS of a file than it thinks is
    exactly the failure this whole gate exists against, so block
    comments are left in and a file that names an asset inside one is a
    finding a human resolves by moving the sentence or adding an
    exemption. Every false positive this slice actually produced was a
    `//` header or a Python docstring.

    It does not lex string literals either, which is RIGHT: a
    hard-coded "guests/assets/..." in a string is precisely the second
    resolver this clause refuses.
    """
    if ext == ".py":
        text = DOCSTRING.sub("", text)
    marker = LINE_COMMENT.get(ext)
    if marker:
        text = "\n".join(line.split(marker, 1)[0]
                         for line in text.splitlines())
    return text


# Every lane, both halves stated. STAGES: copy the ROOT rather than a
# file under it. NOTHING_NEEDED: say why, at the staging site.
# lane -> (why it stages, the token that proves HOW the core will find
# what it staged). The token differs per lane because the mechanism
# does: iOS needs no variable at all.
STAGES = {
    "tools/deploy-win.py": (
        "the VM has no repo; the deploy copies the root into the "
        "mirror path every run, outside the deploy stamp",
        "KAYA_ASSET_DIR"),
    "tools/android/run-emulator.py": (
        "a device has no repo; the root is pushed to /data/local/tmp "
        "and named in each leg's intent",
        "KAYA_ASSET_DIR"),
    # The ios token is the python constant the bundle copy reads.
    "tools/ios/run-sim.py": (
        "an app in the simulator has no repo and its cwd is /; the "
        "root goes into the bundle, which is both this lane's staging "
        "and what a shipped iOS app actually does — so the core finds "
        "it through Bundle.main and no variable is involved",
        "ASSET_SRC"),
}
NOTHING_NEEDED = {
    "tools/validate-mac.py":
        "the lane runs from the repo root, so the core's repo-relative "
        "default resolves with no environment at all",
    "tools/linux/run-suites.sh":
        "the repo is bind-mounted at /work and this script runs from "
        "there, so the default resolves inside the container",
}

APK_PREFIX_SITES = {
    "android/kaya/src/main/kotlin/dev/kaya/KayaAssets.kt":
        re.compile(r"""const\s+val\s+ROOT\s*=\s*"([^"]+)\""""),
    "android/build.gradle.kts":
        re.compile(r"""val\s+kayaAssetPrefix\s*=\s*"([^"]+)\""""),
    "tools/android/run-emulator.py":
        re.compile(r"""^APK_ASSET_PREFIX = "([A-Za-z0-9._-]+)"$""",
                   re.MULTILINE),
}


# ------------------------------------------------------------------ C12
# EVERY WEIGHT KAYA ASKS A VENDORED VARIABLE FONT FOR IS ONE IT HAS.
# Measured 2026-09-09: fontconfig enumerates a variable font's NAMED
# INSTANCES, never its continuous axis, so a CSS `font-weight` matching no
# instance fails the match and pango ABORTS the process inside layout —
# `pango_fc_font_map_get_face: assertion failed: (res == FcResultMatch)` —
# with no verdict and no window. guests/assets/fonts/sora-wght.ttf carries
# 100/200/300/400/600/700/800 and NO Medium, so a ruled `font-weight: 500`
# killed all sixteen `typeface` legs of one matrix.
#
# THE REMEDY IS A CLAMP IN THE BACKEND, not a number in a stylesheet: the
# font is OFL with a reserved name and a user's own font could lack any
# weight. So gtk.rs holds WISHES and lowers them through `weight_css_for`,
# which rewrites each to the nearest named instance of the brand font's own
# bytes. This clause holds BOTH halves — the clamp is wired, and any weight
# still written as a literal is one every vendored variable font carries.
#
# IT LIVES HERE AND NOT IN check-gtk.py BECAUSE check-gtk IS EXCLUDED FROM
# THE GATE SWEEP (it needs docker), so a clause there is one someone must
# remember to run — which is how this shipped. check-assets already owns
# guests/assets and already walks the font family. check-gtk keeps the
# RUNTIME half: gtk::weight_tests, over these same bytes, in the container.
GTK = "crates/kaya/src/gtk.rs"
FONT_FAMILY = "fonts"
# A literal weight in a stylesheet; `{...}` is an interpolation and is
# counted separately, because what it holds is the clamp's business.
CSS_WEIGHT = re.compile(r"font-weight:\s*(\{?[A-Za-z0-9_]+\}?)\s*;")
# The two keywords CSS resolves to a number. `lighter`/`bolder` are
# relative to the inherited value and cannot be resolved by reading one
# file, so they are refused by name rather than skipped.
KEYWORD_WEIGHTS = {"normal": 400, "bold": 700}

# The clamp, wired. Each is a callsite no text census elsewhere can see,
# and each perturbation below is a change that reads as correct.
CLAMP_WIRING = (
    # THE RULING ITSELF, all three rows in one needle so a silently
    # re-ruled weight reddens here: no observable on any backend reads a
    # font weight, on any platform, so nothing else in the tree can.
    ("the ruled wishes",
     'const WEIGHT_WISHES: &[(&str, u16)] = &[\n'
     '    ("button, button label", 500),\n'
     '    ("headerbar label.title, windowtitle label.title", 600),\n'
     '    ("label.heading", 500),\n'
     '];'),
    # A sheet added BELOW libadwaita's own (THEME, 200) loses every
    # declaration in it and raises nothing at all.
    ("the sheet added above libadwaita's own",
     "                &weight_css,\n"
     "                gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,"),
    ("the startup sheet lowered through the clamp",
     'load_kaya_css(&weight_css, "label weights", &weight_css_for(None), '
     '&css_error);'),
    ("the brand font's own instances read off its bytes",
     "request.font.as_ref().and_then(|blob| wght_named_instances(&blob.0))"),
    ("the sheet re-lowered when a brand typeface arrives",
     "&weight_css_for(instances.as_deref()),"),
    ("each wish taken to the nearest instance",
     "Some(have) => nearest_weight(*wish, have),"),
    ("the tie broken toward the heavier face",
     "(have.abs_diff(wish), std::cmp::Reverse(*have))"),
)


def named_instance_weights(blob):
    """The `wght` values of a font's NAMED INSTANCES, or None when the file
    is not a variable font with a weight axis. Pure `struct`: the dev shell
    carries no fontTools and a gate may not grow a dependency."""
    if len(blob) < 12:
        return None
    count = struct.unpack_from(">H", blob, 4)[0]
    tables = {}
    for i in range(count):
        if 12 + 16 * i + 16 > len(blob):
            return None
        tag, _sum, off, length = struct.unpack_from(">4sIII", blob, 12 + 16 * i)
        tables[tag.decode("latin1")] = (off, length)
    if "fvar" not in tables:
        return None
    base = tables["fvar"][0]
    if base + 16 > len(blob):
        return None
    axes_off, _pad, axis_count, axis_size, inst_count, inst_size = \
        struct.unpack_from(">HHHHHH", blob, base + 4)
    axis_index = None
    for i in range(axis_count):
        tag = struct.unpack_from(">4s", blob, base + axes_off + i * axis_size)[0]
        if tag == b"wght":
            axis_index = i
    if axis_index is None:
        return None
    first = base + axes_off + axis_count * axis_size
    found = set()
    for i in range(inst_count):
        coords = struct.unpack_from(f">{axis_count}i", blob,
                                    first + i * inst_size + 4)
        found.add(round(coords[axis_index] / 65536))
    return sorted(found)


def variable_fonts(root):
    """Every vendored variable font, with the weights it really has."""
    out = []
    family = pathlib.Path(root) / ASSET_ROOT / FONT_FAMILY
    for path in sorted(family.glob("*.ttf")):
        weights = named_instance_weights(path.read_bytes())
        if weights is not None:
            rel = path.relative_to(pathlib.Path(root)).as_posix()
            out.append((rel, weights))
    return out


def weight_findings(path, text, fonts):
    """One sentence per literal naming a weight some vendored variable font
    does not carry, plus the count of the interpolated ones (which the
    clamp owns and CLAMP_WIRING holds)."""
    bad = []
    interpolated = 0
    for raw in sorted(set(CSS_WEIGHT.findall(text))):
        if raw.startswith("{"):
            interpolated += 1
            continue
        if raw.isdigit():
            asked = int(raw)
        elif raw in KEYWORD_WEIGHTS:
            asked = KEYWORD_WEIGHTS[raw]
        else:
            bad.append(
                f"{path}: `font-weight: {raw}` is relative to the inherited "
                f"weight, so nothing here can tell which face it resolves "
                f"to — name the number instead, or lower it through the "
                f"clamp")
            continue
        for font, weights in fonts:
            if asked not in weights:
                bad.append(
                    f"{path}: `font-weight: {raw}` is written as a LITERAL "
                    f"and names a weight {font} does not carry. Its named "
                    f"instances are {weights}, and fontconfig enumerates "
                    f"THOSE, not the continuous axis — so on any scene that "
                    f"sets this font as its root family the match fails and "
                    f"pango ABORTS the process "
                    f"(`pango_fc_font_map_get_face: assertion failed: (res "
                    f"== FcResultMatch)`), with no verdict and no window. "
                    f"Lower it through weight_css_for's clamp as the label "
                    f"weights are, or ask for one of {weights}")
    return bad, interpolated


def check(root):
    """(stdout lines, findings) for one tree — a doctored shadow in
    the self-tests, the real one at the end."""
    root = pathlib.Path(root)
    bad = []
    out = []

    # -------------------------------------------------------------- C2
    # The listing first: every clause below reads it, and a clause that
    # read nothing must not print OK.
    assets = []
    base = root / ASSET_ROOT
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(dirnames)
        for fn in sorted(filenames):
            f = pathlib.Path(dirpath) / fn
            if f.is_symlink():
                bad.append(f"{f.relative_to(root).as_posix()}: is a "
                           f"symlink — an asset name may not escape "
                           f"the root, and a link inside it is that "
                           f"escape with the filesystem doing the "
                           f"walking")
                continue
            if not f.is_file():
                continue
            assets.append(f.relative_to(base).as_posix())
    assets.sort()

    out.append(f"assets: {len(assets)} under {ASSET_ROOT}: "
               + ", ".join(assets))
    if len(assets) < FLOOR:
        bad.append(f"the asset root lists {len(assets)} files, below "
                   f"the floor of {FLOOR} — a census that reads almost "
                   f"nothing agrees with almost anything, so this "
                   f"refuses a verdict rather than printing one")
    for want in KNOWN:
        if want not in assets:
            bad.append(f"{want} is not in the asset root's listing — "
                       f"it is one of the files this gate knows are "
                       f"there, so either it moved (and this list "
                       f"moves with it) or the walk is reading the "
                       f"wrong place")

    for name in assets:
        if not LEGAL.match(name) or ".." in name.split("/"):
            bad.append(f"{name}: is not spellable as an asset name — a "
                       f"name is a relative path under the root in "
                       f"`/`-separated segments, and the core refuses "
                       f"anything else at the call "
                       f"(crates/kaya/src/assets.rs, wall 1)")
        if name.count("/") > 1:
            bad.append(f"{name}: nests deeper than one family — the "
                       f"convention is flat families "
                       f"(docs/assets-plan.md A2), because the "
                       f"directory listing is the manifest and a deep "
                       f"tree is an index nobody wrote down")

    # -------------------------------------------------------------- C1
    # Every family carries a README. A family is a directory holding
    # anything that is not documentation.
    families = {}
    for name in assets:
        if "/" not in name:
            continue
        family, leaf = name.split("/", 1)
        families.setdefault(family, []).append(leaf)
    if not families:
        bad.append("the asset root has no family directories at all — "
                   "this clause read nothing and would agree with any "
                   "tree")
    for family, leaves in sorted(families.items()):
        payload = [x for x in leaves if not x.lower().endswith(".md")]
        if not payload:
            continue
        readme = base / family / "README.md"
        if not readme.is_file():
            bad.append(f"{ASSET_ROOT}/{family}/ carries {len(payload)} "
                       f"vendored file(s) ({', '.join(sorted(payload))}) "
                       f"and no README.md — a vendored binary with no "
                       f"provenance is the one hygiene question a "
                       f"vendored binary asks, and this is where it is "
                       f"answered (docs/assets-plan.md A2)")
            continue
        text = readme.read_text(encoding="utf-8", errors="replace")
        for label, needles in WANTS:
            if not any(n.lower() in text.lower() for n in needles):
                bad.append(f"{ASSET_ROOT}/{family}/README.md never "
                           f"says {label} — the four things a family "
                           f"README is for are what the files are, "
                           f"where they came from, their licence, and "
                           f"how to regenerate them. An honest "
                           f"\"nobody knows\" counts; silence does "
                           f"not")

    # -------------------------------------------------------------- C3
    resolvers = 0
    for r in SEARCH_ROOTS:
        for dirpath, dirnames, filenames in os.walk(root / r):
            dirnames[:] = sorted(d for d in dirnames if d not in PRUNE)
            for fn in sorted(filenames):
                if os.path.splitext(fn)[1] not in CODE:
                    continue
                f = pathlib.Path(dirpath) / fn
                rel = f.relative_to(root).as_posix()
                text = code_only(
                    f.read_text(encoding="utf-8", errors="replace"),
                    os.path.splitext(fn)[1])
                hit_path = ASSET_PATH.search(text) is not None
                # A BINDING MAY NAME THE VARIABLE AND MAY NOT READ A
                # PATH: KAYA_ASSET_DIR is part of the surface every
                # binding documents, so only the env half is relaxed.
                hit_env = (not rel.startswith("bindings/")
                           and ASSET_ENV.search(text) is not None)
                if not (hit_path or hit_env):
                    continue
                resolvers += 1
                if rel in EXEMPT:
                    continue
                what = ("an asset path" if hit_path
                        else "an asset environment variable")
                bad.append(f"{rel}: names {what} for itself. The "
                           f"resolution rule and its failure sentence "
                           f"live ONCE, in crates/kaya/src/assets.rs, "
                           f"and reach every language through "
                           f"`asset(name)` — a second reader here is "
                           f"the eight-copies problem starting again "
                           f"one file at a time. If this file "
                           f"genuinely cannot use the call, add it to "
                           f"this gate's EXEMPT table with the reason")
    if resolvers == 0:
        bad.append("no file anywhere names an asset path or an asset "
                   "environment variable — this clause read NOTHING, "
                   "so it would agree with a tree in which every guest "
                   "resolved its own assets")
    for rel, why in sorted(EXEMPT.items()):
        path = root / rel
        if not path.is_file():
            bad.append(f"{rel} is exempted from the one-resolver rule "
                       f"but does not exist — delete the exemption "
                       f"rather than leaving a rule that applies to "
                       f"nothing")
            continue
        if len(why.strip()) < 20:
            bad.append(f"{rel} is exempted with no real reason given "
                       f"({why!r})")
        # AND THE EXEMPTION MUST STILL BE EARNED: a file that stopped
        # resolving leaves a permission behind it, and the next edit to
        # that file inherits it silently.
        body = code_only(path.read_text(encoding="utf-8",
                                        errors="replace"),
                         os.path.splitext(rel)[1])
        if not (ASSET_PATH.search(body)
                or (not rel.startswith("bindings/")
                    and ASSET_ENV.search(body))):
            bad.append(f"{rel} is exempted from the one-resolver rule "
                       f"and no longer needs to be — it resolves "
                       f"nothing. Delete the entry: an exemption "
                       f"nobody re-read is how a rule stops applying "
                       f"without anyone deciding that it should")

    # -------------------------------------------------------------- C4
    for rel, (_why, token) in sorted(STAGES.items()):
        path = root / rel
        if not path.is_file():
            bad.append(f"{rel} is listed as an asset stager and does "
                       f"not exist")
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        if token not in text:
            bad.append(f"{rel} stages assets for a guest that cannot "
                       f"see the repo and never names {token} — so "
                       f"whatever it copied, nothing connects it to "
                       f"the route the core will actually take, and "
                       f"every asset call on that machine resolves to "
                       f"the compile-time repo path it does not have")
        # A COPY of one file under the root, never a mere mention of
        # one: the deploy hashes the resource index by path, which is a
        # READ. Both the shell and the python spellings are listed —
        # a lane copying one file in the language this ban did not name
        # would go vacuous.
        COPY = ("scp ", "adb push", "cp ", "copyTo", "install ",
                "rsync", "copy2", "copytree", "copyfile")
        for line in text.splitlines():
            if not re.search(r"guests/assets/(fonts|icons|win)/"
                             r"[A-Za-z0-9*]", line):
                continue
            if not any(verb in line for verb in COPY):
                continue
            bad.append(f"{rel} stages a FILE under the asset root "
                       f"rather than the root itself "
                       f"({line.strip()[:70]}). A lane stages the root "
                       f"as a unit (docs/assets-plan.md A5.1): "
                       f"per-file staging is what made every new asset "
                       f"cost five more lines in five scripts, and the "
                       f"line that got forgotten failed on the lane "
                       f"furthest from the change")
    for rel, why in sorted(NOTHING_NEEDED.items()):
        path = root / rel
        if not path.is_file():
            bad.append(f"{rel} is listed as needing no asset staging "
                       f"and does not exist")
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        if "guests/assets" not in text:
            bad.append(f"{rel} needs no asset staging ({why}) and "
                       f"never says so. The reason belongs at the site "
                       f"rather than in a reader's head: the next "
                       f"person to add an asset reads this file "
                       f"looking for the staging line, and its absence "
                       f"has to be an answer rather than a gap "
                       f"(docs/assets-plan.md A5.4)")

    # -------------------------------------------------------------- C5
    for rel in sorted(STAGES):
        path = root / rel
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        if "shasum" not in text and "sha256" not in text.lower():
            bad.append(f"{rel} stages the asset root and never hashes "
                       f"what arrived against what it sent. A size "
                       f"comparison is the shape this replaced "
                       f"(docs/assets-plan.md A5.1) and it agrees with "
                       f"any corruption that preserved the length")

    # -------------------------------------------------------------- C6
    ASSETS_SCENE = "tools/scenes/assets.steps"
    scene_path = root / ASSETS_SCENE
    if not scene_path.is_file():
        bad.append(f"{ASSETS_SCENE} is not there — it is the only "
                   f"run-time observation of the asset census, and "
                   f"without it nothing checks that a lane staged the "
                   f"whole root rather than one file "
                   f"(docs/assets-plan.md A5.1)")
    else:
        scene = scene_path.read_text(encoding="utf-8", errors="replace")
        statements = [ln.strip() for ln in scene.split("\n")
                      if not ln.strip().startswith("#")]
        frozen = [ln for ln in statements
                  if "the package carries" in ln]
        if not frozen:
            bad.append(f"{ASSETS_SCENE} freezes no census — its "
                       f"`expect label#1` is the whole reason the "
                       f"scene exists, and a scene that stopped "
                       f"asserting it would keep passing on a lane "
                       f"that staged one file")
        for line in frozen:
            m = re.search(r"the package carries (.+)\"\s*$", line)
            if not m:
                bad.append(f"{ASSETS_SCENE}: this gate could not read "
                           f"the census out of {line!r} — the "
                           f"expectation moved and this clause is now "
                           f"reading nothing, which agrees with "
                           f"anything")
                continue
            named = [p.strip() for p in m.group(1).split(",")]
            if named != assets:
                bad.append(f"{ASSETS_SCENE} freezes a census of "
                           f"{len(named)} assets and the root carries "
                           f"{len(assets)}. Frozen: {', '.join(named)}. "
                           f"Root: {', '.join(assets)}. The scene's "
                           f"string is the miss sentence's first line "
                           f"verbatim, so it moves with the root — and "
                           f"it is deliberately expensive to change, "
                           f"because every lane has to stage what it "
                           f"names")
            missing = re.search(r"no asset named \"([^\"]+)\"", line)
            if missing and missing.group(1) in assets:
                bad.append(f"{ASSETS_SCENE} names {missing.group(1)!r} "
                           f"as the asset that is NOT there, and the "
                           f"root now carries it — the scene would "
                           f"then be asserting a sentence the core "
                           f"will never print")

    # -------------------------------------------------------------- C7
    prefixes = {}
    for rel, pattern in sorted(APK_PREFIX_SITES.items()):
        path = root / rel
        if not path.is_file():
            bad.append(f"{rel} is not there and it is one of the three "
                       f"files that spell the APK's asset prefix — "
                       f"deleting one of the three is how the packaged "
                       f"layout and the reader stop agreeing")
            continue
        m = pattern.search(path.read_text(encoding="utf-8",
                                          errors="replace"))
        if not m:
            bad.append(f"{rel} no longer spells the APK asset prefix "
                       f"in the form this gate reads. It is one of "
                       f"three hand-written copies of one string, and "
                       f"a copy this cannot see is a copy nothing "
                       f"holds")
            continue
        prefixes[rel] = m.group(1)
    if len(set(prefixes.values())) > 1:
        bad.append("the APK's asset prefix is spelled differently in "
                   + "; ".join(f"{k} = {v!r}"
                               for k, v in sorted(prefixes.items()))
                   + " — the build copies into one, the reader reads "
                     "the other, and the miss sentence would name a "
                     "census the app cannot produce")
    GRADLE = "android/build.gradle.kts"
    gradle_path = root / GRADLE
    if gradle_path.is_file():
        gradle = gradle_path.read_text(encoding="utf-8",
                                       errors="replace")
        if "assets.srcDir" not in gradle:
            bad.append(f"{GRADLE} never adds an assets source "
                       f"directory — an APK that carries no assets/ "
                       f"resolves nothing through AssetManager, and "
                       f"the leg that runs without a staged root would "
                       f"fall through to a path the device does not "
                       f"have (docs/assets-plan.md A4)")

    # -------------------------------------------------------------- C8
    # The market artifact is DERIVED (maintainer 2026-08-24): the
    # generator is committed, the csv is not. The honest check
    # regenerates into a scratch and byte-compares — target/'s stamp is
    # only --ensure's fast path and is deliberately not read here
    # (shadows carry no target/).
    gen = root / "tools" / "gen-market.py"
    market = root / "guests" / "assets" / "market"
    art = market / "transactions.csv"
    hist = market / "prices.csv"
    # BOTH artifacts, because the family grew a second one (2026-08-27)
    # and a clause that regenerated one of two would call a stale
    # history current.
    DERIVED = [("transactions.csv", art), ("prices.csv", hist)]
    if not gen.is_file():
        bad.append("tools/gen-market.py is gone while the market "
                   "family exists — the derived artifacts would have "
                   "no regeneration story")
    elif [n for n, p in DERIVED if not p.is_file()]:
        for name, path in DERIVED:
            if not path.is_file():
                bad.append(f"guests/assets/market/{name} is missing — "
                           f"it is derived, never committed: run "
                           f"`python3 tools/gen-market.py --ensure` "
                           f"(docs, guests/assets/market/README.md)")
    else:
        with tempfile.TemporaryDirectory() as td:
            scratch = pathlib.Path(td)
            env = dict(os.environ, KAYA_GEN_MARKET_DIR=str(scratch))
            r = subprocess.run([sys.executable, str(gen)], env=env,
                               capture_output=True, text=True,
                               check=False)
            if r.returncode != 0:
                bad.append("tools/gen-market.py failed to run for the "
                           "derivation check: " + r.stderr.strip()[:200])
            else:
                for name, path in DERIVED:
                    fresh_art = scratch / name
                    if not fresh_art.is_file():
                        bad.append(f"tools/gen-market.py wrote no "
                                   f"{name} into the scratch "
                                   f"directory, so the derivation "
                                   f"check had nothing to compare that "
                                   f"artifact against")
                    elif fresh_art.read_bytes() != path.read_bytes():
                        bad.append(f"guests/assets/market/{name} does "
                                   f"not match what "
                                   f"tools/gen-market.py generates — "
                                   f"the artifact is derived, never "
                                   f"hand-edited: run `python3 "
                                   f"tools/gen-market.py --ensure`")

    # -------------------------------------------------------------- C9
    # THE SCENE IS DERIVED FROM THE ARTIFACT TOO: C8 holds the CSV to its
    # generator, and nothing held the transactions view's byte-frozen
    # scene to the CSV, so retuning the generator left it asserting last
    # month's ledger — five failing strings on every windowed lane, no
    # file named. The scene sees the ledger AFTER THE TICK, so the
    # derivation is the CSV plus what "Day tick" posts; POSTED, RECENT,
    # BOOK, TICK and FILTERS are read out of the guest by ast (importing
    # it would build a window). C10 rides here for the same five tables.
    PF_SCENE = "tools/scenes/portfolio.steps"
    GUEST = "guests/python/portfolio.py"
    pf_scene_path = root / PF_SCENE
    guest_path = root / GUEST
    if art.is_file() and not pf_scene_path.is_file():
        bad.append(f"{PF_SCENE} is gone while the market artifact "
                   f"whose rows it freezes is still here — the "
                   f"transactions view's scene is the only run-time "
                   f"observation that the ledger arrived whole")
    elif art.is_file() and not guest_path.is_file():
        bad.append(f"{GUEST} is gone while the market artifact it "
                   f"reads is still here — this clause reads POSTED "
                   f"and RECENT out of that guest and cannot derive "
                   f"the scene without it")
    elif art.is_file():
        guest_tree = ast_mod.parse(
            guest_path.read_text(encoding="utf-8"), GUEST)

        def _const(name):
            """The guest's own table, by name. A reader that cannot
            find its subject agrees with anything, so a missing name is
            a red."""
            for node in guest_tree.body:
                if (isinstance(node, ast_mod.Assign)
                        and len(node.targets) == 1
                        and isinstance(node.targets[0], ast_mod.Name)
                        and node.targets[0].id == name):
                    try:
                        return ast_mod.literal_eval(node.value)
                    except (ValueError, SyntaxError):
                        return None
            return None

        RECENT = _const("RECENT")
        POSTED = _const("POSTED")
        BOOK = _const("BOOK")
        TICK = _const("TICK")
        FILTERS = _const("FILTERS")
        if not isinstance(RECENT, int) or not isinstance(POSTED, list):
            bad.append(f"{GUEST} no longer spells RECENT (an int) and "
                       f"POSTED (a list of literal rows) at module "
                       f"scope — this clause reads both to derive the "
                       f"scene, and a reader that finds neither would "
                       f"agree with any scene at all")
        elif not isinstance(BOOK, dict) or not isinstance(TICK, dict) \
                or not isinstance(FILTERS, list):
            bad.append(f"{GUEST} no longer spells BOOK (the holdings), "
                       f"TICK (the per-ticker delta) and FILTERS (the "
                       f"view's account filter) at module scope — C10 "
                       f"nets the ledger against that book and a "
                       f"reader that cannot find it would call any "
                       f"data tied")
        else:
            # The guest's own row shape: date, account, ticker, side,
            # qty, total_cents. POSTED is written in it, so the tick's
            # rows need no arithmetic here.
            rows = [(d, a, t, s_, int(q), int(tot))
                    for d, a, t, s_, q, _p, tot in
                    (line.split(",") for line in
                     art.read_text(encoding="utf-8").splitlines()[1:])]
            csv_len = len(rows)
            rows = rows + [tuple(r) for r in POSTED]

            def _money(cents):
                return f"${cents // 100}.{cents % 100:02d}"

            def _edge(word, row):
                date, _account, ticker, side, _qty, total = row
                return f"{word} {date} {ticker} {side} {_money(total)}"

            def _cells(row):
                date, _account, ticker, side, _qty, total = row
                return f"{date},{ticker},{side},{_money(total)}"

            scene_text = pf_scene_path.read_text(encoding="utf-8")
            derived = [
                (f'expect label#1 "Transactions: {csv_len}"',
                 "the dashboard's count of the book as the artifact "
                 "has it"),
                (f'expect label#1 "Transactions: {len(rows)}"',
                 "the dashboard's count after the tick posted its "
                 "rows"),
                (f'expect label@count "{len(rows)} of {len(rows)} '
                 f'transactions"',
                 "the ledger's declared size"),
                (f'expect label@first "{_edge("first", rows[0])}"',
                 "the ledger's first row"),
                (f'expect label@last "{_edge("last", rows[-1])}"',
                 "the ledger's last row"),
                ('expect_rows column@recent "'
                 + "|".join(_cells(r) for r in rows[-RECENT:]) + '"',
                 f"the {RECENT} most recent rows"),
            ]

            # ------------------------------------------------------ C10
            # THE TIE-OUT (ruled 2026-08-26): an account's holdings ARE
            # the sum of its transactions. The generator holds that at
            # write time; this holds the ARTIFACT ON DISK to it — the
            # half a doctored or half-written CSV breaks with the
            # generator innocent — and requires each derived `label@net`
            # money to be a string the dashboard also says (invariant 3).
            holdings = {a: {t: q for t, q, _ in hs}
                        for a, (_n, hs) in BOOK.items()}
            anchors = {t: c for _n, hs in BOOK.values()
                       for t, _q, c in hs}
            live = {t: c + TICK.get(t, 0) for t, c in anchors.items()}
            net = {}
            for _d, account, ticker, side, qty, _tot in rows:
                if side in ("buy", "sell"):
                    net[(account, ticker)] = (
                        net.get((account, ticker), 0)
                        + (qty if side == "buy" else -qty))
            pairs = sorted(set(net) | {(a, t) for a in holdings
                                       for t in anchors})
            for account, ticker in pairs:
                want = holdings.get(account, {}).get(ticker, 0)
                got = net.get((account, ticker), 0)
                if got != want:
                    bad.append(
                        f"guests/assets/market/transactions.csv does "
                        f"not net to {GUEST}'s BOOK: {account}/{ticker} "
                        f"nets to {got} and the book holds {want}. THE "
                        f"LEDGER IS GENERATED TO TIE (ruled 2026-08-26, "
                        f"docs/deferred.md) — the two screens claim the "
                        f"same positions, so a ledger that disagrees "
                        f"makes the dashboard a fiction. Regenerate: "
                        f"`python3 tools/gen-market.py --ensure`")

            # ------------------------------------------------------ C11
            # THE HISTORY TIES TO THE SAME BOOK, one column over
            # (2026-08-27, docs/canvas-plan.md §10): prices.csv's LAST
            # DAY is the dashboard's live prices, so the chart's right
            # edge is the money label#0 shows. Held on the ARTIFACT ON
            # DISK, and the scene's chart lines are DERIVED from it —
            # C9's rule for the ledger, applied to the chart.
            CHART_DAYS = _const("CHART_DAYS")
            if not hist.is_file():
                pass  # C8 already named the missing artifact.
            elif not isinstance(CHART_DAYS, int):
                bad.append(f"{GUEST} no longer spells CHART_DAYS (an "
                           f"int) at module scope — C11 derives the "
                           f"chart's frozen accessible name from that "
                           f"window, and a reader that cannot find it "
                           f"would agree with any chart at all")
            else:
                hist_days, walk_ = [], {}
                for line in hist.read_text(
                        encoding="utf-8").splitlines()[1:]:
                    date, ticker, cents = line.split(",")
                    if not hist_days or hist_days[-1] != date:
                        hist_days.append(date)
                    walk_.setdefault(ticker, []).append(int(cents))
                for ticker, anchor in sorted(anchors.items()):
                    end = walk_.get(ticker, [None])[-1]
                    if end != anchor:
                        bad.append(
                            f"guests/assets/market/prices.csv ends "
                            f"{ticker} at {end} and {GUEST}'s BOOK "
                            f"prices it at {anchor}. THE LAST DAY OF "
                            f"HISTORY IS THE DASHBOARD'S PRESENT "
                            f"(docs/canvas-plan.md §10) — a history "
                            f"that ends anywhere else draws a "
                            f"plausible chart nobody can see is wrong. "
                            f"Regenerate: `python3 tools/gen-market.py "
                            f"--ensure`")
                qty = {t: q for _n, hs in BOOK.values()
                       for t, q, _c in hs}
                first = len(hist_days) - CHART_DAYS
                if first < 0:
                    bad.append("guests/assets/market/prices.csv holds "
                               f"{len(hist_days)} days and {GUEST} "
                               f"charts {CHART_DAYS}")
                else:
                    window = [sum(q_ * walk_[t][first + i]
                                  for t, q_ in qty.items())
                              for i in range(CHART_DAYS)]
                    for last, when in (
                            (sum(q_ * anchors[t]
                                 for t, q_ in qty.items()), "at rest"),
                            (sum(q_ * live[t]
                                 for t, q_ in qty.items()),
                             "after the tick")):
                        series = window[:-1] + [last]
                        derived.append((
                            f'expect_ax canvas@chart "image/Portfolio '
                            f'value, {CHART_DAYS} days to '
                            f'{hist_days[-1]}, {_money(min(series))} '
                            f'to {_money(max(series))}, '
                            f'now {_money(last)}"',
                            f"the chart's accessible name {when}"))
                        # The chart's own tie-out: its right edge is
                        # money the dashboard says out loud on the same
                        # screen.
                        twin = f'"Portfolio: {_money(last)}"'
                        if twin not in scene_text:
                            bad.append(
                                f"{PF_SCENE} freezes a chart whose "
                                f"last point is {_money(last)} {when} "
                                f"and never asserts {twin} beside it. "
                                f"The chart's tie-out is only a guard "
                                f"while ONE scene says the same money "
                                f"twice (docs/canvas-plan.md §10)")

            def _net_line(subset):
                held = {}
                for _d, _a, ticker, side, qty_, _tot in subset:
                    if side in ("buy", "sell"):
                        held[ticker] = (held.get(ticker, 0)
                                        + (qty_ if side == "buy"
                                           else -qty_))
                held = {t: q_ for t, q_ in held.items() if q_}
                if not held:
                    return "net — = $0.00", 0
                value = sum(q_ * live[t] for t, q_ in held.items())
                return ("net "
                        + ", ".join(f"{t} {held[t]}"
                                    for t in sorted(held))
                        + f" = {_money(value)}"), value

            # Index 0 of FILTERS is "no filter", which the freshly
            # pushed view is in; every other index the scene actually
            # chooses is read out of the scene rather than assumed.
            chosen = {0} | {int(n) for n in
                            re.findall(r"^choose select#0 (\d+)",
                                       scene_text, re.M)}
            for index in sorted(chosen):
                if index >= len(FILTERS):
                    bad.append(f"{PF_SCENE} chooses filter #{index} "
                               f"and {GUEST}'s FILTERS has "
                               f"{len(FILTERS)} entries")
                    continue
                account = FILTERS[index][1]
                subset = [r for r in rows
                          if account is None or r[1] == account]
                line, value = _net_line(subset)
                derived.append((f'expect label@net "{line}"',
                                "the tie-out for "
                                + (f"account {account}" if account
                                   else "the whole book")))
                # The other half of the tie: that money is the
                # DASHBOARD's, so the scene must say it on both
                # screens.
                twin = (f'"Account total: {_money(value)}"' if account
                        else f'"Portfolio: {_money(value)}"')
                if twin not in scene_text:
                    bad.append(
                        f"{PF_SCENE} freezes a net line worth "
                        f"{_money(value)} for "
                        + (f"account {account}" if account
                           else "the whole book")
                        + f" and never asserts {twin} on the "
                          f"dashboard. The tie-out is only a guard "
                          f"while ONE scene says the same money on "
                          f"both screens (docs/portfolio-plan.md §6)")

            for line, what in derived:
                if line not in scene_text:
                    bad.append(f"{PF_SCENE} no longer freezes {what} "
                               f"the way the generated artifact has "
                               f"it. That scene is DERIVED from "
                               f"guests/assets/market/transactions.csv "
                               f"and the guest's own POSTED — move the "
                               f"expectation, never the artifact. The "
                               f"line the data asks for is:\n"
                               f"    {line}")

    # ------------------------------------------------------------- C12
    fonts = variable_fonts(root)
    if not fonts:
        bad.append(f"no variable font under {ASSET_ROOT}/{FONT_FAMILY} "
                   f"could be read, so the weight clause checked nothing "
                   f"and would pass any stylesheet at all — a census that "
                   f"reads no font agrees with everything")
    for font, weights in fonts:
        out.append(f"{font} carries named weights {weights}")
    gtk_path = pathlib.Path(root) / GTK
    if not gtk_path.is_file():
        bad.append(f"{GTK} is not in the tree — this clause reads the GTK "
                   f"backend's stylesheets and cannot say anything without "
                   f"it")
    elif fonts:
        gtk_text = gtk_path.read_text(encoding="utf-8")
        for label, needle in CLAMP_WIRING:
            seen = gtk_text.count(needle)
            if seen != 1:
                bad.append(
                    f"{GTK}: {label} appears {seen} time(s), wanted "
                    f"exactly 1 (`{needle}`). The label weights are WISHES "
                    f"lowered through weight_css_for against the brand "
                    f"font's own named instances; with that path broken "
                    f"the sheet asks for a weight the font may not have "
                    f"and pango aborts every leg of the scene that sets "
                    f"it — which no other gate, and no lane but that "
                    f"scene's, can see")
        found, interpolated = weight_findings(GTK, gtk_text, fonts)
        bad.extend(found)
        out.append(f"{GTK}: {interpolated} interpolated font-weight(s) "
                   f"through the clamp, every literal one a named "
                   f"instance of {len(fonts)} vendored variable font(s)")

    return out, bad


# ---------------------------------------------------------- self-tests
def fresh(name):
    """A shadow root the checker can read. THE ASSET ROOT IS COPIED,
    EVERYTHING ELSE IS LINKED: C2 refuses a symlink inside the root, so
    an all-links shadow would fail that clause for a reason belonging
    to the shadow rather than to the perturbation."""
    dst = g.scratch() / name
    n = 0
    for r in SHADOW_ROOTS:
        for dirpath, dirnames, filenames in os.walk(ROOT / r):
            dirnames[:] = sorted(d for d in dirnames
                                 if d not in PRUNE)
            for fn in sorted(filenames):
                f = pathlib.Path(dirpath) / fn
                if not f.is_file():
                    continue
                out = dst / f.relative_to(ROOT)
                out.parent.mkdir(parents=True, exist_ok=True)
                if f.relative_to(ROOT).as_posix().startswith(
                        "guests/assets/"):
                    shutil.copyfile(f, out)
                else:
                    os.symlink(f, out)
                n += 1
    if n == 0:
        g.refuse("SELF-TEST FAIL (the shadow root is empty)")
    return dst


def doctor_shadow(label, shadow_root, rel, pattern, repl):
    """The old shell accepted ANY count >= 1 and replaced every site
    (66 for the deploy's run_ssh), so the honest want is measured at
    run time rather than pinned: a zero still refuses through
    doctor(want=1), and the printed count is the real one."""
    p = shadow_root / rel
    text = p.read_text(encoding="utf-8")
    n = len(re.findall(pattern, text, re.S)) or 1
    out = g.doctor(label, text, pattern, repl, want=n, flags=re.S)
    p.unlink()  # never write through the symlink into the real tree
    p.write_text(out, encoding="utf-8")


def combined(root):
    out, bad = check(root)
    return out + bad


def refused(root, fragment, label):
    g.negative(label, lambda: combined(root), want=fragment)


# N0 — the shadow root itself must pass, or every refusal below could
# be an artifact of the copy rather than of the perturbation.
base = fresh("base")
out0, bad0 = check(base)
if bad0:
    print("\n".join(out0 + bad0), file=sys.stderr)
    print("check-assets: FAIL — refused before any perturbation, so "
          "this is the tree and not the self-test", file=sys.stderr)
    raise SystemExit(1)

# N1 — C1: a family loses its README.
s = fresh("n1")
(s / "guests/assets/win/README.md").unlink()
refused(s, "and no README.md", "N1 (a family with no provenance)")

# N2 — C1: a README stops answering one of its four questions.
s = fresh("n2")
doctor_shadow("N2's licence redaction", s,
              "guests/assets/fonts/README.md",
              r"(?i)licence|license|\bOFL\b", "permission")
refused(s, "never says the licence",
        "N2 (a README that drops its licence)")

# N3 — C3: a guest resolves an asset path for itself again.
s = fresh("n3")
doctor_shadow("N3's re-introduced path", s, "guests/rust/typeface.rs",
              r"use kaya::Occurrence;",
              'use kaya::Occurrence;\nconst FONT: &str = '
              '"guests/assets/fonts/sora-wght.ttf";')
refused(s, "names an asset path for itself", "N3 (a second resolver)")

# N4 — C4: a stager copies a FILE under the root rather than the root.
s = fresh("n4")
doctor_shadow("N4's per-file staging", s, "tools/deploy-win.py",
              r"run_ssh",
              "scp guests/assets/fonts/sora-wght.ttf ignored\n"
              "run_ssh")
refused(s, "stages a FILE under the asset root",
        "N4 (per-file staging)")

# N4b — the same defect in the ios lane's PYTHON spelling: a
# shutil.copy2 of one file under the root must trip the ban the shell
# verbs used to carry alone.
s = fresh("n4b")
doctor_shadow("N4b's per-file python staging", s, "tools/ios/run-sim.py",
              r'    shutil\.copytree\(ASSET_SRC, app / "assets"\)',
              '    shutil.copy2("guests/assets/fonts/sora-wght.ttf", app)\n'
              '    shutil.copytree(ASSET_SRC, app / "assets")')
refused(s, "stages a FILE under the asset root",
        "N4b (per-file staging, python spelling)")

# N5 — C4: a lane that needs nothing stops saying so.
s = fresh("n5")
doctor_shadow("N5's redacted reason", s, "tools/linux/run-suites.sh",
              r"guests/assets", "guests/somewhere")
refused(s, "needs no asset staging", "N5 (an unexplained absence)")

# N6 — C2: the census floor refuses a root that lost most of itself.
# EVERYTHING BUT identity.toml GOES, not a named list: a named list is
# sized against today's root, and the day two small files joined the
# root the deletions stopped reaching the floor and this self-test
# failed sideways (2026-08-19, the a11y stand-in picture and its family
# README).
s = fresh("n6")
for p in sorted((s / "guests/assets").rglob("*")):
    if p.is_file() and p.name != "identity.toml":
        p.unlink()
refused(s, "below the floor of",
        "N6 (a census that reads almost nothing)")

# N7 — C5: a stager verifies by size rather than by hash.
s = fresh("n7")
doctor_shadow("N7's hash removal", s, "tools/android/run-emulator.py",
              r"(?i)sha256sum|shasum|sha256", "wc -c")
refused(s, "never hashes what arrived",
        "N7 (a size check standing in for a hash)")

# N8 — C6: the root gains an asset and the scene's frozen census does
# not. Without the clause the first notice is five red lanes, each
# blaming a scene rather than the file that was added.
s = fresh("n8")
(s / "guests/assets/fonts/extra.bin").write_text(
    "a second font nobody told the scene about\n", encoding="utf-8")
refused(s, "freezes a census of", "N8 (an asset the scene does not "
                                  "name)")

# N9 — C6: the scene stops freezing a census at all — how the expensive
# expectation gets quietly dropped rather than updated.
s = fresh("n9")
doctor_shadow("N9's census removal", s, "tools/scenes/assets.steps",
              r"the package carries", "the package holds")
refused(s, "freezes no census",
        "N9 (a scene that stopped asserting the census)")

# N10 — C7: the APK's prefix is spelled differently in two of the three
# files, so the build copies into one directory and the reader reads
# another.
s = fresh("n10")
doctor_shadow("N10's prefix rename", s,
              "android/kaya/src/main/kotlin/dev/kaya/KayaAssets.kt",
              r'const val ROOT = "kaya"',
              'const val ROOT = "kaya-assets"')
refused(s, "asset prefix is spelled differently",
        "N10 (three files, two prefixes)")

# N11 — C7: the APK stops carrying assets at all, and the failure names
# a directory rather than the packaging step that stopped packaging.
s = fresh("n11")
doctor_shadow("N11's removed assets source directory", s,
              "android/build.gradle.kts", r"assets\.srcDir",
              "assets.ignored")
refused(s, "never adds an assets source directory",
        "N11 (an APK carrying no assets)")

# N12 — C8: the generator's seed moves while the artifact stays — a
# stale derived artifact must be refused with the regeneration named.
s = fresh("n12")
doctor_shadow("N12's reseeded generator", s, "tools/gen-market.py",
              r"0x6B617961", "0x6B617962")
refused(s, "does not match what tools/gen-market.py generates",
        "N12 (a stale derived artifact)")

# N13 — C8: the artifact is absent entirely (the fresh-clone state
# before any build) and the refusal names the ensure command.
s = fresh("n13")
(s / "guests/assets/market/transactions.csv").unlink()
refused(s, "derived, never committed",
        "N13 (a missing derived artifact)")

# N14 — C9: the scene's frozen last row drifts from the artifact's. The
# SCENE is doctored rather than the CSV, so C8 stays green and this red
# can only be C9's.
s = fresh("n14")
doctor_shadow("N14's drifted last row", s,
              "tools/scenes/portfolio.steps",
              r'expect label@last "last [^"]*"',
              'expect label@last "last 1999-01-01 AAPL buy $1.00"')
refused(s, "the ledger's last row",
        "N14 (a scene that outlived its artifact)")

# N15 — C9: the same, one string over — the most recent rows, which is
# the expectation a regenerated ledger moves every time. COUNT-FREE on
# purpose: the census derives the count from the guest's own RECENT (8
# since 2026-08-30, 12 before), and a self-test pinned to the number
# broke the day the number moved while the census itself was right.
s = fresh("n15")
doctor_shadow("N15's drifted recent rows", s,
              "tools/scenes/portfolio.steps",
              r'(expect_rows column@recent ")[^"]*"',
              r"\1nothing,here,at,$0.00" + '"')
refused(s, "most recent rows", "N15 (a stale recent table)")

# N16 — C9: the scene is deleted while the artifact stays.
s = fresh("n16")
(s / "tools/scenes/portfolio.steps").unlink()
refused(s, "is gone while the market artifact",
        "N16 (a deleted scene)")

# N17 — C9's tick half: the GUEST's posting rule moves and the scene
# does not. Nothing else in the sweep reads POSTED, and the scene's
# recent table is where the three posted rows show.
s = fresh("n17")
doctor_shadow("N17's re-valued posted dividend", s,
              "guests/python/portfolio.py",
              r'\("2026-08-25", "brokerage", "AAPL", "div", 0, 240\)',
              '("2026-08-25", "brokerage", "AAPL", "div", 0, 250)')
refused(s, "most recent rows",
        "N17 (a posting rule the scene never heard about)")

# N18 — C9: the DASHBOARD's own count of the book drifts. That label is
# the one place the two screens are asserted to share a model, and it
# is derived from the artifact's length alone.
s = fresh("n18")
doctor_shadow("N18's drifted book count", s,
              "tools/scenes/portfolio.steps",
              r'expect label#1 "Transactions: 15003"',
              'expect label#1 "Transactions: 999"')
refused(s, "after the tick posted its rows",
        "N18 (a dashboard count the ledger cannot produce)")

# N19 — C9: the guest stops spelling the tables this clause reads, so
# the derivation would silently have nothing to check against.
s = fresh("n19")
doctor_shadow("N19's renamed POSTED", s, "guests/python/portfolio.py",
              r"\nPOSTED = \[", "\nPOSTED_ROWS = [")
refused(s, "no longer spells RECENT",
        "N19 (a census that lost its subject)")

# N20 — C10: THE BOOK MOVES AND THE LEDGER DOES NOT, which is the way
# the tie-out will actually break — someone edits a holding and never
# reruns the generator. C8 reds beside it (the generator reads BOOK, so
# a regeneration would no longer match the artifact on disk) and that
# is the fix instruction; the fragment demanded here is C10's own, so
# this proves the tie clause fired rather than its neighbour.
s = fresh("n20")
doctor_shadow("N20's moved holding", s, "guests/python/portfolio.py",
              r'\("AAPL", 10, 18000\)', '("AAPL", 11, 18000)')
refused(s, "does not net to",
        "N20 (a book the ledger no longer sums to)")

# N21 — C10's scene half, and the only perturbation in this file that
# reaches C10 ALONE: the artifact and the book still agree, and the
# scene's frozen net line does not.
s = fresh("n21")
doctor_shadow("N21's drifted net line", s,
              "tools/scenes/portfolio.steps",
              r'(expect label@net "net BND )\d+', r"\g<1>21")
refused(s, "the tie-out for account retirement",
        "N21 (a stale tie-out assertion)")

# N22 — C10's other half: the net line survives and the DASHBOARD stops
# saying the same money. A tie-out one screen asserts alone ties
# nothing.
s = fresh("n22")
doctor_shadow("N22's silenced dashboard twin", s,
              "tools/scenes/portfolio.steps",
              r"Account total: \$2370\.00", "Account total: $2370.01")
refused(s, "never asserts",
        "N22 (a tie-out asserted on one screen only)")

# N23 — C10: the guest stops spelling the book this clause nets
# against. The GENERATOR refuses in its own words too (C8 reports that
# refusal), which is the wall on the path nobody can avoid; this is the
# gate half.
s = fresh("n23")
doctor_shadow("N23's renamed BOOK", s, "guests/python/portfolio.py",
              r"\nBOOK = \{", "\nHOLDINGS = {")
refused(s, "no longer spells BOOK",
        "N23 (a tie-out census with no book)")

# N24 — C8's second artifact: the HISTORY is hand-edited while the
# ledger stays honest. A derivation clause that regenerated one of two
# files would call this current, which is the hole the family's second
# artifact opened (2026-08-27).
s = fresh("n24")
doctor_shadow("N24's hand-edited history", s,
              "guests/assets/market/prices.csv",
              r"2026-08-24,VTI,26025", "2026-08-24,VTI,26026")
refused(s, "prices.csv does not match",
        "N24 (a hand-edited price history)")

# N25 — C8: the history is absent while the ledger is present, which is
# every checkout made before this artifact existed.
s = fresh("n25")
(s / "guests/assets/market/prices.csv").unlink()
refused(s, "prices.csv is missing", "N25 (a missing price history)")

# N26 — C11: THE HISTORY STOPS ENDING ON THE BOOK. The book moves and
# the walk does not, which is how the chart's tie-out will actually
# break. C8 reds beside it (the generator reads BOOK), so the fragment
# demanded here is C11's own.
s = fresh("n26")
doctor_shadow("N26's re-priced holding", s,
              "guests/python/portfolio.py",
              r'\("VTI", 6, 26025\)', '("VTI", 6, 26030)')
refused(s, "IS THE DASHBOARD'S PRESENT",
        "N26 (a history that ends off the book)")

# N27 — C11's scene half, and the only perturbation here that reaches
# C11 alone: the artifact and the book still agree, and the chart's
# frozen accessible name does not.
s = fresh("n27")
doctor_shadow("N27's drifted chart summary", s,
              "tools/scenes/portfolio.steps",
              r'now \$10026\.50"', 'now $10026.51"')
refused(s, "the chart's accessible name at rest",
        "N27 (a stale chart assertion)")

# N28 — C11's other half: the chart's last point survives and the
# DASHBOARD stops saying the same money. A tie-out one widget asserts
# alone ties nothing.
s = fresh("n28")
doctor_shadow("N28's silenced dashboard twin", s,
              "tools/scenes/portfolio.steps",
              r"Portfolio: \$10023\.00", "Portfolio: $10023.01")
refused(s, "The chart's tie-out is only a guard",
        "N28 (a chart tie-out asserted alone)")

# N29 — C11: the guest stops spelling the window this clause derives
# the chart's frozen name from.
s = fresh("n29")
doctor_shadow("N29's renamed CHART_DAYS", s,
              "guests/python/portfolio.py",
              r"\nCHART_DAYS = ", "\nCHART_WINDOW = ")
refused(s, "no longer spells CHART_DAYS",
        "N29 (a chart census with no window)")

# N30 — C12: THE CLAMP REMOVED. The wish goes straight through, and on
# Sora that is a `font-weight: 500` no named instance answers: pango
# aborts inside layout and every leg of the `typeface` scene dies with no
# verdict at all. The sheet still reads exactly as its author meant it to.
s = fresh("n30")
doctor_shadow("N30's removed clamp", s, GTK,
              r"Some\(have\) => nearest_weight\(\*wish, have\),",
              "Some(_have) => *wish,")
refused(s, "each wish taken to the nearest instance appears 0 time(s)",
        "N30 (the clamp removed)")

# N31 — C12: THE TIE BROKEN THE OTHER WAY. 500 lands on 400 instead of
# 600, so kaya's medium reads one rung LIGHTER than its regular text and
# nothing anywhere is red — the pixels are the only witness.
s = fresh("n31")
doctor_shadow("N31's inverted tie", s, GTK,
              r"\(have\.abs_diff\(wish\), std::cmp::Reverse\(\*have\)\)",
              "(have.abs_diff(wish), *have)")
refused(s, "the tie broken toward the heavier face appears 0 time(s)",
        "N31 (the tie broken toward the lighter face)")

# N32 — C12: A WISHED WEIGHT WRITTEN STRAIGHT INTO THE PROVIDER, which is
# the shape the defect actually shipped in. Two clauses catch it: the
# re-lowering callsite is gone, and the literal is a weight Sora lacks.
s = fresh("n32")
doctor_shadow("N32's hand-written sheet", s, GTK,
              r"&weight_css_for\(instances\.as_deref\(\)\),",
              '"button, button label { font-weight: 500; }\\n",')
refused(s, "is written as a LITERAL and names a weight",
        "N32 (a wished weight written straight into the provider)")

# N33 — C12: the startup install stops going through the clamp, so a
# brand font that arrives LATE is honoured and one that never arrives
# leaves the wish standing — half the guard, and the half no scene reaches.
s = fresh("n33")
doctor_shadow("N33's raw startup sheet", s, GTK,
              r'load_kaya_css\(&weight_css, "label weights", '
              r'&weight_css_for\(None\), &css_error\);',
              'load_kaya_css(&weight_css, "label weights", "", &css_error);')
refused(s, "the startup sheet lowered through the clamp appears 0 time(s)",
        "N33 (the startup sheet not lowered through the clamp)")

# N34 — C12: the vacuity floor. With no readable variable font the clause
# would pass any stylesheet, so it refuses a verdict instead.
s = fresh("n34")
(s / "guests/assets/fonts/sora-wght.ttf").write_bytes(b"not a font")
refused(s, "a census that reads no font agrees with everything",
        "N34 (no vendored variable font to check against)")

# N35 — C12: a wish silently RE-RULED. The title drops back to regular and
# every lane stays green, because no observable on any backend reads a
# weight — the review page's pixels were the only witness the first time.
s = fresh("n35")
doctor_shadow("N35's re-ruled title wish", s, GTK,
              r'\("headerbar label\.title, windowtitle label\.title", 600\),',
              '("headerbar label.title, windowtitle label.title", 400),')
refused(s, "the ruled wishes appears 0 time(s)",
        "N35 (a wish re-ruled with no ruling)")

# N36 — C12: the sheet installed below libadwaita's own priority, so every
# rule in it loses to the theme and nothing is red anywhere.
s = fresh("n36")
doctor_shadow("N36's demoted sheet", s, GTK,
              r"&weight_css,\n                "
              r"gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,",
              "&weight_css,\n                "
              "gtk4::STYLE_PROVIDER_PRIORITY_FALLBACK,")
refused(s, "the sheet added above libadwaita's own appears 0 time(s)",
        "N36 (the weight sheet below the theme's priority)")

g.negatives_ran(37)

# The vacuity floor rule 5 asks for, over the census the checker walks.
g.counted("files under the asset root",
          [p for p in (ROOT / ASSET_ROOT).rglob("*") if p.is_file()],
          floor=FLOOR)

# ---------------------------------------------------------------------
# The tree as it stands.
out, bad = check(ROOT)
print("\n".join(out))
if bad:
    for b in bad:
        print("check-assets: " + b, file=sys.stderr)
    print("check-assets: FAIL", file=sys.stderr)
    raise SystemExit(1)
g.verdict()
