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
# ONE DECLARATION, TWO READERS, AND NOTHING BETWEEN THEM THAT CAN DRIFT.
#
# docs/app-identity-plan.md ruling 4: an app's identity is a NAME and a
# PICTURE FILE declared in one place, guests/assets/identity.toml, and
# two different kinds of consumer read it.
#
#   the BUILD, before any program has run — the APK's mipmap resource
#   and android:icon/android:label, the iOS bundle's icon and
#   CFBundleDisplayName, a .desktop file's Icon=/Name=;
#   the RUNNING APP, which sends that same file's BYTES over the wire in
#   `set_app_identity`, reaching the macOS Dock, the Windows taskbar and
#   caption, and an X11 window.
#
# The plan states the failure this gate exists for in one sentence:
# "five routes reading five different files is how a promise like this
# one gets broken quietly". The launcher shows last month's icon, the
# running window shows this month's, and every test still passes,
# because each reader is internally consistent. Nothing else in the tree
# compares two readers with each other.
#
# WHERE THE WALL SITS. Invariant 3 asks for the guard on a path nobody
# can avoid, so the byte comparison ITSELF lives in each packaging step —
# the step that copies the icon into an artifact compares what it wrote
# with what the manifest declares and refuses. This gate is the static
# half: it holds the DECLARATION and every hand-written copy of it level
# with each other, on every platform at once, including the platforms
# whose packaging step does not exist yet.
#
# THE CLAUSES, and what each one is for:
#
#   C1  the manifest declares a non-empty name and an icon file that
#       exists and is not empty. Everything below reads those two values
#       out of it; neither is ever written down in this gate.
#
#   C2  THE PIXELS ARE THE EXPECTATION. tools/scenes/*.steps are shared
#       verbatim across every platform and language and are compared
#       byte-for-byte, so `expect_app_icon "E01B24/33D17A/1C71D8/F6D32D"`
#       is a frozen string — and it is a claim about the CONTENT of the
#       declared icon. This clause decodes the icon and samples the four
#       quadrant centres, so swapping the asset without moving the
#       expectation fails HERE rather than on five lanes at once. It is
#       also what keeps guests/assets/icons/README.md's argument true:
#       the mark's four flat quadrants are what survives a per-platform
#       conversion, and a mark that stopped having them would make every
#       identity leg unfalsifiable.
#
#   C3  THE DECLARATION IS WRITTEN DOWN ONCE. The runtime readers are
#       eight languages and a batch file, none of which parses TOML, so
#       a site may name the declaration in THREE ways and no fourth:
#
#         READ THE MANIFEST — what a script that can parse TOML does;
#         SPELL THE DECLARED PATH — what the .cmd launchers and the lane
#           scripts' repo-relative KAYA_ICON_FILE default do (backslashes
#           and a drive-letter mirror allowed, since tools/deploy-win.sh
#           stages the tree to C:\kaya);
#         OPEN IT AS AN ASSET — `asset("icons/kaya-mark.png")`, which is
#           the manifest's path with the asset root's prefix removed, and
#           is what the eight identity guests say since they stopped
#           resolving their own icon path (docs/assets-plan.md). This
#           gate DERIVES that name from the manifest; typing it here
#           would be the very second source of truth the clause exists
#           to prevent.
#
#       They may spell it, but they may not DISAGREE with it. Two ways to
#       disagree, and both are checked: naming KAYA_ICON_FILE while
#       naming none of the three is a third source of truth wearing the
#       override's name, and opening some OTHER file out of the mark's
#       own asset family is a second mark — which is silent at runtime,
#       because an asset name nothing answers to leaves each platform's
#       own icon in place.
#
#   C4  THE NAME IS WRITTEN DOWN ONCE, same rule one field over: every
#       identity guest declares it, and the scene's own
#       `expect_title window#1` reads it back off the platform. Those are
#       the two ends of the name half of the declaration and they cannot
#       be allowed to part.
#
#   C5  ONE PICTURE. Any app-icon resource anywhere in the tree — an
#       Android mipmap/drawable launcher icon, a .ico, a .icns, an
#       AppIcon — must be BYTE-IDENTICAL to the declared icon, or be in
#       EXCLUDED with a reason. This is the byte-equality half that can
#       be checked without building anything, and it is what stops a
#       packaging step from growing its own private copy of the art.
#
#   C6  A PACKAGING CONSUMER READS THE MANIFEST. A tools/ script that
#       stages or packages the icon must obtain the path FROM
#       guests/assets/identity.toml rather than hard-coding it; a script
#       that names the icon and not the manifest fails. The .cmd
#       launchers are exempt and C3 covers them instead — a batch file
#       cannot read TOML, which is a fact about cmd.exe and not a
#       loophole.
#
# THE SELF-TEST at the bottom runs the real checker over a shadow root of
# symlinks with one file doctored, and requires the red. A fixture would
# only ever prove the patterns match the fixture, which is how the
# wayland seat guard passed vacuously twice (docs/traps.md).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

# The checker takes ONE argument: a root to read the tree out of.
check() {
    python3 - "$1" <<'PY'
import pathlib
import re
import struct
import sys
import tomllib
import zlib

root = pathlib.Path(sys.argv[1])
bad = []

MANIFEST = "guests/assets/identity.toml"

# Directory names that hold BUILD OUTPUT rather than tree. Pruned by
# name while walking, not filtered after: the unpruned walk of this
# repo visits 752,511 paths, 750,000 of which are cargo's, and a gate
# that takes a minute and a half is a gate people stop running.
#
# `build` is in the list for a second reason, and it is a rule about
# WHERE each half of the byte-equality check belongs. This gate is the
# STATIC half; the bytes actually written into an artifact are checked
# by the packaging step itself, which is the path nobody can avoid
# (invariant 3). Reading a build directory here would make the verdict
# depend on whatever the last build — or the last WATCHED NEGATIVE —
# left lying around: measured 2026-08-18, this clause went red on
# `android/*/build/generated/kaya-identity/res/mipmap/kaya_mark.png`,
# a gitignored artifact of the android arm's own disagreement test.
# A gate that a negative test can turn red afterwards is a gate whose
# red means nothing.
PRUNE = {".git", ".gradle", ".build", "build", "target", "_build", "obj",
         "bin", "node_modules", "__pycache__", "DerivedData"}


def walk(base):
    """Every file under `base`, artifact directories pruned."""
    import os
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames if d not in PRUNE)
        for f in sorted(filenames):
            yield pathlib.Path(dirpath) / f

# Files that carry app-icon-shaped bytes and are NOT the declared mark,
# each with the reason it is exempt. An entry here is a claim, so keep
# them narrow: a directory prefix, never a bare extension.
EXCLUDED = {
    "third_party": "vendored SDKs ship their own art; nothing in the tree "
                   "packages it as kaya's identity",
}

# The scripts that may name the icon without reading the manifest,
# because their language cannot read it.
CMD_LAUNCHERS = "tools/guest/"


def excluded(rel: str):
    for prefix, why in EXCLUDED.items():
        if rel == prefix or rel.startswith(prefix + "/"):
            return why
    return None


# ---------------------------------------------------------------- C1
man_path = root / MANIFEST
if not man_path.is_file():
    print(f"{MANIFEST}: the app identity's declaration is missing — "
          "docs/app-identity-plan.md ruling 4 makes this file the source "
          "of truth for both the build and the running app")
    sys.exit(1)
try:
    manifest = tomllib.loads(man_path.read_text(encoding="utf-8"))
except Exception as exc:                                  # noqa: BLE001
    print(f"{MANIFEST}: does not parse as TOML: {exc}")
    sys.exit(1)

name = manifest.get("name")
icon_rel = manifest.get("icon")
if not isinstance(name, str) or not name.strip():
    bad.append(f"{MANIFEST}: declares no non-empty `name` — an app that "
               "wants the platform's own identity declares none at all, "
               "and an empty one would sail through five lowerings")
if not isinstance(icon_rel, str) or not icon_rel.strip():
    bad.append(f"{MANIFEST}: declares no non-empty `icon`")

icon_bytes = b""
if isinstance(icon_rel, str) and icon_rel.strip():
    icon_path = root / icon_rel
    if not icon_path.is_file():
        bad.append(f"{MANIFEST}: names icon \"{icon_rel}\", which is not a "
                   "file in this tree")
    else:
        icon_bytes = icon_path.read_bytes()
        if not icon_bytes:
            bad.append(f"{icon_rel}: the declared icon is empty")

if bad:
    print("\n".join(bad))
    sys.exit(1)


# ---------------------------------------------------------------- C2
def decode_png(data: bytes):
    """(width, height, pixel(x, y) -> (r, g, b)). Deliberately narrow:
    8-bit, non-interlaced. A mark outside that is a real finding — every
    platform's decoder is being asked to reproduce these pixels, and the
    reason to widen this is a mark somebody chose, not a guess made
    here."""
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
        raise ValueError(f"bit depth {depth}, interlace {interlace} — this "
                         "gate reads 8-bit non-interlaced PNGs only")
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
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
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
            g = row[x * channels]
            return (g, g, g)
        o = x * channels
        return (row[o], row[o + 1], row[o + 2])

    return w, h, pixel


def quadrant_samples(data: bytes) -> str:
    w, h, pixel = decode_png(data)
    out = []
    for qy in (0, 1):
        for qx in (0, 1):
            x = qx * (w // 2) + (w // 4)
            y = qy * (h // 2) + (h // 4)
            out.append("%02X%02X%02X" % pixel(x, y))
    return "/".join(out)


scene_dir = root / "tools/scenes"
want_pattern = re.compile(r'expect_app_icon\s+"([^"]*)"')
scene_hits = []
for steps in sorted(scene_dir.glob("*.steps")):
    for n, line in enumerate(steps.read_text(encoding="utf-8").splitlines(), 1):
        m = want_pattern.search(line.strip())
        if m and not line.strip().startswith("#"):
            scene_hits.append((steps.relative_to(root).as_posix(), n, m.group(1)))

if not scene_hits:
    bad.append("tools/scenes: no scene asserts expect_app_icon at all — the "
               "identity lowering has no observation on any platform, so "
               "this gate would agree with anything")
else:
    try:
        measured = quadrant_samples(icon_bytes)
    except Exception as exc:                              # noqa: BLE001
        measured = None
        bad.append(f"{icon_rel}: cannot be decoded here ({exc}), so the "
                   "expectation in tools/scenes cannot be held to the "
                   "pixels every platform's decoder is asked to reproduce")
    if measured is not None:
        for rel, n, want in scene_hits:
            if want != measured:
                bad.append(
                    f"{rel}:{n}: expects app icon \"{want}\" but the declared "
                    f"mark ({icon_rel}) samples \"{measured}\" at its four "
                    "quadrant centres — the scene is byte-frozen across every "
                    "platform and language, so the asset and the expectation "
                    "move together or not at all")

# ---------------------------------------------------------------- C3/C6
icon_posix = icon_rel.replace("\\", "/")

# THE THIRD WAY TO NAME THE DECLARATION, DERIVED AND NEVER RETYPED. A
# guest that opens the mark as an ASSET names it the way the core
# resolves it — by its path UNDER THE ASSET ROOT, with no repo checkout,
# bundle or APK in front of it — so the accepted string is the manifest's
# own `icon` minus that prefix and nothing else. Deriving it is the whole
# point of the clause: a literal "icons/kaya-mark.png" written down here
# would be exactly the second source of truth C3 exists to refuse.
ASSET_ROOT = "guests/assets/"
icon_under_root = (icon_posix[len(ASSET_ROOT):]
                   if icon_posix.startswith(ASSET_ROOT) else None)
if icon_under_root is None:
    bad.append(f"{MANIFEST}: declares icon \"{icon_rel}\", which is not under "
               f"the asset root {ASSET_ROOT} — the identity guests open the "
               "mark by asset name, and a file outside the root has no asset "
               "name for them to open")
# The family the mark lives in (`icons`), for the wrong-name half below.
icon_family = icon_under_root.split("/")[0] if icon_under_root else None

# Every language's spelling of one call, and they differ only in what
# sits in front of the word and whether a paren follows:
#
#   tx.asset("...")      kaya.asset("...")     tx.Asset("...")
#   KayaApp.asset("...") KayaAsset("...")      asset "..."
#
# No leading word boundary, because Swift's constructor is `KayaAsset(`
# and OCaml's is a bare `asset `. The looseness costs nothing: the only
# two questions asked of a captured name are whether the DECLARED one is
# among them and whether any of them is in the mark's family but is not
# the declared one, and a stray capture (`AppIdentityAsset("Aurora
# Notes"` matches, and its argument is the app's NAME) answers no to
# both.
ASSET_CALL = re.compile(r'(?i)asset\s*\(?\s*"([^"\n]+)"')

manifest_readers, icon_namers = [], []
SOURCE_ROOTS = ("guests", "tools", "android", "swift", "crates", "bindings")
for r in SOURCE_ROOTS:
    base = root / r
    if not base.is_dir():
        continue
    for f in walk(base):
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
        asset_names = {m.group(1) for m in ASSET_CALL.finditer(text)}
        names_asset = icon_under_root is not None and icon_under_root in asset_names
        if MANIFEST in text:
            manifest_readers.append(rel)
        # PROSE AND SCENE SCRIPTS ARE NOT READERS. A .md file explains
        # the mechanism and a tools/scenes/*.steps file records why the
        # guest opens a file at all; neither copies a byte anywhere, and
        # demanding they parse the manifest would be a rule about
        # documentation rather than about drift.
        prose = rel.endswith(".md") or rel.startswith("tools/scenes/")
        # C3, THE ASSET FORM'S OWN HALF, and it is asked BEFORE the
        # is-this-a-namer question below rather than after. A file that
        # opens the WRONG file out of the mark's family names none of the
        # three accepted forms, so it would fall out of this loop
        # unlooked-at — and it is precisely the failure the asset form
        # introduced: an asset call carrying a mistyped name compiles in
        # all eight languages and, at runtime, leaves whatever icon the
        # platform already had. (No comment here may quote such a name;
        # the arm would read it and refuse this file. See `declared`
        # below, which is where the self-test's own counterexample comes
        # from.)
        if not prose and icon_family:
            for other in sorted(n for n in asset_names
                                if n.startswith(icon_family + "/")
                                and n != icon_under_root):
                bad.append(
                    f"{rel}: opens the asset \"{other}\", which is in the "
                    f"declared mark's own family but is not it — {MANIFEST} "
                    f"declares \"{icon_rel}\", and under the asset root that "
                    f"is \"{icon_under_root}\". One picture is the picture on "
                    "all five platforms (ruling 1), and a name nothing "
                    "answers to fails SILENTLY: the platform's own icon "
                    "stays, and every expectation that reads it goes red "
                    "somewhere else")
        if not (names_var or names_path or names_asset):
            continue
        if prose:
            continue
        icon_namers.append(rel)
        # C3 — a site that names the variable must get its DEFAULT from
        # the declaration: by reading the manifest, by spelling the
        # declared path, or by opening the declared asset. Naming none of
        # them is a third source of truth wearing the override's name.
        if names_var and not names_path and not names_asset and MANIFEST not in text:
            bad.append(
                f"{rel}: names KAYA_ICON_FILE but names the declaration in "
                f"none of C3's three ways — not the path \"{icon_rel}\", not "
                f"the asset name \"{icon_under_root}\", not {MANIFEST} — and "
                "the override needs a default to override, so the default is "
                "the manifest's or it is a second source of truth")
        # C6 — a tools/ consumer derives the path; it does not retype it.
        if (rel.startswith("tools/") and not rel.startswith(CMD_LAUNCHERS)
                and MANIFEST not in text):
            bad.append(
                f"{rel}: stages or packages the app mark but never reads "
                f"{MANIFEST} — a packaging step that retypes the path is the "
                "second reader ruling 4 exists to prevent (batch launchers "
                f"under {CMD_LAUNCHERS} are exempt: cmd.exe cannot read TOML, "
                "and C3 holds their literal to the manifest instead)")

if not icon_namers:
    bad.append("no file in the tree names the declared icon — not its path, "
               "not its asset name, not KAYA_ICON_FILE — so C3 read nothing "
               "and would agree with any manifest")

# ---------------------------------------------------------------- C4
guests = sorted((root / "guests").glob("*/identity.*"))
if not guests:
    bad.append("guests/*/identity.*: no identity guest exists, so the name "
               "half of the declaration has no writer and C4 reads nothing")
for g in guests:
    rel = g.relative_to(root).as_posix()
    if name not in g.read_text(encoding="utf-8"):
        bad.append(f"{rel}: does not declare the identity name \"{name}\" "
                   f"that {MANIFEST} declares — one app, one name")

steps = root / "tools/scenes/identity.steps"
if steps.is_file():
    text = steps.read_text(encoding="utf-8")
    if not re.search(r'expect_title\s+window#1\s+"%s"' % re.escape(name), text):
        bad.append(f"tools/scenes/identity.steps: never reads the declared "
                   f"name \"{name}\" back off a window — the name half of the "
                   "declaration would ship unobserved on every platform")

# ---------------------------------------------------------------- C5
ICONISH = re.compile(r"(^|/)(mipmap|drawable)[^/]*/", re.I)
resources = []
for f in walk(root):
    rel = f.relative_to(root).as_posix()
    if not f.is_file() or f.is_symlink():
        continue
    if excluded(rel):
        continue
    lower = rel.lower()
    hit = (lower.endswith((".ico", ".icns"))
           or ICONISH.search(lower) is not None
           or pathlib.PurePosixPath(lower).name.startswith(("ic_launcher", "appicon")))
    if not hit or rel == icon_rel:
        continue
    resources.append(rel)
    if f.read_bytes() != icon_bytes:
        bad.append(
            f"{rel}: is an app-icon resource whose bytes are not the declared "
            f"mark's ({icon_rel}) — ruling 1 is that one picture is the "
            "picture on all five platforms, so a packaging step reads the "
            "declared file or it is showing something else")

print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
}

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# <destination> -> a shadow root of symlinks the checker can read
shadow() {
    python3 -c '
import os
import pathlib
import sys

root, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
ROOTS = ["guests", "tools", "android", "swift", "crates", "bindings"]
PRUNE = {".git", ".gradle", ".build", "build", "target", "_build", "obj",
         "bin", "node_modules", "__pycache__", "DerivedData"}
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
            os.symlink(f, out)
            n += 1
if n == 0:
    sys.exit("check-app-identity: SELF-TEST FAIL (the shadow root is empty)")
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

# <shadow> <relative path> <x> <y> -> 1 if the pixel moved
doctor_pixel() {
    python3 -c '
import os
import pathlib
import struct
import sys
import zlib

shadow, rel, x, y = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
path = pathlib.Path(shadow) / rel
data = path.read_bytes()
i, idat, hdr, tail = 8, b"", None, []
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
    sys.exit("check-app-identity: SELF-TEST FAIL (the mark is no longer "
             "8-bit truecolour; the pixel doctor reads only that)")
raw = bytearray(zlib.decompress(idat))
stride = w * 3
# Unfilter, edit, re-emit every row with filter 0 — the simplest thing
# that produces a valid PNG a decoder will agree with.
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
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[k] = (line[k] + pr) & 0xFF
    rows.append(line)
    prev = line
before = bytes(rows[y][x * 3:x * 3 + 3])
# Repaint the whole quadrant so a centre sample cannot miss it.
qx, qy = (x // (w // 2)) * (w // 2), (y // (h // 2)) * (h // 2)
for yy in range(qy, qy + h // 2):
    for xx in range(qx, qx + w // 2):
        rows[yy][xx * 3:xx * 3 + 3] = b"\x12\x34\x56"
after = bytes(rows[y][x * 3:x * 3 + 3])
body = b"".join(b"\x00" + bytes(r) for r in rows)
def chunk(typ, payload):
    return (struct.pack(">I", len(payload)) + typ + payload
            + struct.pack(">I", zlib.crc32(typ + payload) & 0xFFFFFFFF))
out = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(body))
       + chunk(b"IEND", b""))
os.remove(path)
path.write_bytes(out)
print(0 if before == after else 1)
' "$@"
}

applied() { # count label
    if [ "$1" -ge 1 ]; then
        return 0
    fi
    echo "check-app-identity: SELF-TEST FAIL ($2 applied $1 times, want at" \
        "least 1 — an unchanged copy cannot prove the rule fires)" >&2
    exit 1
}

refuses() { # <shadow> <want-fragment> <label>
    local out
    out="$(check "$1")" && {
        echo "check-app-identity: SELF-TEST FAIL ($3 passed)" >&2
        exit 1
    }
    case "$out" in
        *"$2"*) ;;
        *)
            echo "check-app-identity: SELF-TEST FAIL ($3 failed for another reason:" >&2
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

# <name|pattern|other> -> the declared icon's ASSET name (the manifest's
# `icon` with the asset root's prefix removed), a regex matching it, or a
# NEIGHBOUR of it: same family, not the declared file.
#
# THE SELF-TEST DERIVES ITS DATA FOR THE SAME REASON THE CLAUSE DOES, and
# for one more. C3 derives so it holds one source of truth; this derives
# so it does not become a second one — and because THIS SCRIPT IS IN THE
# TREE THE CHECKER READS. An asset call spelled out here, naming any file
# in the mark's family other than the declared one, is a file in the tree
# opening an asset the manifest does not declare, and the arm above
# refuses it in the real run with the gate pointing at itself. Measured:
# it did, twice, the first time this was written — once for the
# perturbation's own data and once for a COMMENT that quoted a
# counterexample. The rule reaches prose because prose is text, so no
# comment in this file may spell one either.
declared() {
    python3 -c '
import pathlib
import re
import sys
import tomllib

root, which = sys.argv[1], sys.argv[2]
man = pathlib.Path(root) / "guests/assets/identity.toml"
icon = tomllib.loads(man.read_text(encoding="utf-8"))["icon"].replace("\\", "/")
PREFIX = "guests/assets/"
if not icon.startswith(PREFIX):
    sys.exit("check-app-identity: SELF-TEST FAIL (the declared icon is not "
             "under the asset root, so no guest can open it by name and "
             "neither of C3'"'"'s asset perturbations means anything)")
name = icon[len(PREFIX):]
family, _, base = name.rpartition("/")
print({"name": name,
       "pattern": re.escape(name),
       "other": f"{family}/not-{base}"}[which])
' "$ROOT" "$1"
}

# N0 — the shadow root itself must pass, or every refusal below could be
# an artifact of the copy rather than of the perturbation.
base="$(fresh base)"
if ! out="$(check "$base")"; then
    echo "$out"
    echo "check-app-identity: FAIL — refused before any perturbation, so this" \
        "is the tree and not the self-test" >&2
    exit 1
fi

# N1 — THE DRIFT ITSELF: repaint a quadrant of the declared mark and
# watch the byte-frozen scene expectation stop being true of it. This is
# the failure that would otherwise surface as five red lanes.
s="$(fresh repainted)"
hits="$(doctor_pixel "$s" guests/assets/icons/kaya-mark.png 16 16)"
applied "$hits" "the repainted-quadrant perturbation"
refuses "$s" "quadrant centres" "a mark whose pixels left the scene's expectation behind"

# N2 — the name changed in the manifest and nowhere else.
s="$(fresh renamed)"
hits="$(doctor "$s" guests/assets/identity.toml \
    'name = "Aurora Notes"' 'name = "Borealis Notes"')"
applied "$hits" "the manifest rename"
refuses "$s" "one app, one name" "a manifest name no guest declares"

# N3 — the icon path changed in the manifest and nowhere else.
s="$(fresh repathed)"
hits="$(doctor "$s" guests/assets/identity.toml \
    'icon = "guests/assets/icons/kaya-mark.png"' \
    'icon = "guests/assets/icons/kaya-other.png"')"
applied "$hits" "the manifest repath"
refuses "$s" "which is not a file in this tree" "a manifest naming a missing icon"

# N4 — a SECOND copy of the art, which is ruling 1's quiet failure.
s="$(fresh twocopies)"
mkdir -p "$s/android/kaya/src/main/res/mipmap-hdpi"
printf 'not the declared mark' > "$s/android/kaya/src/main/res/mipmap-hdpi/ic_launcher.png"
refuses "$s" "is an app-icon resource whose bytes are not the declared" \
    "a packaging resource carrying its own private art"

# N5 — a packaging step that retypes the path instead of reading it.
s="$(fresh retyped)"
printf 'cp guests/assets/icons/kaya-mark.png "$STAGE/icon.png"\n' \
    > "$s/tools/zz-selftest-packager.sh"
refuses "$s" "never reads guests/assets/identity.toml" \
    "a tools/ packaging step that hard-codes the icon path"

# N6 — the scene stops observing the name, which would make the name half
# of the declaration ship unwatched.
s="$(fresh unobserved)"
hits="$(doctor "$s" tools/scenes/identity.steps \
    'expect_title window#1 "Aurora Notes"' 'expect_title window#1 "identity"')"
applied "$hits" "the unobserved-name perturbation"
refuses "$s" "never reads the declared name" "a scene that stopped reading the name back"

# N7 — the vacuity half: no scene asserts the icon at all. A gate that
# stopped finding its site must be loud rather than clean.
s="$(fresh noobservation)"
hits="$(doctor "$s" tools/scenes/identity.steps 'expect_app_icon' 'expect_app_haiku')"
applied "$hits" "the no-observation perturbation"
refuses "$s" "would agree with anything" "a tree where no scene reads the icon"

# N8 — C3'S OWN NEGATIVE, which the clause went without until the identity
# guests stopped resolving their own path. Put the environment read back
# into a guest and take the asset call away: the file then names
# KAYA_ICON_FILE, the declared path nowhere, the manifest nowhere and no
# asset at all, which is the third source of truth the clause is about.
#
# It is also the reason C3's positive side cannot rot unnoticed. All
# eight migrated guests still SAY "KAYA_ICON_FILE" — in the paragraph
# explaining what they stopped doing — so the asset form is the only
# thing keeping them on the right side of this clause. If the asset arm
# below ever stopped matching, N0 would go red eight times over before
# anyone reached this test.
mark_re="$(declared pattern)" || exit 1
s="$(fresh envreader)"
hits="$(doctor "$s" guests/rust/identity.rs \
    "tx\\.asset\\(\"$mark_re\"\\)" \
    'std::env::var("KAYA_ICON_FILE").unwrap()')"
applied "$hits" "the environment-reader perturbation"
refuses "$s" "names the declaration in none of C3's three ways" \
    "a guest that names the override with no declaration behind it"

# N9 — THE ASSET ARM'S OWN NEGATIVE: a guest that opens a DIFFERENT file
# out of the mark's family. A name is not a path and nothing checks it at
# compile time, so the guest still builds in all eight languages; at
# runtime the name answers to nothing and each platform keeps whatever
# icon it already had. The Swift guest is the one doctored on purpose —
# its spelling is the constructor `KayaAsset(`, with no word boundary in
# front of the word, so a pattern written for `tx.asset(` alone would
# read this file and find nothing in it.
other_mark="$(declared other)" || exit 1
s="$(fresh othermark)"
hits="$(doctor "$s" guests/swift/identity.swift \
    "KayaAsset\\(\"$mark_re\"\\)" "KayaAsset(\"$other_mark\")")"
applied "$hits" "the other-mark perturbation"
refuses "$s" "in the declared mark's own family but is not it" \
    "a guest opening an asset the manifest does not declare"

if ! offenders="$(check "$ROOT")"; then
    echo "$offenders"
    echo "check-app-identity: FAIL"
    exit 1
fi
echo "check-app-identity: OK"
