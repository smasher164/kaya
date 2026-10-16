"""The cards scene (tools/scenes/cards.steps; docs/styling-pass-plan.md Y4): a
grid of cards that each take a click as a whole and show the platform's
hover, and a library list whose rows the app selects on activation. See
guests/rust/cards.rs."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Playlist:
    name: str
    selected: bool


CARDS = [("card1", "Daily Mix 1"), ("card2", "Daily Mix 2"), ("card3", "Discover Weekly")]
LIBRARY = [("p1", "Liked Songs"), ("p2", "Late Night Jazz"), ("p3", "Focus")]

app = kaya.App()


def opener(name):
    return lambda: status.set(f"opened: {name}")


def on_open(row):
    for key, _ in LIBRARY:
        library.patch(key, selected=key == row.key)


with app.window(title="cards", width=520, height=520):
    status = kaya.signal("opened: none")
    library = kaya.collection(Playlist)
    with kaya.column(spacing=16):
        with kaya.grid(3, spacing=12):
            for key, name in CARDS:
                with kaya.column(filled=kaya.Tint.NEUTRAL, on_activate=opener(name)) as card:
                    card.a11y_id(key)
                    kaya.label(name)
                    kaya.caption("Made for you")
        kaya.label(bind=status).a11y_id("status")
        for playlist in library:
            with kaya.row(selected=playlist.selected, on_activate=on_open) as item:
                item.a11y_id("lib")
                kaya.label(bind=playlist.name)
    for key, name in LIBRARY:
        library.insert(key, Playlist(name=name, selected=False))

sys.exit(app.run())
