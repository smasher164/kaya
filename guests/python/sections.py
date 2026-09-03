"""The sections conformance scene (tools/scenes/sections.steps): two peer
roots in the primary window's section set."""

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
    # An aux window, reached only by the desktop tail's click, so the phones
    # never see a create_window their host rejects.
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


# With sections the window has no root: NOTHING MOUNTS here.
with app.window(title="sections", sections_presentation=kaya.SECTIONS_BAR):
    visits = kaya.signal("archive: 0 visits")

# SF Symbols are licensed to Apple platforms: no shared asset exists.
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
