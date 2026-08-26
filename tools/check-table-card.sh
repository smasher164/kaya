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
# A TABLE BOUNDS ITS OWN EXTENT — one semantics, three spellings
# (docs/deferred.md's table-card entry, ruled 2026-08-25). macOS has it
# from the native widget; GTK, WinUI and Compose each draw a card.
#
# NO SCENE CAN FAIL THIS. The card is pixels and nothing else: every
# table observable — expect_columns, expect_rows, expect_column_edges,
# expect_window — answers exactly the same with the card gone, which is
# how the three backends shipped for months drawing a table's OPENING
# grammar and never its close (the CASH row running into "Account
# total"). So, like the native-undo pair, a gate is the only wall
# available, and it holds three things a capture would otherwise be the
# only witness to: the card is THERE, it is FLAT (the ruling: no shadow,
# no blur, no elevation), and its colours come from the platform's own
# tokens rather than from literals.
#
# WHAT IT DELIBERATELY DOES NOT HOLD: the mac tier, which delineates
# natively and is not to be touched; and whether the card LOOKS right,
# which is the capture sign-off the ledger entry still holds open.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

python3 - <<'PY'
from pathlib import Path
import sys

GTK = "crates/kaya/src/gtk.rs"
WINUI = "crates/kaya/src/winui/mod.rs"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"

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
    ("compose card fill", COMPOSE,
     ".background(MaterialTheme.colorScheme.surfaceContainer, KAYA_TABLE_CARD_SHAPE)",
     ".background(MaterialTheme.colorScheme.surface, KAYA_TABLE_CARD_SHAPE)"),
    ("compose card stroke", COMPOSE,
     ".border(1.dp, MaterialTheme.colorScheme.outlineVariant, KAYA_TABLE_CARD_SHAPE)",
     ".padding(1.dp)"),
    ("compose card radius", COMPOSE,
     "private val KAYA_TABLE_CARD_SHAPE = RoundedCornerShape(12.dp)",
     "private val KAYA_TABLE_CARD_SHAPE = RoundedCornerShape(0.dp)"),
    # ABOVE the viewport read, which is the whole of why it is safe: the
    # padded box is the one this Layout reports as its viewport.
    ("compose card interior", COMPOSE,
     ".padding(horizontal = KAYA_TABLE_CARD_PAD_X, vertical = KAYA_TABLE_CARD_PAD_Y)",
     ".padding(0.dp)"),
)

# THE INTERIOR IS A NAMED NUMBER, not a literal at the use site. No
# platform hands out a TOKEN for a card's content padding the way it does
# for the fill and the stroke — Adwaita's lives in its row's own
# stylesheet, Fluent's in a control's default style, Material's in its
# spec — so the substitute is a constant whose comment carries the
# provenance, and this holds the use sites to naming it.
NAMED = (
    ("winui card interior", WINUI, "const TABLE_CARD_PAD: f64 = 12.0;"),
    ("compose card interior x", COMPOSE, "private val KAYA_TABLE_CARD_PAD_X = 16.dp"),
    ("compose card interior y", COMPOSE, "private val KAYA_TABLE_CARD_PAD_Y = 8.dp"),
)

# --- AND IT IS FLAT ----------------------------------------------------
#
# Read out of the card's OWN BLOCK, never the file: all three of these
# files legitimately name shadows and elevations elsewhere (a menu
# popover has one, a dialog has one), so a file-wide grep would be a
# sentence about the wrong widget. The ruling is flat HERE.
#
# (label, file, first line of the block, last line, forbidden spellings)
BLOCKS = (
    ("gtk card rule", GTK,
     "const TABLE_CSS: &str = ", '";',
     ("box-shadow", "text-shadow", "filter:", "blur")),
    ("winui card markup", WINUI,
     "const TABLE_CARD_XAML: &str = ", ");",
     ("Shadow", "Elevation", "Translation", "#")),
    ("compose card modifiers", COMPOSE,
     "        modifier = modifier\n            // THE CARD", "\n            .verticalScroll(",
     (".shadow(", "elevation", "tonalElevation", "shadowElevation")),
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
    for label, path, start, end, forbidden in BLOCKS:
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
                    f"check-table-card: {path}: the {label} names `{word}` — the "
                    "ruling of 2026-08-25 is a FLAT card: fill, a 1px stroke and "
                    "the radius, zero blur, zero elevation, and colours from the "
                    "platform's tokens rather than literals"
                )
    return out


def load(over=None):
    files = {p: Path(p).read_text(encoding="utf-8") for p in (GTK, WINUI, COMPOSE)}
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
    raise SystemExit(1)
print(
    f"check-table-card: the card is present, padded and flat in all three "
    f"backends — {len(PRESENT)} clauses + {len(NAMED)} named interiors + "
    f"{len(BLOCKS)} flatness blocks"
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
        raise SystemExit(
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
        raise SystemExit(
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
    ("compose card modifiers", COMPOSE,
     ".background(MaterialTheme.colorScheme.surfaceContainer, KAYA_TABLE_CARD_SHAPE)",
     ".shadow(4.dp, KAYA_TABLE_CARD_SHAPE)\n"
     "            .background(MaterialTheme.colorScheme.surfaceContainer, "
     "KAYA_TABLE_CARD_SHAPE)",
     ".shadow("),
)
for label, path, needle, replacement, word in ELEVATE:
    applied = real[path].count(needle)
    print(f"check-table-card: self-test — {label} flatness applied {applied} "
          f"substitution(s)")
    if applied != 1:
        raise SystemExit(
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

if failures:
    raise SystemExit(1)
print(f"check-table-card: {len(PRESENT) + len(NAMED) + len(ELEVATE)} watched "
      "negatives, every one red as demanded")
PY
rc=$?
if [ "$rc" != 0 ]; then
    echo "check-table-card: FAIL" >&2
    exit 1
fi
echo "check-table-card: OK"
