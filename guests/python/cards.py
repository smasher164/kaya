"""The cards scene (tools/scenes/cards.steps; docs/styling-pass-plan.md Y4): a
grid of cards that each take a click as a whole and show the platform's
hover, a library list whose rows the app selects on activation and whose play
buttons take their symbol from the row, and a card the app adds to the built
grid. See guests/rust/cards.rs."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Playlist:
    name: str
    selected: bool
    symbol: kaya.Symbol


CARDS = [("card1", "Daily Mix 1"), ("card2", "Daily Mix 2"), ("card3", "Discover Weekly")]
# The third card is taller, so the row's cards take its height (M16 (1)).
TALL = "card3"
# Cut at two lines with the platform's ellipsis (M16 (2)).
BLURB = "Fresh picks every Monday, from the artists you play the most and the ones they listen to"
LIBRARY = [("p1", "Liked Songs"), ("p2", "Late Night Jazz"), ("p3", "Focus")]

app = kaya.App()


def opener(name):
    return lambda: status.set(f"opened: {name}")


def on_open(row):
    for key, _ in LIBRARY:
        library.patch(key, selected=key == row.key)


def on_play(row):
    for key, _ in LIBRARY:
        library.patch(key, symbol=kaya.Symbol.PAUSE if key == row.key else kaya.Symbol.PLAY)


def card(key, name):
    with kaya.column(filled=kaya.Tint.NEUTRAL, on_activate=opener(name)) as handle:
        handle.a11y_id(key)
        kaya.label(name)
        kaya.caption("Made for you")
        if key == TALL:
            kaya.caption(BLURB, max_lines=2).a11y_id("blurb")


def more():
    with kaya.within(cards):
        card("card4", "Release Radar")


with app.window(title="cards", width=520, height=520):
    status = kaya.signal("opened: none")
    library = kaya.collection(Playlist)
    # A section hidden by a When and an empty For take no space (M16 (3)).
    hidden = kaya.signal(False)
    empty = kaya.collection(Playlist)
    with kaya.column(spacing=16):
        with kaya.grid(1, spacing=12) as cards:
            for key, name in CARDS:
                card(key, name)
        cards.columns_auto(140).a11y_id("cards")
        kaya.button("More", on_click=more).a11y_id("more")
        kaya.label(bind=status).a11y_id("status")
        with kaya.when(hidden):
            kaya.label("never shown")
        for playlist in empty:
            with kaya.row():
                kaya.label(bind=playlist.name)
        kaya.label("end").a11y_id("end")
        for playlist in library:
            with kaya.row():
                with kaya.row(selected=playlist.selected, on_activate=on_open) as item:
                    item.a11y_id("lib")
                    kaya.label(bind=playlist.name)
                kaya.button("Play", symbol=playlist.symbol, on_click=on_play).a11y_id("go")
    for key, name in LIBRARY:
        library.insert(key, Playlist(name=name, selected=False, symbol=kaya.Symbol.PLAY))

sys.exit(app.run())
