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

visit_count = 0


def archive_shown():
    global visit_count
    visit_count += 1
    with app.build():
        visits.set(f"archive: {visit_count} visits")


def go_archive():
    # Programmatic selection: configuration, no echo — on_selected
    # must NOT fire (the scene asserts the count holds).
    kaya.select_section(ARCHIVE)


# No window() scope: with sections the window has no root of its own
# — the switcher IS the window content. app.build() carries the
# title, the ADVISORY hint (`bar`: each desktop's horizontal
# spelling; the phones' physics regardless), and the shared signal.
with app.build():
    kaya.window_title("sections")
    kaya.sections_presentation(kaya.SECTIONS_BAR)
    visits = kaya.signal("archive: 0 visits")

with app.add_section(FEED, title="Feed"):
    ready = kaya.signal("feed ready")
    with kaya.column():
        kaya.label(bind=ready)  # label#0
        kaya.button("to archive", on_click=go_archive)  # button#0

with app.add_section(ARCHIVE, title="Archive", on_selected=archive_shown):
    with kaya.column():
        kaya.label(bind=visits)  # label#1


sys.exit(app.run())
