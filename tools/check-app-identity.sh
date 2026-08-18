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
#   C3  THE PATH IS WRITTEN DOWN ONCE. Eight guests and the Windows
#       launchers spell the icon's repo-relative default, because the
#       runtime reader is eight languages and a .cmd file, none of which
#       parses TOML. They may spell it, but they may not DISAGREE with
#       it: every file naming KAYA_ICON_FILE must name the manifest's
#       path (backslashes and a drive-letter mirror allowed, since
#       tools/deploy-win.sh stages the tree to C:\kaya).
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
        if MANIFEST in text:
            manifest_readers.append(rel)
        if not (names_var or names_path):
            continue
        # PROSE AND SCENE SCRIPTS ARE NOT READERS. A .md file explains
        # the mechanism and a tools/scenes/*.steps file records why the
        # guest opens a file at all; neither copies a byte anywhere, and
        # demanding they parse the manifest would be a rule about
        # documentation rather than about drift.
        if rel.endswith(".md") or rel.startswith("tools/scenes/"):
            continue
        icon_namers.append(rel)
        # C3 — a site that names the variable must get its DEFAULT from
        # the declaration: either by reading the manifest (what a script
        # that can parse TOML does) or by spelling the declared path
        # (what eight guests and a batch file do). Naming neither is a
        # third source of truth wearing the override's name.
        if names_var and not names_path and MANIFEST not in text:
            bad.append(
                f"{rel}: names KAYA_ICON_FILE but does not name the declared "
                f"icon path \"{icon_rel}\" — the override needs a default to "
                "override, and the default is the manifest's or it is a "
                "second source of truth")
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
    bad.append("no file in the tree names the declared icon or "
               "KAYA_ICON_FILE — this gate read nothing and would agree "
               "with any manifest")

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

if ! offenders="$(check "$ROOT")"; then
    echo "$offenders"
    echo "check-app-identity: FAIL"
    exit 1
fi
echo "check-app-identity: OK"
