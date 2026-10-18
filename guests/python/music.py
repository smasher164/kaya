"""The media player demo (docs/media-player-plan.md): the library sidebar
and Home (tools/scenes/music_home.steps), an album's track table that plays
through kaya's player (tools/scenes/music_playlist.steps), and the album's
gradient header (tools/scenes/music_header.steps), and the dock with the
media session and the phones' full player (tools/scenes/music_dock.steps)."""

import contextlib
import html
import json
import os
import random
import struct
import sys
import threading
import zlib
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass

import kaya

HOME = 7
CONNECT = 20
DOCK = 21
PLAYER_SHEET = 22
SECTION_HOME = 30
SECTION_LIBRARY = 31
FIRST_ALBUM_ENTRY = 100

SHELVES = [("jazz", "Jazz"), ("electronic", "Electronic"), ("rock", "Rock")]
SHELF_CARDS = 12
CARD_ART = 120
ROW_ART = 40
HEADER_ART = 200 if kaya.capabilities().aux_windows else 180
DOCK_ART = 48
# Previous restarts the track past this point (docs/media-player-plan.md M14).
RESTART_AFTER_MS = 3000
FULL_ART = 300
# The header's colour until the cover has decoded (docs/styling-pass-plan.md Y2).
UNKNOWN_COLOUR = kaya.Color(0x8E, 0x8E, 0x93)
CLIENT_ID_PREF = "jamendo.client_id"
JAMENDO_API = "https://api.jamendo.com/v3.0/"
SAMPLER = "sampler:"
# A lane's leg takes the host's Now Playing only in the scene that reads it
# (tools/lib/lanes/mac.py HOST_VERBS derives the session legs from the verbs).
SESSION = os.environ.get("KAYA_SELFTEST", "") in ("", "music_dock")
# A lane's legs play on the maintainer's desk, so they play silently.
SILENT = bool(os.environ.get("KAYA_SELFTEST"))
# The album header's comparison (docs/media-player-plan.md M15), read by its
# captures only: `B:RRGGBB` a full-bleed gradient, `C:RRGGBB` a full-bleed solid.
HEADER_VARIANT = os.environ.get("KAYA_MUSIC_HEADER", "")
BLEED = HEADER_VARIANT[:1] in ("B", "C")
PAGE_INSET = 16


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
playback = {"key": None, "album": [], "order": [], "at": 0, "start": False,
            "shuffle": False, "repeat": "off", "seconds": 0, "ms": 0,
            "muted": False}
favorites = set()
liked = set()
covers = {}
dock_ready = {"built": False}
live = {"play": [], "repeat": [], "sheet": False}
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


def padded(**props):
    """The page's own margin when the window gives none (M15's bleed)."""
    return kaya.column(inset=PAGE_INSET, **props) if BLEED else contextlib.nullcontext()


def solid_png(rgb):
    row = b"\0" + bytes(rgb) * 8
    chunk = lambda kind, data: (struct.pack(">I", len(data)) + kind + data
                                + struct.pack(">I", zlib.crc32(kind + data)))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 8, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(row * 8)) + chunk(b"IEND", b""))


def album_body(album, page):
    with kaya.column(spacing=12, align="stretch") as body:
        body.a11y_id("album")
        if HEADER_VARIANT[:1] == "C":
            solid_header(album, page)
        else:
            album_header(album, page)
        # A phone's width holds no album column (the album is the page).
        names = ("#", "Title", "Album", "Time") if desktop else ("#", "Title", "Time")
        with padded(grow=1, align="stretch"):
            track_table(page, names)


def track_table(page, names):
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
    colour = page["colour"]
    if HEADER_VARIANT[:1] == "B":
        colour = kaya.Color(*bytes.fromhex(HEADER_VARIANT[2:]))
    with kaya.column(inset=24, ground_gradient=colour) as header:
        header.a11y_id("album_header")
        header_content(album, page)


def solid_header(album, page):
    """M15's C: a solid ground, which only an image ground can carry, so the
    text sits in the overlay panel Y3 demands over an image."""
    rgb = bytes.fromhex(HEADER_VARIANT[2:])
    with kaya.column(inset=24, ground_image=solid_png(rgb)) as header:
        header.a11y_id("album_header")
        header_content(album, page, panel=True)


def header_content(album, page, panel=False):
    with kaya.row(spacing=24, align="end") if desktop else \
            kaya.column(spacing=16, align="center"):
        kaya.image(page["cover"], fit=kaya.Fit.COVER, shape=kaya.Shape.ROUNDED,
                   phase=page["cover_phase"]) \
            .max_width(HEADER_ART).max_height(HEADER_ART).a11y_id("album_art")
        with kaya.column(spacing=6, align="start", inset=12 if panel else None,
                         filled=kaya.Tint.OVERLAY if panel else None):
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
    covers[page["album"]] = cover
    key = playback["key"]
    if key is not None and songs[key]["album"] == page["album"]:
        show_art()
        declare_session()
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
        songs[key] = {"title": html.unescape(t["name"]), "audio": t["audio"],
                      "artist": artist, "album": album["id"], "album_name": album["name"],
                      "seconds": int(t["duration"])}
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
    start_queue(pages_holding(row.key)[0]["keys"], row.key)


def play_album(page):
    if not page["keys"]:
        return
    select_track(page["keys"][0])
    start_queue(page["keys"], page["keys"][0])


def start_queue(keys, first):
    """The queue is the app's (M11): the album in its order, or the playing
    track and the rest of the album shuffled."""
    playback["album"] = list(keys)
    playback["order"] = shuffled(first) if playback["shuffle"] else list(keys)
    playback["at"] = playback["order"].index(first)
    play_track(first, start=True)


def shuffled(first):
    rest = [k for k in playback["album"] if k != first]
    random.shuffle(rest)
    return [first, *rest]


def play_track(key, start):
    previous = playback["key"]
    playback["key"] = key
    for k in (previous, key):
        for page in pages_holding(k) if k else ():
            page["tracks"].patch(k, tint=kaya.Tint.ACCENT if k == key else kaya.Tint.NONE)
    song = songs[key]
    playback["start"] = start
    playback["seconds"] = song["seconds"]
    player.set_source(catalogue.source(song["audio"]))
    show_position(0)
    if not dock_ready["built"]:
        build_dock()
    dock_title.set(song["title"])
    dock_artist.set(song["artist"])
    liked_now.set(key in liked)
    show_art()
    show_play_state(False)
    declare_session()


def show_art():
    cover = covers.get(songs[playback["key"]]["album"])
    if cover is None:
        dock_phase.set(kaya.ImagePhase.LOADING)
        return
    dock_art.set(cover)
    dock_phase.set(kaya.ImagePhase.SHOWN)


def declare_session():
    if not SESSION:
        return
    song = songs[playback["key"]]
    kaya.session(player=player, title=song["title"], artist=song["artist"],
                 album=song["album_name"], artwork=covers.get(song["album"], ""),
                 handles=[kaya.SessionAction.NEXT, kaya.SessionAction.PREVIOUS],
                 on_action=on_session_action)


def on_session_action(action, _at_ms):
    if action == kaya.SessionAction.NEXT:
        skip_next()
    elif action == kaya.SessionAction.PREVIOUS:
        skip_previous()


def skip_next():
    if playback["key"] is None:
        return
    advance(by_user=True)


def advance(by_user):
    at = playback["at"] + 1
    if at < len(playback["order"]):
        playback["at"] = at
        play_track(playback["order"][at], start=True)
        return
    if playback["repeat"] == "all":
        if playback["shuffle"]:
            playback["order"] = shuffled(playback["album"][0])
        playback["at"] = 0
        play_track(playback["order"][0], start=True)
        return
    if by_user:
        playback["at"] = 0
        play_track(playback["order"][0], start=False)


def skip_previous():
    if playback["key"] is None:
        return
    if playback["at"] == 0 or playback["ms"] > RESTART_AFTER_MS:
        seek_to(0)
        return
    playback["at"] -= 1
    play_track(playback["order"][playback["at"]], start=True)


def toggle_play():
    if playback["key"] is None:
        return
    if player.state == kaya.PlayerState.PLAYING:
        player.pause()
    elif player.state == kaya.PlayerState.ENDED:
        player.seek(0)
        player.play()
    elif player.state in (kaya.PlayerState.READY, kaya.PlayerState.PAUSED):
        player.play()
    else:
        playback["start"] = True


def set_shuffle(on):
    playback["shuffle"] = on
    shuffle_on.set(on)
    if playback["key"] is None:
        return
    playback["order"] = shuffled(playback["key"]) if on else list(playback["album"])
    playback["at"] = playback["order"].index(playback["key"])


REPEAT_NEXT = {"off": "all", "all": "one", "one": "off"}
REPEAT_NAME = {"off": "Repeat off", "all": "Repeat all", "one": "Repeat one"}


def repeat_symbol():
    return kaya.Symbol.REPEAT_ONE if playback["repeat"] == "one" else kaya.Symbol.REPEAT


def cycle_repeat():
    playback["repeat"] = REPEAT_NEXT[playback["repeat"]]
    repeat_name.set(REPEAT_NAME[playback["repeat"]])
    for button in live["repeat"]:
        button.symbol(repeat_symbol())


def set_liked(on):
    key = playback["key"]
    if key is None:
        return
    if on:
        liked.add(key)
    else:
        liked.discard(key)
    liked_now.set(on)


def show_play_state(playing):
    play_name.set("Pause" if playing else "Play")
    for button in live["play"]:
        button.symbol(kaya.Symbol.PAUSE if playing else kaya.Symbol.PLAY)


def show_position(ms):
    playback["ms"] = ms
    seconds = playback["seconds"]
    at = min(ms / 1000, seconds) if seconds else 0
    position.set(at / seconds if seconds else 0.0)
    elapsed.set(kaya.fmt.duration(int(at) * 1000))
    remaining.set("-" + kaya.fmt.duration(max(0, seconds - int(at)) * 1000))


def seek_to(fraction):
    ms = int(fraction * playback["seconds"] * 1000)
    player.seek(ms)
    show_position(ms)


def on_scrub(value):
    if playback["key"] is not None:
        seek_to(value)


def on_position(ms):
    if player.state == kaya.PlayerState.PLAYING:
        show_position(ms)


def on_player_state(state):
    key = playback["key"]
    if key is None:
        return
    if state == kaya.PlayerState.READY and playback["start"]:
        playback["start"] = False
        player.play()
    elif state == kaya.PlayerState.PLAYING:
        show_play_state(True)
    elif state in (kaya.PlayerState.PAUSED, kaya.PlayerState.READY):
        show_play_state(False)
    elif state == kaya.PlayerState.ENDED:
        if playback["repeat"] == "one":
            player.seek(0)
            player.play()
            return
        show_play_state(False)
        advance(by_user=False)


def on_player_failed(why, detail):
    key = playback["key"]
    print(f"music: track {key} failed: {why} {detail}", file=sys.stderr)
    if key is not None:
        dock_artist.set(f"Couldn't play {songs[key]['title']}.")
        show_play_state(False)


def transport(full):
    """Shuffle, previous, play or pause, next and repeat: the dock's on the
    desktops, the full player's on the phones, centred in its row."""
    with kaya.row(spacing=8, align="center") as row:
        row.a11y_id("full_transport" if full else "transport")
        kaya.spacer()
        kaya.checkbox("Shuffle", checked=shuffle_on, on_toggle=set_shuffle) \
            .role(kaya.Role.TOGGLE).symbol(kaya.Symbol.SHUFFLE).a11y_id("shuffle")
        kaya.button("Previous", on_click=skip_previous, symbol=kaya.Symbol.PREVIOUS) \
            .a11y_id("previous")
        play_button(full)
        kaya.button("Next", on_click=skip_next, symbol=kaya.Symbol.NEXT) \
            .a11y_id("full_next" if full else "next")
        live["repeat"].append(
            kaya.button("Repeat", on_click=cycle_repeat, symbol=repeat_symbol())
            .a11y_label(repeat_name).a11y_id("repeat"))
        kaya.spacer()


def play_button(full):
    button = kaya.button("Play", on_click=toggle_play, symbol=kaya.Symbol.PLAY) \
        .role(kaya.Role.PROMINENT).a11y_label(play_name) \
        .a11y_id("full_play_pause" if full else "play_pause")
    live["play"].append(button)
    playing = player.state == kaya.PlayerState.PLAYING
    button.symbol(kaya.Symbol.PAUSE if playing else kaya.Symbol.PLAY)


def scrubber():
    with kaya.row(spacing=8, align="center"):
        kaya.caption(bind=elapsed).a11y_id("elapsed")
        kaya.slider(position, min=0.0, max=1.0, on_commit=on_scrub, grow=1) \
            .a11y_label("Position").a11y_id("progress")
        kaya.caption(bind=remaining).a11y_id("remaining")


def set_volume(value):
    volume.set(value)
    player.set_volume(value)


def set_muted(on):
    playback["muted"] = on
    muted_now.set(on)
    player.set_muted(on or SILENT)


def volume_zone():
    """The heart, mute and the volume slider, which takes the zone's rest."""
    with kaya.row(spacing=8, align="center", grow=1) as zone:
        zone.a11y_id("dock_end")
        like_box()
        kaya.checkbox("Mute", checked=muted_now, on_toggle=set_muted) \
            .role(kaya.Role.TOGGLE).symbol(kaya.Symbol.VOLUME).a11y_id("mute")
        kaya.slider(volume, min=0.0, max=1.0, on_change=set_volume, on_commit=set_volume,
                    grow=1).a11y_label("Volume").a11y_id("volume")


def like_box():
    kaya.checkbox("Like", checked=liked_now, on_toggle=set_liked) \
        .role(kaya.Role.TOGGLE).symbol(kaya.Symbol.FAVORITE).a11y_id("like")


def build_dock():
    """The dock (docs/styling-pass-plan.md Y8), attached once something has
    played (M6): the bar at the window's foot on the desktops, above the tab
    bar on the phones, where a tap opens the full player."""
    dock_ready["built"] = True
    with app.dock(DOCK):
        if desktop:
            with kaya.row(spacing=16, align="center") as bar:
                bar.a11y_id("dock_bar")
                # Equal side zones keep the transport on the window's centre
                # whatever the title's length (M14).
                now_playing(grow=1)
                with kaya.column(spacing=4, align="stretch", grow=2):
                    transport(full=False)
                    scrubber()
                volume_zone()
        else:
            with kaya.row(spacing=12, align="center") as bar:
                bar.a11y_id("dock_bar")
                # Only the art and lines open the full player: an activatable
                # container is one element to an assistive reader, buttons and all.
                with kaya.row(on_activate=open_full_player, grow=1) as opener:
                    opener.a11y_id("dock_open")
                    now_playing(grow=1)
                play_button(full=False)
                kaya.button("Next", on_click=skip_next, symbol=kaya.Symbol.NEXT) \
                    .a11y_id("next")


def now_playing(grow):
    with kaya.row(spacing=12, align="center", grow=grow):
        kaya.image(dock_art, fit=kaya.Fit.COVER, shape=kaya.Shape.ROUNDED, phase=dock_phase) \
            .max_width(DOCK_ART).max_height(DOCK_ART).a11y_id("dock_art")
        with kaya.column(spacing=0):
            kaya.label(bind=dock_title).a11y_id("dock_title")
            kaya.caption(bind=dock_artist).a11y_id("dock_artist")


def open_full_player():
    if live["sheet"]:
        return
    live["sheet"] = True
    with app.sheet(PLAYER_SHEET, title="Now Playing", detent="large",
                   on_dismissed=full_player_closed):
        with kaya.column(spacing=16, align="stretch") as full:
            full.a11y_id("full_player")
            with kaya.column(align="center"):
                kaya.image(dock_art, fit=kaya.Fit.COVER, shape=kaya.Shape.ROUNDED, phase=dock_phase) \
                    .max_width(FULL_ART).max_height(FULL_ART).a11y_id("full_art")
            with kaya.row(align="center"):
                with kaya.column(spacing=0, grow=1):
                    kaya.heading(bind=dock_title).a11y_id("full_title")
                    kaya.caption(bind=dock_artist)
                like_box()
            scrubber()
            transport(full=True)


def full_player_closed():
    live["sheet"] = False
    live["play"] = live["play"][:1]
    live["repeat"] = []


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
        with kaya.column(spacing=20, align="stretch",
                         inset=PAGE_INSET if BLEED else None) as home:
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
    with kaya.column(spacing=4, inset=PAGE_INSET if BLEED else None) as side:
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
                panes=2 if desktop else None, inset=0 if BLEED else None,
                sections_presentation=None if desktop else kaya.SectionsPresentation.BAR):
    notice = kaya.signal("Browsing the bundled sampler.")
    library_hint = kaya.signal(library_caption())
    library = kaya.collection(Saved)
    library_art = kaya.RowImages(app, library, url="art_url", art="art", phase="phase",
                                 fetch=catalogue.fetch)
    home_shown = kaya.signal(False)
    dock_title = kaya.signal("")
    dock_artist = kaya.signal("")
    dock_art = kaya.signal(b"")
    dock_phase = kaya.signal(kaya.ImagePhase.LOADING)
    liked_now = kaya.signal(False)
    shuffle_on = kaya.signal(False)
    play_name = kaya.signal("Play")
    repeat_name = kaya.signal(REPEAT_NAME["off"])
    position = kaya.signal(0.0)
    elapsed = kaya.signal(kaya.fmt.duration(0))
    remaining = kaya.signal("-" + kaya.fmt.duration(0))
    volume = kaya.signal(1.0)
    muted_now = kaya.signal(False)
    player = kaya.player(muted=SILENT,
                         on_state=on_player_state, on_failed=on_player_failed,
                         on_position=on_position)
    if desktop:
        library_body()

threading.Thread(target=load_home, daemon=True).start()

sys.exit(app.run())
