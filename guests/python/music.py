"""The media player demo (docs/media-player-plan.md), screen 1: the library
sidebar and Home (tools/scenes/music_home.steps)."""

import html
import json
import os
import sys
import threading
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass

import kaya

HOME = 7
CONNECT = 20
SECTION_HOME = 30
SECTION_LIBRARY = 31

SHELVES = [("jazz", "Jazz"), ("electronic", "Electronic"), ("rock", "Rock")]
SHELF_CARDS = 12
CARD_ART = 120
ROW_ART = 40
CLIENT_ID_PREF = "jamendo.client_id"
JAMENDO_API = "https://api.jamendo.com/v3.0/"
SAMPLER = "sampler:"


@dataclass
class Saved:
    title: str
    caption: str
    art_url: str
    art: bytes
    phase: kaya.ImagePhase
    selected: bool


def http_fetch(url):
    # Jamendo's image host answers urllib's own User-Agent 403
    # (docs/traps.md, the catalogue that refuses Python-urllib).
    request = urllib.request.Request(url, headers={"User-Agent": "kaya-music/1"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


class Sampler:
    """The bundled snapshot (M1's no-id mode): the mirror's addresses
    (tools/lib/catalogue.py) answered from the asset root."""

    def __init__(self):
        with kaya.asset("catalogue/api.json") as asset:
            self.answers = json.loads(asset.bytes().decode("utf-8"))

    def fetch(self, url):
        parts = urllib.parse.urlsplit(url[len(SAMPLER):])
        query = dict(urllib.parse.parse_qsl(parts.query))
        if parts.path.startswith("/catalogue/v3.0/"):
            pairs = sorted((k, v) for k, v in urllib.parse.parse_qsl(parts.query)
                           if k not in ("client_id", "format"))
            key = parts.path[len("/catalogue/v3.0/"):].strip("/")
            if pairs:
                key += "?" + urllib.parse.urlencode(pairs, quote_via=urllib.parse.quote)
            if key not in self.answers:
                raise OSError(f"the sampler holds no answer for {key}")
            return json.dumps(self.answers[key]).encode("utf-8")
        if parts.path == "/catalogue/usercontent":
            album = query["id"]
            if query["type"] == "artist":
                album = self.answers["_snapshot"]["artist_images"][album]
            with kaya.asset(f"catalogue/album-{album}-{query['width']}.jpg") as asset:
                return asset.bytes()
        raise OSError(f"the sampler holds nothing at {parts.path}")


class Catalogue:
    """Jamendo's API v3 at one base: Jamendo itself, the lane's mirror of
    it, or the sampler (M1, M2)."""

    def __init__(self):
        mirror = os.environ.get("KAYA_MEDIA_URL")
        client_id = (os.environ.get("KAYA_JAMENDO_CLIENT_ID")
                     or kaya.prefs().get(CLIENT_ID_PREF, "")).strip()
        self.params = {"format": "json"}
        if mirror:
            self.base = mirror.rstrip("/") + "/"
            self.api = self.base + "catalogue/v3.0/"
            self.fetch = http_fetch
            self.sampler = False
        elif client_id:
            self.base = JAMENDO_API
            self.api = JAMENDO_API
            self.params["client_id"] = client_id
            self.fetch = http_fetch
            self.sampler = False
        else:
            self.base = SAMPLER + "/"
            self.api = SAMPLER + "/catalogue/v3.0/"
            self.fetch = Sampler().fetch
            self.sampler = True

    def address(self, url):
        if url.startswith(SAMPLER) or "://" in url:
            return url
        if self.sampler:
            return SAMPLER + url
        return urllib.parse.urljoin(self.base, url)

    def get(self, endpoint, **query):
        pairs = {**query, **self.params}
        url = f"{self.api}{endpoint}/?" + urllib.parse.urlencode(pairs)
        answer = json.loads(self.fetch(url).decode("utf-8"))
        headers = answer.get("headers", {})
        if headers.get("status") != "success":
            raise OSError(f"{endpoint}: {headers.get('error_message') or 'failed'}")
        return answer["results"]

    def chart(self, genre):
        """The week's most played CC BY and BY-SA tracks in a genre, as
        their albums in chart order."""
        tracks = []
        for _ in range(3):
            # Jamendo answers a populated chart empty now and then
            # (docs/media-player-plan.md §7), so an empty answer is asked again.
            tracks = self.get("tracks", tags=genre, order="popularity_week",
                              include="musicinfo", ccnc="false", ccnd="false", limit=50)
            if tracks:
                break
        albums = []
        for track in tracks:
            if all(a["id"] != track["album_id"] for a in albums):
                albums.append({"id": track["album_id"],
                               "name": html.unescape(track["album_name"]),
                               "artist": html.unescape(track["artist_name"]),
                               "image": self.address(track["album_image"])})
        return albums


app = kaya.App()
catalogue = Catalogue()
desktop = kaya.capabilities().aux_windows
art_pool = ThreadPoolExecutor(max_workers=6)
cards = {}
viewing = {"album": None}
library_keys = []


def library_caption():
    return f"{len(library_keys)} albums" if library_keys else "Albums you open appear here."


def show_selection(album_id):
    viewing["album"] = album_id
    for key, card in cards.items():
        card["selected"].set(key == album_id)
    for key in library_keys:
        library.patch(key, selected=key == album_id)


def open_album(album):
    key = album["id"]
    if key not in library_keys:
        library.insert(key, Saved(title=album["name"], caption=f"Album · {album['artist']}",
                                  art_url=album["image"], art=b"",
                                  phase=kaya.ImagePhase.LOADING, selected=False))
        library_keys.append(key)
    library_keys.remove(key)
    library_keys.insert(0, key)
    for other in library_keys[1:]:
        library.move_to_end(other)
    library_hint.set(library_caption())
    show_selection(key)


def on_saved(row):
    show_selection(row.key)


def card_art_landed(album_id, data):
    card = cards[album_id]
    if data is None:
        card["phase"].set(kaya.ImagePhase.FAILED)
    else:
        card["art"].set(data)
        card["phase"].set(kaya.ImagePhase.SHOWN)


def fetch_card_art(album_id, url):
    try:
        data = catalogue.fetch(url)
    except OSError:
        data = None
    app.post(card_art_landed, album_id, data)


def card(album):
    art = kaya.signal(b"")
    phase = kaya.signal(kaya.ImagePhase.LOADING)
    selected = kaya.signal(False)
    with kaya.column(filled=kaya.Tint.NEUTRAL, selected=selected,
                     on_activate=lambda: open_album(album)) as tile:
        tile.a11y_id(f"card_{album['id']}").fill(True)
        kaya.image(art, fit=kaya.Fit.COVER, shape=kaya.Shape.ROUNDED, phase=phase) \
            .max_width(CARD_ART).max_height(CARD_ART).a11y_id(f"art_{album['id']}")
        kaya.label(album["name"])
        kaya.caption(album["artist"])
    cards[album["id"]] = {"art": art, "phase": phase, "selected": selected,
                          "url": album["image"]}


def connect_typed(text):
    connect_draft["text"] = text


def connect_save():
    if connect_draft["text"].strip():
        kaya.prefs().set(CLIENT_ID_PREF, connect_draft["text"].strip())
        notice.set("Saved. Reopen Music to browse Jamendo.")
    kaya.dismiss_sheet(CONNECT)


def open_connect():
    connect_draft["text"] = ""
    with app.sheet(CONNECT, title="Connect a catalogue", detent="medium"):
        with kaya.column():
            kaya.label("Jamendo client ID")
            kaya.secure_field(on_change=connect_typed, on_submit=lambda _: connect_save()) \
                .a11y_id("client_id")
            kaya.caption("A free client ID from devportal.jamendo.com. Music keeps it on "
                         "this device and sends it only to Jamendo.")
            with kaya.row():
                kaya.button("Cancel", on_click=lambda: kaya.dismiss_sheet(CONNECT))
                kaya.button("Save", on_click=connect_save)


connect_draft = {"text": ""}


def home_body(shelves):
    with kaya.scroll(grow=1):
        with kaya.column(spacing=20, align="stretch") as home:
            home.a11y_id("home")
            if catalogue.sampler:
                with kaya.row(align="center"):
                    kaya.caption(bind=notice)
                    kaya.button("Connect a catalogue", on_click=open_connect)
            for (genre, title), albums in zip(SHELVES, shelves):
                with kaya.column(spacing=8, align="stretch"):
                    kaya.heading(title)
                    if albums is None:
                        kaya.caption("Couldn't reach the catalogue.")
                        continue
                    if not albums:
                        kaya.caption("Nothing in this chart this week.")
                        continue
                    with kaya.grid(1, spacing=12) as shelf:
                        for album in albums:
                            card(album)
                    shelf.columns_auto(CARD_ART + 24).a11y_id(f"shelf_{genre}")


def library_body():
    with kaya.column(spacing=4) as side:
        side.a11y_id("library")
        kaya.heading("Your Library")
        kaya.caption(bind=library_hint)
        for item in library:
            with kaya.row(selected=item.selected, on_activate=on_saved) as entry:
                entry.a11y_id("saved")
                kaya.image(item.art, fit=kaya.Fit.COVER, shape=kaya.Shape.ROUNDED,
                           phase=item.phase, on_needed=library_art.needed,
                           on_released=library_art.released) \
                    .max_width(ROW_ART).max_height(ROW_ART).a11y_id("saved_art")
                with kaya.column(spacing=0):
                    kaya.label(bind=item.title)
                    kaya.caption(bind=item.caption)


def home_arrived(shelves):
    if desktop:
        with app.push_entry(HOME, title="Home"):
            home_body(shelves)
    else:
        with app.add_section(SECTION_HOME, title="Home", symbol=kaya.Symbol.HOME):
            home_body(shelves)
        with app.add_section(SECTION_LIBRARY, title="Library", symbol=kaya.Symbol.QUEUE):
            library_body()
    for album_id, entry in cards.items():
        art_pool.submit(fetch_card_art, album_id, entry["url"])


def load_home():
    seen = set()
    shelves = []
    for genre, _ in SHELVES:
        try:
            albums = [a for a in catalogue.chart(genre) if a["id"] not in seen]
        except (OSError, ValueError, KeyError) as e:
            print(f"music: the {genre} chart did not load: {e!r}", file=sys.stderr)
            shelves.append(None)
            continue
        albums = albums[:SHELF_CARDS]
        seen.update(a["id"] for a in albums)
        shelves.append(albums)
    app.post(home_arrived, shelves)


with app.window(title="Music", width=1100, height=720,
                panes=2 if desktop else None,
                sections_presentation=None if desktop else kaya.SectionsPresentation.BAR):
    notice = kaya.signal("Browsing the bundled sampler.")
    library_hint = kaya.signal(library_caption())
    library = kaya.collection(Saved)
    library_art = kaya.RowImages(app, library, url="art_url", art="art", phase="phase",
                                 fetch=catalogue.fetch)
    if desktop:
        library_body()

threading.Thread(target=load_home, daemon=True).start()

sys.exit(app.run())
