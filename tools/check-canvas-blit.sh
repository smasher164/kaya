#!/usr/bin/env bash

kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# KAYA RASTERIZES, BACKENDS BLIT — the architecture's one rule
# (docs/canvas-plan.md §1.1, ruling 1), and three things about it that NO
# SCENE CAN FAIL.
#
# 1. A BACKEND THAT INTERPRETED AN OP WOULD DRAW THE SAME PICTURE. That
#    is the whole difficulty: the lowering design this plan killed (§1.2,
#    Qt's own migration away from it and MAUI's issue record as the
#    shipped version) reintroduces itself one arm at a time, and every
#    canvas observable stays green while it does — the hash is taken of
#    the CORE's raster, and expect_ink samples pixels that would still
#    match. So the rule is held statically: outside crates/kaya/src/canvas.rs
#    no backend may consult a draw op, a paint role, a fill rule, an
#    align or a baseline. The two interpreters carry private COPIES of
#    those numbers (check-verbs holds their values) and may name them in
#    exactly two places — the definition, and the one vocabulary list
#    that exists so the compiler does not call them unused.
#
# 2. A WRONG PIXEL FORMAT SURVIVES A SYMMETRIC SAMPLE. The core's buffer
#    is premultiplied RGBA8 (tiny-skia's Pixmap layout) and each platform
#    takes it differently — GTK's R8g8b8a8Premultiplied and Android's
#    ARGB_8888 are that layout verbatim, SwiftUI's CGImage says so with
#    premultipliedLast|byteOrder32Big, and WinUI is the ONE arm that
#    swizzles, because WriteableBitmap.PixelBuffer is premultiplied BGRA8.
#    tools/scenes/canvas.steps catches a swap only at a probe point whose
#    colour is asymmetric: FFFFFF is not, and a scene whose points all
#    landed on greys would pass a red-blue swap on every lane. So the
#    format each backend declares is held here, by name.
#
# 3. THE SCALE MUST BE THE TRUE ONE, AND MUST BE REPORTED AT ALL. Every
#    lane this project runs is at scale 1 (the container's Xvfb) or at a
#    scale the platform reports exactly, so a backend that read the
#    ROUNDED scale, or that never reported one, is invisible to all five.
#    GTK is where it bites: gtk_widget_get_scale_factor is an integer and
#    GTK's own docs say it "returns the next higher integer value" under
#    fractional scaling, so a 125% display would raster at 2 and blit a
#    buffer of the wrong size (§5 rule 1).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

GTK=crates/kaya/src/gtk.rs
WINUI=crates/kaya/src/winui/mod.rs
SWIFTUI=swift/KayaSwiftUI.swift
COMPOSE=android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt

check() {
    # $1..$4: gtk.rs, winui/mod.rs, KayaSwiftUI.swift, KayaCompose.kt.
    # Prints offenders on stdout, returns 1 on any.
    python3 - "$@" <<'PY'
import re
import sys

gtk, winui, swiftui, compose = sys.argv[1:5]
read = lambda p: open(p, encoding="utf-8").read()
bad = []


def strip_comments(text):
    """Comments legitimately DISCUSS the vocabulary — every file here
    explains why it does not read one — so a clause that searched raw
    text would be satisfied, or refused, by prose.

    LINE COUNT PRESERVED, which is the half that bit: a block comment
    replaced by nothing SHIFTS every line after it, and the first draft
    of this gate then reported a doc line as a use and read a constant's
    definition as an arm. A block becomes its own newlines, a line
    comment becomes its indent."""
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"),
                  text, flags=re.S)
    return re.sub(r"^([ \t]*)//.*$", r"\1", text, flags=re.M)


# --- 1. THE ONE RULE: no backend consults the op vocabulary. ---------
#
# The Rust backends do not even define the numbers, so ANY mention is a
# finding. The interpreters define them privately and name them once.
VOCAB = re.compile(
    r"\b("
    r"draw(MoveTo|LineTo|Close|Stroke|Fill|Font|Text)"
    r"|paint(Series|SeriesFill|Grid|Axis|Ground)"
    r"|fill(Nonzero|EvenOdd)"
    r"|textAlign(Start|Middle|End)"
    r"|textBaseline(Alphabetic|Middle|Top|Bottom)"
    r"|DRAW_(MOVE_TO|LINE_TO|CLOSE|STROKE|FILL|FONT|TEXT)"
    r"|PAINT_(SERIES|SERIES_FILL|GRID|AXIS|GROUND)"
    r"|FILL_(NONZERO|EVEN_ODD)"
    r"|TEXT_ALIGN_(START|MIDDLE|END)"
    r"|TEXT_BASELINE_(ALPHABETIC|MIDDLE|TOP|BOTTOM)"
    r")\b")

# Where an interpreter is allowed to name one: its own definition line,
# and its one vocabulary list.
DEFINITION = re.compile(r"^\s*(private (let|const val)|const val)\s+\w+")
# The closer is the bracket AT THE BLOCK'S OWN INDENT, not the next one
# of its kind: the Kotlin list's first entry is
# `APPLY_SET_DRAWING.toLong(),` and a bare `)` search stopped there,
# leaving every later line outside the allowed span and reporting the
# declaration itself as a use.
VOCAB_BLOCKS = {
    swiftui: (r"let kayaCanvasVocabulary: \[Int64\] = \[", r"\n\]"),
    compose: (r"val CANVAS_VOCABULARY: List<Long> = listOf\(", r"\n    \)"),
}

for path in (gtk, winui):
    body = strip_comments(read(path))
    for n, line in enumerate(body.splitlines(), 1):
        m = VOCAB.search(line)
        if m:
            bad.append(
                f"{path}:{n} names the canvas vocabulary ({m.group(1)}). A widget "
                f"backend BLITS and never interprets an op (docs/canvas-plan.md "
                f"§1.1): the core rasterizes once and every platform shows the same "
                f"bytes, which is what makes tools/scenes/canvas.steps' frozen hash "
                f"one string on five lanes. A backend that lowered ops itself would "
                f"draw a picture no observable could tell from this one")

for path, (opener, closer) in VOCAB_BLOCKS.items():
    text = read(path)
    m = re.search(opener, text)
    if m is None:
        bad.append(
            f"{path}: the canvas vocabulary list this gate reads is gone. It is "
            f"where the private constant copies are named once so the compiler "
            f"does not call them unused, and it is what tells this clause a "
            f"mention is a declaration rather than a use — without it the clause "
            f"reports a clean bill about nothing")
        continue
    tail = re.search(closer, text[m.end():])
    if tail is None:
        bad.append(
            f"{path}: the canvas vocabulary list never closes at its own indent, "
            f"so this gate cannot tell where the declaration ends")
        continue
    end = m.end() + tail.end()
    allowed = set(range(text.count("\n", 0, m.start()) + 1,
                        text.count("\n", 0, end) + 2))
    body = strip_comments(text)
    # Comment-stripping preserves line numbers (it blanks, never joins).
    for n, line in enumerate(body.splitlines(), 1):
        hit = VOCAB.search(line)
        if hit is None or n in allowed or DEFINITION.match(line):
            continue
        bad.append(
            f"{path}:{n} consults the canvas vocabulary ({hit.group(1)}) outside "
            f"its definition and its one vocabulary list. This interpreter BLITS "
            f"and never interprets an op (docs/canvas-plan.md §1.1); the constant "
            f"copies exist so a drifted NUMBER fails tools/check-verbs.sh rather "
            f"than a lane, not so an arm can switch on one")

# --- 2. THE PIXEL FORMAT EACH BACKEND DECLARES. ----------------------
#
# One row per backend: the token that names what it hands the platform,
# and why that token is the right one. A format changed here and nowhere
# else renders a blue chart red, and a scene sampling a grey cannot see
# it.
FORMATS = [
    (gtk, r"MemoryFormat::R8g8b8a8Premultiplied",
     "GdkMemoryTexture takes tiny-skia's Pixmap layout verbatim — R at byte 0, "
     "A at byte 3 — so the GTK arm swizzles nothing"),
    (swiftui, r"CGImageAlphaInfo\.premultipliedLast",
     "premultipliedLast plus byteOrder32Big is RGBA in MEMORY order on a "
     "little-endian host, which is the core's layout"),
    (swiftui, r"\.byteOrder32Big",
     "the byte order half of the same declaration: without it the CGImage reads "
     "the words the other way round"),
    (compose, r"Bitmap\.Config\.ARGB_8888",
     "Android's ARGB_8888 is RGBA in memory order (the platform's own kN32 "
     "layout) and premultiplied by default, so the Compose arm swizzles nothing"),
]
for path, token, why in FORMATS:
    if re.search(token, read(path)) is None:
        bad.append(
            f"{path}: the canvas blit no longer names the pixel format it hands "
            f"the platform ({token}). {why}. tools/scenes/canvas.steps can only "
            f"catch a channel swap at a probe point whose colour is ASYMMETRIC, "
            f"so this is the wall for the rest")

# THE ONE ARM THAT SWIZZLES, and the three index-shifted writes that ARE
# the swizzle. WriteableBitmap.PixelBuffer is premultiplied BGRA8 by
# Microsoft's documented contract; the core's buffer is RGBA8.
winui_text = read(winui)
swizzle = re.search(r"fn set_drawing\(.*?\n\}", winui_text, flags=re.S)
if swizzle is None:
    bad.append(
        f"{winui}: set_drawing is not where this gate looks, so the BGRA swizzle "
        f"clause reports a clean bill about nothing")
else:
    body = swizzle.group(0)
    for want, why in (
        (r"\*dst\.add\(at\) = pixels\[at \+ 2\]", "blue takes the buffer's red slot"),
        (r"\*dst\.add\(at \+ 1\) = pixels\[at \+ 1\]", "green stays where it is"),
        (r"\*dst\.add\(at \+ 2\) = pixels\[at\]", "red takes the buffer's blue slot"),
    ):
        if re.search(want, body) is None:
            bad.append(
                f"{winui}: set_drawing no longer writes the BGRA swizzle "
                f"({why}). WriteableBitmap.PixelBuffer is premultiplied BGRA8 and "
                f"the core hands over premultiplied RGBA8, so this is the one "
                f"backend arm that trades two channels — an identity copy here "
                f"draws the chart's blues as reds")

# --- 3. THE SCALE IS THE TRUE ONE, AND IT IS REPORTED. ---------------
#
# The reading is pinned TO ITS SITE, not searched for across the file:
# three of these four backends read a density somewhere else for their
# own layout arithmetic, and a whole-file search was measured passing
# with the report's own reading replaced by a constant.
REPORTS = [
    (gtk, r"fn presentation_report\(core: &mut CoreState\)",
     r"\|surface\| surface\.scale\(\)",
     "gdk_surface_get_scale's DOUBLE (§5 rule 1)"),
    (winui, r"fn presentation_report\(core: &mut CoreState\)",
     r"\|xaml_root\| xaml_root\.RasterizationScale\(\)",
     "the XAML island's own density, which is what WM_DPICHANGED moves"),
    (swiftui, r"struct KayaPresentationReporter",
     r"@Environment\(\\\.displayScale\) private var displayScale",
     "SwiftUI's own environment value"),
    (compose, r"KayaPresent\.presentation\(",
     r"val presentationScale = LocalDensity\.current\.density",
     "the composition's density, which IS this platform's window scale"),
]
for path, site, reading, why in REPORTS:
    text = read(path)
    if re.search(site, text) is None:
        bad.append(
            f"{path}: this backend has no canvas presentation report. The core "
            f"re-rasters every canvas at the window's scale and appearance "
            f"(docs/canvas-plan.md §5, §6), and a backend that never reports "
            f"leaves every drawing at the canonical 1.0 — invisible on every lane "
            f"this project runs, because they are all at 1.0 or at a scale the "
            f"platform states exactly")
    elif re.search(reading, text) is None:
        bad.append(
            f"{path}: the presentation report no longer reads {why}. That is the "
            f"scale the core rasterizes at, and reading anything else blits a "
            f"buffer of the wrong size on the displays no lane has")

# GTK IS THE ONE THAT CAN BE ROUNDED, so its integer sibling is refused
# by name rather than merely unused.
gtk_body = strip_comments(read(gtk))
m = re.search(r"\bscale_factor\(\)", gtk_body)
if m:
    n = gtk_body.count("\n", 0, m.start()) + 1
    bad.append(
        f"{gtk}:{n} calls gtk_widget_get_scale_factor. GTK's own documentation "
        f"says it \"returns the next higher integer value\" under fractional "
        f"scaling, so a 125% display would raster at 2 and blit a stale-size "
        f"buffer — the reading docs/canvas-plan.md §5 rule 1 exists to forbid. "
        f"gdk_surface_get_scale's double is the one to read, and the container "
        f"runs Xvfb at scale 1, so no lane can tell the two apart")

print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
}

# THE GUARD GUARDS ITSELF, on DOCTORED COPIES OF THE REAL FILES rather
# than on synthetic samples (docs/traps.md, the wayland seat guard).
# Every perturbation prints its substitution count and is refused if it
# did not apply, and every refusal is checked for its REASON.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# <source> <regex> <replacement> <destination> -> substitution count
perturb() {
    python3 -c '
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
out, n = re.subn(sys.argv[2], sys.argv[3], text, flags=re.S)
open(sys.argv[4], "w", encoding="utf-8").write(out)
print(n)
' "$@"
}

applied() { # count label
    if [ "$1" -ge 1 ]; then
        echo "check-canvas-blit: $2 applied $1 substitution(s)"
        return 0
    fi
    echo "check-canvas-blit: SELF-TEST FAIL ($2 applied $1 times, want at least 1 —" \
        "an unchanged copy cannot prove the rule fires)" >&2
    exit 1
}

# <gtk> <winui> <swiftui> <compose> <want-fragment> <label>
refuses() {
    local out
    out="$(check "$1" "$2" "$3" "$4")" && {
        echo "check-canvas-blit: SELF-TEST FAIL ($6 passed)" >&2
        exit 1
    }
    case "$out" in
        *"$5"*) ;;
        *)
            echo "check-canvas-blit: SELF-TEST FAIL ($6 failed for another reason: $out)" >&2
            exit 1
            ;;
    esac
}

# N1: A WIDGET BACKEND THAT INTERPRETS AN OP. The shipped defect this
# rule exists against, in its smallest form — one arm that resolves a
# paint role for itself.
hits="$(perturb "$GTK" 'fn set_drawing\(picture: &gtk4::Picture' \
    'fn kaya_paint_is_series(p: i64) -> bool { p == PAINT_SERIES }\nfn set_drawing(picture: \&gtk4::Picture' \
    "$T/gtk-lowers.rs")"
applied "$hits" "N1 (a GTK arm that consults a paint role)"
refuses "$T/gtk-lowers.rs" "$WINUI" "$SWIFTUI" "$COMPOSE" \
    "names the canvas vocabulary" "a GTK backend that lowers ops itself"

# N1b: the same in an INTERPRETER, where the constants legitimately
# exist — so the clause has to tell a use from a declaration.
hits="$(perturb "$COMPOSE" 'KayaCompose\.KIND_CANVAS -> \{' \
    'KayaCompose.KIND_CANVAS -> {\n            if (node.drawingScale == DRAW_MOVE_TO.toDouble()) return' \
    "$T/compose-lowers.kt")"
applied "$hits" "N1b (a Compose arm that consults a draw op)"
refuses "$GTK" "$WINUI" "$SWIFTUI" "$T/compose-lowers.kt" \
    "consults the canvas vocabulary" "a Compose arm that switches on an op"

# N1c: AND THE VOCABULARY LIST ITSELF IS THE ANCHOR. Losing it would
# make every later mention look like a use — or, if the clause were
# written the other way, make the whole sweep vacuous.
hits="$(perturb "$SWIFTUI" 'let kayaCanvasVocabulary: \[Int64\] = \[' \
    'let kayaCanvasNumbers: [Int64] = [' "$T/swiftui-no-vocab.swift")"
applied "$hits" "N1c (the SwiftUI vocabulary list renamed)"
refuses "$GTK" "$WINUI" "$T/swiftui-no-vocab.swift" "$COMPOSE" \
    "vocabulary list this gate reads is gone" "a renamed vocabulary anchor"

# N2: THE PIXEL FORMAT, changed to the other plausible one. This is the
# perturbation a scene sampling a grey would pass.
hits="$(perturb "$GTK" 'MemoryFormat::R8g8b8a8Premultiplied' \
    'MemoryFormat::B8g8r8a8Premultiplied' "$T/gtk-bgra.rs")"
applied "$hits" "N2 (the GTK texture format swapped to BGRA)"
refuses "$T/gtk-bgra.rs" "$WINUI" "$SWIFTUI" "$COMPOSE" \
    "no longer names the pixel format" "a GTK arm handing over the wrong format"

# N2b: THE WINUI SWIZZLE, flattened to an identity copy — which is what
# a reader who believed the buffers matched would write.
hits="$(perturb "$WINUI" '\*dst\.add\(at\) = pixels\[at \+ 2\];' \
    '*dst.add(at) = pixels[at];' "$T/winui-noswizzle.rs")"
applied "$hits" "N2b (the WinUI blue/red swizzle flattened)"
refuses "$GTK" "$T/winui-noswizzle.rs" "$SWIFTUI" "$COMPOSE" \
    "no longer writes the BGRA swizzle" "a WinUI arm that stopped swizzling"

# N2c: SwiftUI's byte order, the half that is easy to drop.
hits="$(perturb "$SWIFTUI" '\.union\(\.byteOrder32Big\)' '' "$T/swiftui-noorder.swift")"
applied "$hits" "N2c (the SwiftUI byte order dropped)"
refuses "$GTK" "$WINUI" "$T/swiftui-noorder.swift" "$COMPOSE" \
    "no longer names the pixel format" "a CGImage with no declared byte order"

# N3: THE ROUNDED SCALE — GTK's integer sibling, which every lane this
# project runs would accept in silence.
hits="$(perturb "$GTK" '\.map_or\(crate::canvas::CANONICAL_SCALE, \|surface\| surface\.scale\(\)\)' \
    '.map_or(crate::canvas::CANONICAL_SCALE, |surface| f64::from(surface.scale_factor()))' \
    "$T/gtk-rounded.rs")"
applied "$hits" "N3 (the GTK scale read rounded to an integer)"
refuses "$T/gtk-rounded.rs" "$WINUI" "$SWIFTUI" "$COMPOSE" \
    "gtk_widget_get_scale_factor" "a GTK report reading the rounded scale"

# N3b: A BACKEND THAT NEVER REPORTS AT ALL. Invisible on five lanes,
# because they are all at 1.0 or at a scale the platform states exactly.
hits="$(perturb "$WINUI" 'fn presentation_report\(core: &mut CoreState\)' \
    'fn unreported_presentation(core: &mut CoreState)' "$T/winui-silent.rs")"
applied "$hits" "N3b (the WinUI presentation report removed)"
refuses "$GTK" "$T/winui-silent.rs" "$SWIFTUI" "$COMPOSE" \
    "has no canvas presentation report" "a WinUI backend that never reports its scale"

# N3c: the reading swapped out under a report that still exists.
hits="$(perturb "$COMPOSE" 'LocalDensity\.current\.density\.toDouble\(\)\n    val presentationDark' \
    '1.0\n    val presentationDark' "$T/compose-flat.kt")"
applied "$hits" "N3c (the Compose density report pinned to 1.0)"
refuses "$GTK" "$WINUI" "$SWIFTUI" "$T/compose-flat.kt" \
    "no longer reads" "a Compose report that stopped reading the density"

if ! offenders="$(check "$GTK" "$WINUI" "$SWIFTUI" "$COMPOSE")"; then
    echo "$offenders"
    echo "check-canvas-blit: FAIL"
    exit 1
fi
echo "check-canvas-blit: OK (4 backends: the one rule, the four pixel formats," \
    "the one swizzle, and the true scale reported)"
