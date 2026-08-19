#!/usr/bin/env bash

# Everything runs inside the dev shell: the flake pins every toolchain.
# A shell entered before the flake last changed is a bystander
# toolchain, so the marker carries the fingerprint of
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
# THE ASSET ROOT'S DRIFT GATE (docs/assets-plan.md A6, gates 2 and 3).
#
# `asset(name)` moved one rule — where the bytes are and what to say
# when they are not there — out of eight guests and into one Rust
# module. That is only true while nothing ELSE resolves an asset for
# itself, and while every lane that has to carry the root carries the
# WHOLE root. Neither of those is checkable by the core, because both
# are statements about files the core never reads.
#
# THE SIBLING RATHER THAN A GENERALIZATION, and the reason is measured
# rather than stylistic. tools/check-app-identity.sh has six clauses and
# three of them are about a DECLARATION — a manifest with a `name`, a
# pixel expectation frozen in a scene, a name read back off a window —
# which no other asset has or should have. Folding this in would put a
# family-README walk and a census floor under a header whose whole
# argument is "one declaration, two readers". The two files share their
# self-test scaffolding below (shadow/doctor/applied/refuses) verbatim,
# which is the part that would actually have drifted.
#
# FIVE CLAUSES.
#
#   C1 PROVENANCE   Every family under the root carries a README that
#                   says what the files are, where they came from, their
#                   licence, and how to regenerate them. This is three
#                   lines of shell and it is the thing that makes
#                   vendoring safe: guests/assets/fonts/README.md passes
#                   it and always did, and the file that FAILED it —
#                   an opaque 1040-byte MRT index filed under tools/ —
#                   is how the survey found there was a problem at all.
#
#   C2 CENSUS       The root's listing is printed with its count, every
#                   name is legal as an asset name, and the count may
#                   not fall below a floor. A census that reads two
#                   files agrees with everything (docs/assets-plan.md
#                   A6's first required property).
#
#   C3 ONE RESOLVER Nothing outside the core resolves an asset path for
#                   itself. A guest that spells `guests/assets/...` or
#                   reads an asset environment variable has taken the
#                   rule back out of the one place it lives, and the
#                   eight-copies problem starts again one file at a
#                   time. Table-driven, and the table's own claim is
#                   checked: an exemption carries a reason and the
#                   reason has to be about a file that still exists.
#
#   C4 EVERY LANE   Each of the five lanes either stages the root or
#                   says why it needs nothing, and BOTH halves are here
#                   rather than inferred. A lane that stages one FILE is
#                   the shape this whole convention replaced: every
#                   future asset would cost five more staging lines, and
#                   the one that got forgotten would fail on the lane
#                   furthest from the change.
#
#   C5 WHAT ARRIVED The staging lanes verify the bytes they staged
#                   against the tree's, by HASH. A size check misses a
#                   same-length corruption, which is exactly what a
#                   half-written push or a re-encoding packaging step
#                   produces (docs/assets-plan.md A5.1 asks for this
#                   change in those words).
#
# NO FIXTURE ANYWHERE. Every negative below doctors a shadow of the REAL
# tree, so what is proven is that the rule still bites on the sources as
# they are actually written today — the wayland seat guard passed
# vacuously twice against a pattern that matched nothing.
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
# THE EXEMPTIONS ARE THE INTERESTING HALF. Each names a file and a
# reason, and a stale exemption — one whose file is gone, or which no
# longer matches — is itself a failure: an exemption nobody re-read is
# how a rule quietly stops applying.
EXEMPT = {
    "crates/kaya/src/assets.rs":
        "the core's own resolver — this is the one place the rule lives",
    "crates/kaya/src/winui/mod.rs":
        "the harness-only include_bytes! of the vendored font, so the "
        "DirectWrite name-table tests measure a real font on whatever "
        "machine runs them; a test fixture, never a runtime read",
    "guests/rust/identity.rs": "identity has not migrated yet — see the ledger",
    "guests/python/identity.py": "identity has not migrated yet — see the ledger",
    "guests/go/identity/identity.go": "identity has not migrated yet — see the ledger",
    "guests/swift/identity.swift": "identity has not migrated yet — see the ledger",
    "guests/csharp/IdentityScene.cs": "identity has not migrated yet — see the ledger",
    "guests/ocaml/identity.ml": "identity has not migrated yet — see the ledger",
    "guests/haskell/identity.hs": "identity has not migrated yet — see the ledger",
    "guests/java/dev/kaya/milestone2kt/Identity.java":
        "identity has not migrated yet — see the ledger",
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

# THIS CLAUSE READS CODE AND NOT PROSE, and that is not a convenience.
# Every guest this slice migrated explains in its own header what it
# USED to do — "this scene used to read KAYA_FONT_FILE with a
# repo-relative default" — which is exactly the sentence the next reader
# needs and exactly the sentence a naive grep calls a violation. A gate
# that fires on its own subject's documentation gets muted, and a muted
# gate is worse than none (tools/check-diagnostics.sh costed and
# rejected a prose regex for the same reason). So comments and string
# literals come out first, and what is left is what the program does.
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
            # A BINDING MAY NAME THE VARIABLE AND MAY NOT READ A PATH.
            # KAYA_ASSET_DIR is part of the surface every binding
            # documents — `asset(name)` resolves under it — and a doc
            # comment that says so is the opposite of a second resolver.
            # A hard-coded `guests/assets/...` in a binding is still a
            # second resolver, so only the env half is relaxed.
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
    # AND THE EXEMPTION MUST STILL BE EARNED. A file that stopped
    # resolving — because it migrated to `asset(name)`, or because the
    # mention was only ever a comment this clause no longer reads —
    # leaves a permission behind it, and the next edit to that file
    # inherits it silently. That is the shape check-gates refuses in its
    # own EXCLUDED table, one gate over.
    body = code_only(path.read_text(encoding="utf-8", errors="replace"),
                     os.path.splitext(rel)[1])
    if not (ASSET_PATH.search(body) or (not rel.startswith("bindings/")
                                        and ASSET_ENV.search(body))):
        bad.append(f"{rel} is exempted from the one-resolver rule and no longer "
                   "needs to be — it resolves nothing. Delete the entry: an "
                   "exemption nobody re-read is how a rule stops applying "
                   "without anyone deciding that it should")

# ------------------------------------------------------------------ C4
# Every lane, both halves stated. STAGES: must name KAYA_ASSET_DIR and
# must copy the ROOT rather than a file under it. NOTHING_NEEDED: must
# say why, at the staging site, rather than leaving it to be inferred.
# lane -> (why it stages, the token that proves HOW the core will find
# what it staged). The token differs per lane because the mechanism
# does, and a single "must name KAYA_ASSET_DIR" rule would have forced
# iOS to carry a variable it does not need — which is the opposite of
# what the plan asks for there.
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
    # A COPY of one file under the root, never a mere mention of one.
    # The deploy hashes the resource index into its stamp by path and
    # that is a READ, not a staging — a pattern that could not tell the
    # two apart would have to be silenced, and a silenced clause is a
    # clause nobody reads.
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

for b in bad:
    print("check-assets: " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
}

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# <destination> -> a shadow root of symlinks the checker can read.
# tools/check-app-identity.sh's, verbatim but for the roots: the two
# gates read overlapping trees and a second spelling of this walk is a
# second thing to keep true.
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
            # THE ASSET ROOT IS COPIED, EVERYTHING ELSE IS LINKED. C2
            # refuses a symlink inside the root — fs::read follows one,
            # so a link there is the escape wall 1 exists to close — and
            # a shadow built entirely of links would fail that clause
            # for a reason belonging to the shadow rather than to the
            # perturbation. Copying one small directory buys a shadow
            # the real clause can read; the rest stays links, which is
            # what keeps this walk cheap enough to run seven times.
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
s="$(fresh n6)"
rm -f "$s/guests/assets/fonts/sora-wght.ttf" "$s/guests/assets/icons/kaya-mark.png" \
    "$s/guests/assets/fonts/OFL.txt" "$s/guests/assets/win/minimal-resources.pri"
refuses "$s" "below the floor of" "N6 (a census that reads almost nothing)"

# N7 — C5: a stager verifies by size rather than by hash.
s="$(fresh n7)"
hits="$(doctor "$s" tools/android/run-emulator.sh '(?i)sha256sum|shasum|sha256' 'wc -c')"
applied "$hits" "N7's hash removal"
refuses "$s" "never hashes what arrived" "N7 (a size check standing in for a hash)"

echo "check-assets: self-test: 7 watched negatives, each with its" \
    "perturbation proven applied"

# ---------------------------------------------------------------------
# The tree as it stands.
if ! check "$ROOT"; then
    echo "check-assets: FAIL" >&2
    exit 1
fi
echo "check-assets: OK"
