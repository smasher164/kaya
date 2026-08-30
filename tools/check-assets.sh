#!/usr/bin/env bash

# Dev-shell guard; the marker is the flake fingerprint (CLAUDE.md).
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# THE ASSET ROOT'S DRIFT GATE (docs/assets-plan.md A6, gates 2 and 3).
# `asset(name)` holds one rule in one Rust module, which is true only
# while nothing else resolves an asset and every lane carries the WHOLE
# root — neither checkable by the core, which reads none of those files.
#
# SEVEN CLAUSES.
#
#   C1 PROVENANCE   Every family under the root carries a README saying
#                   what the files are, where they came from, their
#                   licence, and how to regenerate them.
#   C2 CENSUS       The listing is printed with its count, every name is
#                   legal as an asset name, and the count may not fall
#                   below a floor: a census that reads two files agrees
#                   with everything.
#   C3 ONE RESOLVER Nothing outside the core resolves an asset path for
#                   itself. Table-driven, and the table's own claim is
#                   checked: an exemption carries a reason and the
#                   reason has to be about a file that still exists.
#   C4 EVERY LANE   Each of the five lanes either stages the root or
#                   says why it needs nothing, BOTH halves stated rather
#                   than inferred. A lane that stages one FILE is the
#                   shape this convention replaced.
#   C5 WHAT ARRIVED The staging lanes verify what they staged by HASH: a
#                   size check misses a same-length corruption.
#   C6 THE FROZEN    tools/scenes/assets.steps expects the miss
#      CENSUS        sentence's first line, which names every asset the
#                    package carries — the one run-time observation that
#                    a lane staged the WHOLE root. Adding an asset
#                    reddens five lanes, so this clause turns that into
#                    ONE gate failure naming the .steps file.
#   C7 THE APK'S     Android packages assets into `assets/<prefix>/`,
#      PREFIX        read back through AssetManager. Three files spell
#                    that prefix and this holds them equal. THE BYTES
#                    are checked where they are packaged, by
#                    `apk_assets_verify` in run-emulator.sh.
#
# NO FIXTURE ANYWHERE. Every negative below doctors a shadow of the REAL
# tree (docs/traps.md: the wayland seat guard passed vacuously twice
# against a pattern that matched nothing).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

# $1: a tree root to check (the real one, or a doctored shadow).
check() {
    python3 - "$1" <<'PY'
import os
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
bad = []

ASSET_ROOT = "guests/assets"

# ------------------------------------------------------------------ C2
# The listing first: every clause below reads it, and a clause that read
# nothing must not print OK.
assets = []
base = root / ASSET_ROOT
for dirpath, dirnames, filenames in os.walk(base):
    dirnames[:] = sorted(dirnames)
    for fn in sorted(filenames):
        f = pathlib.Path(dirpath) / fn
        if f.is_symlink():
            bad.append(f"{f.relative_to(root).as_posix()}: is a symlink — an asset "
                       "name may not escape the root, and a link inside it is that "
                       "escape with the filesystem doing the walking")
            continue
        if not f.is_file():
            continue
        assets.append(f.relative_to(base).as_posix())
assets.sort()

# The floor. Not "some number": the families this tree is known to carry,
# so a walk that lost one says which.
FLOOR = 6
KNOWN = ["fonts/sora-wght.ttf", "icons/kaya-mark.png", "identity.toml"]
print(f"assets: {len(assets)} under {ASSET_ROOT}: " + ", ".join(assets))
if len(assets) < FLOOR:
    bad.append(f"the asset root lists {len(assets)} files, below the floor of "
               f"{FLOOR} — a census that reads almost nothing agrees with "
               "almost anything, so this refuses a verdict rather than "
               "printing one")
for want in KNOWN:
    if want not in assets:
        bad.append(f"{want} is not in the asset root's listing — it is one of the "
                   "files this gate knows are there, so either it moved (and this "
                   "list moves with it) or the walk is reading the wrong place")

LEGAL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*(?:/[A-Za-z0-9][A-Za-z0-9._-]*)*$")
for name in assets:
    if not LEGAL.match(name) or ".." in name.split("/"):
        bad.append(f"{name}: is not spellable as an asset name — a name is a "
                   "relative path under the root in `/`-separated segments, and "
                   "the core refuses anything else at the call "
                   "(crates/kaya/src/assets.rs, wall 1)")
    if name.count("/") > 1:
        bad.append(f"{name}: nests deeper than one family — the convention is "
                   "flat families (docs/assets-plan.md A2), because the directory "
                   "listing is the manifest and a deep tree is an index nobody "
                   "wrote down")

# ------------------------------------------------------------------ C1
# Every family carries a README. A family is a directory holding
# anything that is not documentation.
families = {}
for name in assets:
    if "/" not in name:
        continue
    family, leaf = name.split("/", 1)
    families.setdefault(family, []).append(leaf)
if not families:
    bad.append("the asset root has no family directories at all — this clause "
               "read nothing and would agree with any tree")
WANTS = [("what the files are", ("bytes", "byte", "is —", "—")),
         ("where they came from", ("came from", "upstream", "provenance",
                                   "vendored", "written by", "committed")),
         ("the licence", ("licence", "license", "OFL", "no licence",
                          "no upstream")),
         ("how to regenerate them", ("regenerate", "regeneration", "makepri",
                                     "reproduce", "nobody knows"))]
for family, leaves in sorted(families.items()):
    payload = [x for x in leaves if not x.lower().endswith(".md")]
    if not payload:
        continue
    readme = base / family / "README.md"
    if not readme.is_file():
        bad.append(f"{ASSET_ROOT}/{family}/ carries {len(payload)} vendored "
                   f"file(s) ({', '.join(sorted(payload))}) and no README.md — "
                   "a vendored binary with no provenance is the one hygiene "
                   "question a vendored binary asks, and this is where it is "
                   "answered (docs/assets-plan.md A2)")
        continue
    text = readme.read_text(encoding="utf-8", errors="replace")
    for label, needles in WANTS:
        if not any(n.lower() in text.lower() for n in needles):
            bad.append(f"{ASSET_ROOT}/{family}/README.md never says {label} — "
                       "the four things a family README is for are what the "
                       "files are, where they came from, their licence, and how "
                       "to regenerate them. An honest \"nobody knows\" counts; "
                       "silence does not")

# ------------------------------------------------------------------ C3
# One resolver. Nothing outside the core may spell an asset's path or
# read an asset environment variable for itself.
#
# Each exemption names a file and a reason, and a stale one — file gone,
# or no longer matching — is itself a failure.
EXEMPT = {
    "crates/kaya/src/assets.rs":
        "the core's own resolver — this is the one place the rule lives",
    "crates/kaya/src/winui/mod.rs":
        "the harness-only include_bytes! of the vendored font, so the "
        "DirectWrite name-table tests measure a real font on whatever "
        "machine runs them; a test fixture, never a runtime read",
    "android/build.gradle.kts":
        "the APK's BUILD reads guests/assets/identity.toml, which is the "
        "declaration's second reader by ruling 4 and not a runtime asset "
        "resolution — no program has started when it runs",
    "bindings/python/kaya_app_checks.py":
        "a tier-1 check that asserts what the bindings emit; the path it names "
        "is test input, and the core is never entered",
}
SEARCH_ROOTS = ["guests", "bindings", "crates", "swift", "android"]
PRUNE = {".git", ".gradle", ".build", "build", "target", "target-linux",
         "_build", "_build-linux", "obj", "bin", "node_modules",
         "__pycache__", "DerivedData", "dist", "dist-newstyle"}
CODE = (".rs", ".py", ".go", ".cs", ".java", ".swift", ".ml", ".mli", ".hs",
        ".c", ".h", ".kt", ".kts")
ASSET_PATH = re.compile(r"guests/assets/")
ASSET_ENV = re.compile(r"KAYA_(?:FONT_FILE|ICON_FILE|ASSET_DIR)")

# THIS CLAUSE READS CODE AND NOT PROSE: a header explaining what a file
# USED to do is exactly the sentence a naive grep calls a violation, and
# a gate that fires on its own subject's documentation gets muted.
LINE_COMMENT = {".rs": "//", ".go": "//", ".cs": "//", ".java": "//",
                ".swift": "//", ".kt": "//", ".kts": "//", ".c": "//",
                ".h": "//", ".py": "#", ".hs": "--"}
DOCSTRING = re.compile(r'"""(?:.|\n)*?"""')


def code_only(text, ext):
    """The file with its comments and its docstring prose removed.

    LINE COMMENTS ONLY, PLUS PYTHON'S TRIPLE QUOTES, and the omission is
    the interesting part. A naive `/* ... */` stripper was written first
    and this gate's own stale-exemption clause caught it inside ten
    minutes: crates/kaya/src/winui/mod.rs stopped matching, because a
    `/*` somewhere in 15000 lines of Windows code opened a region the
    stripper ate to the next `*/`, taking the real `include_bytes!` with
    it. A clause that reads LESS of a file than it thinks is exactly the
    failure this whole gate exists against, so block comments are left
    in and a file that names an asset inside one is a finding a human
    resolves by moving the sentence or adding an exemption. Every false
    positive this slice actually produced was a `//` header or a Python
    docstring.

    It does not lex string literals either, which is RIGHT: a hard-coded
    "guests/assets/..." in a string is precisely the second resolver
    this clause refuses.
    """
    if ext == ".py":
        text = DOCSTRING.sub("", text)
    marker = LINE_COMMENT.get(ext)
    if marker:
        text = "\n".join(line.split(marker, 1)[0] for line in text.splitlines())
    return text


resolvers = 0
for r in SEARCH_ROOTS:
    for dirpath, dirnames, filenames in os.walk(root / r):
        dirnames[:] = sorted(d for d in dirnames if d not in PRUNE)
        for fn in sorted(filenames):
            if os.path.splitext(fn)[1] not in CODE:
                continue
            f = pathlib.Path(dirpath) / fn
            rel = f.relative_to(root).as_posix()
            text = code_only(f.read_text(encoding="utf-8", errors="replace"),
                             os.path.splitext(fn)[1])
            hit_path = ASSET_PATH.search(text) is not None
            # A BINDING MAY NAME THE VARIABLE AND MAY NOT READ A PATH:
            # KAYA_ASSET_DIR is part of the surface every binding
            # documents, so only the env half is relaxed.
            hit_env = (not rel.startswith("bindings/")
                       and ASSET_ENV.search(text) is not None)
            if not (hit_path or hit_env):
                continue
            resolvers += 1
            if rel in EXEMPT:
                continue
            what = "an asset path" if hit_path else "an asset environment variable"
            bad.append(f"{rel}: names {what} for itself. The resolution rule and "
                       "its failure sentence live ONCE, in "
                       "crates/kaya/src/assets.rs, and reach every language "
                       "through `asset(name)` — a second reader here is the "
                       "eight-copies problem starting again one file at a time. "
                       "If this file genuinely cannot use the call, add it to "
                       "this gate's EXEMPT table with the reason")
if resolvers == 0:
    bad.append("no file anywhere names an asset path or an asset environment "
               "variable — this clause read NOTHING, so it would agree with a "
               "tree in which every guest resolved its own assets")
for rel, why in sorted(EXEMPT.items()):
    path = root / rel
    if not path.is_file():
        bad.append(f"{rel} is exempted from the one-resolver rule but does not "
                   "exist — delete the exemption rather than leaving a rule "
                   "that applies to nothing")
        continue
    if len(why.strip()) < 20:
        bad.append(f"{rel} is exempted with no real reason given ({why!r})")
    # AND THE EXEMPTION MUST STILL BE EARNED: a file that stopped
    # resolving leaves a permission behind it, and the next edit to that
    # file inherits it silently.
    body = code_only(path.read_text(encoding="utf-8", errors="replace"),
                     os.path.splitext(rel)[1])
    if not (ASSET_PATH.search(body) or (not rel.startswith("bindings/")
                                        and ASSET_ENV.search(body))):
        bad.append(f"{rel} is exempted from the one-resolver rule and no longer "
                   "needs to be — it resolves nothing. Delete the entry: an "
                   "exemption nobody re-read is how a rule stops applying "
                   "without anyone deciding that it should")

# ------------------------------------------------------------------ C4
# Every lane, both halves stated. STAGES: copy the ROOT rather than a
# file under it. NOTHING_NEEDED: say why, at the staging site.
# lane -> (why it stages, the token that proves HOW the core will find
# what it staged). The token differs per lane because the mechanism
# does: iOS needs no variable at all.
STAGES = {
    "tools/deploy-win.sh": (
        "the VM has no repo; the deploy copies the root into the mirror path "
        "every run, outside the deploy stamp",
        "KAYA_ASSET_DIR"),
    "tools/android/run-emulator.sh": (
        "a device has no repo; the root is pushed to /data/local/tmp and "
        "named in each leg's intent",
        "KAYA_ASSET_DIR"),
    "tools/ios/run-sim.sh": (
        "an app in the simulator has no repo and its cwd is /; the root goes "
        "into the bundle, which is both this lane's staging and what a "
        "shipped iOS app actually does — so the core finds it through "
        "Bundle.main and no variable is involved",
        "$ASSET_SRC"),
}
NOTHING_NEEDED = {
    "tools/validate-mac.sh":
        "the lane runs from the repo root, so the core's repo-relative default "
        "resolves with no environment at all",
    "tools/linux/run-suites.sh":
        "the repo is bind-mounted at /work and this script runs from there, so "
        "the default resolves inside the container",
}
for rel, (_why, token) in sorted(STAGES.items()):
    path = root / rel
    if not path.is_file():
        bad.append(f"{rel} is listed as an asset stager and does not exist")
        continue
    text = path.read_text(encoding="utf-8", errors="replace")
    if token not in text:
        bad.append(f"{rel} stages assets for a guest that cannot see the repo "
                   f"and never names {token} — so whatever it copied, nothing "
                   "connects it to the route the core will actually take, and "
                   "every asset call on that machine resolves to the "
                   "compile-time repo path it does not have")
    # A COPY of one file under the root, never a mere mention of one:
    # the deploy hashes the resource index by path, which is a READ.
    COPY = ("scp ", "adb push", "cp ", "copyTo", "install ", "rsync")
    for line in text.splitlines():
        if not re.search(r"guests/assets/(fonts|icons|win)/[A-Za-z0-9*]", line):
            continue
        if not any(verb in line for verb in COPY):
            continue
        bad.append(f"{rel} stages a FILE under the asset root rather than the "
                   f"root itself ({line.strip()[:70]}). A lane stages the root "
                   "as a unit (docs/assets-plan.md A5.1): per-file staging is "
                   "what made every new asset cost five more lines in five "
                   "scripts, and the line that got forgotten failed on the "
                   "lane furthest from the change")
for rel, why in sorted(NOTHING_NEEDED.items()):
    path = root / rel
    if not path.is_file():
        bad.append(f"{rel} is listed as needing no asset staging and does not exist")
        continue
    text = path.read_text(encoding="utf-8", errors="replace")
    if "guests/assets" not in text:
        bad.append(f"{rel} needs no asset staging ({why}) and never says so. "
                   "The reason belongs at the site rather than in a reader's "
                   "head: the next person to add an asset reads this file "
                   "looking for the staging line, and its absence has to be "
                   "an answer rather than a gap (docs/assets-plan.md A5.4)")

# ------------------------------------------------------------------ C5
# What arrived is what was sent, by HASH. A size check passes a
# same-length corruption, which is precisely what a truncated-then-
# padded push and a re-encoding packaging step both produce.
for rel in sorted(STAGES):
    path = root / rel
    if not path.is_file():
        continue
    text = path.read_text(encoding="utf-8", errors="replace")
    if "shasum" not in text and "sha256" not in text.lower():
        bad.append(f"{rel} stages the asset root and never hashes what arrived "
                   "against what it sent. A size comparison is the shape this "
                   "replaced (docs/assets-plan.md A5.1) and it agrees with any "
                   "corruption that preserved the length")

# ------------------------------------------------------------------ C6
# The conformance scene's FROZEN CENSUS equals the root's listing, which
# is what forces a lane to stage the WHOLE root (docs/assets-plan.md
# A5.1).
SCENE = "tools/scenes/assets.steps"
scene_path = root / SCENE
if not scene_path.is_file():
    bad.append(f"{SCENE} is not there — it is the only run-time observation of the "
               "asset census, and without it nothing checks that a lane staged the "
               "whole root rather than one file (docs/assets-plan.md A5.1)")
else:
    scene = scene_path.read_text(encoding="utf-8", errors="replace")
    statements = [ln.strip() for ln in scene.split("\n") if not ln.strip().startswith("#")]
    frozen = [ln for ln in statements if "the package carries" in ln]
    if not frozen:
        bad.append(f"{SCENE} freezes no census — its `expect label#1` is the whole "
                   "reason the scene exists, and a scene that stopped asserting it "
                   "would keep passing on a lane that staged one file")
    for line in frozen:
        m = re.search(r"the package carries (.+)\"\s*$", line)
        if not m:
            bad.append(f"{SCENE}: this gate could not read the census out of "
                       f"{line!r} — the expectation moved and this clause is now "
                       "reading nothing, which agrees with anything")
            continue
        named = [p.strip() for p in m.group(1).split(",")]
        if named != assets:
            bad.append(f"{SCENE} freezes a census of {len(named)} assets and the root "
                       f"carries {len(assets)}. Frozen: {', '.join(named)}. Root: "
                       f"{', '.join(assets)}. The scene's string is the miss "
                       "sentence's first line verbatim, so it moves with the root — "
                       "and it is deliberately expensive to change, because every "
                       "lane has to stage what it names")
        missing = re.search(r"no asset named \"([^\"]+)\"", line)
        if missing and missing.group(1) in assets:
            bad.append(f"{SCENE} names {missing.group(1)!r} as the asset that is NOT "
                       "there, and the root now carries it — the scene would then be "
                       "asserting a sentence the core will never print")

# ------------------------------------------------------------------ C7
# The APK carries the root under ONE prefix that three files spell. The
# prefix exists because an app's AssetManager root listing is not
# exclusively the app's (framework directories are visible there, and
# every AAR merges its own `assets/` in), which would make C6's frozen
# census a fact about the toolchain.
#
# THE BYTES ARE CHECKED WHERE THEY ARE PACKAGED, by run-emulator.sh's
# `apk_assets_verify`. This clause holds only what a built artifact
# cannot show: that the three spellings are one string.
APK_PREFIX_SITES = {
    "android/kaya/src/main/kotlin/dev/kaya/KayaAssets.kt":
        re.compile(r"""const\s+val\s+ROOT\s*=\s*"([^"]+)\""""),
    "android/build.gradle.kts":
        re.compile(r"""val\s+kayaAssetPrefix\s*=\s*"([^"]+)\""""),
    "tools/android/run-emulator.sh":
        re.compile(r"""^APK_ASSET_PREFIX=([A-Za-z0-9._-]+)""", re.MULTILINE),
}
prefixes = {}
for rel, pattern in sorted(APK_PREFIX_SITES.items()):
    path = root / rel
    if not path.is_file():
        bad.append(f"{rel} is not there and it is one of the three files that spell "
                   "the APK's asset prefix — deleting one of the three is how the "
                   "packaged layout and the reader stop agreeing")
        continue
    m = pattern.search(path.read_text(encoding="utf-8", errors="replace"))
    if not m:
        bad.append(f"{rel} no longer spells the APK asset prefix in the form this "
                   "gate reads. It is one of three hand-written copies of one "
                   "string, and a copy this cannot see is a copy nothing holds")
        continue
    prefixes[rel] = m.group(1)
if len(set(prefixes.values())) > 1:
    bad.append("the APK's asset prefix is spelled differently in "
               + "; ".join(f"{k} = {v!r}" for k, v in sorted(prefixes.items()))
               + " — the build copies into one, the reader reads the other, and the "
                 "miss sentence would name a census the app cannot produce")
GRADLE = "android/build.gradle.kts"
gradle_path = root / GRADLE
if gradle_path.is_file():
    gradle = gradle_path.read_text(encoding="utf-8", errors="replace")
    if "assets.srcDir" not in gradle:
        bad.append(f"{GRADLE} never adds an assets source directory — an APK that "
                   "carries no assets/ resolves nothing through AssetManager, and "
                   "the leg that runs without a staged root would fall through to a "
                   "path the device does not have (docs/assets-plan.md A4)")

# ------------------------------------------------------------------ C8
# The market artifact is DERIVED (maintainer 2026-08-24): the generator
# is committed, the csv is not. The honest check regenerates into a
# scratch and byte-compares — target/'s stamp is only --ensure's fast
# path and is deliberately not read here (shadows carry no target/).
import subprocess
import tempfile
gen = root / "tools" / "gen-market.py"
market = root / "guests" / "assets" / "market"
art = market / "transactions.csv"
hist = market / "prices.csv"
# BOTH artifacts, because the family grew a second one (2026-08-27) and a
# clause that regenerated one of two would call a stale history current.
DERIVED = [("transactions.csv", art), ("prices.csv", hist)]
if not gen.is_file():
    bad.append("tools/gen-market.py is gone while the market family exists — "
               "the derived artifacts would have no regeneration story")
elif [n for n, p in DERIVED if not p.is_file()]:
    for name, path in DERIVED:
        if not path.is_file():
            bad.append(f"guests/assets/market/{name} is missing — it is "
                       "derived, never committed: run `python3 "
                       "tools/gen-market.py --ensure` (docs, "
                       "guests/assets/market/README.md)")
else:
    with tempfile.TemporaryDirectory() as td:
        scratch = pathlib.Path(td)
        env = dict(os.environ, KAYA_GEN_MARKET_DIR=str(scratch))
        r = subprocess.run([sys.executable, str(gen)], env=env,
                           capture_output=True, text=True)
        if r.returncode != 0:
            bad.append("tools/gen-market.py failed to run for the derivation "
                       "check: " + r.stderr.strip()[:200])
        else:
            for name, path in DERIVED:
                fresh = scratch / name
                if not fresh.is_file():
                    bad.append(f"tools/gen-market.py wrote no {name} into the "
                               "scratch directory, so the derivation check "
                               "had nothing to compare that artifact against")
                elif fresh.read_bytes() != path.read_bytes():
                    bad.append(f"guests/assets/market/{name} does not match "
                               "what tools/gen-market.py generates — the "
                               "artifact is derived, never hand-edited: run "
                               "`python3 tools/gen-market.py --ensure`")

# ------------------------------------------------------------------ C9
# THE SCENE IS DERIVED FROM THE ARTIFACT TOO. C8 holds the CSV to its
# generator; nothing held the transactions view's byte-frozen scene to
# the CSV, so retuning the generator left it asserting last month's
# ledger — a red that would arrive on every windowed lane at once, with
# five failing strings and no file named. This re-derives every
# expectation that comes from the artifact and prints the line the CSV
# asks for.
#
#
# THE SCENE SEES THE LEDGER AFTER THE TICK, so the derivation is the
# CSV plus what "Day tick" posts. POSTED, RECENT, BOOK, TICK and FILTERS
# are READ OUT OF THE GUEST by ast (importing it would build a window at
# import time); a second copy here would be one more thing to drift. The
# money rule is the one line still written twice, and a guest that moves
# it reddens this clause naming the file. C10 rides in the same block
# because it wants the same five tables.
SCENE = "tools/scenes/portfolio.steps"
GUEST = "guests/python/portfolio.py"
scene_path = root / SCENE
guest_path = root / GUEST
if art.is_file() and not scene_path.is_file():
    bad.append(f"{SCENE} is gone while the market artifact whose rows it "
               "freezes is still here — the transactions view's scene is the "
               "only run-time observation that the ledger arrived whole")
elif art.is_file() and not guest_path.is_file():
    bad.append(f"{GUEST} is gone while the market artifact it reads is still "
               "here — this clause reads POSTED and RECENT out of that guest "
               "and cannot derive the scene without it")
elif art.is_file():
    import ast
    guest_tree = ast.parse(guest_path.read_text(), GUEST)

    def _const(name):
        """The guest's own table, by name. A reader that cannot find its
        subject agrees with anything, so a missing name is a red."""
        for node in guest_tree.body:
            if (isinstance(node, ast.Assign) and len(node.targets) == 1
                    and isinstance(node.targets[0], ast.Name)
                    and node.targets[0].id == name):
                try:
                    return ast.literal_eval(node.value)
                except (ValueError, SyntaxError):
                    return None
        return None

    RECENT = _const("RECENT")
    POSTED = _const("POSTED")
    BOOK = _const("BOOK")
    TICK = _const("TICK")
    FILTERS = _const("FILTERS")
    if not isinstance(RECENT, int) or not isinstance(POSTED, list):
        bad.append(f"{GUEST} no longer spells RECENT (an int) and POSTED (a "
                   "list of literal rows) at module scope — this clause reads "
                   "both to derive the scene, and a reader that finds neither "
                   "would agree with any scene at all")
    elif not isinstance(BOOK, dict) or not isinstance(TICK, dict) \
            or not isinstance(FILTERS, list):
        bad.append(f"{GUEST} no longer spells BOOK (the holdings), TICK (the "
                   "per-ticker delta) and FILTERS (the view's account filter) "
                   "at module scope — C10 nets the ledger against that book "
                   "and a reader that cannot find it would call any data tied")
    else:
        # The guest's own row shape: date, account, ticker, side, qty,
        # total_cents. POSTED is written in it, so the tick's rows need
        # no arithmetic here.
        rows = [(d, a, t, s, int(q), int(tot))
                for d, a, t, s, q, _p, tot in
                (line.split(",") for line in art.read_text().splitlines()[1:])]
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

        scene_text = scene_path.read_text()
        derived = [
            (f'expect label#1 "Transactions: {csv_len}"',
             "the dashboard's count of the book as the artifact has it"),
            (f'expect label#1 "Transactions: {len(rows)}"',
             "the dashboard's count after the tick posted its rows"),
            (f'expect label@count "{len(rows)} of {len(rows)} transactions"',
             "the ledger's declared size"),
            (f'expect label@first "{_edge("first", rows[0])}"',
             "the ledger's first row"),
            (f'expect label@last "{_edge("last", rows[-1])}"',
             "the ledger's last row"),
            ('expect_rows column@recent "'
             + "|".join(_cells(r) for r in rows[-RECENT:]) + '"',
             f"the {RECENT} most recent rows"),
        ]

        # ---------------------------------------------------------- C10
        # THE TIE-OUT (ruled 2026-08-26): an account's holdings ARE the
        # sum of its transactions. The generator holds that at write
        # time and refuses itself if it slips; this holds the ARTIFACT
        # ON DISK to it, which is the half a doctored or half-written
        # CSV can break with the generator innocent. Then it derives the
        # `label@net` lines the scene freezes, and requires the MONEY in
        # each to be a string the dashboard also says — a tie-out
        # asserted nowhere is not a guard (invariant 3).
        holdings = {a: {t: q for t, q, _ in hs} for a, (_n, hs) in BOOK.items()}
        anchors = {t: c for _n, hs in BOOK.values() for t, _q, c in hs}
        live = {t: c + TICK.get(t, 0) for t, c in anchors.items()}
        net = {}
        for _d, account, ticker, side, qty, _tot in rows:
            if side in ("buy", "sell"):
                net[(account, ticker)] = (net.get((account, ticker), 0)
                                          + (qty if side == "buy" else -qty))
        pairs = sorted(set(net) | {(a, t) for a in holdings for t in anchors})
        for account, ticker in pairs:
            want = holdings.get(account, {}).get(ticker, 0)
            got = net.get((account, ticker), 0)
            if got != want:
                bad.append(
                    f"guests/assets/market/transactions.csv does not net to "
                    f"{GUEST}'s BOOK: {account}/{ticker} nets to {got} and the "
                    f"book holds {want}. THE LEDGER IS GENERATED TO TIE (ruled "
                    "2026-08-26, docs/deferred.md) — the two screens claim the "
                    "same positions, so a ledger that disagrees makes the "
                    "dashboard a fiction. Regenerate: `python3 "
                    "tools/gen-market.py --ensure`")

        # ---------------------------------------------------------- C11
        # THE HISTORY TIES TO THE SAME BOOK, one column over
        # (2026-08-27, docs/canvas-plan.md §10): prices.csv's LAST DAY is
        # the dashboard's live prices, so the chart's right edge is the
        # money label#0 shows. Held here on the ARTIFACT ON DISK, the
        # half a doctored or half-written file breaks with the generator
        # innocent — and then the scene's own chart lines are DERIVED
        # from that artifact, C9's rule for the ledger applied to the
        # chart: retuning the walk without moving the scene is a red
        # naming this file instead of three failing lanes.
        CHART_DAYS = _const("CHART_DAYS")
        if not hist.is_file():
            pass  # C8 already named the missing artifact.
        elif not isinstance(CHART_DAYS, int):
            bad.append(f"{GUEST} no longer spells CHART_DAYS (an int) at "
                       "module scope — C11 derives the chart's frozen "
                       "accessible name from that window, and a reader that "
                       "cannot find it would agree with any chart at all")
        else:
            hist_days, walk = [], {}
            for line in hist.read_text().splitlines()[1:]:
                date, ticker, cents = line.split(",")
                if not hist_days or hist_days[-1] != date:
                    hist_days.append(date)
                walk.setdefault(ticker, []).append(int(cents))
            for ticker, anchor in sorted(anchors.items()):
                end = walk.get(ticker, [None])[-1]
                if end != anchor:
                    bad.append(
                        f"guests/assets/market/prices.csv ends {ticker} at "
                        f"{end} and {GUEST}'s BOOK prices it at {anchor}. THE "
                        "LAST DAY OF HISTORY IS THE DASHBOARD'S PRESENT "
                        "(docs/canvas-plan.md §10) — a history that ends "
                        "anywhere else draws a plausible chart nobody can see "
                        "is wrong. Regenerate: `python3 tools/gen-market.py "
                        "--ensure`")
            qty = {t: q for _n, hs in BOOK.values() for t, q, _c in hs}
            first = len(hist_days) - CHART_DAYS
            if first < 0:
                bad.append("guests/assets/market/prices.csv holds "
                           f"{len(hist_days)} days and {GUEST} charts "
                           f"{CHART_DAYS}")
            else:
                window = [sum(q * walk[t][first + i] for t, q in qty.items())
                          for i in range(CHART_DAYS)]
                for last, when in ((sum(q * anchors[t] for t, q in qty.items()),
                                    "at rest"),
                                   (sum(q * live[t] for t, q in qty.items()),
                                    "after the tick")):
                    series = window[:-1] + [last]
                    derived.append((
                        f'expect_ax canvas@chart "image/Portfolio value, '
                        f'{CHART_DAYS} days to {hist_days[-1]}, '
                        f'{_money(min(series))} to {_money(max(series))}, '
                        f'now {_money(last)}"',
                        f"the chart's accessible name {when}"))
                    # The chart's own tie-out: its right edge is money the
                    # dashboard says out loud on the same screen.
                    twin = f'"Portfolio: {_money(last)}"'
                    if twin not in scene_text:
                        bad.append(
                            f"{SCENE} freezes a chart whose last point is "
                            f"{_money(last)} {when} and never asserts {twin} "
                            "beside it. The chart's tie-out is only a guard "
                            "while ONE scene says the same money twice "
                            "(docs/canvas-plan.md §10)")

        def _net_line(subset):
            held = {}
            for _d, _a, ticker, side, qty, _tot in subset:
                if side in ("buy", "sell"):
                    held[ticker] = (held.get(ticker, 0)
                                    + (qty if side == "buy" else -qty))
            held = {t: q for t, q in held.items() if q}
            if not held:
                return "net — = $0.00", 0
            value = sum(q * live[t] for t, q in held.items())
            return ("net " + ", ".join(f"{t} {held[t]}" for t in sorted(held))
                    + f" = {_money(value)}"), value

        # Index 0 of FILTERS is "no filter", which the freshly pushed
        # view is in; every other index the scene actually chooses is
        # read out of the scene rather than assumed.
        chosen = {0} | {int(n) for n in
                        re.findall(r"^choose select#0 (\d+)", scene_text,
                                   re.M)}
        for index in sorted(chosen):
            if index >= len(FILTERS):
                bad.append(f"{SCENE} chooses filter #{index} and {GUEST}'s "
                           f"FILTERS has {len(FILTERS)} entries")
                continue
            account = FILTERS[index][1]
            subset = [r for r in rows if account is None or r[1] == account]
            line, value = _net_line(subset)
            derived.append((f'expect label@net "{line}"',
                            "the tie-out for "
                            + (f"account {account}" if account else
                               "the whole book")))
            # The other half of the tie: that money is the DASHBOARD's,
            # so the scene must say it on both screens.
            twin = (f'"Account total: {_money(value)}"' if account
                    else f'"Portfolio: {_money(value)}"')
            if twin not in scene_text:
                bad.append(
                    f"{SCENE} freezes a net line worth {_money(value)} for "
                    + (f"account {account}" if account else "the whole book")
                    + f" and never asserts {twin} on the dashboard. The "
                    "tie-out is only a guard while ONE scene says the same "
                    "money on both screens (docs/portfolio-plan.md §6)")

        for line, what in derived:
            if line not in scene_text:
                bad.append(f"{SCENE} no longer freezes {what} the way the "
                           "generated artifact has it. That scene is DERIVED "
                           "from guests/assets/market/transactions.csv and the "
                           f"guest's own POSTED — move the expectation, never "
                           f"the artifact. The line the data asks for is:\n"
                           f"    {line}")

for b in bad:
    print("check-assets: " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
}

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# <destination> -> a shadow root of symlinks the checker can read.
# Shared verbatim with tools/check-app-identity.sh but for the roots.
shadow() {
    python3 -c '
import os
import pathlib
import shutil
import sys

root, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
ROOTS = ["guests", "tools", "android", "swift", "crates", "bindings"]
PRUNE = {".git", ".gradle", ".build", "build", "target", "target-linux",
         "_build", "_build-linux", "obj", "bin", "node_modules",
         "__pycache__", "DerivedData", "dist", "dist-newstyle"}
n = 0
for r in ROOTS:
    for dirpath, dirnames, filenames in os.walk(root / r):
        dirnames[:] = sorted(d for d in dirnames if d not in PRUNE)
        for fn in sorted(filenames):
            f = pathlib.Path(dirpath) / fn
            if not f.is_file():
                continue
            out = dst / f.relative_to(root)
            out.parent.mkdir(parents=True, exist_ok=True)
            # THE ASSET ROOT IS COPIED, EVERYTHING ELSE IS LINKED: C2
            # refuses a symlink inside the root, so an all-links shadow
            # would fail that clause for a reason belonging to the
            # shadow rather than to the perturbation.
            if f.relative_to(root).as_posix().startswith("guests/assets/"):
                shutil.copyfile(f, out)
            else:
                os.symlink(f, out)
            n += 1
if n == 0:
    sys.exit("check-assets: SELF-TEST FAIL (the shadow root is empty)")
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
    echo "check-assets: SELF-TEST FAIL ($2 applied $1 times, want at" \
        "least 1 — an unchanged copy cannot prove the rule fires)" >&2
    exit 1
}

refuses() { # <shadow> <want-fragment> <label>
    local out
    out="$(check "$1" 2>&1)" && {
        echo "check-assets: SELF-TEST FAIL ($3 passed)" >&2
        exit 1
    }
    case "$out" in
        *"$2"*) ;;
        *)
            echo "check-assets: SELF-TEST FAIL ($3 failed for another reason:" >&2
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
# an artifact of the copy rather than of the perturbation.
base="$(fresh base)"
if ! out="$(check "$base" 2>&1)"; then
    echo "$out" >&2
    echo "check-assets: FAIL — refused before any perturbation, so this is the" \
        "tree and not the self-test" >&2
    exit 1
fi

# N1 — C1: a family loses its README.
s="$(fresh n1)"
rm -f "$s/guests/assets/win/README.md"
refuses "$s" "and no README.md" "N1 (a family with no provenance)"

# N2 — C1: a README stops answering one of its four questions.
s="$(fresh n2)"
hits="$(doctor "$s" guests/assets/fonts/README.md '(?i)licence|license|\bOFL\b' 'permission')"
applied "$hits" "N2's licence redaction"
refuses "$s" "never says the licence" "N2 (a README that drops its licence)"

# N3 — C3: a guest resolves an asset path for itself again.
s="$(fresh n3)"
hits="$(doctor "$s" guests/rust/typeface.rs 'use kaya::Occurrence;' \
    'use kaya::Occurrence;\nconst FONT: \&str = "guests/assets/fonts/sora-wght.ttf";')"
applied "$hits" "N3's re-introduced path"
refuses "$s" "names an asset path for itself" "N3 (a second resolver)"

# N4 — C4: a stager copies a FILE under the root rather than the root.
s="$(fresh n4)"
hits="$(doctor "$s" tools/deploy-win.sh 'run_ssh' \
    'scp guests/assets/fonts/sora-wght.ttf ignored\nrun_ssh')"
applied "$hits" "N4's per-file staging"
refuses "$s" "stages a FILE under the asset root" "N4 (per-file staging)"

# N5 — C4: a lane that needs nothing stops saying so.
s="$(fresh n5)"
hits="$(doctor "$s" tools/linux/run-suites.sh 'guests/assets' 'guests/somewhere')"
applied "$hits" "N5's redacted reason"
refuses "$s" "needs no asset staging" "N5 (an unexplained absence)"

# N6 — C2: the census floor refuses a root that lost most of itself.
# EVERYTHING BUT identity.toml GOES, not a named list: a named list is
# sized against today's root, and the day two small files joined the
# root the deletions stopped reaching the floor and this self-test
# failed sideways (2026-08-19, the a11y stand-in picture and its
# family README).
s="$(fresh n6)"
find "$s/guests/assets" -type f ! -name identity.toml -delete
refuses "$s" "below the floor of" "N6 (a census that reads almost nothing)"

# N7 — C5: a stager verifies by size rather than by hash.
s="$(fresh n7)"
hits="$(doctor "$s" tools/android/run-emulator.sh '(?i)sha256sum|shasum|sha256' 'wc -c')"
applied "$hits" "N7's hash removal"
refuses "$s" "never hashes what arrived" "N7 (a size check standing in for a hash)"

# N8 — C6: the root gains an asset and the scene's frozen census does
# not. Without the clause the first notice is five red lanes, each
# blaming a scene rather than the file that was added.
s="$(fresh n8)"
printf 'a second font nobody told the scene about\n' >"$s/guests/assets/fonts/extra.bin"
refuses "$s" "freezes a census of" "N8 (an asset the scene does not name)"

# N9 — C6: the scene stops freezing a census at all — how the expensive
# expectation gets quietly dropped rather than updated.
s="$(fresh n9)"
hits="$(doctor "$s" tools/scenes/assets.steps 'the package carries' 'the package holds')"
applied "$hits" "N9's census removal"
refuses "$s" "freezes no census" "N9 (a scene that stopped asserting the census)"

# N10 — C7: the APK's prefix is spelled differently in two of the three
# files, so the build copies into one directory and the reader reads
# another.
s="$(fresh n10)"
hits="$(doctor "$s" android/kaya/src/main/kotlin/dev/kaya/KayaAssets.kt \
    'const val ROOT = "kaya"' 'const val ROOT = "kaya-assets"')"
applied "$hits" "N10's prefix rename"
refuses "$s" "asset prefix is spelled differently" "N10 (three files, two prefixes)"

# N11 — C7: the APK stops carrying assets at all, and the failure names
# a directory rather than the packaging step that stopped packaging.
s="$(fresh n11)"
hits="$(doctor "$s" android/build.gradle.kts 'assets\.srcDir' 'assets.ignored')"
applied "$hits" "N11's removed assets source directory"
refuses "$s" "never adds an assets source directory" "N11 (an APK carrying no assets)"

# N12 — C8: the generator's seed moves while the artifact stays — a
# stale derived artifact must be refused with the regeneration named.
s="$(fresh n12)"
hits="$(doctor "$s" tools/gen-market.py '0x6B617961' '0x6B617962')"
applied "$hits" "N12's reseeded generator"
refuses "$s" "does not match what tools/gen-market.py generates" "N12 (a stale derived artifact)"

# N13 — C8: the artifact is absent entirely (the fresh-clone state
# before any build) and the refusal names the ensure command.
s="$(fresh n13)"
rm "$s/guests/assets/market/transactions.csv"
refuses "$s" "derived, never committed" "N13 (a missing derived artifact)"

# N14 — C9: the scene's frozen last row drifts from the artifact's. The
# SCENE is doctored rather than the CSV, so C8 stays green and this red
# can only be C9's.
s="$(fresh n14)"
hits="$(doctor "$s" tools/scenes/portfolio.steps 'expect label@last "last [^"]*"' \
    'expect label@last "last 1999-01-01 AAPL buy $1.00"')"
applied "$hits" "N14's drifted last row"
refuses "$s" "the ledger's last row" "N14 (a scene that outlived its artifact)"

# N15 — C9: the same, one string over — the most recent rows, which is
# the expectation a regenerated ledger moves every time. COUNT-FREE on
# purpose: the census derives the count from the guest's own RECENT
# (8 since 2026-08-30, 12 before), and a self-test pinned to the number
# broke the day the number moved while the census itself was right.
s="$(fresh n15)"
hits="$(doctor "$s" tools/scenes/portfolio.steps '(expect_rows column@recent ")[^"]*"' \
    '\1nothing,here,at,$0.00"')"
applied "$hits" "N15's drifted recent rows"
refuses "$s" "most recent rows" "N15 (a stale recent table)"

# N16 — C9: the scene is deleted while the artifact stays.
s="$(fresh n16)"
rm "$s/tools/scenes/portfolio.steps"
refuses "$s" "is gone while the market artifact" "N16 (a deleted scene)"

# N17 — C9's tick half: the GUEST's posting rule moves and the scene
# does not. Nothing else in the sweep reads POSTED, and the scene's
# recent table is where the three posted rows show.
s="$(fresh n17)"
hits="$(doctor "$s" guests/python/portfolio.py \
    '\("2026-08-25", "brokerage", "AAPL", "div", 0, 240\)' \
    '("2026-08-25", "brokerage", "AAPL", "div", 0, 250)')"
applied "$hits" "N17's re-valued posted dividend"
refuses "$s" "most recent rows" "N17 (a posting rule the scene never heard about)"

# N18 — C9: the DASHBOARD's own count of the book drifts. That label is
# the one place the two screens are asserted to share a model, and it
# is derived from the artifact's length alone.
s="$(fresh n18)"
hits="$(doctor "$s" tools/scenes/portfolio.steps 'expect label#1 "Transactions: 15003"' \
    'expect label#1 "Transactions: 999"')"
applied "$hits" "N18's drifted book count"
refuses "$s" "after the tick posted its rows" "N18 (a dashboard count the ledger cannot produce)"

# N19 — C9: the guest stops spelling the tables this clause reads, so
# the derivation would silently have nothing to check against.
s="$(fresh n19)"
hits="$(doctor "$s" guests/python/portfolio.py '\nPOSTED = \[' '\nPOSTED_ROWS = [')"
applied "$hits" "N19's renamed POSTED"
refuses "$s" "no longer spells RECENT" "N19 (a census that lost its subject)"

# N20 — C10: THE BOOK MOVES AND THE LEDGER DOES NOT, which is the way
# the tie-out will actually break — someone edits a holding and never
# reruns the generator. C8 reds beside it (the generator reads BOOK, so
# a regeneration would no longer match the artifact on disk) and that is
# the fix instruction; the fragment demanded here is C10's own, so this
# proves the tie clause fired rather than its neighbour.
s="$(fresh n20)"
hits="$(doctor "$s" guests/python/portfolio.py '\("AAPL", 10, 18000\)' \
    '("AAPL", 11, 18000)')"
applied "$hits" "N20's moved holding"
refuses "$s" "does not net to" "N20 (a book the ledger no longer sums to)"

# N21 — C10's scene half, and the only perturbation in this file that
# reaches C10 ALONE: the artifact and the book still agree, and the
# scene's frozen net line does not.
s="$(fresh n21)"
hits="$(doctor "$s" tools/scenes/portfolio.steps '(expect label@net "net BND )\d+' \
    '\g<1>21')"
applied "$hits" "N21's drifted net line"
refuses "$s" "the tie-out for account retirement" "N21 (a stale tie-out assertion)"

# N22 — C10's other half: the net line survives and the DASHBOARD stops
# saying the same money. A tie-out one screen asserts alone ties nothing.
s="$(fresh n22)"
hits="$(doctor "$s" tools/scenes/portfolio.steps 'Account total: \$2370\.00' \
    'Account total: $2370.01')"
applied "$hits" "N22's silenced dashboard twin"
refuses "$s" "never asserts" "N22 (a tie-out asserted on one screen only)"

# N23 — C10: the guest stops spelling the book this clause nets against.
# The GENERATOR refuses in its own words too (C8 reports that refusal),
# which is the wall on the path nobody can avoid; this is the gate half.
s="$(fresh n23)"
hits="$(doctor "$s" guests/python/portfolio.py '\nBOOK = \{' '\nHOLDINGS = {')"
applied "$hits" "N23's renamed BOOK"
refuses "$s" "no longer spells BOOK" "N23 (a tie-out census with no book)"

# N24 — C8's second artifact: the HISTORY is hand-edited while the
# ledger stays honest. A derivation clause that regenerated one of two
# files would call this current, which is the hole the family's second
# artifact opened (2026-08-27).
s="$(fresh n24)"
hits="$(doctor "$s" guests/assets/market/prices.csv '2026-08-24,VTI,26025' \
    '2026-08-24,VTI,26026')"
applied "$hits" "N24's hand-edited history"
refuses "$s" "prices.csv does not match" "N24 (a hand-edited price history)"

# N25 — C8: the history is absent while the ledger is present, which is
# every checkout made before this artifact existed.
s="$(fresh n25)"
rm "$s/guests/assets/market/prices.csv"
refuses "$s" "prices.csv is missing" "N25 (a missing price history)"

# N26 — C11: THE HISTORY STOPS ENDING ON THE BOOK. The book moves and
# the walk does not, which is how the chart's tie-out will actually
# break. C8 reds beside it (the generator reads BOOK), so the fragment
# demanded here is C11's own.
s="$(fresh n26)"
hits="$(doctor "$s" guests/python/portfolio.py '\("VTI", 6, 26025\)' \
    '("VTI", 6, 26030)')"
applied "$hits" "N26's re-priced holding"
refuses "$s" "IS THE DASHBOARD'S PRESENT" "N26 (a history that ends off the book)"

# N27 — C11's scene half, and the only perturbation here that reaches
# C11 alone: the artifact and the book still agree, and the chart's
# frozen accessible name does not.
s="$(fresh n27)"
hits="$(doctor "$s" tools/scenes/portfolio.steps 'now \$10026\.50"' 'now $10026.51"')"
applied "$hits" "N27's drifted chart summary"
refuses "$s" "the chart's accessible name at rest" "N27 (a stale chart assertion)"

# N28 — C11's other half: the chart's last point survives and the
# DASHBOARD stops saying the same money. A tie-out one widget asserts
# alone ties nothing.
s="$(fresh n28)"
hits="$(doctor "$s" tools/scenes/portfolio.steps 'Portfolio: \$10023\.00' \
    'Portfolio: $10023.01')"
applied "$hits" "N28's silenced dashboard twin"
refuses "$s" "The chart's tie-out is only a guard" "N28 (a chart tie-out asserted alone)"

# N29 — C11: the guest stops spelling the window this clause derives
# the chart's frozen name from.
s="$(fresh n29)"
hits="$(doctor "$s" guests/python/portfolio.py '\nCHART_DAYS = ' '\nCHART_WINDOW = ')"
applied "$hits" "N29's renamed CHART_DAYS"
refuses "$s" "no longer spells CHART_DAYS" "N29 (a chart census with no window)"

echo "check-assets: self-test: 29 watched negatives, each with its" \
    "perturbation proven applied"

# ---------------------------------------------------------------------
# The tree as it stands.
if ! check "$ROOT"; then
    echo "check-assets: FAIL" >&2
    exit 1
fi
echo "check-assets: OK"
