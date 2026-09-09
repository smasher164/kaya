#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# ONE DECLARATION, TWO READERS, AND NOTHING BETWEEN THEM THAT CAN DRIFT
# (docs/app-identity-plan.md ruling 4; CLAUDE.md's gate list). The byte
# comparison itself lives in each packaging step, on the path nobody can
# avoid; this gate is the STATIC half, and it reaches platforms whose
# packaging step does not exist yet.
#
# THE CONTRACT.
#   C1  the manifest declares a non-empty name and an icon file that
#       exists and is not empty; neither value is written down here.
#   C2  THE PIXELS ARE THE EXPECTATION: `expect_app_icon` freezes the
#       CONTENT of the declared icon, decoded here so that swapping the
#       asset fails HERE rather than on five lanes at once.
#   C3  THE DECLARATION IS WRITTEN DOWN ONCE. No runtime reader parses
#       TOML, so a site may name it in THREE ways and no fourth: READ
#       THE MANIFEST; SPELL THE DECLARED PATH (backslashes and a
#       drive-letter mirror allowed, since deploy-win stages the tree to
#       C:\kaya); or OPEN IT AS AN ASSET, which this gate DERIVES rather
#       than types. Naming KAYA_ICON_FILE while naming none of the three
#       is a third source of truth wearing the override's name, and
#       opening some OTHER file out of the mark's family is a second
#       mark — silent at runtime, since an asset name nothing answers to
#       leaves each platform's own icon in place. NO COMMENT IN THIS
#       FILE MAY SPELL AN ASSET NAME IN THE MARK'S FAMILY: the checker
#       reads this file too, and it will refuse it.
#   C4  THE NAME IS WRITTEN DOWN ONCE, same rule one field over.
#   C5  ONE PICTURE: any app-icon resource in the tree is BYTE-IDENTICAL
#       to the declared icon or in EXCLUDED with a reason.
#   C6  A PACKAGING CONSUMER READS THE MANIFEST. The .cmd launchers are
#       exempt and C3 covers them: a batch file cannot read TOML.
#   C9  ONE MANIFEST READER IN tools/. Every packaging step goes
#       through tools/lib/packaging/identity.py, so a file that parses
#       the declaration ITSELF is the second reader ruling 4 exists to
#       prevent — C6 says a consumer must READ the declaration and this
#       says WHICH reader. Two files are exempt by name with reasons.
#   C10 EVERY ARM READS THE DECLARATION. A module under
#       tools/lib/packaging/ that is not one of the shared halves must
#       name the reader: an arm that does not is retyping something.
#   C11 THE COMMITTED SOURCE IS THE DESCRIPTION'S OWN PICTURE, and
#       NOTHING PACKAGES BY RENDERING (docs/packaging-plan.md P2, as
#       ruled 2026-09-08). A packager works from the FILE the manifest
#       names, the way a user's app would; a renderer that knows kaya's
#       mark could only ever package kaya's app. So the example asset is
#       held BYTE-IDENTICAL to `mark.render_png()` — a regeneration
#       guard — and `render_png(` is refused under tools/ outside the
#       renderer, its regeneration script and this gate.
#   C12 ONE GENERATOR PER PLATFORM (P4, P5). The tools each arm uses to
#       assemble an identity artifact — the mac icon set's compiler, the
#       Linux desktop entry's own header — appear under tools/ in the
#       arm alone; a second copy anywhere else is the lane wrapper the
#       generator replaced, coming back.
#   C13 A BACKEND SENTENCE A LEG PARSES IS AN INTERFACE. The GTK
#       identity lowering's own words are grepped by
#       tools/linux/identity-wayland-witness.sh to tell a lowering that
#       RAN and cannot be read back on wayland from one that was
#       SKIPPED — a version note against a carve-out
#       (docs/app-identity-plan.md I4a) — and nothing in the sentence
#       says so. tools/lib/identity_phrases.py owns the phrase, the
#       witness reads it from there, and this holds the backend to
#       still printing it. HERE AND NOT IN tools/check-gtk.py because
#       that gate needs docker and sits outside the fast sweep.
#   C7  THE LAUNCH SLOT IS DECLARED ONCE AND HONOURED WHERE THE
#       PLATFORM HAS ONE (docs/tasks-s2-plan.md T4). `[launch]` names a
#       colour and a picture; the iOS bundle turns them into
#       UILaunchScreen's two asset entries and the APK into the
#       SplashScreen theme's two attributes, while macOS, GTK and
#       unpackaged WinUI have no slot to honour. The colour is a
#       LITERAL nowhere but the manifest — no gate can see a second
#       copy at runtime, because a splash that is the wrong colour
#       still launches. AND THE ANDROID CALL: the manifest names the
#       LAUNCH theme, so `installSplashScreen()` is what puts the app
#       back on its own; a module that stops calling it wears the
#       launch colour as its window background for the app's whole
#       life, and no scene can see that either (every kaya surface
#       paints its own ground). Beside them the packaging steps' own
#       byte checks, which is where the comparison lives.
# The self-test runs the real checker over a shadow root of symlinks
# (CLAUDE.md invariant 3: the wayland seat guard passed vacuously twice).

import importlib.util
import os
import re
import struct
import tomllib
import zlib

g = Gate("check-app-identity")

MANIFEST = "guests/assets/identity.toml"

# Directory names holding BUILD OUTPUT rather than tree, pruned while
# walking (the unpruned walk visits 752,511 paths, 750,000 of them
# cargo's). `build` is pruned for a second reason: reading a build
# directory would make the verdict depend on what the last build — or
# the last WATCHED NEGATIVE — left lying around, and a gate a negative
# test can turn red afterwards is a gate whose red means nothing.
PRUNE = {".git", ".gradle", ".build", "build", "target", "_build",
         "obj", "bin", "node_modules", "__pycache__", "DerivedData"}

# Files that carry app-icon-shaped bytes and are NOT the declared mark,
# each with the reason it is exempt. An entry here is a claim, so keep
# them narrow: a directory prefix, never a bare extension.
EXCLUDED = {
    "third_party": "vendored SDKs ship their own art; nothing in the "
                   "tree packages it as kaya's identity",
}

# The scripts that may name the icon without reading the manifest,
# because their language cannot read it.
CMD_LAUNCHERS = "tools/guest/"

SOURCE_ROOTS = ("guests", "tools", "android", "swift", "crates",
                "bindings")

# C9. The only files under tools/ that may parse the declaration
# themselves, each with its reason. This list only shrinks.
MANIFEST_PARSER_EXEMPT = {
    "tools/lib/packaging/identity.py":
        "IS the one reader (docs/packaging-plan.md P1); every other "
        "tools/ consumer imports it",
    "tools/check-app-identity.py":
        "this gate is the declaration's own static half — it reads the "
        "manifest to hold every other reader to it, and a gate that "
        "asked the shared reader would be checking that reader with "
        "itself",
}
PARSES_TOML = re.compile(r"\b(?:import\s+tomllib|from\s+tomllib\s+import"
                         r"|import\s+toml\b|tomllib\.load)")

# C10/C11/C12. The arms and the two halves every arm shares.
# C13. Where the parsed phrases live, and the file that must print each.
PHRASE_SITES = {"GTK_ICON_LOWERED": "crates/kaya/src/gtk.rs"}
PACKAGING_DIR = "tools/lib/packaging"
SHARED_HALVES = {"identity.py", "mark.py", "__init__.py"}

# C11. Who may call the description's renderer. Every other consumer of
# the mark RESAMPLES the declared file, which is the whole difference
# between packaging an app and packaging THIS app.
RENDER_CALLERS = {
    f"{PACKAGING_DIR}/mark.py": "defines it",
    "tools/regen-mark.py":
        "the example asset's one writer (guests/assets/icons/README.md)",
    "tools/check-app-identity.py":
        "this gate, which holds the committed file to what it renders",
}

# C12. The generators' own tools, refused under tools/ outside the arms.
# SPELLED IN HALVES because THIS FILE IS IN THE TREE THE CHECKER READS —
# the rule reaches every file under tools/, this one included, and a
# literal here would make the gate refuse itself (the asset-name and
# launch-colour clauses solved the same problem by forbidding the
# comment; a table cannot be forbidden, so it is assembled instead).
ONE_GENERATOR = {
    "icon" + "util":
        "the mac bundle's icon set is built by tools/lib/packaging/"
        "mac.py alone (docs/packaging-plan.md P4): one code path for the "
        "lane and for a shipped bundle, or the lane's plist and a real "
        "one drift with nothing to notice",
    "[Desktop " + "Entry]":
        "the Linux desktop entry is written by tools/lib/packaging/"
        "linux.py alone (P5), so the notify leg runs what an installed "
        "app has rather than a hand-written entry beside it",
}


def tree_walk(base):
    """Every file under `base`, artifact directories pruned."""
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames if d not in PRUNE)
        for f in sorted(filenames):
            yield pathlib.Path(dirpath) / f


def excluded(rel):
    for prefix, why in EXCLUDED.items():
        if rel == prefix or rel.startswith(prefix + "/"):
            return why
    return None


def defined_and_called(text, fn):
    """A function that EXISTS and is REACHED, comments stripped: a
    packaging step's byte check that nobody calls is prose, and a
    mention of it in a comment is prose twice over (watched — the
    clause's first draft counted mentions and a sentence naming the
    function paid for the call)."""
    body = "\n".join(line for line in text.splitlines()
                     if not line.lstrip().startswith("#"))
    if f"def {fn}(" not in body:
        return False
    return body.count(f"{fn}(") > 1


def decode_png(data):
    """(width, height, pixel(x, y) -> (r, g, b)). Deliberately narrow:
    8-bit, non-interlaced. A mark outside that is a real finding —
    every platform's decoder is being asked to reproduce these pixels,
    and the reason to widen this is a mark somebody chose, not a guess
    made here."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG (the signature is wrong)")
    i, idat, hdr, plte = 8, b"", None, b""
    while i + 8 <= len(data):
        ln = struct.unpack(">I", data[i:i + 4])[0]
        typ = data[i + 4:i + 8]
        chunk = data[i + 8:i + 8 + ln]
        if typ == b"IHDR":
            hdr = struct.unpack(">IIBBBBB", chunk)
        elif typ == b"IDAT":
            idat += chunk
        elif typ == b"PLTE":
            plte = chunk
        i += 12 + ln
    if hdr is None:
        raise ValueError("no IHDR")
    w, h, depth, colour, _comp, _filt, interlace = hdr
    if depth != 8 or interlace != 0:
        raise ValueError(f"bit depth {depth}, interlace {interlace} — "
                         f"this gate reads 8-bit non-interlaced PNGs "
                         f"only")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(colour)
    if channels is None:
        raise ValueError(f"colour type {colour}")
    raw = zlib.decompress(idat)
    stride = w * channels
    rows, prev, pos = [], bytearray(stride), 0
    for _ in range(h):
        ft = raw[pos]
        line = bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride
        for x in range(stride):
            a = line[x - channels] if x >= channels else 0
            b = prev[x]
            c = prev[x - channels] if x >= channels else 0
            if ft == 1:
                line[x] = (line[x] + a) & 0xFF
            elif ft == 2:
                line[x] = (line[x] + b) & 0xFF
            elif ft == 3:
                line[x] = (line[x] + (a + b) // 2) & 0xFF
            elif ft == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (
                    b if pb <= pc else c)
                line[x] = (line[x] + pr) & 0xFF
            elif ft != 0:
                raise ValueError(f"filter type {ft}")
        rows.append(bytes(line))
        prev = line

    def pixel(x, y):
        row = rows[y]
        if colour == 3:
            idx = row[x]
            return tuple(plte[idx * 3:idx * 3 + 3])
        if colour in (0, 4):
            grey = row[x * channels]
            return (grey, grey, grey)
        o = x * channels
        return (row[o], row[o + 1], row[o + 2])

    return w, h, pixel


def quadrant_samples(data):
    w, h, pixel = decode_png(data)
    out = []
    for qy in (0, 1):
        for qx in (0, 1):
            x = qx * (w // 2) + (w // 4)
            y = qy * (h // 2) + (h // 4)
            out.append("%02X%02X%02X" % pixel(x, y))
    return "/".join(out)


# Every language's spelling of one call. NO leading word boundary,
# because Swift's constructor is `KayaAsset(` and OCaml's is a bare
# `asset `. The looseness costs nothing: a captured name is only ever
# asked whether it IS the declared one and whether it is in the mark's
# family but is not, and a stray capture answers no to both.
ASSET_CALL = re.compile(r'(?i)asset\s*\(?\s*"([^"\n]+)"')
ICONISH = re.compile(r"(^|/)(mipmap|drawable)[^/]*/", re.I)
ASSET_ROOT = "guests/assets/"


def check(root):
    """Findings for one tree — the shadow roots in the self-tests, the
    real one at the end."""
    root = pathlib.Path(root)
    bad = []

    # ------------------------------------------------------------- C1
    man_path = root / MANIFEST
    if not man_path.is_file():
        return [f"{MANIFEST}: the app identity's declaration is "
                f"missing — docs/app-identity-plan.md ruling 4 makes "
                f"this file the source of truth for both the build and "
                f"the running app"]
    try:
        manifest = tomllib.loads(man_path.read_text(encoding="utf-8"))
    except Exception as exc:                              # noqa: BLE001
        return [f"{MANIFEST}: does not parse as TOML: {exc}"]

    name = manifest.get("name")
    icon_rel = manifest.get("icon")
    if not isinstance(name, str) or not name.strip():
        bad.append(f"{MANIFEST}: declares no non-empty `name` — an app "
                   f"that wants the platform's own identity declares "
                   f"none at all, and an empty one would sail through "
                   f"five lowerings")
    if not isinstance(icon_rel, str) or not icon_rel.strip():
        bad.append(f"{MANIFEST}: declares no non-empty `icon`")

    # C8 — THE REVERSE-DNS ID (docs/tasks-s3-plan.md N4), the third value
    # the declaration carries and the one every platform needs to POST a
    # notification under: the mac wrapper's CFBundleIdentifier, GTK's
    # application id, WinUI's registration. The core reads it out of this
    # file at startup, so a manifest without it is an app that cannot
    # post — and the failure is a REFUSAL at the declaration rather than
    # a silence at the first reminder, which is why it is required here
    # too and not merely allowed.
    app_id = manifest.get("id")
    if not isinstance(app_id, str) or not app_id.strip():
        bad.append(f"{MANIFEST}: declares no non-empty `id` — the "
                   f"reverse-DNS name the app registers under, and the "
                   f"one value a notification cannot be posted without "
                   f"(docs/tasks-s3-plan.md N4)")
        app_id = ""
    elif not re.fullmatch(r"[a-z][a-z0-9-]*(\.[a-z0-9][a-z0-9-]*){1,}",
                          app_id):
        bad.append(f"{MANIFEST}: declares id \"{app_id}\", which is not "
                   f"a reverse-DNS name — two or more dot-separated "
                   f"lowercase labels (\"dev.kaya.aurora\"). Apple "
                   f"refuses a bundle identifier outside that shape and "
                   f"GNOME attributes a notification to nothing it does "
                   f"not recognise, so the post fails on two platforms "
                   f"and nowhere else")
        app_id = ""

    icon_bytes = b""
    if isinstance(icon_rel, str) and icon_rel.strip():
        icon_path = root / icon_rel
        if not icon_path.is_file():
            bad.append(f"{MANIFEST}: names icon \"{icon_rel}\", which "
                       f"is not a file in this tree")
        else:
            icon_bytes = icon_path.read_bytes()
            if not icon_bytes:
                bad.append(f"{icon_rel}: the declared icon is empty")

    if bad:
        return bad

    # ------------------------------------------------------------- C2
    scene_dir = root / "tools/scenes"
    want_pattern = re.compile(r'expect_app_icon\s+"([^"]*)"')
    scene_hits = []
    for steps in sorted(scene_dir.glob("*.steps")):
        step_lines = steps.read_text(encoding="utf-8").splitlines()
        for n, line in enumerate(step_lines, 1):
            m = want_pattern.search(line.strip())
            if m and not line.strip().startswith("#"):
                scene_hits.append(
                    (steps.relative_to(root).as_posix(), n, m.group(1)))

    if not scene_hits:
        bad.append("tools/scenes: no scene asserts expect_app_icon at "
                   "all — the identity lowering has no observation on "
                   "any platform, so this gate would agree with "
                   "anything")
    else:
        try:
            measured = quadrant_samples(icon_bytes)
        except Exception as exc:                          # noqa: BLE001
            measured = None
            bad.append(f"{icon_rel}: cannot be decoded here ({exc}), "
                       f"so the expectation in tools/scenes cannot be "
                       f"held to the pixels every platform's decoder "
                       f"is asked to reproduce")
        if measured is not None:
            for rel, n, want in scene_hits:
                if want != measured:
                    bad.append(
                        f"{rel}:{n}: expects app icon \"{want}\" but "
                        f"the declared mark ({icon_rel}) samples "
                        f"\"{measured}\" at its four quadrant centres "
                        f"— the scene is byte-frozen across every "
                        f"platform and language, so the asset and the "
                        f"expectation move together or not at all")

    # ---------------------------------------------------------- C3/C6
    icon_posix = icon_rel.replace("\\", "/")

    # THE THIRD WAY TO NAME THE DECLARATION, DERIVED AND NEVER RETYPED:
    # the accepted string is the manifest's own `icon` minus the asset
    # root's prefix. Typing it here would be the second source of truth
    # C3 refuses.
    icon_under_root = (icon_posix[len(ASSET_ROOT):]
                       if icon_posix.startswith(ASSET_ROOT) else None)
    if icon_under_root is None:
        bad.append(f"{MANIFEST}: declares icon \"{icon_rel}\", which "
                   f"is not under the asset root {ASSET_ROOT} — the "
                   f"identity guests open the mark by asset name, and "
                   f"a file outside the root has no asset name for "
                   f"them to open")
    # The family the mark lives in (`icons`), for the wrong-name half
    # below.
    icon_family = (icon_under_root.split("/")[0] if icon_under_root
                   else None)

    manifest_readers, icon_namers = [], []
    for r in SOURCE_ROOTS:
        base = root / r
        if not base.is_dir():
            continue
        for f in tree_walk(base):
            rel = f.relative_to(root).as_posix()
            if not f.is_file() or excluded(rel):
                continue
            try:
                text = f.read_text(encoding="utf-8")
            except (UnicodeDecodeError, ValueError):
                continue
            names_var = "KAYA_ICON_FILE" in text
            norm = text.replace("\\", "/")
            names_path = icon_posix in norm
            asset_names = {m.group(1)
                           for m in ASSET_CALL.finditer(text)}
            names_asset = (icon_under_root is not None
                           and icon_under_root in asset_names)
            if MANIFEST in text:
                manifest_readers.append(rel)
            # PROSE AND SCENE SCRIPTS ARE NOT READERS. A .md file
            # explains the mechanism and a tools/scenes/*.steps file
            # records why the guest opens a file at all; neither copies
            # a byte anywhere, and demanding they parse the manifest
            # would be a rule about documentation rather than about
            # drift.
            prose = (rel.endswith(".md")
                     or rel.startswith("tools/scenes/"))
            # ------------------------------------------------- C9, C12
            if rel.startswith("tools/") and not prose:
                if (MANIFEST in text and PARSES_TOML.search(text)
                        and rel not in MANIFEST_PARSER_EXEMPT):
                    bad.append(
                        f"{rel}: parses {MANIFEST} itself. There is ONE "
                        f"reader in tools/ ({PACKAGING_DIR}/identity.py, "
                        f"docs/packaging-plan.md P1) and every packaging "
                        f"step goes through it — a second parser is a "
                        f"second set of refusals for a half-spelled "
                        f"declaration, which is how one mark on five "
                        f"platforms breaks quietly. Import it: "
                        f"`from packaging.identity import load`")
                if not rel.startswith(PACKAGING_DIR + "/"):
                    for tool, why in sorted(ONE_GENERATOR.items()):
                        if tool in text:
                            bad.append(
                                f"{rel}: names {tool!r}, which belongs to "
                                f"one arm alone — {why}")
                if "render_png(" in text and rel not in RENDER_CALLERS:
                    bad.append(
                        f"{rel}: calls render_png — the description's "
                        f"renderer draws THIS repo's example mark, and a "
                        f"packaging step that used it would package "
                        f"kaya's picture for every app that ever declares "
                        f"one. Resample the declared file instead: "
                        f"`mark.resample(declared.icon_path.read_bytes(), "
                        f"px)` (docs/packaging-plan.md P2, ruled "
                        f"2026-09-08). The callers that may are "
                        f"{sorted(RENDER_CALLERS)}")
            # C3, THE ASSET FORM'S OWN HALF, asked BEFORE the
            # is-this-a-namer question: a file opening the WRONG file
            # out of the mark's family names none of the three accepted
            # forms and would fall out of this loop unlooked-at, and a
            # mistyped asset name compiles in all eight languages.
            # (NO COMMENT HERE MAY QUOTE SUCH A NAME.)
            if not prose and icon_family:
                for other in sorted(
                        n for n in asset_names
                        if n.startswith(icon_family + "/")
                        and n != icon_under_root):
                    bad.append(
                        f"{rel}: opens the asset \"{other}\", which is "
                        f"in the declared mark's own family but is not "
                        f"it — {MANIFEST} declares \"{icon_rel}\", and "
                        f"under the asset root that is "
                        f"\"{icon_under_root}\". One picture is the "
                        f"picture on all five platforms (ruling 1), "
                        f"and a name nothing answers to fails "
                        f"SILENTLY: the platform's own icon stays, and "
                        f"every expectation that reads it goes red "
                        f"somewhere else")
            if not (names_var or names_path or names_asset):
                continue
            if prose:
                continue
            icon_namers.append(rel)
            # C3 — a site that names the variable must get its DEFAULT
            # from the declaration: by reading the manifest, by
            # spelling the declared path, or by opening the declared
            # asset. Naming none of them is a third source of truth
            # wearing the override's name.
            if names_var and not names_path and not names_asset \
                    and MANIFEST not in text:
                bad.append(
                    f"{rel}: names KAYA_ICON_FILE but names the "
                    f"declaration in none of C3's three ways — not the "
                    f"path \"{icon_rel}\", not the asset name "
                    f"\"{icon_under_root}\", not {MANIFEST} — and the "
                    f"override needs a default to override, so the "
                    f"default is the manifest's or it is a second "
                    f"source of truth")
            # C6 — a tools/ consumer derives the path; it does not
            # retype it.
            if (rel.startswith("tools/")
                    and not rel.startswith(CMD_LAUNCHERS)
                    and MANIFEST not in text):
                bad.append(
                    f"{rel}: stages or packages the app mark but never "
                    f"reads {MANIFEST} — a packaging step that retypes "
                    f"the path is the second reader ruling 4 exists to "
                    f"prevent (batch launchers under {CMD_LAUNCHERS} "
                    f"are exempt: cmd.exe cannot read TOML, and C3 "
                    f"holds their literal to the manifest instead)")

    if not icon_namers:
        bad.append("no file in the tree names the declared icon — not "
                   "its path, not its asset name, not KAYA_ICON_FILE — "
                   "so C3 read nothing and would agree with any "
                   "manifest")

    # ------------------------------------------------------------- C4
    # THE DECLARATION IS A CALL AND CARRIES NOTHING (docs/tasks-s3-plan.md
    # N4). It used to be `app_identity("Aurora Notes", icon)` in nine
    # guests and this clause held those nine strings to the manifest; the
    # values moved into the core, so what is left to hold is that each
    # guest still MAKES the declaration — a policy on macOS, where a
    # declared app is a Dock app (ruling 1) — and that none of them
    # retypes a value. The name is still read back off a real window by
    # tools/scenes/identity.steps, below.
    #
    # PER LANGUAGE AND NOT ONE LOOSE PATTERN: a bare name matches the
    # prose beside the call, and Haskell's `appIdentity` is an action
    # with no argument list at all.
    DECLARATION_CALL = {
        ".rs": r"\btx\.app_identity\(\)",
        ".py": r"\bkaya\.app_identity\(\)",
        ".go": r"\btx\.AppIdentity\(\)",
        ".cs": r"\btx\.AppIdentity\(\)",
        ".java": r"\btx\.appIdentity\(\)",
        ".swift": r"\btx\.appIdentity\(\)",
        ".ml": r"\bapp_identity \(\)",
        ".hs": r"(?m)^\s*appIdentity\s*$",
        ".ts": r"\bkaya\.appIdentity\(\)",
    }
    # FOUND BY WALKING, not by one glob: the identity guest is
    # `guests/<lang>/identity.<ext>` in seven languages,
    # `guests/go/identity/identity.go` in Go, `IdentityScene.cs` in C#
    # and `dev/kaya/guests/Identity.java` in Java — so
    # `guests/*/identity.*` had been reading SEVEN of the nine (and the
    # manifest, which is not a guest) since this clause was written.
    guests = sorted(
        f for f in tree_walk(root / "guests")
        if f.is_file()
        and f.suffix in DECLARATION_CALL
        and f.stem.lower().startswith("identity"))
    if len(guests) != 9:
        bad.append(f"guests/: {len(guests)} identity guests found "
                   f"({', '.join(g.name for g in guests)}) and kaya has "
                   f"nine bindings — the declaration has fewer writers "
                   f"than languages, and C4 would agree with a binding "
                   f"that lost it")
    for gp in guests:
        rel = gp.relative_to(root).as_posix()
        pattern = DECLARATION_CALL.get(gp.suffix)
        if pattern is None:
            bad.append(f"{rel}: C4 has no declaration-call pattern for "
                       f"{gp.suffix} — a language it cannot read is a "
                       f"guest it would pass without looking")
            continue
        text = gp.read_text(encoding="utf-8")
        if not re.search(pattern, text):
            bad.append(f"{rel}: never CALLS the identity declaration "
                       f"(wanted /{pattern}/) — the values come from "
                       f"{MANIFEST} now, but the call is still the act, "
                       f"and an app that makes it is a Dock app on "
                       f"macOS (docs/app-identity-plan.md ruling 1)")
        # AND RETYPES NONE OF THEM: a guest still passing the name would
        # have it silently replaced by the manifest's at the root.
        for what, value in (("name", name), ("id", app_id)):
            if value and value in text:
                bad.append(f"{rel}: spells the declared {what} "
                           f"\"{value}\" — {MANIFEST} is the one place "
                           f"it is written, and app_identity() takes no "
                           f"arguments in any of the nine "
                           f"(docs/tasks-s3-plan.md N4)")

    steps = root / "tools/scenes/identity.steps"
    if steps.is_file():
        text = steps.read_text(encoding="utf-8")
        if not re.search(r'expect_title\s+window#1\s+"%s"'
                         % re.escape(name), text):
            bad.append(f"tools/scenes/identity.steps: never reads the "
                       f"declared name \"{name}\" back off a window — "
                       f"the name half of the declaration would ship "
                       f"unobserved on every platform")

    # ------------------------------------------------------------- C5
    for f in tree_walk(root):
        rel = f.relative_to(root).as_posix()
        if not f.is_file() or f.is_symlink():
            continue
        if excluded(rel):
            continue
        lower = rel.lower()
        hit = (lower.endswith((".ico", ".icns"))
               or ICONISH.search(lower) is not None
               or pathlib.PurePosixPath(lower).name.startswith(
                   ("ic_launcher", "appicon")))
        if not hit or rel == icon_rel:
            continue
        if f.read_bytes() != icon_bytes:
            bad.append(
                f"{rel}: is an app-icon resource whose bytes are not "
                f"the declared mark's ({icon_rel}) — ruling 1 is that "
                f"one picture is the picture on all five platforms, so "
                f"a packaging step reads the declared file or it is "
                f"showing something else")

    # ------------------------------------------------------------ C10
    # EVERY ARM READS THE DECLARATION. C6 says a tools/ consumer must
    # read it; this says the arms in particular do, and it is the clause
    # that grows by itself — a new platform's module joins this census
    # the moment it is written, with nothing to remember to add.
    arms_dir = root / PACKAGING_DIR
    arms = sorted(p for p in arms_dir.glob("*.py")
                  if p.name not in SHARED_HALVES) if arms_dir.is_dir() \
        else []
    if not arms:
        bad.append(
            f"{PACKAGING_DIR}: carries no platform arm at all — the "
            f"generator is one module per platform beside the shared "
            f"reader and renderer (docs/packaging-plan.md §2), so this "
            f"clause read nothing and would agree with anything")
    for arm in arms:
        rel = arm.relative_to(root).as_posix()
        text = arm.read_text(encoding="utf-8")
        reads = (re.search(r"from \.identity import [^\n]*\bload\b", text)
                 is not None or "identity.load(" in text)
        if not reads:
            bad.append(
                f"{rel}: never names the shared reader's `load` — an arm "
                f"that does not read {MANIFEST} is writing a name, a "
                f"picture or an id it got from somewhere else, which is "
                f"the second source of truth ruling 4 exists to prevent")

    # ------------------------------------------------------------ C11
    # THE COMMITTED SOURCE IS WHAT THE DESCRIPTION RENDERS — a
    # REGENERATION guard, not a packaging one: the arms resample this
    # file and never draw it. Loaded out of the tree BEING CHECKED, so a
    # doctored description is what the negative exercises.
    mark_rel = f"{PACKAGING_DIR}/mark.py"
    mark_py = root / mark_rel
    if not mark_py.is_file():
        bad.append(
            f"{mark_rel}: is gone, so nothing resizes the declared file "
            f"and no platform's slot can be filled from it "
            f"(docs/packaging-plan.md P2)")
    elif icon_bytes:
        try:
            spec = importlib.util.spec_from_file_location(
                "kaya_mark_under_check", mark_py)
            renderer = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(renderer)
            drawn = renderer.render_png()
        except Exception as exc:                          # noqa: BLE001
            drawn = None
            bad.append(
                f"{mark_rel}: could not be run against {icon_rel} "
                f"({exc}) — the committed source and the description are "
                f"held equal HERE, and a comparison that cannot run is "
                f"not a pass")
        if drawn is not None and drawn != icon_bytes:
            w, h, _pixel = decode_png(icon_bytes)
            dw, dh, _dpixel = decode_png(drawn)
            bad.append(
                f"{icon_rel}: is {w}x{h} and {len(icon_bytes)} bytes, "
                f"and {mark_rel} renders {dw}x{dh} and {len(drawn)} "
                f"bytes. The committed picture is the EXAMPLE the "
                f"description writes (guests/assets/icons/README.md): "
                f"run tools/regen-mark.py, and remember that its bytes "
                f"ride the wire and every packaged copy comes down from "
                f"them")

    # ------------------------------------------------------------ C13
    # THE SENTENCES A LEG PARSES, still printed by the backend that owns
    # them. Read out of the tree BEING CHECKED, so a doctored backend is
    # what the negative exercises.
    phrases_rel = "tools/lib/identity_phrases.py"
    phrases_py = root / phrases_rel
    if not phrases_py.is_file():
        bad.append(
            f"{phrases_rel}: is gone, so the witness that greps a backend "
            f"sentence and the backend that prints it have no shared "
            f"copy of the words and can drift with nothing noticing")
    else:
        spec = importlib.util.spec_from_file_location(
            "kaya_phrases_under_check", phrases_py)
        phrases = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(phrases)
        for name, site in sorted(PHRASE_SITES.items()):
            phrase = getattr(phrases, name, "")
            src = root / site
            if not phrase:
                bad.append(f"{phrases_rel}: declares no {name}")
            elif not src.is_file():
                bad.append(f"{site}: is gone, and {name} names it as the "
                           f"file that prints that phrase")
            elif phrase not in src.read_text(encoding="utf-8"):
                bad.append(
                    f"{site}: no longer prints \"{phrase}\" ({name} in "
                    f"{phrases_rel}). A LEG PARSES THAT SENTENCE — "
                    f"tools/linux/identity-wayland-witness.sh reads it to "
                    f"tell a lowering that RAN from one that was SKIPPED, "
                    f"which is a version note against a carve-out "
                    f"(docs/app-identity-plan.md I4a) — so rewording it "
                    f"reds a leg for a reason the leg cannot name. Reword "
                    f"AROUND the phrase, or move it here and in the "
                    f"backend together")

    # ------------------------------------------------------------- C7
    launch = manifest.get("launch")
    if not isinstance(launch, dict):
        bad.append(
            f"{MANIFEST}: declares no `[launch]` table — the iOS bundle "
            f"and the APK each have a slot the platform draws between "
            f"the tap and the first frame, and an app that declares "
            f"nothing gets the system's plain ground on both "
            f"(docs/tasks-s2-plan.md T4)")
        return bad

    bg = launch.get("background")
    if not isinstance(bg, str) or not re.fullmatch(r"#[0-9A-Fa-f]{6}",
                                                   bg):
        bad.append(
            f"{MANIFEST}: declares `[launch] background = {bg!r}`, which "
            f"is not #RRGGBB — it becomes an Android colour resource and "
            f"an iOS colour asset, and neither reader can guess what a "
            f"half-spelled one meant")
        return bad
    launch_rel = launch.get("image", icon_rel)
    if not isinstance(launch_rel, str) or not (root / launch_rel).is_file():
        bad.append(
            f"{MANIFEST}: names the launch image {launch_rel!r}, which is "
            f"not a file in this tree (leave `image` out to take the "
            f"declared icon)")
        return bad

    # C7, THE COLOUR IS A LITERAL ONCE. Every reader derives it; a second
    # copy is silent, because a splash drawn in the wrong colour still
    # launches and every observable the harness has is drawn after it.
    # Comments count: this file's own rule for asset names, one field
    # over. NO COMMENT IN THIS FILE MAY SPELL THE DECLARED COLOUR.
    # `#RGB`, Android's `#AARRGGBB` and a Kotlin/Swift `0x` literal —
    # the three spellings a second copy would plausibly wear. A BARE run
    # of six hex digits is deliberately not matched: every build id and
    # sha256 in this tree would answer to it.
    colour_re = re.compile(r"(?:#|0[xX])(?:[0-9A-Fa-f]{2})?" + bg[1:]
                           + r"\b", re.I)
    for r in SOURCE_ROOTS:
        base = root / r
        if not base.is_dir():
            continue
        for f in tree_walk(base):
            rel = f.relative_to(root).as_posix()
            if rel == MANIFEST or not f.is_file() or excluded(rel):
                continue
            try:
                text = f.read_text(encoding="utf-8")
            except (UnicodeDecodeError, ValueError):
                continue
            if colour_re.search(text):
                bad.append(
                    f"{rel}: spells the launch colour {bg} — {MANIFEST} "
                    f"declares it and every reader DERIVES it, so a "
                    f"second copy here is a second source of truth that "
                    f"nothing at run time can see: a slot drawn in the "
                    f"wrong colour still launches, and the first frame "
                    f"after it covers the evidence")

    # C7, THE iOS SLOT. The template carries the key and the build fills
    # it; an EMPTY dict is what this bundle had before the slot was
    # declared, and it is what a revert looks like.
    tpl_rel = "tools/ios/Info.plist.in"
    tpl_path = root / tpl_rel
    if not tpl_path.is_file():
        bad.append(f"{tpl_rel}: is gone, so the iOS bundles carry "
                   f"whatever Info.plist keys nothing writes")
    else:
        tpl = tpl_path.read_text(encoding="utf-8")
        if not re.search(r"<key>UILaunchScreen</key>", tpl):
            bad.append(
                f"{tpl_rel}: declares no UILaunchScreen — iOS has a slot "
                f"and this bundle would not use it")
        elif re.search(r"<key>UILaunchScreen</key>\s*<dict\s*/>", tpl):
            bad.append(
                f"{tpl_rel}: declares an EMPTY UILaunchScreen dict, which "
                f"is the system's plain ground — {MANIFEST} declares a "
                f"colour and a picture and this bundle draws neither")

    ios_rel = "tools/ios/run-sim.py"
    ios_path = root / ios_rel
    if not ios_path.is_file():
        bad.append(f"{ios_rel}: is gone, so nothing assembles the iOS "
                   f"bundles this clause is about")
    else:
        ios = ios_path.read_text(encoding="utf-8")
        for key in ("UIColorName", "UIImageName"):
            if key not in ios:
                bad.append(
                    f"{ios_rel}: never writes {key} — UILaunchScreen "
                    f"takes the colour and the picture under those two "
                    f"names, and a key it does not write is half a slot")
        # MEASURED 2026-09-07: UIColorName resolves ONLY inside a
        # compiled catalog (a loose file has no colour spelling), and a
        # name nothing answers to comes up white with no error.
        if "actool" not in ios:
            bad.append(
                f"{ios_rel}: never runs actool — UIColorName names an "
                f"asset-catalog entry and there is no loose-file "
                f"spelling of a colour, so without a compiled catalog "
                f"the ground comes up white and NOTHING says so")
        if not defined_and_called(ios, "launch_catalog_verify"):
            bad.append(
                f"{ios_rel}: does not both define and CALL "
                f"launch_catalog_verify — the byte comparison lives in "
                f"the packaging step, and this gate is only its static "
                f"half")

    # C7, THE ANDROID SLOT. One theme in the library, named by every
    # app module's manifest, and the call that takes the app back off it.
    theme_rel = "android/kaya/src/main/res/values/themes.xml"
    theme_path = root / theme_rel
    launch_theme = ""
    if not theme_path.is_file():
        bad.append(f"{theme_rel}: is gone, so no kaya app declares a "
                   f"platform theme at all")
    else:
        themes = theme_path.read_text(encoding="utf-8")
        # THE STYLE'S OWN BLOCK, not a window over the file: the plain
        # theme beside it is SELF-CLOSING, so a pattern that opens at
        # `<style name="…"` and runs to the first attribute reads that
        # one's NAME with this one's body (watched, the clause's first
        # draft).
        blocks = {m.group(1): m.group(0) for m in re.finditer(
            r'<style name="([^"]+)"(?![^>]*/>).*?</style>', themes, re.S)}
        hit = [n for n, b in blocks.items()
               if "windowSplashScreenBackground" in b]
        if not hit:
            bad.append(
                f"{theme_rel}: declares no style setting "
                f"windowSplashScreenBackground — Android's slot is theme "
                f"attributes and nothing else, so the APK would draw the "
                f"window background alone")
        else:
            launch_theme = hit[0]
            block = blocks[launch_theme]
            for attr in ("windowSplashScreenAnimatedIcon",
                         "postSplashScreenTheme"):
                if attr not in block:
                    bad.append(
                        f"{theme_rel}: {launch_theme} sets no {attr} — "
                        f"the picture and the theme the activity wears "
                        f"AFTER the slot are the other two thirds of it, "
                        f"and without postSplashScreenTheme the launch "
                        f"colour is the app's window background for its "
                        f"whole life")

    gradle_rel = "android/build.gradle.kts"
    gradle_path = root / gradle_rel
    if not gradle_path.is_file():
        bad.append(f"{gradle_rel}: is gone, so nothing reads the "
                   f"declaration into the APK")
    else:
        gradle = gradle_path.read_text(encoding="utf-8")
        for want in ("kaya_launch_background", "kaya_launch_mark"):
            if want not in gradle:
                bad.append(
                    f"{gradle_rel}: generates no {want} — "
                    f"{theme_rel} names it, and a theme attribute "
                    f"pointing at a resource nothing writes does not "
                    f"build")

    # Every APP module — the manifests that declare a launcher icon; the
    # library's has none, which is how they are told apart without a
    # list to keep in step.
    app_manifests = [f for f in sorted(
        (root / "android").glob("*/src/main/AndroidManifest.xml"))
        if "android:icon" in f.read_text(encoding="utf-8")]
    if not app_manifests:
        bad.append("android/*/src/main/AndroidManifest.xml: no app "
                   "module declares a launcher icon, so C7's Android "
                   "half read nothing and would agree with anything")
    for mf in app_manifests:
        rel = mf.relative_to(root).as_posix()
        module = mf.relative_to(root).parts[1]
        text = mf.read_text(encoding="utf-8")
        if launch_theme and f"@style/{launch_theme}" not in text:
            bad.append(
                f"{rel}: names no android:theme=\"@style/{launch_theme}\" "
                f"— the platform reads the slot off the MANIFEST theme "
                f"before any of this app's code runs, so a module on the "
                f"plain theme has no slot however the declaration reads")
        acts = sorted((root / "android" / module / "src/main/kotlin")
                      .rglob("MainActivity.kt"))
        if not acts:
            bad.append(f"android/{module}: declares a launcher icon and "
                       f"has no MainActivity.kt, so nothing can take it "
                       f"off the launch theme")
        for act in acts:
            arel = act.relative_to(root).as_posix()
            if "installSplashScreen()" not in act.read_text(
                    encoding="utf-8"):
                bad.append(
                    f"{arel}: never calls installSplashScreen() while "
                    f"{rel} names the launch theme — the activity then "
                    f"KEEPS that theme, so {bg} is its window background "
                    f"for the app's whole life. No scene can see it "
                    f"(every kaya surface paints its own ground) and the "
                    f"app still launches")

    runner_rel = "tools/android/run-emulator.py"
    runner_path = root / runner_rel
    if not runner_path.is_file():
        bad.append(f"{runner_rel}: is gone, so the APK's launch bytes "
                   f"are compared by nothing")
    else:
        runner = runner_path.read_text(encoding="utf-8")
        if not defined_and_called(runner, "apk_launch_verify"):
            bad.append(
                f"{runner_rel}: does not both define and CALL "
                f"apk_launch_verify — the picture's bytes and the "
                f"colour's value inside the APK are held to "
                f"{MANIFEST} there, on the path nobody can avoid, and "
                f"this gate is only the static half of that")

    return bad


# ---------------------------------------------------------- self-tests
def fresh(name):
    """A shadow root of symlinks the checker can read."""
    dst = g.scratch() / name
    n = 0
    for r in SOURCE_ROOTS:
        for f in tree_walk(ROOT / r):
            if not f.is_file():
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


def doctor_pixel(label, shadow_root, rel, x, y):
    """Repaint the whole quadrant holding (x, y) in a copy of the mark
    — the simplest edit that produces a valid PNG a decoder will agree
    with — and refuse if the sampled pixel did not move."""
    path = shadow_root / rel
    data = path.read_bytes()
    i, idat, hdr = 8, b"", None
    while i + 8 <= len(data):
        ln = struct.unpack(">I", data[i:i + 4])[0]
        typ = data[i + 4:i + 8]
        chunk = data[i + 8:i + 8 + ln]
        if typ == b"IHDR":
            hdr = struct.unpack(">IIBBBBB", chunk)
        elif typ == b"IDAT":
            idat += chunk
        i += 12 + ln
    w, h, depth, colour, _c, _f, _il = hdr
    if (depth, colour) != (8, 2):
        g.refuse("SELF-TEST FAIL (the mark is no longer 8-bit "
                 "truecolour; the pixel doctor reads only that)")
    raw = bytearray(zlib.decompress(idat))
    stride = w * 3
    rows, prev, pos = [], bytearray(stride), 0
    for _ in range(h):
        ft = raw[pos]
        line = bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride
        for k in range(stride):
            a = line[k - 3] if k >= 3 else 0
            b = prev[k]
            c = prev[k - 3] if k >= 3 else 0
            if ft == 1:
                line[k] = (line[k] + a) & 0xFF
            elif ft == 2:
                line[k] = (line[k] + b) & 0xFF
            elif ft == 3:
                line[k] = (line[k] + (a + b) // 2) & 0xFF
            elif ft == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (
                    b if pb <= pc else c)
                line[k] = (line[k] + pr) & 0xFF
        rows.append(line)
        prev = line
    before = bytes(rows[y][x * 3:x * 3 + 3])
    qx, qy = (x // (w // 2)) * (w // 2), (y // (h // 2)) * (h // 2)
    for yy in range(qy, qy + h // 2):
        for xx in range(qx, qx + w // 2):
            rows[yy][xx * 3:xx * 3 + 3] = b"\x12\x34\x56"
    after = bytes(rows[y][x * 3:x * 3 + 3])
    body = b"".join(b"\x00" + bytes(r) for r in rows)

    def chunk(typ, payload):
        return (struct.pack(">I", len(payload)) + typ + payload
                + struct.pack(">I",
                              zlib.crc32(typ + payload) & 0xFFFFFFFF))

    out = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0,
                                        0))
           + chunk(b"IDAT", zlib.compress(body))
           + chunk(b"IEND", b""))
    path.unlink()
    path.write_bytes(out)
    moved = 0 if before == after else 1
    print(f"check-app-identity: self-test {label}, {moved} "
          f"substitution(s)")
    if moved != 1:
        g.refuse(f"SELF-TEST FAIL ({label} applied {moved} times, want "
                 f"at least 1 — an unchanged copy cannot prove the "
                 f"rule fires)")


# The declared icon's ASSET name (the manifest's `icon` minus the asset
# root's prefix), a regex matching it, and a NEIGHBOUR of it: same
# family, not the declared file. DERIVED, because THIS SCRIPT IS IN THE
# TREE THE CHECKER READS — an asset call naming any file in the mark's
# family but the declared one makes the gate refuse itself, and the rule
# reaches prose, so no comment here may spell one either.
def declared(which):
    man = ROOT / MANIFEST
    icon = tomllib.loads(man.read_text(encoding="utf-8"))["icon"] \
        .replace("\\", "/")
    if not icon.startswith(ASSET_ROOT):
        g.refuse("SELF-TEST FAIL (the declared icon is not under the "
                 "asset root, so no guest can open it by name and "
                 "neither of C3's asset perturbations means anything)")
    asset_name = icon[len(ASSET_ROOT):]
    family, _, base = asset_name.rpartition("/")
    return {"name": asset_name,
            "pattern": re.escape(asset_name),
            "other": f"{family}/not-{base}"}[which]


# N0 — the shadow root itself must pass, or every refusal below could
# be an artifact of the copy rather than of the perturbation.
base_shadow = fresh("base")
out = check(base_shadow)
if out:
    print("\n".join(out))
    print("check-app-identity: FAIL — refused before any perturbation, "
          "so this is the tree and not the self-test", file=sys.stderr)
    raise SystemExit(1)

# N1 — THE DRIFT ITSELF: repaint a quadrant of the declared mark and
# watch the byte-frozen scene expectation stop being true of it — the
# failure that would otherwise surface as five red lanes.
s = fresh("repainted")
mark_rel = tomllib.loads((ROOT / MANIFEST).read_text(
    encoding="utf-8"))["icon"].replace("\\", "/")
doctor_pixel("the repainted-quadrant perturbation", s, mark_rel, 16, 16)
g.negative("a mark whose pixels left the scene's expectation behind",
           lambda p=s: check(p), want="quadrant centres")

# N2 — the name changed in the manifest and nowhere else. Since
# docs/tasks-s3-plan.md N4 the guests carry no name at all, so the wall
# is the SCENE: the name half of the declaration is read back off a real
# window, and a manifest nobody observes is a name that ships unwatched.
s = fresh("renamed")
doctor_shadow("the manifest rename", s, MANIFEST,
              r'name = "Aurora Notes"', 'name = "Borealis Notes"')
g.negative("a manifest name no scene reads back", lambda p=s: check(p),
           want="never reads the declared name")

# N2a — C4'S OWN NEGATIVE: a guest that stops CALLING the declaration.
# The call is the act — a declared app is a Dock app on macOS — and it
# is all that is left in a guest now that the values moved to the core,
# so a guest that dropped it would ship unidentified with every other
# clause green.
s = fresh("uncalled")
doctor_shadow("the uncalled-declaration perturbation", s,
              "guests/python/identity.py",
              r"kaya\.app_identity\(\)", "pass  # declared nowhere")
g.negative("a guest that never calls the declaration",
           lambda p=s: check(p),
           want="never CALLS the identity declaration")

# N2b — THE RETYPED VALUE, the duplication N4 removed: a guest that
# spells the name again would have it silently replaced by the
# manifest's at the root, so nothing at run time could tell the two
# apart.
s = fresh("retypedname")
doctor_shadow("the retyped-name perturbation", s,
              "guests/js/identity.ts",
              r"kaya\.appIdentity\(\)",
              'kaya.appIdentity(); // Aurora Notes')
g.negative("a guest that retypes the declared name",
           lambda p=s: check(p), want="spells the declared name")

# N2c — C8: the manifest without its reverse-DNS id, which is the one
# value a notification cannot be posted without.
s = fresh("noid")
doctor_shadow("the missing-id perturbation", s, MANIFEST,
              r'(?m)^id = "[^"]+"$', "# no id declared")
g.negative("a manifest with no reverse-DNS id", lambda p=s: check(p),
           want="declares no non-empty `id`")

# N2d — and an id that is not reverse-DNS at all: Apple refuses the
# bundle identifier and GNOME attributes the notification to nothing,
# so the post fails on two platforms and nowhere else.
s = fresh("flatid")
doctor_shadow("the flat-id perturbation", s, MANIFEST,
              r'(?m)^id = "[^"]+"$', 'id = "AuroraNotes"')
g.negative("an id that is not a reverse-DNS name",
           lambda p=s: check(p), want="is not a reverse-DNS name")

# N3 — the icon path changed in the manifest and nowhere else.
s = fresh("repathed")
doctor_shadow("the manifest repath", s, MANIFEST,
              r'icon = "' + re.escape(mark_rel) + r'"',
              'icon = "' + mark_rel.rsplit(".", 1)[0]
              + '-repathed-by-selftest.png"')
g.negative("a manifest naming a missing icon", lambda p=s: check(p),
           want="which is not a file in this tree")

# N4 — a SECOND copy of the art, which is ruling 1's quiet failure.
s = fresh("twocopies")
res = s / "android/kaya/src/main/res/mipmap-hdpi"
res.mkdir(parents=True)
(res / "ic_launcher.png").write_text("not the declared mark",
                                     encoding="utf-8")
g.negative("a packaging resource carrying its own private art",
           lambda p=s: check(p),
           want="is an app-icon resource whose bytes are not the "
                "declared")

# N5 — a packaging step that retypes the path instead of reading it.
s = fresh("retyped")
(s / "tools" / "zz-selftest-packager.sh").write_text(
    f'cp {mark_rel} "$STAGE/icon.png"\n', encoding="utf-8")
g.negative("a tools/ packaging step that hard-codes the icon path",
           lambda p=s: check(p),
           want=f"never reads {MANIFEST}")

# N6 — the scene stops observing the name, which would make the name
# half of the declaration ship unwatched.
s = fresh("unobserved")
doctor_shadow("the unobserved-name perturbation", s,
              "tools/scenes/identity.steps",
              r'expect_title window#1 "Aurora Notes"',
              'expect_title window#1 "identity"')
g.negative("a scene that stopped reading the name back",
           lambda p=s: check(p), want="never reads the declared name")

# N7 — the vacuity half: no scene asserts the icon at all. A gate that
# stopped finding its site must be loud rather than clean. Both verb
# sites replaced (anchored: a comment naming the verb is not a site).
s = fresh("noobservation")
doctor_shadow("the no-observation perturbation", s,
              "tools/scenes/identity.steps", r"(?m)^expect_app_icon",
              "expect_app_haiku", want=2)
g.negative("a tree where no scene reads the icon",
           lambda p=s: check(p), want="would agree with anything")

# N8 — C3'S OWN NEGATIVE: put the environment read back into a guest
# and take the asset call away, so the file names KAYA_ICON_FILE and
# neither the declared path, the manifest nor an asset — the third
# source of truth the clause is about.
mark_re = declared("pattern")
s = fresh("envreader")
# THE HOST IS THE ASSETS GUEST since docs/tasks-s3-plan.md N4: the
# identity guests stopped opening the mark when app_identity() stopped
# taking one, and this clause needs a file that still does.
doctor_shadow("the environment-reader perturbation", s,
              "guests/rust/assets.rs",
              r'const MARK: &str = "' + mark_re + r'";',
              'const MARK: &str = "unused"; // std::env::var("KAYA_ICON_FILE")')
g.negative("a guest that names the override with no declaration "
           "behind it", lambda p=s: check(p),
           want="names the declaration in none of C3's three ways")

# N9 — THE ASSET ARM'S OWN NEGATIVE: a site that opens a DIFFERENT file
# out of the mark's family. Nothing checks an asset name at compile
# time, and a name nothing answers to fails SILENTLY.
#
# THE HOST MOVED WITH N4: the identity guests were the asset-call sites
# and they open nothing now, so what is left in the tree that spells the
# mark inside an `asset(...)` call is the Go binding's own asset test.
# The clause is also less needed than it was — the core DERIVES the
# asset name from the manifest, so the guests have no name left to
# mistype — but a live site keeps it from passing vacuously.
other_mark = declared("other")
s = fresh("othermark")
doctor_shadow("the other-mark perturbation", s,
              "bindings/go/asset_test.go",
              r'tx\.Asset\("' + mark_re + r'"\)',
              f'tx.Asset("{other_mark}")')
g.negative("a guest opening an asset the manifest does not declare",
           lambda p=s: check(p),
           want="in the declared mark's own family but is not it")

# --------------------------------------------------------------- C7 ---
# N10 — a launch background nothing can turn into a colour.
s = fresh("badcolour")
doctor_shadow("the half-spelled launch colour", s, MANIFEST,
              r'background = "#[0-9A-Fa-f]{6}"',
              'background = "dark grey"')
g.negative("a launch background that is not #RRGGBB",
           lambda p=s: check(p), want="which is not #RRGGBB")

# N11 — THE SECOND SOURCE OF TRUTH: the colour typed into a build step
# instead of derived. Silent at run time — a slot drawn in the wrong
# colour still launches, and the app's own first frame covers it.
s = fresh("twocolours")
_bg = tomllib.loads((ROOT / MANIFEST).read_text(
    encoding="utf-8"))["launch"]["background"]
(s / "tools" / "zz-selftest-splash.sh").write_text(
    f'splash_background="{_bg}"\n', encoding="utf-8")
g.negative("a build step that retypes the launch colour",
           lambda p=s: check(p), want="spells the launch colour")

# N12 — THE FORGOTTEN CALL: an app module on the launch theme whose
# activity never leaves it. The app launches and every scene passes.
s = fresh("nocall")
doctor_shadow("the missing installSplashScreen", s,
              "android/rusthost/src/main/kotlin/dev/kaya/rusthost/"
              "MainActivity.kt",
              r"\n\s*installSplashScreen\(\)", "")
g.negative("an app module that keeps the launch theme for its whole life",
           lambda p=s: check(p), want="never calls installSplashScreen()")

# N13 — a module put back on the plain theme: the platform reads the
# slot off the MANIFEST theme, so this one has none.
s = fresh("plaintheme")
doctor_shadow("the reverted manifest theme", s,
              "android/gohost/src/main/AndroidManifest.xml",
              r'android:theme="@style/Theme\.Kaya\.Launch"',
              'android:theme="@style/Theme.Kaya.NoActionBar"')
g.negative("an app module whose manifest names no launch theme",
           lambda p=s: check(p), want="names no android:theme=")

# N14 — the iOS slot back to the empty dict it carried before T4.
s = fresh("emptylaunch")
doctor_shadow("the emptied UILaunchScreen", s, "tools/ios/Info.plist.in",
              r"<key>UILaunchScreen</key>\n    @LAUNCH@",
              "<key>UILaunchScreen</key>\n    <dict/>")
g.negative("an iOS bundle whose launch screen is the system's plain "
           "ground", lambda p=s: check(p), want="EMPTY UILaunchScreen")

# N15 — the theme keeps the colour and loses the picture.
s = fresh("noicon")
doctor_shadow("the dropped splash icon", s,
              "android/kaya/src/main/res/values/themes.xml",
              r'<item name="windowSplashScreenAnimatedIcon">'
              r'[^<]*</item>\n\s*', "")
g.negative("a splash theme with a colour and no picture",
           lambda p=s: check(p), want="sets no windowSplashScreenAnimatedIcon")

# N16 — the APK's own byte check stops being called, which is where the
# comparison actually lives.
s = fresh("noapkverify")
doctor_shadow("the uncalled apk_launch_verify", s,
              "tools/android/run-emulator.py",
              r"    if not apk_launch_verify\(apk\):\n        "
              r"return False\n", "")
g.negative("a lane that packages the slot and never checks it",
           lambda p=s: check(p), want="define and CALL apk_launch_verify")

# ---------------------------------------------------- C9, C10, C11, C12
# N17 — THE DESCRIPTION DRIFTING FROM THE COMMITTED SOURCE (P2): the
# example asset is what `render_png` writes, and a colour changed in the
# table without a regeneration leaves the two disagreeing about what this
# repo's own app looks like. DERIVED, not retyped: the perturbation reads
# the table's first entry out of the file rather than spelling a quadrant
# here.
s = fresh("markdrift")
doctor_shadow("the drifted mark description", s,
              f"{PACKAGING_DIR}/mark.py",
              r'QUADRANTS = \("[0-9A-Fa-f]{6}"',
              'QUADRANTS = ("00FF00"')
g.negative("a renderer whose description left the committed source behind",
           lambda p=s: check(p), want="run tools/regen-mark.py")

# N17a — C11'S OTHER HALF: an arm that DRAWS the mark instead of
# resampling the declared file. It would package this repo's own picture
# for every app that ever declares one, and no lane could see it — the
# example app's declared mark and the description's output are the same
# picture on purpose.
s = fresh("rendering-arm")
(s / PACKAGING_DIR / "zz_selftest_render.py").write_text(
    '"""An arm that draws instead of resampling."""\n'
    "from .identity import load\n"
    "from . import mark\n\n"
    "def package(root, executable, out_dir):\n"
    "    load(root)\n"
    "    return mark.render_png(64)\n",
    encoding="utf-8")
g.negative("a packaging arm that renders the mark instead of resampling "
           "the declared file", lambda p=s: check(p),
           want="calls render_png")

# N17b — C13'S OWN NEGATIVE, and it is MY OWN DEFECT spliced back in:
# the lowering sentence reworded THROUGH the phrase the wayland witness
# greps. It reddened identity-witness-rust-wayland on 2026-09-08 with a
# sentence that says, in words, exactly what the witness said it could
# not find.
s = fresh("rewordedphrase")
doctor_shadow("the reworded lowering sentence", s,
              PHRASE_SITES["GTK_ICON_LOWERED"],
              r"gdk_toplevel_set_icon_list with it on window \\\n",
              "gdk_toplevel_set_icon_list with the texture on window \\\n")
g.negative("a backend that reworded the sentence a leg parses",
           lambda p=s: check(p), want="no longer prints")

# N18 — C9'S OWN NEGATIVE: a second parser of the declaration. Silent
# until the day a half-spelled manifest reaches two readers with two sets
# of refusals.
s = fresh("secondreader")
(s / "tools" / "zz-selftest-reader.py").write_text(
    "import tomllib\n"
    f'print(tomllib.loads(open("{MANIFEST}").read())["name"])\n',
    encoding="utf-8")
g.negative("a tools/ script that parses the declaration itself",
           lambda p=s: check(p), want="There is ONE reader in tools/")

# N19 — C10'S OWN NEGATIVE: an arm that writes an identity artifact
# without reading the declaration, which is where a retyped name gets in.
s = fresh("blindarm")
(s / PACKAGING_DIR / "zz_selftest_arm.py").write_text(
    '"""A platform arm that reads nothing."""\n'
    "def package(root, executable, out_dir):\n"
    "    return out_dir\n",
    encoding="utf-8")
g.negative("a packaging arm that never reads the declaration",
           lambda p=s: check(p),
           want="never names the shared reader's `load`")

# N20/N21 — C12'S OWN NEGATIVES, one per generator in the table, so a
# platform added to it brings its own watched negative with it: a second
# copy of an arm's own tool is the lane wrapper the generator replaced,
# coming back.
for _n, _tool in enumerate(sorted(ONE_GENERATOR)):
    s = fresh(f"secondgen{_n}")
    (s / "tools" / f"zz-selftest-gen{_n}").write_text(
        f"# a second generator, assembling an identity artifact of its own\n"
        f"{_tool}\n", encoding="utf-8")
    g.negative(f"a second copy of {_tool!r} outside the arms",
               lambda p=s: check(p), want="belongs to one arm alone")

g.negatives_ran(27)

# The vacuity floor rule 5 asks for: the census below walks these six
# roots, and a walk that found almost nothing agrees with everything.
g.counted("files under the source roots",
          [f for r in SOURCE_ROOTS for f in tree_walk(ROOT / r)
           if f.is_file()], floor=200)

offenders = check(ROOT)
if offenders:
    print("\n".join(offenders))
    print("check-app-identity: FAIL")
    raise SystemExit(1)
g.verdict()
