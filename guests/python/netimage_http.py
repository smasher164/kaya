"""The network images scene over HTTP (tools/scenes/netimage_http.steps;
docs/network-images-plan.md §5, N12): kaya.RowImages fetching from the
lane's media server with its default fetch, urllib.request. Twelve rows
share three covers, the album case; four rows fail or wait in the ways a
real catalogue does. See guests/rust/netimage_http.rs."""

import os
import sys
from dataclasses import dataclass

import kaya


@dataclass
class Track:
    title: str
    art_url: str
    art: bytes
    phase: kaya.ImagePhase


COVERS = ("covers/cover-600.jpg", "covers/cover-320.jpg", "covers/cover-1000.jpg")

base = os.environ.get("KAYA_MEDIA_URL")
if not base:
    raise SystemExit(
        "kaya: the netimage_http scene reads KAYA_MEDIA_URL, the local server "
        "the lane starts (tools/lib/media_server.py)")

app = kaya.App()
failures = 0


def on_error(row, reason):
    global failures
    failures += 1
    errors.set(f"errors: {failures}")


with app.window(title="netimage_http", width=640, height=560):
    errors = kaya.signal("errors: 0")
    tracks = kaya.collection(Track)
    images = kaya.RowImages(app, tracks, url="art_url", art="art",
                            phase="phase", on_error=on_error)
    with kaya.row():
        kaya.label(bind=errors).a11y_id("errors")
        for track in tracks.columns("Art", "Title", grow=1):
            with kaya.row():
                kaya.image(track.art, fit=kaya.Fit.COVER, phase=track.phase,
                           on_needed=images.needed,
                           on_released=images.released) \
                    .max_width(20).max_height(20).a11y_id("art")
                kaya.label(bind=track.title)
    for key, path in (("missing", "status/404/"), ("broken", "status/500/"),
                      ("junk", "covers/README.md"),
                      ("slow", "trickle/covers/cover-600.jpg")):
        tracks.insert(key, Track(title=key, art_url=f"{base}/{path}", art=b"",
                                 phase=kaya.ImagePhase.LOADING))
    for i in range(12):
        tracks.insert(f"a{i:02}", Track(title=f"Track {i}",
                                        art_url=f"{base}/{COVERS[i % 3]}",
                                        art=b"", phase=kaya.ImagePhase.LOADING))

sys.exit(app.run())
