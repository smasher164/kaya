"""The tracks scene (tools/scenes/tracks.steps; docs/styling-pass-plan.md Y5,
Y6, Y7): a playlist's table whose title cell is rounded art beside the
track's name over its artist, the playing track's name in the accent, and a
row the app selects on activation (Y4). See guests/rust/tracks.rs."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Track:
    number: str
    title: str
    artist: str
    album: str
    art: bytes
    tint: kaya.Tint
    selected: bool


PLAYLIST = 60
PLAYING = 3
NAMES = [("Blue in Green", "Miles Davis", "Kind of Blue"),
         ("So What", "Miles Davis", "Kind of Blue"),
         ("Naima", "John Coltrane", "Giant Steps")]

app = kaya.App()
art = kaya.asset("covers/cover-600.jpg").bytes()


def table(tracks, table_id, row_id, grow=None):
    for track in tracks.columns("#", "Title", "Album", a11y_id=table_id, grow=grow):
        with kaya.row(selected=track.selected, on_activate=on_pick) as line:
            line.a11y_id(row_id)
            kaya.label(bind=track.number)
            with kaya.row():
                kaya.image(track.art, fit=kaya.Fit.COVER, shape=kaya.Shape.ROUNDED) \
                    .max_width(40).max_height(40).a11y_id("art")
                with kaya.column():
                    kaya.label(bind=track.title, tint=track.tint).a11y_id("name")
                    kaya.caption(bind=track.artist)
            kaya.label(bind=track.album)


def on_pick(row):
    for i in range(len(NAMES)):
        album.patch(f"a{i + 1}", selected=f"a{i + 1}" == row.key)
    for i in range(PLAYLIST):
        playlist.patch(f"t{i + 1}", selected=f"t{i + 1}" == row.key)


def track(i):
    title, artist, album = NAMES[i % len(NAMES)]
    return Track(number=str(i + 1), title=title, artist=artist, album=album, art=art,
                 tint=kaya.Tint.ACCENT if i + 1 == PLAYING else kaya.Tint.NONE, selected=False)


with app.window(title="tracks", width=720, height=640):
    album = kaya.collection(Track)
    playlist = kaya.collection(Track)
    with kaya.column(spacing=12):
        table(album, "album", "a")
        table(playlist, "tracks", "t", grow=1)
    for i in range(len(NAMES)):
        album.insert(f"a{i + 1}", track(i))
    for i in range(PLAYLIST):
        playlist.insert(f"t{i + 1}", track(i))

sys.exit(app.run())
