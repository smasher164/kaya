#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# ONE DECLARATION, TWO READERS, AND NOTHING BETWEEN THEM THAT CAN DRIFT
# (docs/app-identity-plan.md ruling 4). The identity is a NAME and a
# PICTURE FILE in guests/assets/identity.toml; the BUILD reads it
# before any program runs, and the RUNNING APP sends the same file's
# BYTES over the wire. Five routes reading five different files is how
# the promise gets broken quietly, with every test still passing
# because each reader is internally consistent.
#
# WHERE THE WALL SITS: the byte comparison itself lives in each
# packaging step, on the path nobody can avoid. This gate is the STATIC
# half — it holds the DECLARATION and every hand-written copy of it
# level, including on platforms whose packaging step does not exist
# yet.
#
# THE CLAUSES:
#
#   C1  the manifest declares a non-empty name and an icon file that
#       exists and is not empty. Everything below reads those two
#       values out of it; neither is ever written down in this gate.
#
#   C2  THE PIXELS ARE THE EXPECTATION. tools/scenes/*.steps are shared
#       verbatim and compared byte-for-byte, so `expect_app_icon
#       "E01B24/33D17A/1C71D8/F6D32D"` is a frozen claim about the
#       CONTENT of the declared icon. Decoding it here means swapping
#       the asset fails HERE rather than on five lanes at once.
#
#   C3  THE DECLARATION IS WRITTEN DOWN ONCE. None of the runtime
#       readers parses TOML, so a site may name it in THREE ways and no
#       fourth: READ THE MANIFEST; SPELL THE DECLARED PATH (backslashes
#       and a drive-letter mirror allowed, since deploy-win stages the
#       tree to C:\kaya); or OPEN IT AS AN ASSET, which this gate
#       DERIVES from the manifest rather than typing. NO COMMENT IN
#       THIS FILE MAY SPELL AN ASSET NAME IN THE MARK'S FAMILY: the
#       checker reads this file too, and it will refuse it.
#
#       They may spell it, they may not DISAGREE with it: naming
#       KAYA_ICON_FILE while naming none of the three is a third
#       source of truth wearing the override's name, and opening some
#       OTHER file out of the mark's asset family is a second mark —
#       silent at runtime, because an asset name nothing answers to
#       leaves each platform's own icon in place.
#
#   C4  THE NAME IS WRITTEN DOWN ONCE, same rule one field over: every
#       identity guest declares it and `expect_title window#1` reads it
#       back off the platform.
#
#   C5  ONE PICTURE. Any app-icon resource anywhere in the tree must be
#       BYTE-IDENTICAL to the declared icon or be in EXCLUDED with a
#       reason.
#
#   C6  A PACKAGING CONSUMER READS THE MANIFEST rather than hard-coding
#       the path. The .cmd launchers are exempt and C3 covers them
#       instead: a batch file cannot read TOML.
#
# THE SELF-TEST runs the real checker over a shadow root of symlinks
# with one file doctored and requires the red (docs/traps.md: the
# wayland seat guard passed vacuously twice against a fixture).

import os
import re
import struct
import tomllib
import zlib

g = Gate("check-app-identity")

MANIFEST = "guests/assets/identity.toml"

# Directory names that hold BUILD OUTPUT rather than tree, pruned by
# name while walking (the unpruned walk visits 752,511 paths, 750,000
# of them cargo's).
#
# `build` is here for a second reason: reading a build directory would
# make the verdict depend on whatever the last build — or the last
# WATCHED NEGATIVE — left lying around, and a gate a negative test can
# turn red afterwards is a gate whose red means nothing.
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
            # C3, THE ASSET FORM'S OWN HALF, asked BEFORE the
            # is-this-a-namer question below: a file opening the WRONG
            # file out of the mark's family names none of the three
            # accepted forms and would fall out of this loop
            # unlooked-at. A mistyped asset name compiles in all eight
            # languages and leaves whatever icon the platform had.
            # (NO COMMENT HERE MAY QUOTE SUCH A NAME — the arm would
            # read it and refuse this file.)
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
    guests = sorted((root / "guests").glob("*/identity.*"))
    if not guests:
        bad.append("guests/*/identity.*: no identity guest exists, so "
                   "the name half of the declaration has no writer and "
                   "C4 reads nothing")
    for gp in guests:
        rel = gp.relative_to(root).as_posix()
        if name not in gp.read_text(encoding="utf-8"):
            bad.append(f"{rel}: does not declare the identity name "
                       f"\"{name}\" that {MANIFEST} declares — one "
                       f"app, one name")

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


# The declared icon's ASSET name (the manifest's `icon` with the asset
# root's prefix removed), a regex matching it, and a NEIGHBOUR of it:
# same family, not the declared file.
#
# THE SELF-TEST DERIVES ITS DATA, because THIS SCRIPT IS IN THE TREE
# THE CHECKER READS: an asset call spelled out here, naming any file in
# the mark's family other than the declared one, makes the gate refuse
# itself. The rule reaches PROSE because prose is text, so no comment
# in this file may spell one either.
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
# watch the byte-frozen scene expectation stop being true of it. This
# is the failure that would otherwise surface as five red lanes.
s = fresh("repainted")
mark_rel = tomllib.loads((ROOT / MANIFEST).read_text(
    encoding="utf-8"))["icon"].replace("\\", "/")
doctor_pixel("the repainted-quadrant perturbation", s, mark_rel, 16, 16)
g.negative("a mark whose pixels left the scene's expectation behind",
           lambda p=s: check(p), want="quadrant centres")

# N2 — the name changed in the manifest and nowhere else.
s = fresh("renamed")
doctor_shadow("the manifest rename", s, MANIFEST,
              r'name = "Aurora Notes"', 'name = "Borealis Notes"')
g.negative("a manifest name no guest declares", lambda p=s: check(p),
           want="one app, one name")

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
# stopped finding its site must be loud rather than clean. THREE
# SITES, all replaced — the old subn replaced every one.
s = fresh("noobservation")
doctor_shadow("the no-observation perturbation", s,
              "tools/scenes/identity.steps", r"expect_app_icon",
              "expect_app_haiku", want=3)
g.negative("a tree where no scene reads the icon",
           lambda p=s: check(p), want="would agree with anything")

# N8 — C3'S OWN NEGATIVE: put the environment read back into a guest
# and take the asset call away, so the file names KAYA_ICON_FILE and
# neither the declared path, the manifest nor an asset — the third
# source of truth the clause is about.
mark_re = declared("pattern")
s = fresh("envreader")
doctor_shadow("the environment-reader perturbation", s,
              "guests/rust/identity.rs",
              r'tx\.asset\("' + mark_re + r'"\)',
              'std::env::var("KAYA_ICON_FILE").unwrap()')
g.negative("a guest that names the override with no declaration "
           "behind it", lambda p=s: check(p),
           want="names the declaration in none of C3's three ways")

# N9 — THE ASSET ARM'S OWN NEGATIVE: a guest that opens a DIFFERENT
# file out of the mark's family. Nothing checks an asset name at
# compile time. The SWIFT guest is doctored on purpose — its spelling
# is the constructor `KayaAsset(`, with no word boundary in front, so a
# pattern written for the Rust spelling alone would find nothing in it.
other_mark = declared("other")
s = fresh("othermark")
doctor_shadow("the other-mark perturbation", s,
              "guests/swift/identity.swift",
              r'KayaAsset\("' + mark_re + r'"\)',
              f'KayaAsset("{other_mark}")')
g.negative("a guest opening an asset the manifest does not declare",
           lambda p=s: check(p),
           want="in the declared mark's own family but is not it")

g.negatives_ran(9)

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
