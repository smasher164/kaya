"""The media player demo (docs/media-player-plan.md): the library sidebar
and Home (tools/scenes/music_home.steps), an album's track table that plays
through kaya's player (tools/scenes/music_playlist.steps), and the album's
gradient header (tools/scenes/music_header.steps)."""

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
FIRST_ALBUM_ENTRY = 100

SHELVES = [("jazz", "Jazz"), ("electronic", "Electronic"), ("rock", "Rock")]
SHELF_CARDS = 12
CARD_ART = 120
ROW_ART = 40
HEADER_ART = 200 if kaya.capabilities().aux_windows else 180
# The header's colour until the cover has decoded (docs/styling-pass-plan.md Y2).
UNKNOWN_COLOUR = kaya.Color(0x8E, 0x8E, 0x93)
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


@dataclass
class Track:
    number: str
    title: str
    artist: str
    album: str
    duration: str
    art_url: str
    art: bytes
    phase: kaya.ImagePhase
    tint: kaya.Tint
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

    def source(self, audio):
        if self.sampler:
            query = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(audio).query))
            return kaya.MediaSource.asset(f"catalogue/t{query['trackid']}.mp3")
        return kaya.MediaSource.url(self.address(audio))

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

    def album(self, album_id):
        return self.get("albums/tracks", id=album_id, imagesize=600)[0]


app = kaya.App()
catalogue = Catalogue()
desktop = kaya.capabilities().aux_windows
art_pool = ThreadPoolExecutor(max_workers=6)
cards = {}
viewing = {"album": None}
library_keys = []
known = {}
pages = {}
songs = {}
playback = {"key": None, "queue": [], "start": False}
favorites = set()
entries = iter(range(FIRST_ALBUM_ENTRY, 1 << 32))


def library_caption():
    if not library_keys:
        return "Albums you open appear here."
    return "1 album" if len(library_keys) == 1 else f"{len(library_keys)} albums"


def show_selection(album_id):
    viewing["album"] = album_id
    for key, card in cards.items():
        card["selected"].set(key == album_id)
    show_library_selection(album_id)


def show_library_selection(album_id):
    for key in library_keys:
        library.patch(key, selected=key == album_id)


def open_album(album):
    key = album["id"]
    show_album(album, 0 if desktop else SECTION_HOME)
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
    show_album(known[row.key], 0 if desktop else SECTION_LIBRARY)


def go_home():
    if 0 in pages:
        kaya.pop_entry()
        del pages[0]
    # The album last opened stays the selected card under Home.
    show_library_selection(None)
    home_shown.set(True)


def show_album(album, surface):
    if desktop:
        home_shown.set(False)
    page = pages.get(surface)
    if page is not None and page["album"] == album["id"]:
        return
    if page is not None:
        kaya.pop_entry(surface)
    entry = next(entries)
    page = {"album": album["id"], "entry": entry, "keys": []}
    pages[surface] = page
    with app.push_entry(entry, title=album["name"], window=surface,
                        on_popped=lambda: page_closed(surface, entry)):
        page["about"] = kaya.signal(album["artist"])
        page["cover"] = kaya.signal(b"")
        page["cover_phase"] = kaya.signal(kaya.ImagePhase.LOADING)
        page["colour"] = kaya.signal(UNKNOWN_COLOUR)
        page["liked"] = kaya.signal(album["id"] in favorites)
        page["tracks"] = kaya.collection(Track)
        page["art"] = kaya.RowImages(app, page["tracks"], url="art_url", art="art",
                                     phase="phase", fetch=catalogue.fetch)
        album_body(album, page)
    threading.Thread(target=load_album, args=(album, surface, entry), daemon=True).start()


def album_body(album, page):
    with kaya.column(spacing=12, align="stretch") as body:
        body.a11y_id("album")
        album_header(album, page)
        # A phone's width holds no album column (the album is the page).
        names = ("#", "Title", "Album", "Time") if desktop else ("#", "Title", "Time")
        for track in page["tracks"].columns(*names, a11y_id="tracks", grow=1):
            with kaya.row(selected=track.selected, on_select=on_pick,
                          on_activate=on_play) as line:
                line.a11y_id("track")
                kaya.label(bind=track.number)
                with kaya.row(spacing=8):
                    kaya.image(track.art, fit=kaya.Fit.COVER, shape=kaya.Shape.ROUNDED,
                               phase=track.phase, on_needed=page["art"].needed,
                               on_released=page["art"].released) \
                        .max_width(ROW_ART).max_height(ROW_ART).a11y_id("track_art")
                    with kaya.column(spacing=0):
                        kaya.label(bind=track.title, tint=track.tint).a11y_id("track_name")
                        kaya.caption(bind=track.artist)
                if desktop:
                    kaya.label(bind=track.album)
                kaya.label(bind=track.duration).a11y_id("track_time")


def album_header(album, page):
    with kaya.column(inset=24, ground_gradient=page["colour"]) as header:
        header.a11y_id("album_header")
        with kaya.row(spacing=24, align="end") if desktop else \
                kaya.column(spacing=16, align="center"):
            kaya.image(page["cover"], fit=kaya.Fit.COVER, shape=kaya.Shape.ROUNDED,
                       phase=page["cover_phase"]) \
                .max_width(HEADER_ART).max_height(HEADER_ART).a11y_id("album_art")
            with kaya.column(spacing=6, align="start"):
                kaya.heading(album["name"]).a11y_id("album_title")
                kaya.caption(bind=page["about"]).a11y_id("album_about")
                with kaya.row(spacing=12, align="center"):
                    kaya.button("Play", on_click=lambda: play_album(page),
                                symbol=kaya.Symbol.PLAY) \
                        .role(kaya.Role.PROMINENT).a11y_id("play_album")
                    kaya.checkbox("Favorite", checked=page["liked"],
                                  on_toggle=lambda on: set_favorite(album["id"], on)) \
                        .role(kaya.Role.TOGGLE).symbol(kaya.Symbol.FAVORITE) \
                        .a11y_id("favorite")
                kaya.caption(bind=now_line).a11y_id("now")


def set_favorite(album_id, on):
    if on:
        favorites.add(album_id)
    else:
        favorites.discard(album_id)
    for page in pages.values():
        if page["album"] == album_id:
            page["liked"].set(on)


def page_closed(surface, entry):
    if pages.get(surface, {}).get("entry") == entry:
        del pages[surface]


def load_album(album, surface, entry):
    try:
        answer = catalogue.album(album["id"])
    except (OSError, ValueError, KeyError, IndexError) as e:
        print(f"music: album {album['id']} did not load: {e!r}", file=sys.stderr)
        answer = None
    app.post(album_arrived, album, surface, entry, answer)
    if answer is None:
        return
    try:
        cover = catalogue.fetch(catalogue.address(answer["image"]))
    except OSError as e:
        print(f"music: album {album['id']}'s cover did not load: {e!r}", file=sys.stderr)
        cover = None
    colour = kaya.image_dominant(cover) if cover else None
    app.post(cover_arrived, surface, entry, cover, colour)


def cover_arrived(surface, entry, cover, colour):
    page = pages.get(surface)
    if page is None or page["entry"] != entry:
        return
    if cover is None:
        page["cover_phase"].set(kaya.ImagePhase.FAILED)
        return
    page["cover"].set(cover)
    page["cover_phase"].set(kaya.ImagePhase.SHOWN)
    if colour is not None:
        page["colour"].set(colour)


def songs_line(count, seconds):
    songs_word = "1 song" if count == 1 else f"{count} songs"
    return f"{songs_word}, {kaya.fmt.duration(seconds * 1000)}"


def album_arrived(album, surface, entry, answer):
    page = pages.get(surface)
    if page is None or page["entry"] != entry:
        return
    if answer is None:
        page["about"].set("Couldn't reach the catalogue.")
        return
    artist = html.unescape(answer["artist_name"])
    year = answer.get("releasedate", "")[:4]
    listed = sorted(answer["tracks"], key=lambda t: int(t["position"]))
    total = songs_line(len(listed), sum(int(t["duration"]) for t in listed))
    page["about"].set(" · ".join(p for p in (artist, year, total) if p))
    for t in listed:
        key = t["id"]
        songs[key] = {"title": html.unescape(t["name"]), "audio": t["audio"]}
        page["keys"].append(key)
        page["tracks"].insert(key, Track(
            number=str(t["position"]), title=songs[key]["title"], artist=artist,
            album=album["name"], duration=kaya.fmt.duration(int(t["duration"]) * 1000),
            art_url=album["image"], art=b"", phase=kaya.ImagePhase.LOADING,
            tint=kaya.Tint.ACCENT if key == playback["key"] else kaya.Tint.NONE,
            selected=False))


def pages_holding(key):
    return [page for page in pages.values() if key in page["keys"]]


def select_track(key):
    for page in pages_holding(key):
        for other in page["keys"]:
            page["tracks"].patch(other, selected=other == key)


def on_pick(row):
    select_track(row.key)


def on_play(row):
    select_track(row.key)
    keys = pages_holding(row.key)[0]["keys"]
    # The queue is the app's: the album from this track on (M11).
    playback["queue"] = keys[keys.index(row.key):]
    play_next()


def play_album(page):
    if not page["keys"]:
        return
    select_track(page["keys"][0])
    playback["queue"] = list(page["keys"])
    play_next()


def play_next():
    previous = playback["key"]
    playback["key"] = playback["queue"].pop(0) if playback["queue"] else None
    for key in (previous, playback["key"]):
        for page in pages_holding(key) if key else ():
            page["tracks"].patch(key, tint=kaya.Tint.ACCENT if key == playback["key"]
                                 else kaya.Tint.NONE)
    if playback["key"] is None:
        player.unload()
        now_line.set("")
        return
    playback["start"] = True
    player.set_source(catalogue.source(songs[playback["key"]]["audio"]))
    now_line.set(f"Loading · {songs[playback['key']]['title']}")


def on_player_state(state):
    key = playback["key"]
    if key is None:
        return
    title = songs[key]["title"]
    if state == kaya.PlayerState.READY and playback["start"]:
        playback["start"] = False
        player.play()
    elif state == kaya.PlayerState.PLAYING:
        now_line.set(f"Playing · {title}")
    elif state == kaya.PlayerState.PAUSED:
        now_line.set(f"Paused · {title}")
    elif state == kaya.PlayerState.ENDED:
        play_next()


def on_player_failed(why, detail):
    key = playback["key"]
    print(f"music: track {key} failed: {why} {detail}", file=sys.stderr)
    if key is not None:
        now_line.set(f"Couldn't play {songs[key]['title']}.")


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
    known[album["id"]] = album
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
        if desktop:
            # Home is a sidebar destination (docs/media-player-plan.md §1).
            with kaya.row(selected=home_shown, on_activate=go_home) as destination:
                destination.a11y_id("go_home")
                kaya.label("Home")
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
        home_shown.set(True)
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
    now_line = kaya.signal("")
    home_shown = kaya.signal(False)
    # A lane's legs play on the maintainer's desk, so they play silently.
    player = kaya.player(muted=bool(os.environ.get("KAYA_SELFTEST")),
                         on_state=on_player_state, on_failed=on_player_failed)
    if desktop:
        library_body()

threading.Thread(target=load_home, daemon=True).start()

sys.exit(app.run())
