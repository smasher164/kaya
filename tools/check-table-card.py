#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# A TABLE BOUNDS ITS OWN EXTENT — one semantics, four spellings
# (docs/deferred.md's table-card entry, ruled 2026-08-25). The mac's
# NATIVE tier has it from the widget; GTK and WinUI each draw a flat card;
# the iOS SYNTHESIZED tier draws the INSET-GROUPED one — the Settings
# look, where a card is parted from its page by the grouped background
# behind it and never by an outline — and COMPOSE draws Android's own
# answer to the same sentence, the SEGMENTED GROUPED CONTAINER: a header
# segment, androidx's 2dp gap, one container for every body row, corners
# by position (16dp at the group's true ends, 4dp at the boundary), and
# no stroke anywhere.
#
# NO SCENE CAN FAIL THIS. The card is pixels and nothing else: every
# table observable — expect_columns, expect_rows, expect_column_edges,
# expect_window — answers exactly the same with the card gone, which is
# how the three backends shipped for months drawing a table's OPENING
# grammar and never its close (the CASH row running into "Account
# total"). So, like the native-undo pair, a gate is the only wall
# available, and it holds three things a capture would otherwise be the
# only witness to: the card is THERE, it is FLAT (the ruling: no shadow,
# no blur, no elevation — and on iOS no stroke either), and its colours
# come from the platform's own tokens rather than from literals.
#
# AND WHERE IT MAY NOT REACH: the mac. Its native tier delineates from
# NSTableView's own interior and is not to be touched, so the iOS card
# is the synthesized tier's alone, its numbers are zero on macOS, and
# both halves are held here — a card wrapped around KayaNativeTable and
# a macOS arm that draws are each watched being refused.
#
# WHAT IT DELIBERATELY DOES NOT HOLD: whether the card LOOKS right,
# which is the capture sign-off the ledger entry still holds open.

import re


def _die(msg=None):
    """The shell tail, ported: the sentence, then the verdict."""
    if msg is not None:
        print(msg, file=sys.stderr)
    print("check-table-card: FAIL", file=sys.stderr)
    raise SystemExit(1)

GTK = "crates/kaya/src/gtk.rs"
WINUI = "crates/kaya/src/winui/mod.rs"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"
SWIFTUI = "swift/KayaSwiftUI.swift"

FACE_CALL = ".modifier(KayaTableCardFace())"
TIER_HEAD = "private struct KayaSynthesizedTable: View {"
FACE_HEAD = "private struct KayaTableCardFace: ViewModifier {"
CLIP_HEAD = "ScrollView(.vertical) {"

# --- THE CARD IS THERE -------------------------------------------------
#
# (label, file, needle, the perturbation that would otherwise be silent).
# Every perturbation is a plausible bug — a token swapped for a literal,
# a draw modifier that became a layout one, a card left unparented — and
# never the deletion of the counted string, which would prove only that
# str.count works.
PRESENT = (
    ("gtk card fill", GTK,
     ".kaya-table-card { background-color: @card_bg_color; border-radius: 12px;",
     ".kaya-table-card { background-color: #ffffff; border-radius: 12px;"),
    ("gtk card stroke", GTK,
     "outline: 1px solid @borders; outline-offset: -1px;",
     "outline: 0px solid @borders; outline-offset: -1px;"),
    # THE INTERIOR, all three. A card whose content sits on its own stroke
    # is what the 2026-08-25 captures were refused for, and it is pixels:
    # no observable moves when the padding goes.
    ("gtk card interior", GTK,
     "padding: 8px 12px; }",
     "padding: 0px; }"),
    # And the one number that has to follow it: GTK's assigned track is an
    # OUTER measure while the viewport is the content box, so the card's
    # own span comes off the track or every padded table convicts itself.
    ("gtk card interior off the assigned track", GTK,
     "let inset = css_inset_span(column);",
     "let inset = 0.0;"),
    # A rule nothing wears is a rule nothing draws.
    ("gtk card worn by the table container", GTK,
     "column.add_css_class(TABLE_CARD_CLASS);",
     "let _ = TABLE_CARD_CLASS;"),
    ("winui card fill", WINUI,
     'Background=\\"{ThemeResource CardBackgroundFillColorDefaultBrush}\\" ',
     'Background=\\"#FF2B2B2B\\" '),
    ("winui card stroke", WINUI,
     'BorderBrush=\\"{ThemeResource CardStrokeColorDefaultBrush}\\" ',
     'BorderBrush=\\"#FF808080\\" '),
    ("winui card stroke width and radius", WINUI,
     'BorderThickness=\\"1\\" CornerRadius=\\"{ThemeResource OverlayCornerRadius}\\" ',
     'BorderThickness=\\"0\\" CornerRadius=\\"{ThemeResource OverlayCornerRadius}\\" '),
    # BEHIND the three tracks and spanning them: appended instead, the
    # card paints OVER the rows, and a lane sees a blank table.
    ("winui card parented behind the tracks", WINUI,
     "children.InsertAt(0, &card)?;",
     "children.Append(&card)?;"),
    # The interior rides the CONTAINER's padding, which is the number
    # every track arithmetic there already subtracts — that is what keeps
    # the cell edges where they were.
    ("winui card interior on the container padding", WINUI,
     "own + card + if root { core.inset } else { 0.0 }",
     "own + if root { core.inset } else { 0.0 }"),
    # And the card is pulled back OUT of that padding, or it is inset
    # twice and hugs the text again.
    ("winui card pulled out to the container box", WINUI,
     "Left: -TABLE_CARD_PAD,",
     "Left: 0.0,"),
    ("winui card spans the three tracks", WINUI,
     "Grid::SetRowSpan(&card_element, 3)?;",
     "Grid::SetRowSpan(&card_element, 1)?;"),
    # COMPOSE IS THE SEGMENTED GROUPED CONTAINER (ruled 2026-08-25 after
    # the Material research): filled, BORDERLESS, elevation 0, two
    # segments parted by androidx's own 2dp gap, corners by position.
    ("compose segment fill", COMPOSE,
     "Box(Modifier.background(MaterialTheme.colorScheme.surfaceContainer, shape))",
     "Box(Modifier.background(MaterialTheme.colorScheme.surface, shape))"),
    # CORNERS BY POSITION is the whole idiom: outer pair at the true ends
    # of the group, the small inner radius at the segment boundary. Rounded
    # all four, the two segments read as two cards with a 2dp crack.
    ("compose header segment corners", COMPOSE,
     "    topStart = KAYA_TABLE_SEGMENT_OUTER,\n"
     "    topEnd = KAYA_TABLE_SEGMENT_OUTER,\n"
     "    bottomStart = KAYA_TABLE_SEGMENT_INNER,",
     "    topStart = KAYA_TABLE_SEGMENT_OUTER,\n"
     "    topEnd = KAYA_TABLE_SEGMENT_OUTER,\n"
     "    bottomStart = KAYA_TABLE_SEGMENT_OUTER,"),
    ("compose body segment corners", COMPOSE,
     "    topStart = KAYA_TABLE_SEGMENT_INNER,\n"
     "    topEnd = KAYA_TABLE_SEGMENT_INNER,\n"
     "    bottomStart = KAYA_TABLE_SEGMENT_OUTER,",
     "    topStart = KAYA_TABLE_SEGMENT_OUTER,\n"
     "    topEnd = KAYA_TABLE_SEGMENT_INNER,\n"
     "    bottomStart = KAYA_TABLE_SEGMENT_OUTER,"),
    # And the gap between them: fused, it is one container again and the
    # header stops being a segment at all.
    # The folded block (docs/adaptive-layout-plan.md D7) leads the sum;
    # the gap this clause holds is still the one between the segments.
    ("compose segment gap", COMPOSE,
     "val bodyTop = foldedBlock + headerSegH + gap",
     "val bodyTop = foldedBlock + headerSegH"),
    # THE INTERIOR, inside each segment. Both numbers are laid out rather
    # than padded now, so the perturbation is the measure that reads them.
    ("compose card interior", COMPOSE,
     "val padX = KAYA_TABLE_CARD_PAD_X.roundToPx()",
     "val padX = 0"),
    ("compose card interior, vertical", COMPOSE,
     "val padY = KAYA_TABLE_CARD_PAD_Y.roundToPx()",
     "val padY = 0"),
    # And the one number that has to follow it, GTK's `css_inset_span`
    # clause in this backend's spelling: the segments span the outer box
    # while the cells lay out in the interior, so the card's own span comes
    # off the track or every carded table convicts itself of a 32dp
    # underfill at expect_column_edges.
    ("compose card interior off the assigned track", COMPOSE,
     "if (constraints.hasBoundedWidth) (constraints.maxWidth - 2 * padX) / density else -1f",
     "if (constraints.hasBoundedWidth) constraints.maxWidth / density else -1f"),
    # THE OTHER HALF OF THAT SAME TRUTH: the interior scrolls INSIDE the
    # clip, so the clip is not the cells' box and the viewport writer must
    # inset it — reported raw, the table starts 16dp inside its own
    # viewport (swift's two-writer clause, one platform over).
    ("compose carded viewport reports the cells' box", COMPOSE,
     "                    KAYA_TABLE_CARD_PAD_X.value,\n                )",
     "                    0f,\n                )"),
    # THE iOS SYNTHESIZED TIER, inset-grouped: the two SEMANTIC colours
    # carry the whole boundary here, so a literal is not a style slip —
    # it is the card going blank in dark mode, or (light mode, white on
    # white) the boundary disappearing altogether.
    ("ios card fill", SWIFTUI,
     ".fill(Color(uiColor: .secondarySystemGroupedBackground))",
     ".fill(Color(white: 1.0))"),
    # THE GROUND IS THE SCREEN'S (the grouped-screen rule, ratified
    # 2026-08-30): edge to edge behind the title, worn by every surface
    # root the registry marks, never a band around a table's region.
    ("ios screen ground", SWIFTUI,
     "Color(uiColor: .systemGroupedBackground).ignoresSafeArea())",
     "Color(white: 0.95).ignoresSafeArea())"),
    ("ios screen ground worn by pushed entries", SWIFTUI,
     ".modifier(KayaGroupedScreenGround(on: scene.groupedEntries.contains(entryId)))",
     ".modifier(EmptyModifier())"),
    ("ios screen ground worn by the primary window", SWIFTUI,
     "KayaGroupedScreenGround(\n"
     "                on: scene.groupedWindows.contains(0))",
     "EmptyModifier()"),
    ("ios card radius", SWIFTUI,
     "RoundedRectangle(cornerRadius: kayaTableCardRadius, style: .continuous)",
     "Rectangle()"),
    ("ios card interior", SWIFTUI,
     ".padding(.horizontal, kayaTableCardInsetX)",
     ".padding(.horizontal, 0)"),
    ("ios card interior, vertical", SWIFTUI,
     ".padding(.vertical, kayaTableCardInsetY)",
     ".padding(.vertical, 0)"),

    # And the one number that has to follow it, GTK's `css_inset_span`
    # clause in this file's spelling: the reporters read the card's
    # CONTENT box and KayaTrackReader the flex cell's OUTER one, so the
    # card's own span comes off the track or every carded table convicts
    # itself at expect_column_edges.
    ("ios card interior off the assigned track", SWIFTUI,
     "assigned, pad: kayaTableCardPad, synthesized: got.2)",
     "assigned, pad: 0, synthesized: got.2)"),
    # The pad IS the interior since the band died with the grouped-screen
    # rule: every synthesized card sits on a SCREEN ground now, so the
    # only span between track and cells is the card's own 16.
    ("ios card span is the interior", SWIFTUI,
     "let kayaTableCardPad: CGFloat = kayaTableCardInsetX",
     "let kayaTableCardPad: CGFloat = 0"),
    # THE TWO VIEWPORT WRITERS OF A GROWN TABLE, which the content-layer
    # card is what forces apart: the card's interior scrolls INSIDE the
    # clip, so the clip is wider than the cells' box and both writers
    # must report the cells' box or expect_column_edges reads a table
    # that starts 16pt inside its own viewport.
    ("ios carded viewport, the reporter", SWIFTUI,
     "scrollClip: true)",
     "scrollClip: false)"),
    ("ios carded viewport, the window's own writer", SWIFTUI,
     "inScrollClip: viewportRect, interior: kayaTableCardInsetX)",
     "inScrollClip: viewportRect, interior: 0)"),
    # THE MAC SPENDS NOTHING. This is the number the instrument
    # subtracts; non-zero on a mac, it takes 32pt off every mac table's
    # track and convicts a tier that draws no card at all.
    ("mac card interior is zero", SWIFTUI,
     "let kayaTableCardInsetX: CGFloat = 0",
     "let kayaTableCardInsetX: CGFloat = 4"),
    # AND THE MAC'S OWN CLOSE, which is the apron rather than a card: a
    # SHAPESTYLE, resolved in the hierarchy, never a Color(nsColor:).
    # `Color(nsColor:)` snapshots the dynamic NSColor OUTSIDE the window
    # while the table view resolves the same colour inside it, so the
    # perturbation below — the spelling that shipped — filled #1E1E1E
    # under an interior that rendered #24292C: a 5pt bar across the
    # bottom of every dark-mode table, and #FFFFFF both ways in light,
    # so no lane and no light capture could see it (measured 2026-08-26,
    # docs/traps.md).
    ("mac apron resolved in the hierarchy", SWIFTUI,
     "return Rectangle().fill(.background)",
     "return Color(nsColor: .controlBackgroundColor)"),
)

# THE INTERIOR IS A NAMED NUMBER, not a literal at the use site. No
# platform hands out a TOKEN for a card's content padding the way it does
# for the fill and the stroke — Adwaita's lives in its row's own
# stylesheet, Fluent's in a control's default style, Material's in its
# spec — so the substitute is a constant whose comment carries the
# provenance, and this holds the use sites to naming it.
#
# THE COMPOSE THREE ARE ANDROIDX'S OWN NUMBERS and the comment above them
# carries the token each was read from — ListTokens.ContainerShape =
# CornerLarge = 16, ItemContainerExpressiveShape = CornerExtraSmall = 4,
# ListItemDefaults.SegmentedGap = 2. material3 1.3.1 (the pinned
# compose-bom) has no SegmentedListItem to inherit them from, so they are
# copied, which is check-file-modes' trap one surface over.
NAMED = (
    ("winui card interior", WINUI, "const TABLE_CARD_PAD: f64 = 12.0;"),
    ("compose card interior x", COMPOSE, "private val KAYA_TABLE_CARD_PAD_X = 16.dp"),
    ("compose card interior y", COMPOSE, "private val KAYA_TABLE_CARD_PAD_Y = 8.dp"),
    ("compose segment outer radius", COMPOSE,
     "private val KAYA_TABLE_SEGMENT_OUTER = 16.dp"),
    ("compose segment inner radius", COMPOSE,
     "private val KAYA_TABLE_SEGMENT_INNER = 4.dp"),
    ("compose segment gap width", COMPOSE,
     "private val KAYA_TABLE_SEGMENT_GAP = 2.dp"),
    ("ios card interior x", SWIFTUI, "let kayaTableCardInsetX: CGFloat = 16"),
    ("ios card interior y", SWIFTUI, "let kayaTableCardInsetY: CGFloat = 8"),
    ("ios card radius constant", SWIFTUI, "let kayaTableCardRadius: CGFloat = 10"),
)

# --- AND IT IS FLAT ----------------------------------------------------
#
# Read out of the card's OWN BLOCK, never the file: all three of these
# files legitimately name shadows and elevations elsewhere (a menu
# popover has one, a dialog has one), so a file-wide grep would be a
# sentence about the wrong widget. The ruling is flat HERE.
#
# (label, file, first line of the block, last line, forbidden spellings,
#  the rule the spellings would break)
FLAT = ("the ruling of 2026-08-25 is a FLAT card: fill, a 1px stroke and "
        "the radius, zero blur, zero elevation, and colours from the "
        "platform's tokens rather than literals")
GROUPED = ("the iOS spelling of that ruling is INSET-GROUPED: fill, the "
           "radius and the grouped ground behind it — NO stroke, no "
           "elevation, and the two semantic colours rather than literals, "
           "because iOS parts a card from its page by background contrast "
           "and a literal has no dark mode")
SEGMENTED = ("the Compose spelling of that ruling is the SEGMENTED GROUPED "
             "CONTAINER (ruled 2026-08-25 after the Material research): "
             "filled from surfaceContainer, elevation 0, and BORDERLESS — "
             "nothing in the grouped idiom draws a stroke, and the 1dp "
             "outlineVariant border this replaced was the least-supported "
             "part of the card it replaced")
CONTENT = ("the Compose card is CONTENT (ruled 2026-08-25): the segments "
           "are laid-out children sized to the collection's whole extent, "
           "so a short table's container ends at its last row and a tall "
           "one's scrolls with the rows. Anything that paints or pads on "
           "this chain belongs to the scroll VIEWPORT instead — it runs to "
           "the bottom of the screen under a three-row table, cannot "
           "scroll, and no observable moves either way")
BLOCKS = (
    ("gtk card rule", GTK,
     "const TABLE_CSS: &str = ", '";',
     ("box-shadow", "text-shadow", "filter:", "blur"), FLAT),
    ("winui card markup", WINUI,
     "const TABLE_CARD_XAML: &str = ", ");",
     ("Shadow", "Elevation", "Translation", "#"), FLAT),
    ("compose segment fill", COMPOSE,
     "private fun KayaTableSegment(shape: RoundedCornerShape) {", "\n}\n",
     (".border(", ".shadow(", "elevation", "tonalElevation", "shadowElevation",
      "Color(", "outlineVariant"), SEGMENTED),
    ("compose table modifier chain", COMPOSE,
     "        modifier = modifier\n", "            .verticalScroll(node.scrollState),",
     (".background(", ".border(", ".padding(", ".shadow("), CONTENT),
    ("ios card modifiers", SWIFTUI,
     FACE_HEAD, "\n}\n",
     ("stroke", ".border(", ".shadow(", "Color(red:", "Color(white:",
      "Color(hue:", "#colorLiteral"), GROUPED),
)

# --- THE LAYER, AND THE MAC -------------------------------------------
#
# Four ways this could go wrong, each perturbed the way it really would.
# THE FIRST IS THE ONE THAT ALREADY HAPPENED: the card was painted as the
# scroll VIEWPORT's background, so a three-row grown table ran white to
# the bottom of the phone's screen (the maintainer's capture, 2026-08-25)
# while its rows stopped near the top. An inset-grouped card belongs to
# the CONTENT: it ends with the last row, and on a tall table it spans the
# whole extent and scrolls with the rows. No observable moves either way,
# so the layer is a gate clause or nothing.
# (label, file, needle, replacement, the sentence the census must say)
ZONE = (
    # The fold's VStack (docs/adaptive-layout-plan.md D7) sits between the
    # face and the ScrollView's brace, so the shape walks two braces out.
    ("the card back on the scroll viewport's background", SWIFTUI,
     FACE_CALL + "\n                            }\n                        }\n"
     "                        .coordinateSpace(name: kayaTableScrollSpace(node))",
     "\n                            }\n                        }\n"
     "                        .coordinateSpace(name: kayaTableScrollSpace(node))\n"
     "                        " + FACE_CALL,
     "is not inside the scroll clip's content"),
    ("the card wrapped around the mac's native tier", SWIFTUI,
     "case .native: KayaNativeTable(node: node)",
     "case .native: KayaNativeTable(node: node).modifier(KayaTableCardFace())",
     "the card is the synthesized tier's alone"),
    ("a macOS arm that draws", SWIFTUI,
     "#if os(macOS)\n            content\n        #else\n            content\n"
     "                .padding(.horizontal, kayaTableCardInsetX)",
     "#if os(macOS)\n            content.background(Color.gray)\n        #else\n"
     "            content\n                .padding(.horizontal, kayaTableCardInsetX)",
     "the macOS arm of KayaTableCardFace"),
    # THE SAME FOUR WAYS ON COMPOSE, and the first is the same regression:
    # the card was the scroll VIEWPORT's background there too until
    # 2026-08-25, so a three-row grown table's container ran to the bottom
    # of the phone and a tall one's could not scroll with the rows.
    ("the compose card back on the scroll viewport's background", COMPOSE,
     "        modifier = modifier\n            // NOTHING ON THIS CHAIN",
     "        modifier = modifier\n"
     "            .background(MaterialTheme.colorScheme.surfaceContainer, "
     "KAYA_TABLE_BODY_SEGMENT_SHAPE)\n            // NOTHING ON THIS CHAIN",
     "the compose table modifier chain names `.background(`"),
    ("the compose card's interior back on the scroll clip", COMPOSE,
     "        modifier = modifier\n            // NOTHING ON THIS CHAIN",
     "        modifier = modifier\n"
     "            .padding(horizontal = KAYA_TABLE_CARD_PAD_X, "
     "vertical = KAYA_TABLE_CARD_PAD_Y)\n            // NOTHING ON THIS CHAIN",
     "the compose table modifier chain names `.padding(`"),
    ("the compose segments painted over the rows", COMPOSE,
     "            headerSeg.place(0, foldedBlock)\n"
     "            bodySeg.place(0, bodyTop)",
     "            headers.forEachIndexed { c, p -> "
     "p.place(padX + colX[c], foldedBlock + padY) }\n"
     "            headerSeg.place(0, foldedBlock)\n"
     "            bodySeg.place(0, bodyTop)",
     "paints OVER them"),
    # A MOVE, not a deletion: both segments still emitted, still exactly
    # two, and now one child too early — which re-points the cells' sublist
    # and the bottom spacer without moving a single observable.
    ("the compose segments moved off the content's tail", COMPOSE,
     "            Spacer(Modifier)\n"
     "            // LAST IN THE CONTENT AND FIRST IN THE PLACEMENT: placement\n"
     "            // order is draw order, so these paint BEHIND every row, and\n"
     "            // every index in the measure block below counts from the end.\n"
     "            KayaTableSegment(KAYA_TABLE_HEADER_SEGMENT_SHAPE)\n"
     "            KayaTableSegment(KAYA_TABLE_BODY_SEGMENT_SHAPE)",
     "            // LAST IN THE CONTENT AND FIRST IN THE PLACEMENT: placement\n"
     "            // order is draw order, so these paint BEHIND every row, and\n"
     "            // every index in the measure block below counts from the end.\n"
     "            KayaTableSegment(KAYA_TABLE_HEADER_SEGMENT_SHAPE)\n"
     "            KayaTableSegment(KAYA_TABLE_BODY_SEGMENT_SHAPE)\n"
     "            Spacer(Modifier)",
     "are not the last two children"),
    # THE HEADER RULE COMING BACK, spliced exactly where it stood until
    # 2026-08-26. Its absence is pixels like everything else here: no
    # observable moves, and the capture was the only witness.
    ("the compose header hairline back inside the segment", COMPOSE,
     "            Spacer(Modifier)\n            rows.forEach { row ->",
     "            HorizontalDivider()\n"
     "            Spacer(Modifier)\n            rows.forEach { row ->",
     "names `HorizontalDivider`"),
    # The folded children lead the content since D7; the segment census
    # still refuses a third segment wherever it lands.
    ("a third compose segment, at the head of the content", COMPOSE,
     "            folded.forEach { KayaRender(it) }\n            node.tableColumns.forEachIndexed",
     "            folded.forEach { KayaRender(it) }\n"
     "            KayaTableSegment(KAYA_TABLE_HEADER_SEGMENT_SHAPE)\n"
     "            node.tableColumns.forEachIndexed",
     "wanted exactly 2"),
)


def block(text, start, end, path, label):
    """The card's own lowering, COMMENTS STRIPPED: a comment that says
    the card carries no elevation is the rule written down, not a
    violation of it, and a scan that cannot tell those apart convicts
    the documentation."""
    at = text.find(start)
    if at < 0:
        return None
    stop = text.find(end, at + len(start))
    if stop < 0:
        return None
    body = text[at:stop + len(end)]
    return "\n".join(
        line for line in body.splitlines() if not line.strip().startswith("//")
    )


def swift_block(text, head):
    """A Swift declaration's own body, brace-matched from its opening
    line — the zone clauses below are about WHERE a modifier is applied,
    which a file-wide count cannot answer."""
    at = text.find(head)
    if at < 0:
        return None
    depth = 0
    for i in range(at + len(head) - 1, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[at:i + 1]
    return None


def zones(text):
    """WHICH LAYER WEARS THE CARD, and that it stops at the mac.

    The face is CONTENT — inside the scroll clip on the grown arm, so it
    ends with the last row and scrolls with the rows — while the ground
    is OUTSIDE the clip, framing the table's extent without scrolling.
    And neither reaches macOS, whose native tier delineates from
    NSTableView's own interior (the ruling)."""
    out = []
    tier = swift_block(text, TIER_HEAD)
    if tier is None:
        out.append(
            f"check-table-card: {SWIFTUI}: no `{TIER_HEAD}` — the tier that wears "
            "the card is gone or renamed, and every clause about where the card "
            "is applied would pass by reading nothing"
        )
    else:
        # BOTH ARMS wear the face (grown and ungrown). No ground call:
        # the screen carries the ground since the grouped-screen rule.
        for call, want, what in (
            (FACE_CALL, 2, "the card face, once per arm"),
        ):
            worn, here = text.count(call), tier.count(call)
            if worn != want or here != want:
                out.append(
                    f"check-table-card: {SWIFTUI}: `{call}` appears {worn} time(s) "
                    f"in the file and {here} inside KayaSynthesizedTable, wanted "
                    f"{want} of each ({what}) — the card is the synthesized tier's "
                    "alone; the mac's native tier delineates from NSTableView's "
                    "own interior and may not be wrapped in one"
                )
        clip = swift_block(tier, CLIP_HEAD)
        if clip is None:
            out.append(
                f"check-table-card: {SWIFTUI}: KayaSynthesizedTable has no "
                f"`{CLIP_HEAD}` block — the gate cannot tell the scroll clip's "
                "CONTENT from the clip itself, which is the whole of this clause"
            )
        else:
            if clip.count(FACE_CALL) != 1:
                out.append(
                    f"check-table-card: {SWIFTUI}: the grown arm's `{FACE_CALL}` "
                    "is not inside the scroll clip's content "
                    f"({clip.count(FACE_CALL)} inside `{CLIP_HEAD}`) — painted on "
                    "the clip instead, the card is the VIEWPORT's background: it "
                    "runs white to the bottom of the screen under a three-row "
                    "table and cannot scroll with a tall one (the capture of "
                    "2026-08-25)"
                )
    for head, name in ((FACE_HEAD, "KayaTableCardFace"),):
        card = swift_block(text, head)
        if card is None:
            out.append(
                f"check-table-card: {SWIFTUI}: no `{head}` — the modifier this "
                "gate reads the macOS arm out of is gone or renamed"
            )
            continue
        i = card.find("#if os(macOS)")
        j = card.find("#else", i + 1)
        if min(i, j) < 0:
            out.append(
                f"check-table-card: {SWIFTUI}: {name} is not "
                "`#if os(macOS)` / `#else` — the gate reads the two arms "
                "separately because only one of them is the ruling"
            )
            continue
        arm = " ".join(card[i + len("#if os(macOS)"):j].split())
        if arm != "content":
            out.append(
                f"check-table-card: {SWIFTUI}: the macOS arm of {name} "
                f"reads {arm!r}, wanted exactly 'content' — macOS is untouched "
                "by this ruling, and an arm that draws puts a grouped card "
                "under the below-floor mac tier where no lane would see it"
            )
    return out


CONTENT_HEAD = "        content = {"
CONTENT_END = "\n        modifier = modifier"
CONTENT_TAIL = (
    "            KayaTableSegment(KAYA_TABLE_HEADER_SEGMENT_SHAPE)\n"
    "            KayaTableSegment(KAYA_TABLE_BODY_SEGMENT_SHAPE)\n"
    "        },\n        modifier = modifier\n"
)
PLACE_HEAD = "        layout(totalW, totalH) {"


def layers(text):
    """WHICH LAYER WEARS THE COMPOSE CARD, and in what ORDER it paints.

    Compose has no modifier that can draw two separated shapes, so the two
    segments are laid-out CHILDREN — which buys the ruling's whole extent
    (the layout already sizes itself to top spacer + band + bottom spacer)
    and costs two invariants a modifier would not have needed: they are the
    LAST TWO children, because every index in the measure block counts from
    the end, and they are the FIRST TWO PLACED, because placement order is
    draw order."""
    out = []
    # AND NO HEADER RULE INSIDE A SEGMENT (ruled 2026-08-26, off the
    # round-six capture): the phone drew TWO separators nine pixels apart
    # and of different widths — the 1px hairline inset 16dp each side at
    # y=48, 8px of orphaned header fill under it, then the full-bleed 2dp
    # gap. In the grouped idiom the GAP is the separator and a segment
    # carries no internal hairline. Read out of the table's own content
    # lambda, because the file's four other HorizontalDividers are menu
    # separators and section rules and are none of this rule's business —
    # as are GTK's, WinUI's and iOS's, which are native grammar and stay.
    content = None
    at = text.find(CONTENT_HEAD)
    stop = text.find(CONTENT_END, at + len(CONTENT_HEAD)) if at >= 0 else -1
    if at < 0 or stop < 0:
        out.append(
            f"check-table-card: {COMPOSE}: the table's `{CONTENT_HEAD.strip()}` "
            "lambda is not where this gate reads it — every clause about what "
            "the table emits would pass by reading nothing"
        )
    else:
        content = text[at:stop]
        if "HorizontalDivider" in content:
            out.append(
                f"check-table-card: {COMPOSE}: the table's content lambda names "
                "`HorizontalDivider` — a segment carries no internal hairline, "
                "and one under the header draws a second separator beside the "
                "2dp gap that already is one (the capture of 2026-08-26: two "
                "rules nine pixels apart, of different widths, with orphaned "
                "header fill between them)"
            )
    calls = text.count("KayaTableSegment(KAYA_TABLE_")
    if calls != 2:
        out.append(
            f"check-table-card: {COMPOSE}: `KayaTableSegment(KAYA_TABLE_...)` "
            f"appears {calls} time(s), wanted exactly 2 — the header segment and "
            "the body segment, and no third: every index in the measure block "
            "(the cells' sublist, the bottom spacer, both segments) counts from "
            "the END of the content lambda, so one more child silently re-points "
            "every one of them"
        )
    if CONTENT_TAIL not in text:
        out.append(
            f"check-table-card: {COMPOSE}: the two segment fills are not the last "
            "two children of KayaTableSurface's content lambda — the measure block "
            "reads them at size-2 and size-1 and the cells at size-3, so a segment "
            "emitted anywhere else measures a row as a card and a card as a row"
        )
    at = text.find(PLACE_HEAD)
    if at < 0:
        out.append(
            f"check-table-card: {COMPOSE}: no `{PLACE_HEAD.strip()}` — the gate "
            "cannot read the placement ORDER, which is the whole of this clause"
        )
    else:
        stop = text.find("\n        }\n    }\n}", at)
        order = re.findall(r"(\w+)\.place\(", text[at:stop if stop > 0 else len(text)])
        if order[:2] != ["headerSeg", "bodySeg"]:
            out.append(
                f"check-table-card: {COMPOSE}: the table places {order[:2]} first, "
                "wanted ['headerSeg', 'bodySeg'] — placement order is draw order, "
                "so a segment placed after the rows paints OVER them and the lane "
                "sees a blank table (WinUI's appended-instead-of-inserted card, in "
                "this backend's spelling)"
            )
    return out


def census(files):
    """The real predicate. Returns one sentence per finding, naming the
    clause rather than printing a column of counts."""
    out = []
    for label, path, needle, _ in PRESENT:
        n = files[path].count(needle)
        if n != 1:
            out.append(
                f"check-table-card: {path}: {label} appears {n} time(s), "
                f"wanted exactly 1 (`{needle}`)"
            )
    for label, path, needle in NAMED:
        n = files[path].count(needle)
        if n != 1:
            out.append(
                f"check-table-card: {path}: {label} is not the named constant "
                f"this gate reads ({n} occurrence(s) of `{needle}`) — the card's "
                "interior is a number with a provenance in its comment, never a "
                "literal at the use site"
            )
    for label, path, start, end, forbidden, why in BLOCKS:
        body = block(files[path], start, end, path, label)
        if body is None:
            out.append(
                f"check-table-card: {path}: the {label} block is not where this "
                f"gate reads it (`{start}` .. `{end}`) — the flatness clause "
                "would pass by reading nothing"
            )
            continue
        for word in forbidden:
            if word in body:
                out.append(
                    f"check-table-card: {path}: the {label} names `{word}` — {why}"
                )
    out.extend(zones(files[SWIFTUI]))
    out.extend(layers(files[COMPOSE]))
    return out


def load(over=None):
    files = {
        p: (ROOT / p).read_text(encoding="utf-8")
        for p in (GTK, WINUI, COMPOSE, SWIFTUI)
    }
    if over:
        files.update(over)
    return files


real = load()
offenders = census(real)
for line in offenders:
    print(line, file=sys.stderr)
if offenders:
    print(
        "check-table-card: FAIL — a table that does not bound its own extent "
        "runs its last row into whatever follows it, and no lane can see that.",
        file=sys.stderr,
    )
    _die()
print(
    f"check-table-card: the card is present, padded and flat in all four "
    f"backends, iOS's and Compose's on the CONTENT layer, and the mac "
    f"unwrapped — {len(PRESENT)} clauses + {len(NAMED)} named interiors + "
    f"{len(BLOCKS)} flatness blocks + {len(ZONE)} layer/zone negatives"
)

# --- EVERY CLAUSE WATCHED FAILING -------------------------------------
#
# A doctored copy IN MEMORY, the substitution count printed, the REAL
# census re-run against it, and the exact finding demanded. A clause
# whose perturbation does not apply is a BROKEN SELF-TEST, not a pass:
# the red below would otherwise be a green about an unperturbed file.
failures = 0
for label, path, needle, replacement in PRESENT:
    applied = real[path].count(needle)
    print(f"check-table-card: self-test — {label} applied {applied} substitution(s)")
    if applied != 1:
        _die(
            f"check-table-card: SELF-TEST BROKEN — {label} matched {applied} "
            f"sites in {path}, wanted 1."
        )
    shadow = load({path: real[path].replace(needle, replacement, 1)})
    got = census(shadow)
    want = (
        f"check-table-card: {path}: {label} appears 0 time(s), "
        f"wanted exactly 1 (`{needle}`)"
    )
    if want not in got:
        print(f"check-table-card: SELF-TEST FAILED — {label} was not refused.",
              file=sys.stderr)
        print("wanted: " + want, file=sys.stderr)
        print("got: " + ("\n".join(got) or "(nothing — the census accepted it)"),
              file=sys.stderr)
        failures += 1

# The named interiors, perturbed the way they would really go: somebody
# "simplifies" the constant away to a literal at the use site.
for label, path, needle in NAMED:
    applied = real[path].count(needle)
    print(f"check-table-card: self-test — {label} applied {applied} substitution(s)")
    if applied != 1:
        _die(
            f"check-table-card: SELF-TEST BROKEN — {label} matched {applied} "
            f"sites in {path}, wanted 1."
        )
    inlined = needle.rsplit("=", 1)[0] + "= 0"
    shadow = load({path: real[path].replace(needle, inlined, 1)})
    if not [line for line in census(shadow) if label in line and "named constant" in line]:
        print(f"check-table-card: SELF-TEST FAILED — {label} was not refused.",
              file=sys.stderr)
        failures += 1

# The flatness half, perturbed the way it would really break: somebody
# reaches for the platform's elevated card instead of the flat one.
ELEVATE = (
    ("gtk card rule", GTK,
     "outline: 1px solid @borders;",
     "box-shadow: 0 2px 6px rgba(0,0,0,0.3); outline: 1px solid @borders;",
     "box-shadow"),
    ("winui card markup", WINUI,
     'BorderThickness=\\"1\\" ',
     'BorderThickness=\\"1\\" Shadow=\\"{ThemeResource CardShadow}\\" ',
     "Shadow"),
    ("compose segment fill", COMPOSE,
     "Box(Modifier.background(MaterialTheme.colorScheme.surfaceContainer, shape))",
     "Box(Modifier.shadow(4.dp, shape)"
     ".background(MaterialTheme.colorScheme.surfaceContainer, shape))",
     ".shadow("),
    # THE BORDER COMING BACK is the regression this ruling exists to stop:
    # the 1dp outlineVariant stroke of Compose's OutlinedCard, which is
    # spec-legal and which no shipped Google phone surface draws around a
    # list (material-research.md's fourth-ranked candidate, replaced).
    ("compose segment fill", COMPOSE,
     "Box(Modifier.background(MaterialTheme.colorScheme.surfaceContainer, shape))",
     "Box(Modifier.background(MaterialTheme.colorScheme.surfaceContainer, shape)"
     ".border(1.dp, MaterialTheme.colorScheme.outlineVariant, shape))",
     ".border("),
    # iOS's is the same reach for a familiar card: the desktop family's
    # 1px stroke, on the one platform whose idiom refuses it.
    ("ios card modifiers", SWIFTUI,
     ".padding(.vertical, kayaTableCardInsetY)",
     ".padding(.vertical, kayaTableCardInsetY)\n"
     "                .overlay(\n"
     "                    RoundedRectangle(cornerRadius: kayaTableCardRadius)\n"
     "                        .stroke(Color.gray, lineWidth: 1)\n"
     "                )",
     "stroke"),
)
for label, path, needle, replacement, word in ELEVATE:
    applied = real[path].count(needle)
    print(f"check-table-card: self-test — {label} flatness applied {applied} "
          f"substitution(s)")
    if applied != 1:
        _die(
            f"check-table-card: SELF-TEST BROKEN — the {label} flatness "
            f"perturbation matched {applied} sites in {path}, wanted 1."
        )
    shadow = load({path: real[path].replace(needle, replacement, 1)})
    got = [line for line in census(shadow) if f"names `{word}`" in line]
    if not got:
        print(f"check-table-card: SELF-TEST FAILED — an elevated {label} was "
              "not refused.", file=sys.stderr)
        print("got: " + ("\n".join(census(shadow)) or "(nothing)"), file=sys.stderr)
        failures += 1

# And the two leaks onto the mac, each watched being refused BY NAME —
# a count of findings would be satisfied by any other clause going red.
for label, path, needle, replacement, sentence in ZONE:
    applied = real[path].count(needle)
    print(f"check-table-card: self-test — {label} applied {applied} substitution(s)")
    if applied != 1:
        _die(
            f"check-table-card: SELF-TEST BROKEN — {label} matched {applied} "
            f"sites in {path}, wanted 1."
        )
    shadow = load({path: real[path].replace(needle, replacement, 1)})
    got = [line for line in census(shadow) if sentence in line]
    if not got:
        print(f"check-table-card: SELF-TEST FAILED — {label} was not refused.",
              file=sys.stderr)
        print("wanted a sentence containing: " + sentence, file=sys.stderr)
        print("got: " + ("\n".join(census(shadow)) or "(nothing)"), file=sys.stderr)
        failures += 1

if failures:
    _die()
print(f"check-table-card: {len(PRESENT) + len(NAMED) + len(ELEVATE) + len(ZONE)} "
      "watched negatives, every one red as demanded")

print("check-table-card: OK")
