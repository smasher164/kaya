#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# KAYA RASTERIZES, BACKENDS BLIT — the architecture's one rule
# (docs/canvas-plan.md §1.1, ruling 1; CLAUDE.md's gate list), in the
# three places NO SCENE CAN FAIL.
# 1. Outside crates/kaya/src/canvas.rs no backend may consult a draw op,
#    paint role, fill rule, align or baseline: an interpreted op draws
#    the SAME PICTURE, so §1.2's killed design can come back one arm at
#    a time with every observable green. The interpreters carry private
#    COPIES of the numbers (check-verbs holds their values) and may name
#    one twice: at its definition, and in the one vocabulary list.
# 2. A WRONG PIXEL FORMAT SURVIVES A SYMMETRIC SAMPLE — canvas.steps
#    catches a channel swap only where the probe colour is asymmetric —
#    so each backend's declared format is held here by name.
# 3. THE SCALE MUST BE THE TRUE ONE AND REPORTED AT ALL: every lane is
#    at 1.0 or at a scale the platform states exactly, so a rounded or
#    missing scale is invisible to all five. GTK is where it bites —
#    gtk_widget_get_scale_factor "returns the next higher integer value"
#    under fractional scaling, so 125% rasters at 2 (§5 rule 1).

import os
import platform
import re
import subprocess

# Line-buffered stdout: the ink probe writes to the same fd, and
# block-buffered prints would land AFTER output they preceded.
sys.stdout.reconfigure(line_buffering=True)

g = Gate("check-canvas-blit")

GTK = "crates/kaya/src/gtk.rs"
WINUI = "crates/kaya/src/winui/mod.rs"
SWIFTUI = "swift/KayaSwiftUI.swift"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"


def strip_comments(text):
    """Comments legitimately DISCUSS the vocabulary — every file here
    explains why it does not read one — so a clause that searched raw
    text would be satisfied, or refused, by prose.

    LINE COUNT PRESERVED, which is the half that bit: a block comment
    replaced by nothing SHIFTS every line after it, and the first draft
    of this gate then reported a doc line as a use and read a
    constant's definition as an arm. A block becomes its own newlines,
    a line comment becomes its indent."""
    text = re.sub(r"/\*.*?\*/",
                  lambda m: "\n" * m.group(0).count("\n"), text,
                  flags=re.S)
    return re.sub(r"^([ \t]*)//.*$", r"\1", text, flags=re.M)


# --- 1. THE ONE RULE: no backend consults the op vocabulary. ----------
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
    "swiftui": (r"let kayaCanvasVocabulary: \[Int64\] = \[", r"\n\]"),
    "compose": (r"val CANVAS_VOCABULARY: List<Long> = listOf\(",
                r"\n    \)"),
}


def check(gtk, winui, swiftui, compose):
    """Offender sentences for the four given backend paths — any may
    be a perturbed copy; that is how the self-tests drive it."""
    paths = {"gtk": gtk, "winui": winui, "swiftui": swiftui,
             "compose": compose}
    bad = []

    def read(key):
        p = pathlib.Path(paths[key])
        if not p.is_absolute():
            p = ROOT / p
        return p.read_text(encoding="utf-8")

    for key in ("gtk", "winui"):
        body = strip_comments(read(key))
        for n, line in enumerate(body.splitlines(), 1):
            m = VOCAB.search(line)
            if m:
                bad.append(
                    f"{paths[key]}:{n} names the canvas vocabulary "
                    f"({m.group(1)}). A widget backend BLITS and never "
                    f"interprets an op (docs/canvas-plan.md §1.1): the "
                    f"core rasterizes once and every platform shows "
                    f"the same bytes, which is what makes "
                    f"tools/scenes/canvas.steps' frozen hash one "
                    f"string on five lanes. A backend that lowered ops "
                    f"itself would draw a picture no observable could "
                    f"tell from this one")

    for key, (opener, closer) in VOCAB_BLOCKS.items():
        text = read(key)
        m = re.search(opener, text)
        if m is None:
            bad.append(
                f"{paths[key]}: the canvas vocabulary list this gate "
                f"reads is gone. It is where the private constant "
                f"copies are named once so the compiler does not call "
                f"them unused, and it is what tells this clause a "
                f"mention is a declaration rather than a use — without "
                f"it the clause reports a clean bill about nothing")
            continue
        tail = re.search(closer, text[m.end():])
        if tail is None:
            bad.append(
                f"{paths[key]}: the canvas vocabulary list never "
                f"closes at its own indent, so this gate cannot tell "
                f"where the declaration ends")
            continue
        end = m.end() + tail.end()
        allowed = set(range(text.count("\n", 0, m.start()) + 1,
                            text.count("\n", 0, end) + 2))
        body = strip_comments(text)
        # Comment-stripping preserves line numbers (it blanks, never
        # joins).
        for n, line in enumerate(body.splitlines(), 1):
            hit = VOCAB.search(line)
            if hit is None or n in allowed or DEFINITION.match(line):
                continue
            bad.append(
                f"{paths[key]}:{n} consults the canvas vocabulary "
                f"({hit.group(1)}) outside its definition and its one "
                f"vocabulary list. This interpreter BLITS and never "
                f"interprets an op (docs/canvas-plan.md §1.1); the "
                f"constant copies exist so a drifted NUMBER fails "
                f"tools/check-verbs.py rather than a lane, not so an "
                f"arm can switch on one")

    # --- 2. THE PIXEL FORMAT EACH BACKEND DECLARES. -------------------
    #
    # One row per backend: the token that names what it hands the
    # platform, and why that token is the right one. A format changed
    # here and nowhere else renders a blue chart red, and a scene
    # sampling a grey cannot see it.
    FORMATS = [
        ("gtk", r"MemoryFormat::R8g8b8a8Premultiplied",
         "GdkMemoryTexture takes tiny-skia's Pixmap layout verbatim — "
         "R at byte 0, A at byte 3 — so the GTK arm swizzles nothing"),
        ("swiftui", r"CGImageAlphaInfo\.premultipliedLast",
         "premultipliedLast plus byteOrder32Big is RGBA in MEMORY "
         "order on a little-endian host, which is the core's layout"),
        ("swiftui", r"\.byteOrder32Big",
         "the byte order half of the same declaration: without it the "
         "CGImage reads the words the other way round"),
        ("compose", r"Bitmap\.Config\.ARGB_8888",
         "Android's ARGB_8888 is RGBA in memory order (the platform's "
         "own kN32 layout) and premultiplied by default, so the "
         "Compose arm swizzles nothing"),
    ]
    for key, token, why in FORMATS:
        if re.search(token, read(key)) is None:
            bad.append(
                f"{paths[key]}: the canvas blit no longer names the "
                f"pixel format it hands the platform ({token}). {why}. "
                f"tools/scenes/canvas.steps can only catch a channel "
                f"swap at a probe point whose colour is ASYMMETRIC, so "
                f"this is the wall for the rest")

    # THE ONE ARM THAT SWIZZLES, and the three index-shifted writes
    # that ARE the swizzle. WriteableBitmap.PixelBuffer is
    # premultiplied BGRA8 by Microsoft's documented contract; the
    # core's buffer is RGBA8.
    winui_text = read("winui")
    swizzle = re.search(r"fn set_drawing\(.*?\n\}", winui_text,
                        flags=re.S)
    if swizzle is None:
        bad.append(
            f"{paths['winui']}: set_drawing is not where this gate "
            f"looks, so the BGRA swizzle clause reports a clean bill "
            f"about nothing")
    else:
        body = swizzle.group(0)
        for want, why in (
            (r"\*dst\.add\(at\) = pixels\[at \+ 2\]",
             "blue takes the buffer's red slot"),
            (r"\*dst\.add\(at \+ 1\) = pixels\[at \+ 1\]",
             "green stays where it is"),
            (r"\*dst\.add\(at \+ 2\) = pixels\[at\]",
             "red takes the buffer's blue slot"),
        ):
            if re.search(want, body) is None:
                bad.append(
                    f"{paths['winui']}: set_drawing no longer writes "
                    f"the BGRA swizzle ({why}). "
                    f"WriteableBitmap.PixelBuffer is premultiplied "
                    f"BGRA8 and the core hands over premultiplied "
                    f"RGBA8, so this is the one backend arm that "
                    f"trades two channels — an identity copy here "
                    f"draws the chart's blues as reds")

    # --- 3. THE SCALE IS THE TRUE ONE, AND IT IS REPORTED. ------------
    #
    # The reading is pinned TO ITS SITE, not searched for across the
    # file: three of these four backends read a density somewhere else
    # for their own layout arithmetic, and a whole-file search was
    # measured passing with the report's own reading replaced by a
    # constant.
    REPORTS = [
        ("gtk", r"fn presentation_report\(core: &mut CoreState\)",
         r"\|surface\| surface\.scale\(\)",
         "gdk_surface_get_scale's DOUBLE (§5 rule 1)"),
        ("winui", r"fn presentation_report\(core: &mut CoreState\)",
         r"\|xaml_root\| xaml_root\.RasterizationScale\(\)",
         "the XAML island's own density, which is what WM_DPICHANGED "
         "moves"),
        ("swiftui", r"struct KayaPresentationReporter",
         r"@Environment\(\\\.displayScale\) private var displayScale",
         "SwiftUI's own environment value"),
        ("compose", r"KayaPresent\.presentation\(",
         r"val presentationScale = LocalDensity\.current\.density",
         "the composition's density, which IS this platform's window "
         "scale"),
    ]
    for key, site, reading, why in REPORTS:
        text = read(key)
        if re.search(site, text) is None:
            bad.append(
                f"{paths[key]}: this backend has no canvas "
                f"presentation report. The core re-rasters every "
                f"canvas at the window's scale and appearance "
                f"(docs/canvas-plan.md §5, §6), and a backend that "
                f"never reports leaves every drawing at the canonical "
                f"1.0 — invisible on every lane this project runs, "
                f"because they are all at 1.0 or at a scale the "
                f"platform states exactly")
        elif re.search(reading, text) is None:
            bad.append(
                f"{paths[key]}: the presentation report no longer "
                f"reads {why}. That is the scale the core rasterizes "
                f"at, and reading anything else blits a buffer of the "
                f"wrong size on the displays no lane has")

    # GTK IS THE ONE THAT CAN BE ROUNDED, so its integer sibling is
    # refused by name rather than merely unused.
    gtk_body = strip_comments(read("gtk"))
    m = re.search(r"\bscale_factor\(\)", gtk_body)
    if m:
        n = gtk_body.count("\n", 0, m.start()) + 1
        bad.append(
            f"{paths['gtk']}:{n} calls gtk_widget_get_scale_factor. "
            f'GTK\'s own documentation says it "returns the next '
            f'higher integer value" under fractional scaling, so a '
            f"125% display would raster at 2 and blit a stale-size "
            f"buffer — the reading docs/canvas-plan.md §5 rule 1 "
            f"exists to forbid. gdk_surface_get_scale's double is the "
            f"one to read, and the container runs Xvfb at scale 1, so "
            f"no lane can tell the two apart")

    # --- 4. THE BLIT IS STRICTLY 1:1, AND THE TRACK IS REPORTED. ------
    # THE STRETCH DEFECT (docs/deferred.md, "A canvas STRETCHES ITS
    # BUFFER") was this pair going wrong. Both halves of the fix are
    # invisible to every canvas observable — the hash and the ink bounds
    # come from the CANONICAL raster, taken at the viewbox by definition
    # (§7.1), so a stretched blit answers them identically. `fixed` is
    # what makes 1:1 load-bearing (§3.2.1, ruling 2): a `.resizable()`
    # anywhere in this arm takes its guarantee away, still green.
    swiftui_body = strip_comments(read("swiftui"))
    arm = re.search(r"^(\s*)case kindCanvas:\n(.*?)^\1(case |default:)",
                    swiftui_body, re.S | re.M)
    if arm is None:
        bad.append(
            f"{paths['swiftui']}: no `case kindCanvas:` arm — the "
            f"canvas blit moved and this clause is blind, which is "
            f"worse than a failure: it would pass for any arm at all")
    else:
        body = arm.group(2)
        for want, why in (
            (r"CGFloat\(buffer\.width\) / node\.drawingScale",
             "the macOS NSImage's size from the BUFFER's own pixels "
             "over the scale they were drawn at"),
            (r"cgImage: buffer, scale: node\.drawingScale",
             "the iOS UIImage's scale from the buffer's own"),
        ):
            if re.search(want, body) is None:
                bad.append(
                    f"{paths['swiftui']}: the canvas arm no longer "
                    f"takes {why}. A blit sized from anything but the "
                    f"buffer is a STRETCH, and no canvas observable "
                    f"can see one — the hash and the ink bounds are "
                    f"both taken at the viewbox (docs/canvas-plan.md "
                    f"§3.2.1, §7.1)")
        if re.search(r"\.resizable\(\)", body):
            bad.append(
                f"{paths['swiftui']}: the canvas arm calls "
                f".resizable(). That is the stretch this architecture "
                f"removed: the core decides what size to raster at — "
                f"the viewbox for `fixed`, the assigned track for "
                f"everything else — and the backend blits those pixels "
                f"one to one. `fixed`'s whole guarantee is that the "
                f"content does not follow the track, and every scene "
                f"assertion stays green without it")
        if re.search(r"KayaHost\.canvasTrack\(", swiftui_body) is None:
            bad.append(
                f"{paths['swiftui']}: nothing reports a canvas's "
                f"assigned track. Without the report the core can "
                f"only raster at the viewbox and the size policy is "
                f"inert — `scale` never re-rasters, `redraw` is never "
                f'asked, and `expect_raster` answers "no track '
                f'reported" (docs/canvas-plan.md §3.2.1)')

        # THE SAME REPORT, ALL FOUR ARMS (generalized at the
        # 2026-08-28 fan-out merge): a backend that stops reporting
        # leaves the size policy silently inert behind green legs, and
        # only its own lane's runtime negative would ever see it.
        for key, body_, pat, spell in (
            ("compose", strip_comments(read("compose")),
             r"KayaPresent\.canvasTrack\(", "KayaPresent.canvasTrack"),
            ("gtk", gtk_body, r"\.set_canvas_track\(",
             "Scene::set_canvas_track"),
            ("winui", strip_comments(winui_text),
             r"scene\.set_canvas_track\(", "scene.set_canvas_track"),
        ):
            if re.search(pat, body_) is None:
                bad.append(
                    f"{paths[key]}: nothing reports a canvas's "
                    f"assigned track ({spell} is gone). The size "
                    f"policy is silently inert — `scale` never "
                    f"re-rasters, `redraw` is never asked, and "
                    f'`expect_raster` answers "no track reported" '
                    f"(docs/canvas-plan.md §3.2.1)")

        # WINUI ALONE: the report comes from the PARENT-ASSIGNED slot.
        # The Image carries an explicit size from the buffer — the 1:1
        # blit — so a report read off the element's own box returns the
        # RASTER's size and track==raster by construction: every
        # observable green, the policy dead (docs/deferred.md's struck
        # winui bullet carries the measured wording).
        if re.search(r"LayoutInformation::GetLayoutSlot\(",
                     strip_comments(winui_text)) is None:
            bad.append(
                f"{paths['winui']}: the track report no longer reads "
                f"the parent-assigned layout slot. A report off the "
                f"element's own box reads the raster back (the Image "
                f"is explicitly sized from the buffer), so track and "
                f"raster agree by construction while the policy is "
                f"dead")
        if re.search(r"SetWidth\(f64::from\(width\) / scale\)",
                     strip_comments(winui_text)) is None:
            bad.append(
                f"{paths['winui']}: the blit is no longer sized from "
                f"the buffer over the scale. Sized from anything else "
                f"it is a stretch, and no canvas observable can see "
                f"one (docs/canvas-plan.md §3.2.1)")

    # THE 1:1 HALF ON GTK, where the blit is this project's own widget.
    # `GtkPicture` cannot express 1:1 — every member of GtkContentFit
    # scales at some size, and GTK never allocates a widget more than
    # its parent assigned, so a squeezed `fixed` canvas meets one of
    # those fits whichever is chosen. KayaCanvas's natural size IS the
    # blit and its snapshot draws the blit at that size.
    m = re.search(r"\bContentFit\b", gtk_body)
    if m:
        n = gtk_body.count("\n", 0, m.start()) + 1
        bad.append(
            f"{paths['gtk']}:{n} names GtkContentFit. Every member of "
            f"that vocabulary scales the blit at some size — Fill "
            f"stretches, Contain and Cover scale up, ScaleDown scales "
            f"down — and `fixed`'s whole guarantee is that the content "
            f"does NOT follow the track (docs/canvas-plan.md §3.2.1, "
            f"ruling 2). The canvas widget draws its own blit at the "
            f"size the core rastered it for; no scene assertion can "
            f"see the difference")
    snap = re.search(
        r"fn snapshot\(&self, snapshot: &gtk4::Snapshot\) \{(.*?)"
        r"\n        \}", gtk_body, re.S)
    if snap is None:
        bad.append(
            f"{paths['gtk']}: KayaCanvas's snapshot is not where this "
            f"gate looks — the canvas blit moved and this clause is "
            f"blind, which is worse than a failure: it would pass for "
            f"any arm at all")
    else:
        body = snap.group(1)
        for want, why in (
            (r"let \(pw, ph\) = self\.size\.get\(\);",
             "the size the CORE rastered this blit for"),
            (r"PaintableExt::snapshot\(&paintable, snapshot, pw, ph\)",
             "the paintable drawn at that size"),
        ):
            if re.search(want, body) is None:
                bad.append(
                    f"{paths['gtk']}: the canvas snapshot no longer "
                    f"takes {why}. A blit drawn at anything but the "
                    f"buffer's own size is a STRETCH, and no canvas "
                    f"observable can see one — the hash and the ink "
                    f"bounds are both taken at the viewbox "
                    f"(docs/canvas-plan.md §3.2.1, §7.1)")

    return bad


# THE GUARD GUARDS ITSELF, on DOCTORED COPIES OF THE REAL FILES rather
# than on synthetic samples (docs/traps.md, the wayland seat guard).
# Every perturbation prints its substitution count and is refused if it
# did not apply, and every refusal is checked for its REASON.
def negatives():
    # N1: A WIDGET BACKEND THAT INTERPRETS AN OP. The shipped defect
    # this rule exists against, in its smallest form — one arm that
    # resolves a paint role for itself.
    s = g.perturb("N1 (a GTK arm that consults a paint role)", GTK,
                  r"fn set_drawing\(canvas: &KayaCanvas",
                  "fn kaya_paint_is_series(p: i64) -> bool "
                  "{ p == PAINT_SERIES }\n"
                  r"fn set_drawing(canvas: \&KayaCanvas", flags=re.S)
    g.negative("a GTK backend that lowers ops itself",
               lambda p=s: check(str(p), WINUI, SWIFTUI, COMPOSE),
               want="names the canvas vocabulary")

    # N1b: the same in an INTERPRETER, where the constants
    # legitimately exist — so the clause has to tell a use from a
    # declaration.
    s = g.perturb("N1b (a Compose arm that consults a draw op)",
                  COMPOSE, r"KayaCompose\.KIND_CANVAS -> \{",
                  "KayaCompose.KIND_CANVAS -> {\n            "
                  "if (node.drawingScale == DRAW_MOVE_TO.toDouble()) "
                  "return", flags=re.S)
    g.negative("a Compose arm that switches on an op",
               lambda p=s: check(GTK, WINUI, SWIFTUI, str(p)),
               want="consults the canvas vocabulary")

    # N1c: AND THE VOCABULARY LIST ITSELF IS THE ANCHOR. Losing it
    # would make every later mention look like a use — or, if the
    # clause were written the other way, make the whole sweep vacuous.
    s = g.perturb("N1c (the SwiftUI vocabulary list renamed)", SWIFTUI,
                  r"let kayaCanvasVocabulary: \[Int64\] = \[",
                  "let kayaCanvasNumbers: [Int64] = [", flags=re.S)
    g.negative("a renamed vocabulary anchor",
               lambda p=s: check(GTK, WINUI, str(p), COMPOSE),
               want="vocabulary list this gate reads is gone")

    # N2: THE PIXEL FORMAT, changed to the other plausible one. This
    # is the perturbation a scene sampling a grey would pass.
    s = g.perturb("N2 (the GTK texture format swapped to BGRA)", GTK,
                  r"MemoryFormat::R8g8b8a8Premultiplied",
                  "MemoryFormat::B8g8r8a8Premultiplied", flags=re.S)
    g.negative("a GTK arm handing over the wrong format",
               lambda p=s: check(str(p), WINUI, SWIFTUI, COMPOSE),
               want="no longer names the pixel format")

    # N2b: THE WINUI SWIZZLE, flattened to an identity copy — which is
    # what a reader who believed the buffers matched would write.
    s = g.perturb("N2b (the WinUI blue/red swizzle flattened)", WINUI,
                  r"\*dst\.add\(at\) = pixels\[at \+ 2\];",
                  "*dst.add(at) = pixels[at];", flags=re.S)
    g.negative("a WinUI arm that stopped swizzling",
               lambda p=s: check(GTK, str(p), SWIFTUI, COMPOSE),
               want="no longer writes the BGRA swizzle")

    # N2c: SwiftUI's byte order, the half that is easy to drop.
    s = g.perturb("N2c (the SwiftUI byte order dropped)", SWIFTUI,
                  r"\.union\(\.byteOrder32Big\)", "", flags=re.S)
    g.negative("a CGImage with no declared byte order",
               lambda p=s: check(GTK, WINUI, str(p), COMPOSE),
               want="no longer names the pixel format")

    # N3: THE ROUNDED SCALE — GTK's integer sibling, which every lane
    # this project runs would accept in silence.
    s = g.perturb("N3 (the GTK scale read rounded to an integer)", GTK,
                  r"\.map_or\(crate::canvas::CANONICAL_SCALE, "
                  r"\|surface\| surface\.scale\(\)\)",
                  ".map_or(crate::canvas::CANONICAL_SCALE, |surface| "
                  "f64::from(surface.scale_factor()))", flags=re.S)
    g.negative("a GTK report reading the rounded scale",
               lambda p=s: check(str(p), WINUI, SWIFTUI, COMPOSE),
               want="gtk_widget_get_scale_factor")

    # N3b: A BACKEND THAT NEVER REPORTS AT ALL. Invisible on five
    # lanes, because they are all at 1.0 or at a scale the platform
    # states exactly.
    s = g.perturb("N3b (the WinUI presentation report removed)", WINUI,
                  r"fn presentation_report\(core: &mut CoreState\)",
                  "fn unreported_presentation(core: &mut CoreState)",
                  flags=re.S)
    g.negative("a WinUI backend that never reports its scale",
               lambda p=s: check(GTK, str(p), SWIFTUI, COMPOSE),
               want="has no canvas presentation report")

    # N3c: the reading swapped out under a report that still exists.
    s = g.perturb("N3c (the Compose density report pinned to 1.0)",
                  COMPOSE,
                  r"LocalDensity\.current\.density\.toDouble\(\)\n"
                  r"    val presentationDark",
                  "1.0\n    val presentationDark", flags=re.S)
    g.negative("a Compose report that stopped reading the density",
               lambda p=s: check(GTK, WINUI, SWIFTUI, str(p)),
               want="no longer reads")

    # N4: A RESIZABLE CANVAS BLIT — the stretch this architecture
    # removed, in the one line that reintroduces it, with every canvas
    # observable still green.
    s = g.perturb("N4 (the SwiftUI canvas blit made resizable)",
                  SWIFTUI,
                  r"cgImage: buffer, scale: node.drawingScale, "
                  r"orientation: .up\)\)",
                  "cgImage: buffer, scale: node.drawingScale, "
                  "orientation: .up)).resizable()", flags=re.S)
    g.negative("a canvas arm that stretches its buffer",
               lambda p=s: check(GTK, WINUI, str(p), COMPOSE),
               want="calls .resizable()")

    # N4b: THE BLIT SIZED FROM THE TRACK INSTEAD OF THE BUFFER — the
    # same defect written the other way round, and the one a reader
    # reaches for when a `fixed` canvas looks small in its row.
    s = g.perturb("N4b (the macOS blit sized from the laid-out frame)",
                  SWIFTUI,
                  r"width: CGFloat\(buffer.width\) / "
                  r"node.drawingScale,",
                  "width: CGFloat(kayaCanvasFrames[node.id]?.width "
                  "?? 0),", flags=re.S)
    g.negative("a blit sized from the track",
               lambda p=s: check(GTK, WINUI, str(p), COMPOSE),
               want="no longer takes the macOS NSImage's size")

    # N4c: THE TRACK REPORT REMOVED — the shipped state this closes.
    # Every canvas observable stays green and the size policy is
    # silently inert. THREE SITES, all replaced.
    s = g.perturb("N4c (the SwiftUI canvas track report removed)",
                  SWIFTUI, r"KayaHost\.canvasTrack\(",
                  "kayaNoTrackReport(", want=3, flags=re.S)
    g.negative("a backend that reports no track",
               lambda p=s: check(GTK, WINUI, str(p), COMPOSE),
               want="nothing reports a canvas's assigned track")

    # N4d: THE GTK BLIT DRAWN AT THE ALLOCATION — `ContentFit::Fill`
    # written out by hand, which is what the widget replaced. A
    # `fixed` canvas squeezed by its row is compressed and every
    # assertion stays green.
    s = g.perturb("N4d (the GTK blit drawn at the allocation)", GTK,
                  r"PaintableExt::snapshot\(&paintable, snapshot, "
                  r"pw, ph\)",
                  r"PaintableExt::snapshot(\&paintable, snapshot, "
                  r"w, h)", flags=re.S)
    g.negative("a GTK canvas that stretches its buffer",
               lambda p=s: check(str(p), WINUI, SWIFTUI, COMPOSE),
               want="no longer takes the paintable drawn at that size")

    # N4e: AND THE TOOLKIT'S OWN VOCABULARY BACK. Every member of it
    # scales, so naming one at all is the stretch returning by another
    # road.
    s = g.perturb("N4e (a GTK canvas arm that sets a content fit)",
                  GTK, r"let canvas = KayaCanvas::default\(\);",
                  "let canvas = KayaCanvas::default();\n"
                  "                    canvas.set_content_fit("
                  "gtk4::ContentFit::Fill);", flags=re.S)
    g.negative("a canvas arm that lets the toolkit fit the blit",
               lambda p=s: check(str(p), WINUI, SWIFTUI, COMPOSE),
               want="names GtkContentFit")

    # N4f: THE COMPOSE TRACK REPORT REMOVED — the same silent-inert
    # state as N4c, one interpreter over.
    s = g.perturb("N4f (the Compose canvas track report removed)",
                  COMPOSE, r"KayaPresent\.canvasTrack\(",
                  "kayaNoTrackReport(", flags=re.S)
    g.negative("a Compose arm that reports no track",
               lambda p=s: check(GTK, WINUI, SWIFTUI, str(p)),
               want="nothing reports a canvas's assigned track")

    # N4g: THE GTK TRACK REPORT REMOVED.
    s = g.perturb("N4g (the GTK canvas track report removed)", GTK,
                  r"\.set_canvas_track\(", ".no_track_report(",
                  flags=re.S)
    g.negative("a GTK arm that reports no track",
               lambda p=s: check(str(p), WINUI, SWIFTUI, COMPOSE),
               want="nothing reports a canvas's assigned track")

    # N4h: THE WINUI TRACK REPORT REMOVED.
    s = g.perturb("N4h (the WinUI canvas track report removed)", WINUI,
                  r"scene\.set_canvas_track\(", "scene.no_track_report(",
                  flags=re.S)
    g.negative("a WinUI arm that reports no track",
               lambda p=s: check(GTK, str(p), SWIFTUI, COMPOSE),
               want="nothing reports a canvas's assigned track")

    # N4i: THE WINUI REPORT READ OFF THE ELEMENT'S OWN BOX — the
    # reading the ledger bullet's original wording would have
    # produced, measured as track==raster by construction with the
    # policy dead.
    s = g.perturb("N4i (the WinUI report no longer reads the layout "
                  "slot)", WINUI, r"LayoutInformation::GetLayoutSlot\(",
                  "element_own_box(", flags=re.S)
    g.negative("a slot report replaced by the element box",
               lambda p=s: check(GTK, str(p), SWIFTUI, COMPOSE),
               want="no longer reads the parent-assigned layout slot")

    g.negatives_ran(18)


negatives()

# --- Clause 5: THE INK VERB'S PER-MODE COMPARE, live. -----------------
# `expect_ink` names both palettes and the HOST picks one, so a mac leg
# evaluates one arm — which is how a light-only frozen string reached a
# dark-mode host and reddened an untouched scene (2026-08-27,
# docs/traps.md). The other arm is reachable only by writing the user's
# own setting, so both are driven here against the real matcher.
if platform.system() == "Darwin":
    if not (ROOT / "target" / "debug" / "libkaya.dylib").is_file():
        print("check-canvas-blit: target/debug/libkaya.dylib is not "
              "built — the ink probe links against it. Run "
              "tools/gates.py, which builds what its gates read.",
              file=sys.stderr)
        raise SystemExit(1)
    # The probe compiles the interpreter's OWN source, so there is no
    # interpreter artifact in this path to go stale.
    probe_bin = g.scratch() / "swiftui-ink-modes"
    build = subprocess.run(
        ["bash", "-c",
         'source "$1/tools/lib/swift-toolchain.sh" && cd "$1" && '
         'shift && kaya_swiftc "$@"',
         "swift-toolchain", str(ROOT),
         "-import-objc-header", "crates/kaya/include/kaya.h",
         SWIFTUI, "tools/checks/swiftui-ink-modes.swift",
         "-L", "target/debug", "-lkaya",
         "-framework", "AppKit", "-framework", "Foundation",
         "-o", str(probe_bin)], check=False)
    if build.returncode != 0:
        print("check-canvas-blit: the ink-mode probe did not compile",
              file=sys.stderr)
        raise SystemExit(1)
    ink = subprocess.run(
        [str(probe_bin)], check=False,
        env=dict(os.environ,
                 DYLD_LIBRARY_PATH=str(ROOT / "target" / "debug")))
    if ink.returncode != 0:
        print(f"check-canvas-blit: FAIL — the SwiftUI ink-mode probe "
              f"exited {ink.returncode}. The lines above name each "
              f"case that did not hold.", file=sys.stderr)
        raise SystemExit(1)
else:
    print("check-canvas-blit: clause 4 (the SwiftUI ink-mode probe) "
          "SKIPPED — it needs macOS. Clauses 1-3 ran.")

offenders = check(GTK, WINUI, SWIFTUI, COMPOSE)
if offenders:
    print("\n".join(offenders))
    print("check-canvas-blit: FAIL")
    raise SystemExit(1)
g.verdict("4 backends: the one rule, the four pixel formats, the one "
          "swizzle, the true scale reported, the 1:1 blit and its "
          "track report, the GTK canvas's own 1:1 snapshot, and both "
          "ink modes compared")
