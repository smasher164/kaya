"""The media player demo (docs/media-player-plan.md): the library sidebar
and Home (tools/scenes/music_home.steps), an album's track table that plays
through kaya's player (tools/scenes/music_playlist.steps), and the album's
gradient header (tools/scenes/music_header.steps), and the dock with the
media session and the phones' full player (tools/scenes/music_dock.steps),
and the artist page (tools/scenes/music_artist.steps)."""

import html
import json
import math
import os
import random
import sys
import threading
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
AVATAR_ART = 160 if kaya.capabilities().aux_windows else 120
DOCK_ART = 48
# Previous restarts the track past this point (docs/media-player-plan.md M14).
RESTART_AFTER_MS = 3000
FULL_ART = 300
# The header's colour until the cover has decoded (docs/styling-pass-plan.md Y2).
UNKNOWN_COLOUR = kaya.Color(0x47, 0x47, 0x4A)
HEADER_L = 30
VIVID_SHARE = 0.01
VIVID_L = (8, 96)
VIVID_CHROMA = 15
CLIENT_ID_PREF = "jamendo.client_id"
JAMENDO_API = "https://api.jamendo.com/v3.0/"
SAMPLER = "sampler:"
# A lane's leg takes the host's Now Playing only in the scene that reads it
# (tools/lib/lanes/mac.py HOST_VERBS derives the session legs from the verbs).
SESSION = os.environ.get("KAYA_SELFTEST", "") in ("", "music_dock")
# A lane's legs play on the maintainer's desk, so they play silently.
SILENT = bool(os.environ.get("KAYA_SELFTEST"))
# The window gives no margin, so the album header runs full bleed and the
# page gives its own back to the content (docs/media-player-plan.md M15).
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
                               "artist_id": track["artist_id"],
                               "image": self.address(track["album_image"])})
        return albums

    def album(self, album_id):
        return self.get("albums/tracks", id=album_id, imagesize=600)[0]

    def artist(self, artist_id):
        """The artist, their albums and their most played tracks."""
        about = self.get("artists", id=artist_id)[0]
        albums = self.get("artists/albums", id=artist_id)[0]["albums"]
        tracks = self.get("tracks", artist_id=artist_id, order="popularity_total", limit=200)
        return about, albums, tracks


app = kaya.App()
catalogue = Catalogue()
desktop = kaya.capabilities().aux_windows
art_pool = ThreadPoolExecutor(max_workers=6)
cards = {}
artist_cards = {}
viewing = {"album": None}
library_keys = []
known = {}
# Each surface's navigation stack of album and artist pages, top last.
stacks = {}
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
    for _ in stacks.pop(0, []):
        kaya.pop_entry()
    # The album last opened stays the selected card under Home.
    show_library_selection(None)
    home_shown.set(True)


def all_pages():
    return [page for stack in stacks.values() for page in stack]


def find_page(surface, entry):
    return next((p for p in stacks.get(surface, []) if p["entry"] == entry), None)


def open_page(surface, kind, key):
    """None when that page is already on top; otherwise the stack ready for
    a new page: a page of the same kind on top is replaced."""
    stack = stacks.setdefault(surface, [])
    if stack and stack[-1]["kind"] == kind:
        if stack[-1]["id"] == key:
            return None
        kaya.pop_entry(surface)
        stack.pop()
    return stack


def show_album(album, surface):
    if desktop:
        home_shown.set(False)
    stack = open_page(surface, "album", album["id"])
    if stack is None:
        return
    entry = next(entries)
    page = {"kind": "album", "id": album["id"], "album": album["id"], "entry": entry,
            "keys": []}
    stack.append(page)
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
    # No gap under the header: the table's own margin is the gap (M15).
    with kaya.column(spacing=0, align="stretch") as body:
        body.a11y_id("album")
        album_header(album, page)
        # A phone's width holds no album column (the album is the page).
        names = ("#", "Title", "Album", "Time") if desktop else ("#", "Title", "Time")
        with kaya.column(inset=PAGE_INSET, grow=1, align="stretch") as margin:
            margin.a11y_id("album_tracks")
            track_table(page, names)


def track_table(page, names, a11y="tracks", prefix="", grow: float | None = 1, timed=True):
    for track in page["tracks"].columns(*names, a11y_id=a11y, grow=grow):
        with kaya.row(selected=track.selected, on_select=on_pick,
                      on_activate=on_play) as line:
            line.a11y_id(f"{prefix}track")
            kaya.label(bind=track.number)
            with kaya.row(spacing=8):
                kaya.image(track.art, fit=kaya.Fit.COVER, shape=kaya.Shape.ROUNDED,
                           phase=track.phase, on_needed=page["art"].needed,
                           on_released=page["art"].released) \
                    .max_width(ROW_ART).max_height(ROW_ART).a11y_id(f"{prefix}track_art")
                with kaya.column(spacing=0):
                    kaya.label(bind=track.title, tint=track.tint).a11y_id(f"{prefix}track_name")
                    kaya.caption(bind=track.artist)
            if desktop:
                kaya.label(bind=track.album)
            if timed:
                kaya.label(bind=track.duration).a11y_id(f"{prefix}track_time")


def album_header(album, page):
    with kaya.column(inset=24, ground_gradient=page["colour"]) as header:
        header.a11y_id("album_header")
        header_content(album, page)


def header_content(album, page):
    with kaya.row(spacing=24, align="end") if desktop else \
            kaya.column(spacing=16, align="center"):
        kaya.image(page["cover"], fit=kaya.Fit.COVER, shape=kaya.Shape.ROUNDED,
                   phase=page["cover_phase"]) \
            .max_width(HEADER_ART).max_height(HEADER_ART).a11y_id("album_art")
        with kaya.column(spacing=6, align="start"):
            kaya.heading(album["name"]).a11y_id("album_title")
            kaya.button(album["artist"], on_click=lambda: open_artist(album)) \
                .role(kaya.Role.PLAIN).a11y_id("album_artist")
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
    for page in all_pages():
        if page["kind"] == "album" and page["album"] == album_id:
            page["liked"].set(on)


def page_closed(surface, entry):
    page = find_page(surface, entry)
    if page is not None:
        stacks[surface].remove(page)


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
    colour = header_colour(cover) if cover else None
    app.post(cover_arrived, surface, entry, cover, colour)


def lab(c):
    lin = [v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
           for v in (c.r / 255, c.g / 255, c.b / 255)]
    x = (0.4124 * lin[0] + 0.3576 * lin[1] + 0.1805 * lin[2]) / 0.95047
    y = 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
    z = (0.0193 * lin[0] + 0.1192 * lin[1] + 0.9505 * lin[2]) / 1.08883
    f = [t ** (1 / 3) if t > 216 / 24389 else (24389 / 27 * t + 16) / 116 for t in (x, y, z)]
    return 116 * f[1] - 16, 500 * (f[0] - f[1]), 200 * (f[1] - f[2])


def vivid(cover):
    """The palette's most vivid colour with a share worth a header, its
    chroma weighted by the root of its share; paper and ink, and a cover
    with nothing vivid, answer None."""
    best, score = None, 0.0
    for entry in kaya.image_palette(cover, 6) or []:
        light, a, b = lab(entry.color)
        chroma = math.hypot(a, b)
        if entry.share < VIVID_SHARE or not VIVID_L[0] < light < VIVID_L[1] or chroma < VIVID_CHROMA:
            continue
        if chroma * math.sqrt(entry.share) > score:
            best, score = entry.color, chroma * math.sqrt(entry.share)
    return best


def header_colour(cover):
    """The header's wash (M15): the cover's most vivid colour, or its
    dominant one, taken down to a deep, muted L* 30 that the core keeps in
    dark and lifts to its pale floor in light (Y2)."""
    seed = vivid(cover) or kaya.image_dominant(cover)
    if seed is None:
        return None
    _, a, b = lab(seed)
    chroma = min(math.hypot(a, b), 40) * 0.55
    hue = math.atan2(b, a)
    fy = (HEADER_L + 16) / 116
    fx, fz = fy + chroma * math.cos(hue) / 500, fy - chroma * math.sin(hue) / 200
    x, y, z = (t ** 3 if t ** 3 > 216 / 24389 else (116 * t - 16) / (24389 / 27)
               for t in (fx, fy, fz))
    x, z = x * 0.95047, z * 1.08883
    rgb = (3.2406 * x - 1.5372 * y - 0.4986 * z, -0.9689 * x + 1.8758 * y + 0.0415 * z,
           0.0557 * x - 0.2040 * y + 1.0570 * z)
    out = [12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055
           for c in (max(0.0, min(1.0, v)) for v in rgb)]
    return kaya.Color(*(round(c * 255) for c in out))


def cover_arrived(surface, entry, cover, colour):
    page = find_page(surface, entry)
    if page is None:
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
    page = find_page(surface, entry)
    if page is None:
        return
    if answer is None:
        page["about"].set("Couldn't reach the catalogue.")
        return
    artist = html.unescape(answer["artist_name"])
    year = answer.get("releasedate", "")[:4]
    listed = sorted(answer["tracks"], key=lambda t: int(t["position"]))
    total = songs_line(len(listed), sum(int(t["duration"]) for t in listed))
    page["about"].set(" · ".join(p for p in (year, total) if p))
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
    return [page for page in all_pages() if key in page["keys"]]


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
            with kaya.row(spacing=16, align="center", inset=PAGE_INSET) as bar:
                bar.a11y_id("dock_bar")
                # Equal side zones keep the transport on the window's centre
                # whatever the title's length (M14).
                now_playing(grow=1)
                with kaya.column(spacing=4, align="stretch", grow=2):
                    transport(full=False)
                    scrubber()
                volume_zone()
        else:
            with kaya.row(spacing=12, align="center", inset=PAGE_INSET) as bar:
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


def card_art_landed(album_id, data, registry=None):
    card = (cards if registry is None else registry)[album_id]
    if data is None:
        card["phase"].set(kaya.ImagePhase.FAILED)
        return
    card["art"].set(data)
    card["phase"].set(kaya.ImagePhase.SHOWN)
    # A track played from an artist page may be from an album never opened.
    if album_id not in covers:
        covers[album_id] = data
        key = playback["key"]
        if key is not None and songs[key]["album"] == album_id:
            show_art()
            declare_session()


def fetch_card_art(album_id, url, registry=None):
    try:
        data = catalogue.fetch(url)
    except OSError:
        data = None
    app.post(card_art_landed, album_id, data, registry)


def open_artist(album):
    """The artist page opens once its answer is in: its shelf is a grid of
    cards, which is built whole."""
    surface = 0 if desktop else current_surface(album["id"])
    top = stacks.get(surface, [])[-1:]
    if top and top[0]["kind"] == "artist" and top[0]["id"] == album["artist_id"]:
        return
    threading.Thread(target=load_artist, args=(album["artist_id"], surface),
                     daemon=True).start()


def current_surface(album_id):
    """The phone's section whose stack shows the album."""
    for surface, stack in stacks.items():
        if stack and stack[-1].get("album") == album_id:
            return surface
    return SECTION_HOME


def load_artist(artist_id, surface):
    try:
        answer = catalogue.artist(artist_id)
    except (OSError, ValueError, KeyError, IndexError) as e:
        print(f"music: artist {artist_id} did not load: {e!r}", file=sys.stderr)
        return
    app.post(show_artist, surface, answer)


def show_artist(surface, answer):
    about, albums, tracks = answer
    stack = open_page(surface, "artist", about["id"])
    if stack is None:
        return
    name = html.unescape(about["name"])
    entry = next(entries)
    page = {"kind": "artist", "id": about["id"], "entry": entry, "keys": [],
            "cards": {}}
    stack.append(page)
    shelf = [{"id": a["id"], "name": html.unescape(a["name"]), "artist": name,
              "artist_id": about["id"], "image": catalogue.address(a["image"])}
             for a in albums]
    seconds = sum(int(t["duration"]) for t in tracks)
    with app.push_entry(entry, title=name, window=surface,
                        on_popped=lambda: page_closed(surface, entry)):
        page["picture"] = kaya.signal(b"")
        page["picture_phase"] = kaya.signal(kaya.ImagePhase.LOADING)
        page["tracks"] = kaya.collection(Track)
        page["art"] = kaya.RowImages(app, page["tracks"], url="art_url", art="art",
                                     phase="phase", fetch=catalogue.fetch)
        artist_body(name, f"{albums_line(len(albums))} · {songs_line(len(tracks), seconds)}",
                    shelf, page)
    for album in shelf:
        art_pool.submit(fetch_card_art, album["id"], album["image"], page["cards"])
    for rank, t in enumerate(tracks, start=1):
        key = t["id"]
        songs[key] = {"title": html.unescape(t["name"]), "audio": t["audio"],
                      "artist": name, "album": t["album_id"],
                      "album_name": html.unescape(t["album_name"]),
                      "seconds": int(t["duration"])}
        page["keys"].append(key)
        page["tracks"].insert(key, Track(
            number=str(rank), title=songs[key]["title"], artist=name,
            album=songs[key]["album_name"],
            duration=kaya.fmt.duration(int(t["duration"]) * 1000),
            art_url=catalogue.address(t["album_image"]), art=b"",
            phase=kaya.ImagePhase.LOADING,
            tint=kaya.Tint.ACCENT if key == playback["key"] else kaya.Tint.NONE,
            selected=False))
    threading.Thread(target=load_picture, args=(about["image"], surface, entry),
                     daemon=True).start()


def artist_body(name, about, shelf, page):
    """The artist page (docs/media-player-plan.md §1, M13; docs/styling-pass-plan.md
    Y3): the picture as the header's ground, the round avatar and the name in an
    overlay panel, then the top tracks as a table and the albums as a shelf."""
    # The page scrolls whole and its table hugs its rows (the portfolio's shape).
    with kaya.scroll(grow=1) as page_scroll, kaya.column(spacing=0, align="stretch") as body:
        page_scroll.a11y_id("artist_page")
        body.a11y_id("artist")
        with kaya.column(spacing=16, align="start", inset=24,
                         ground_image=page["picture"]) as header:
            header.a11y_id("artist_header")
            kaya.image(page["picture"], fit=kaya.Fit.COVER, shape=kaya.Shape.CIRCLE,
                       phase=page["picture_phase"]) \
                .max_width(AVATAR_ART).max_height(AVATAR_ART).a11y_id("artist_avatar")
            with kaya.row(), kaya.column(spacing=4, align="start", inset=12,
                                         filled=kaya.Tint.OVERLAY) as panel:
                panel.a11y_id("artist_panel")
                kaya.heading(name).a11y_id("artist_name")
                kaya.caption(about).a11y_id("artist_about")
        with kaya.column(spacing=16, inset=PAGE_INSET, align="stretch") as rest:
            rest.a11y_id("artist_rest")
            kaya.heading("Top tracks")
            # A phone's popular list carries no times, as Spotify's does not.
            names = ("#", "Title", "Album", "Time") if desktop else ("#", "Title")
            track_table(page, names, a11y="top_tracks", prefix="top_", grow=None, timed=desktop)
            kaya.heading("Albums")
            with kaya.grid(1, spacing=12) as grid:
                for album in shelf:
                    card(album, page["cards"], prefix="artist_")
            grid.columns_auto(CARD_ART + 24).a11y_id("artist_shelf")


def load_picture(url, surface, entry):
    try:
        picture = catalogue.fetch(catalogue.address(url))
    except OSError as e:
        print(f"music: the artist's picture did not load: {e!r}", file=sys.stderr)
        picture = None
    app.post(picture_arrived, surface, entry, picture)


def picture_arrived(surface, entry, picture):
    page = find_page(surface, entry)
    if page is None:
        return
    if picture is None:
        page["picture_phase"].set(kaya.ImagePhase.FAILED)
        return
    page["picture"].set(picture)
    page["picture_phase"].set(kaya.ImagePhase.SHOWN)


def albums_line(count):
    return "1 album" if count == 1 else f"{count} albums"


def card(album, registry=None, prefix=""):
    """A Home card, or with `registry` and `prefix` an artist page's."""
    registry = cards if registry is None else registry
    known[album["id"]] = album
    art = kaya.signal(b"")
    phase = kaya.signal(kaya.ImagePhase.LOADING)
    selected = kaya.signal(False)
    with kaya.column(filled=kaya.Tint.NEUTRAL, selected=selected,
                     on_activate=lambda: open_album(album)) as tile:
        tile.a11y_id(f"{prefix}card_{album['id']}").fill(True)
        kaya.image(art, fit=kaya.Fit.COVER, shape=kaya.Shape.ROUNDED, phase=phase) \
            .max_width(CARD_ART).max_height(CARD_ART).a11y_id(f"{prefix}art_{album['id']}")
        kaya.label(album["name"])
        kaya.caption(album["artist"])
    registry[album["id"]] = {"art": art, "phase": phase, "selected": selected,
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
        with kaya.column(spacing=20, align="stretch", inset=PAGE_INSET) as home:
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
    with kaya.column(spacing=4, inset=PAGE_INSET) as side:
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
                panes=2 if desktop else None, inset=0,
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
