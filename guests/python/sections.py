"""The sections conformance scene, Python port: two peer roots in the
primary window's section set — presentation context, not lifecycle.
The archive pane folds on_selected into a visit count, pinning the
echo doctrine from both sides: the user's switch emits (the harness
drives the real switcher), while the feed button's programmatic
kaya.select_section moves the selection silently. The count surviving
switch round trips proves retention. See guests/rust/sections.rs and
tools/scenes/sections.steps."""

import sys

import kaya

app = kaya.App()

FEED = 7
ARCHIVE = 8
LIBRARY = 1
SHELVES = 2
LOANS = 3

visit_count = 0


def archive_shown():
    global visit_count
    visit_count += 1
    visits.set(f"archive: {visit_count} visits")


def go_archive():
    kaya.select_section(ARCHIVE)


def open_library():
    # THE SIDEBAR HALF of the presentation enum, in an aux window, so one
    # shared scene covers BOTH arms. Reachability is the gate: only the
    # desktop tail's click lands here, so the phones never see a
    # create_window their host would reject.
    kaya.create_window(LIBRARY)
    app.window(
        window_id=LIBRARY, title="library",
        sections_presentation=kaya.SECTIONS_SIDEBAR)
    with app.add_section(SHELVES, title="Shelves", symbol=kaya.Symbol.SEARCH,
                         window=LIBRARY):
        shelves_ready = kaya.signal("shelves ready")
        with kaya.column():
            kaya.label(bind=shelves_ready)  # label#2
    with app.add_section(LOANS, title="Loans", symbol=kaya.Symbol.LOCK,
                         window=LIBRARY):
        loans_ready = kaya.signal("loans ready")
        with kaya.column():
            kaya.label(bind=loans_ready)  # label#3


# With sections the window has no root of its own — the switcher IS the
# window content — so this body carries only props and the shared signal,
# and NOTHING MOUNTS. The presentation hint is ADVISORY.
with app.window(title="sections", sections_presentation=kaya.SECTIONS_BAR):
    visits = kaya.signal("archive: 0 visits")

# The symbol is SEMANTIC, never an asset (docs/styling-plan.md D6): the
# glyph meaning `home` differs per platform, and SF Symbols are licensed
# to Apple platforms only.
with app.add_section(FEED, title="Feed", symbol=kaya.Symbol.HOME):
    ready = kaya.signal("feed ready")
    with kaya.column():
        kaya.label(bind=ready)  # label#0
        kaya.button("to archive", on_click=go_archive)  # button#0
        kaya.button("open library", on_click=open_library)  # button#1

with app.add_section(ARCHIVE, title="Archive", symbol=kaya.Symbol.STAR,
                     on_selected=archive_shown):
    with kaya.column():
        kaya.label(bind=visits)  # label#1


sys.exit(app.run())
