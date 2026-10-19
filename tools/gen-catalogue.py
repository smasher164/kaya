#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die, scratch_dir

dev_shell_or_die()

# The Jamendo snapshot the lanes' mirror serves (docs/media-player-plan.md M2).
#
#   tools/gen-catalogue.py                 fetch and write guests/assets/catalogue/
#   tools/gen-catalogue.py --dry           fetch and print the selection only
#   tools/gen-catalogue.py --add-searches  fetch the searches the rule names that
#                                          api.json lacks, and keep everything else
#   tools/gen-catalogue.py --check [--against DIR]
#                                          read the committed files only
#
# The client id is the person's own and never written anywhere: it is read
# from KAYA_JAMENDO_CLIENT_ID or ~/.config/kaya/jamendo-client-id, and a
# write of any byte holding it is refused (the API echoes it in
# headers.next).

import argparse
import json
import os
import re
import shutil
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

import catalogue

FAMILY = catalogue.FAMILY
API_BASE = "https://api.jamendo.com/v3.0/"
AGENT = "kaya tools/gen-catalogue.py (a one-off CC BY snapshot for local tests)"
ID_FILE = pathlib.Path.home() / ".config" / "kaya" / "jamendo-client-id"

GENRES = ("jazz", "electronic", "rock")
ARTISTS = 3
ALBUMS_PER_ARTIST = 2
TRACKS_PER_ALBUM = 2
CLIP_S = 20
WIDTHS = {"album": (300, 600)}
KINDS = ("album", "artist")
CHART_LIMIT = 50
WIDE_LIMIT = 200
EMPTY_TRIES = 4
EMPTY_PAUSE_S = 1.5

LICENCE = re.compile(r"^https?://creativecommons\.org/licenses/(by|by-sa)/\d(?:\.\d)?/(?:[a-z]{2}/)?$")
CREDIT_KEYS = ("shareurl", "shorturl", "prourl", "license_ccurl", "website")
STRIPPED = ("waveform", "audiodownload", "audiodownload_allowed", "zip", "zip_allowed")
DOCS = ("README.md", "ATTRIBUTION.md")
# tools/scenes/music_search.steps' terms: one finding an artist, albums and
# tracks in the snapshot, one finding nothing on Jamendo itself.
SCENE_SEARCHES = ("David", "zzqxv")
SEARCH_FIELDS = (("tracks", "search"), ("artists", "namesearch"), ("albums", "namesearch"))
META = "_snapshot"


def client_id():
    cid = os.environ.get("KAYA_JAMENDO_CLIENT_ID", "").strip()
    if not cid and ID_FILE.is_file():
        cid = ID_FILE.read_text(encoding="utf-8").strip()
    if not cid:
        raise SystemExit(f"gen-catalogue: no Jamendo client id — set KAYA_JAMENDO_CLIENT_ID "
                         f"or write it to {ID_FILE} (register one at "
                         f"https://devportal.jamendo.com; it is personal, never commit it)")
    return cid


class Jamendo:
    def __init__(self, cid):
        self.cid = cid
        self.calls = 0

    def scrub(self, text):
        return text.replace(self.cid, "<client id>")

    def fetch(self, url, headers=None):
        req = urllib.request.Request(url, headers={"User-Agent": AGENT, **(headers or {})})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.read(), r.headers.get("Content-Type", "")
        except (urllib.error.URLError, OSError) as e:
            raise SystemExit(f"gen-catalogue: fetching {self.scrub(url)} failed: "
                             f"{self.scrub(str(e))}") from None

    def api(self, endpoint, may_be_empty=False, **params):
        """(the answers' key, Jamendo's answer) for one request. An empty
        answer is asked again: Jamendo answers a populated query with no
        results intermittently (docs/media-player-plan.md §7)."""
        q = urllib.parse.urlencode(sorted(params.items()), quote_via=urllib.parse.quote)
        key = catalogue.canonical(endpoint, q)
        url = f"{API_BASE}{endpoint}/?client_id={urllib.parse.quote(self.cid)}&format=json&{q}"
        for attempt in range(1, EMPTY_TRIES + 1):
            body, _ = self.fetch(url)
            self.calls += 1
            answer = json.loads(body)
            if answer.get("results") or may_be_empty or attempt == EMPTY_TRIES:
                break
            print(f"gen-catalogue: {key} answered no results, asking again ({attempt} of "
                  f"{EMPTY_TRIES})", flush=True)
            time.sleep(EMPTY_PAUSE_S)
        head = answer.get("headers", {})
        if head.get("status") != "success":
            raise SystemExit(f"gen-catalogue: {key} answered {head.get('code')}: "
                             f"{self.scrub(str(head.get('error_message')))}")
        if head.get("warnings"):
            raise SystemExit(f"gen-catalogue: {key} warned: {self.scrub(head['warnings'])}")
        return key, answer


def is_jpeg(data):
    return data[:3] == b"\xff\xd8\xff"


def licensed(url):
    return bool(LICENCE.match(url or ""))


def image_url(kind, ident, width):
    return f"https://usercontent.jamendo.com?type={kind}&id={ident}&width={width}"


def select(j, log):
    """The snapshot's choice, by the rule its README states."""
    raw = {}
    images = {}
    artists, albums, tracks = [], [], []
    home = []

    def keep(key, answer):
        raw[key] = answer
        return answer

    def pictures(kind, ident):
        got = {}
        for w in WIDTHS[kind]:
            data, _ = j.fetch(image_url(kind, ident, w))
            if not is_jpeg(data):
                return None
            got[f"{kind}-{ident}-{w}.jpg"] = data
        return got

    def album_tracks(album_id):
        key, answer = j.api("albums/tracks", id=album_id, imagesize="600")
        res = answer["results"]
        return key, answer, (res[0]["tracks"] if res else [])

    for genre in GENRES:
        key, chart = j.api("tracks", tags=genre, order="popularity_week", ccnc="false",
                           ccnd="false", include="musicinfo", limit=str(CHART_LIMIT))
        keep(key, chart)
        home.append((genre, key))
        if len(artists) == ARTISTS:
            continue
        for seed in chart["results"]:
            aid = seed["artist_id"]
            if aid in {a["id"] for a in artists}:
                continue
            akey, info = j.api("artists", id=aid)
            if not info["results"] or not info["results"][0].get("image"):
                log(f"{seed['artist_name']}: no artist image")
                continue
            pkey, popular = j.api("tracks", artist_id=aid, order="popularity_total",
                                  limit=str(WIDE_LIMIT))
            if not popular["results"]:
                log(f"{seed['artist_name']}: Jamendo lists none of their tracks by popularity, "
                    f"so the artist page would have no top tracks")
                continue
            rank = {t["id"]: i for i, t in enumerate(popular["results"])}
            lkey, listing = j.api("artists/albums", id=aid)
            listed = listing["results"][0]["albums"] if listing["results"] else []
            order = sorted(listed, key=lambda a: (a["id"] != seed["album_id"],
                                                  [-ord(c) for c in a["releasedate"]]))
            picked = []
            for al in order:
                tkey, tanswer, list_ = album_tracks(al["id"])
                bad = [t for t in list_ if not licensed(t["license_ccurl"])]
                if len(list_) < TRACKS_PER_ALBUM:
                    log(f"{seed['artist_name']} / {al['name']}: {len(list_)} track(s)")
                elif bad:
                    log(f"{seed['artist_name']} / {al['name']}: {len(bad)} track(s) not BY or "
                        f"BY-SA, e.g. {bad[0]['license_ccurl']}")
                else:
                    long_ = [t for t in list_ if int(t["duration"]) >= CLIP_S]
                    first = [t for t in long_ if t["id"] == seed["id"]]
                    rest = sorted((t for t in long_ if t["id"] != seed["id"]),
                                  key=lambda t: (rank.get(t["id"], len(rank)), int(t["position"])))
                    chosen = (first + rest)[:TRACKS_PER_ALBUM]
                    whole = (len(chosen) == TRACKS_PER_ALBUM
                             and (first or al["id"] != seed["album_id"]))
                    covers = pictures("album", al["id"]) if whole else None
                    if covers is None:
                        log(f"{seed['artist_name']} / {al['name']}: short tracks or a cover "
                            f"that is not a JPEG")
                    else:
                        picked.append((al, tkey, tanswer, chosen, covers))
                if al["id"] == seed["album_id"] and not picked:
                    break
                if len(picked) == ALBUMS_PER_ARTIST:
                    break
            if len(picked) < ALBUMS_PER_ARTIST:
                log(f"{seed['artist_name']}: {len(picked)} album(s) qualify, the seed's "
                    f"first, wanted {ALBUMS_PER_ARTIST}")
                continue
            keep(akey, info)
            keep(lkey, listing)
            keep(pkey, popular)
            artists.append({"id": aid, "name": seed["artist_name"], "genre": genre})
            for al, tkey, tanswer, chosen, covers in picked:
                keep(tkey, tanswer)
                images.update(covers)
                albums.append({"id": al["id"], "name": al["name"], "artist_id": aid})
                for t in chosen:
                    tracks.append({**t, "artist_name": seed["artist_name"],
                                   "artist_id": aid, "album_id": al["id"],
                                   "album_name": al["name"]})
            log(f"chose {seed['artist_name']} ({genre}): "
                + "; ".join(f"{al['name']} [{', '.join(t['name'] for t in ch)}]"
                            for al, _, _, ch, _ in picked))
            break
    if len(artists) < ARTISTS:
        raise SystemExit(f"gen-catalogue: {len(artists)} artist(s) qualified over "
                         f"{', '.join(GENRES)}, wanted {ARTISTS}")

    searches = [artists[0]["name"], tracks[0]["name"], *SCENE_SEARCHES]
    for term in searches:
        for endpoint, field in SEARCH_FIELDS:
            keep(*j.api(endpoint, limit=str(WIDE_LIMIT), **{field: term}))
    return {"raw": raw, "images": images, "artists": artists, "albums": albums,
            "tracks": tracks, "home": home, "searches": searches}


def clip(j, track, out):
    """The first CLIP_S seconds of Jamendo's own mp31, stream-copied: the
    frames are Jamendo's bytes, the tags are dropped."""
    url = track["audio"]
    head, _ = j.fetch(url, {"Range": "bytes=0-9"})
    tag = 0
    if head[:3] == b"ID3":
        tag = 10 + ((head[6] << 21) | (head[7] << 14) | (head[8] << 7) | head[9])
    want = tag + CLIP_S * 12000 + 64000
    data, ctype = j.fetch(url, {"Range": f"bytes=0-{want}"})
    raw = out.parent / f"{out.stem}.raw.mp3"
    raw.write_bytes(data)
    r = subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                        "-i", str(raw), "-t", str(CLIP_S), "-map", "0:a", "-c:a", "copy",
                        "-map_metadata", "-1", "-id3v2_version", "0", "-write_id3v1", "0",
                        "-fflags", "+bitexact", "-flags", "+bitexact", str(out)],
                       capture_output=True, text=True, encoding="utf-8", check=False)
    raw.unlink()
    if r.returncode != 0:
        raise SystemExit(f"gen-catalogue: ffmpeg could not trim track {track['id']}: "
                         f"{r.stderr.strip()}")
    return probe(out), ctype


def probe(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                        "format=duration,bit_rate:stream=codec_name,sample_rate",
                        "-of", "json", str(path)],
                       capture_output=True, text=True, encoding="utf-8", check=False)
    if r.returncode != 0:
        raise SystemExit(f"gen-catalogue: ffprobe refused {path.name}: {r.stderr.strip()}")
    return json.loads(r.stdout)


def mirror(url):
    """Jamendo's address as the mirror's, or the address itself when it is
    a credit link the mirror does not serve."""
    parts = urllib.parse.urlsplit(url)
    q = dict(urllib.parse.parse_qsl(parts.query))
    host = parts.netloc
    if host.endswith("storage.jamendo.com") and "trackid" in q:
        return f"/catalogue/storage/?trackid={q['trackid']}&format=mp31"
    if host == "usercontent.jamendo.com" and q.get("type") in KINDS:
        return f"/catalogue/usercontent?type={q['type']}&id={q['id']}&width={q.get('width', '300')}"
    m = re.match(r"^/albums/s\d+/(\d+)/covers/", parts.path)
    if host == "images.jamendo.com" and m:
        return f"/catalogue/usercontent?type=album&id={m.group(1)}&width=300"
    return url


def rewrite(node, durations):
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            if k in STRIPPED:
                continue
            v = rewrite(v, durations)
            if k == "duration" and node.get("id") in durations:
                v = type(v)(durations[node["id"]])
            out[k] = v
        return out
    if isinstance(node, list):
        return [rewrite(v, durations) for v in node]
    if isinstance(node, str) and node.startswith("http"):
        return mirror(node)
    return node


def artist_cover(artist, albums):
    """The snapshot album whose cover stands for `artist`'s image: Jamendo's
    artist images carry no licence (docs/traps.md, the client id entry), so
    the first of the artist's own albums in the snapshot whose every track
    is CC BY or BY-SA. `albums` is [(album id, artist id, [licence URL])]."""
    for album, owner, held in albums:
        if owner == artist and held and all(licensed(u) for u in held):
            return album
    raise ValueError(f"artist {artist} has no CC BY or BY-SA album in the snapshot to take "
                     f"its image from, and Jamendo's own artist image carries no licence")


def snapshot_albums(answers):
    """[(album id, artist id, [licence URL])] in the snapshot's album order."""
    held = {}
    for key, ans in answers.items():
        if key.startswith("albums/tracks?"):
            for r in ans["results"]:
                held[r["id"]] = (r["artist_id"], [t["license_ccurl"] for t in r["tracks"]])
    return [(a, *held[a]) for a in answers[META]["albums"] if a in held]


def search_keys(term):
    return [catalogue.canonical(endpoint, urllib.parse.urlencode(
        sorted({"limit": str(WIDE_LIMIT), field: term}.items()), quote_via=urllib.parse.quote))
        for endpoint, field in SEARCH_FIELDS]


def add_searches(j, log):
    """The searches the selection rule names that the committed api.json
    lacks, fetched and narrowed to the committed selection; every other
    answer and file is kept byte for byte."""
    answers = json.loads((FAMILY / catalogue.ANSWERS).read_text(encoding="utf-8"))
    meta = answers[META]
    terms = list(dict.fromkeys([*meta["searches"][:2], *SCENE_SEARCHES]))
    ids = {"track": set(meta["tracks"]), "album": set(meta["albums"]),
           "artist": set(meta["artists"])}
    _, held = tracks_of(answers)
    durations = {tid: int(t["duration"]) for tid, t in held.items()}
    for term in terms:
        for (endpoint, field), key in zip(SEARCH_FIELDS, search_keys(term)):
            if key in answers:
                continue
            got, raw = j.api(endpoint, limit=str(WIDE_LIMIT), **{field: term})
            if got != key:
                raise SystemExit(f"gen-catalogue: asked for {key} and Jamendo's key is {got}")
            answers[key] = rewrite(narrow(key, raw, ids), durations)
            log(f"{key}: {len(raw['results'])} result(s) on Jamendo, "
                f"{len(answers[key]['results'])} in the snapshot")
    meta["searches"] = terms
    return answers


def narrow(key, answer, ids):
    """Jamendo's answer with every item outside the snapshot removed."""
    endpoint = key.split("?", 1)[0]
    res = answer["results"]
    if endpoint == "tracks":
        res = [t for t in res if t["id"] in ids["track"]]
    elif endpoint == "albums":
        res = [a for a in res if a["id"] in ids["album"]]
    elif endpoint == "artists":
        res = [a for a in res if a["id"] in ids["artist"]]
    elif endpoint == "artists/albums":
        res = [{**a, "albums": [x for x in a["albums"] if x["id"] in ids["album"]]} for a in res]
    elif endpoint == "albums/tracks":
        res = [{**a, "tracks": [x for x in a["tracks"] if x["id"] in ids["track"]]} for a in res]
    else:
        raise SystemExit(f"gen-catalogue: no narrowing rule for {endpoint}")
    head = {k: v for k, v in answer["headers"].items() if k != "next"}
    head["results_count"] = len(res)
    return {"headers": head, "results": res}


def generate(j, out, log):
    s = select(j, log)
    out.mkdir(parents=True, exist_ok=True)
    durations = {}
    for t in s["tracks"]:
        info, ctype = clip(j, t, out / f"t{t['id']}.mp3")
        secs = float(info["format"]["duration"])
        durations[t["id"]] = round(secs)
        log(f"clip t{t['id']}.mp3: {secs:.2f} s, {info['streams'][0]['codec_name']} "
            f"{info['streams'][0]['sample_rate']} Hz, "
            f"{int(info['format']['bit_rate']) // 1000} kbps "
            f"(served as {ctype or 'no type'})")
    for name, data in s["images"].items():
        (out / name).write_bytes(data)
    ids = {"track": {t["id"] for t in s["tracks"]}, "album": {a["id"] for a in s["albums"]},
           "artist": {a["id"] for a in s["artists"]}}
    answers = {key: rewrite(narrow(key, ans, ids), durations)
               for key, ans in sorted(s["raw"].items())}
    answers[META] = {"taken": os.environ.get("KAYA_CATALOGUE_DATE") or
                     subprocess.run(["date", "-u", "+%Y-%m-%d"], capture_output=True, text=True,
                                    encoding="utf-8", check=True).stdout.strip(),
                     "genres": [g for g, _ in s["home"]], "home": [k for _, k in s["home"]],
                     "searches": s["searches"],
                     "artists": [a["id"] for a in s["artists"]],
                     "albums": [a["id"] for a in s["albums"]],
                     "tracks": [t["id"] for t in s["tracks"]],
                     "clip_s": CLIP_S}
    try:
        answers[META]["artist_images"] = {
            a["id"]: artist_cover(a["id"], snapshot_albums(answers)) for a in s["artists"]}
    except ValueError as e:
        raise SystemExit(f"gen-catalogue: {e}") from None
    text = json.dumps(answers, ensure_ascii=False, indent=1, sort_keys=True) + "\n"
    (out / catalogue.ANSWERS).write_text(text, encoding="utf-8")
    for name, body in docs(answers).items():
        (out / name).write_text(body, encoding="utf-8")
    leaked = [p.name for p in sorted(out.iterdir()) if j.cid.encode() in p.read_bytes()]
    if leaked:
        for p in out.iterdir():
            p.unlink()
        raise SystemExit(f"gen-catalogue: the client id reached {', '.join(leaked)}; "
                         f"nothing was kept")
    return s


def tracks_of(answers):
    """Every track the snapshot holds, by id, with its album and artist."""
    meta = answers[META]
    found = {}
    for key, ans in answers.items():
        if key == META:
            continue
        for r in ans["results"]:
            if key.startswith("albums/tracks?"):
                for t in r["tracks"]:
                    found.setdefault(t["id"], {**t, "album_id": r["id"], "album_name": r["name"],
                                               "artist_id": r["artist_id"],
                                               "artist_name": r["artist_name"]})
    return [found[t] for t in meta["tracks"] if t in found], found


def docs(answers):
    meta = answers[META]
    ordered, _ = tracks_of(answers)
    names = {}
    for key, ans in answers.items():
        if key.startswith("artists?id="):
            for a in ans["results"]:
                names[a["id"]] = (a["name"], a["shareurl"])
    rows = ["| track | artist | album | Jamendo page | licence |", "|---|---|---|---|---|"]
    for t in ordered:
        page = f"https://www.jamendo.com/track/{t['id']}"
        rows.append(f"| {t['name']} | {t['artist_name']} | {t['album_name']} | {page} | "
                    f"{t['license_ccurl']} |")
    titles = {t["album_id"]: t["album_name"] for t in ordered}
    covers = meta.get("artist_images", {})
    artists = [f"- {names[a][0]}: {names[a][1]}; image: the cover of "
               f"{titles.get(covers.get(a), '(none)')}" for a in meta["artists"] if a in names]
    attribution = f"""# catalogue — attribution

Music from Jamendo (https://www.jamendo.com), taken {meta['taken']} through
Jamendo's API v3. Every recording below is the artist's, under the Creative
Commons licence named in its row; each file here is the first
{meta['clip_s']} s of Jamendo's `mp31` stream (96 kbps MP3), trimmed and with
its tags removed, which is a change to the work (CC BY section 3(a)(1)(B)).
The covers are the albums' own, under the album's licence. Jamendo's artist
images carry no licence, so each artist's image here is the cover of one of
that artist's albums above (named below), never Jamendo's artist image.

{chr(10).join(rows)}

Artists:

{chr(10).join(artists)}
"""
    readme = f"""# catalogue — a Jamendo snapshot (docs/media-player-plan.md M2)

What the files are: the lanes' mirror of Jamendo for the media player demo,
served by tools/media-server.py at addresses shaped like Jamendo's through
tools/lib/catalogue.py:

- `t<track id>.mp3`: {len(meta['tracks'])} clips, the first {meta['clip_s']} s of each track's
  `mp31` stream, at `/catalogue/storage/?trackid=<id>&format=mp31` with no
  file extension, as Jamendo's own storage address has none.
- `album-<id>-<width>.jpg` (300 and 600 px): the covers, at
  `/catalogue/usercontent?type=album&id=<id>&width=<width>`. The artist
  image address `/catalogue/usercontent?type=artist&id=<id>&width=<width>`
  answers with the cover of the album `{META}.artist_images` names for that
  artist: the first of the artist's albums here whose every track is CC BY
  or CC BY-SA. Jamendo's own artist images carry no licence (one was the
  cover of a BY-NC-ND album), so none is in this snapshot.
- `api.json`: Jamendo's answers to the requests the demo makes, keyed by the
  request with `client_id` and `format` dropped and the parameters sorted,
  served at `/catalogue/v3.0/<endpoint>/?<query>` as `application/json`.
  Each answer is Jamendo's own with the items outside this snapshot removed,
  `headers.next` and `results_count` adjusted, the waveform and download
  fields dropped, durations set to the clips', and every storage and image
  address rewritten to the mirror's relative form. `{META}` records the
  selection.
- `ATTRIBUTION.md`: every track's title, artist, album, Jamendo page and
  licence, as CC BY requires.

Where they came from: Jamendo's API v3 (https://api.jamendo.com/v3.0/),
taken {meta['taken']} by tools/gen-catalogue.py with the maintainer's own
client id, which is personal under Jamendo's terms and in no file here.

The selection rule: for each genre in {', '.join(meta['genres'])}, Jamendo's
`tracks` chart (`order=popularity_week`, `ccnc=false`, `ccnd=false`) is walked
in order for the first artist not yet chosen who has an artist image address and two
albums whose every track is CC BY or CC BY-SA, with two tracks of at least
{meta['clip_s']} s each and JPEG covers: the album holding the chart's track
first, then the most recent other. Each album keeps its two tracks highest in
Jamendo's popularity among the artist's own tracks, the chart's track
first, and an artist whose tracks Jamendo will not list by popularity is
passed over (the artist page's top tracks are that list). The searches are
{', '.join(repr(s) for s in meta['searches'])}: the first artist's name, the first
track's title and tools/scenes/music_search.steps' terms.

The licence: CC BY or CC BY-SA per track, named in ATTRIBUTION.md; the
generator refuses any other, and `--check` refuses a committed answer naming
any other.

To regenerate: `tools/gen-catalogue.py` inside `nix develop` with a Jamendo
client id in `KAYA_JAMENDO_CLIENT_ID` or `~/.config/kaya/jamendo-client-id`
rewrites this directory; commit the result. Jamendo's catalogue moves, so a
regeneration may choose other music. A new or renamed file moves
tools/scenes/assets.steps' frozen census. `tools/gen-catalogue.py --check`
reads only these files (tools/check-assets.py runs it).
"""
    return {"README.md": readme, "ATTRIBUTION.md": attribution}


def addresses(node, key=None):
    if isinstance(node, dict):
        for k, v in node.items():
            yield from addresses(v, k)
    elif isinstance(node, list):
        for v in node:
            yield from addresses(v, key)
    elif isinstance(node, str) and (node.startswith("/") or "://" in node):
        yield key, node


def licences(node):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "license_ccurl":
                yield node.get("id", "?"), v
            yield from licences(v)
    elif isinstance(node, list):
        for v in node:
            yield from licences(v)


def check(family):
    """Findings for a committed family, read with no network."""
    bad = []
    f = family / catalogue.ANSWERS
    if not f.is_file():
        return [f"{f} is missing"], 0
    text = f.read_text(encoding="utf-8")
    answers = json.loads(text)
    if META not in answers:
        return [f"{catalogue.ANSWERS} has no {META} entry"], 0
    if "client_id" in text:
        bad.append(f"{catalogue.ANSWERS} names client_id — an echoed request address "
                   f"reached the snapshot, and with it someone's client id")
    named = set()
    held = 0
    for key, ans in answers.items():
        if key == META:
            continue
        if catalogue.canonical(*(key.split("?", 1) + [""])[:2]) != key:
            bad.append(f"answer key {key!r} is not canonical — the mirror would never find it")
        for _, lic in licences(ans):
            held += 1
        for field, url in addresses(ans):
            if url.startswith(catalogue.PREFIX):
                got = catalogue.resolve(url, answers, family)
                if got is None:
                    bad.append(f"{key}: {url} resolves to no file in {family.name}")
                elif got[0] == "file":
                    named.add(got[1].name)
            elif field not in CREDIT_KEYS:
                bad.append(f"{key}: {field} {url} is an address the mirror does not serve and "
                           f"not a credit link — the demo would leave the machine")
    for key, ans in answers.items():
        if key == META:
            continue
        for tid, lic in licences(ans):
            if not licensed(lic):
                bad.append(f"{key}: track {tid} is licensed {lic}, outside CC BY and CC BY-SA "
                           f"— the snapshot may carry only those (docs/media-player-plan.md M2)")
    meta = answers[META]
    for term in meta["searches"]:
        for key in search_keys(term):
            if key not in answers:
                bad.append(f"{META} names the search {term!r} and {key} has no answer — the "
                           f"app's search would fail against the mirror")
    for key in meta["home"]:
        if not answers.get(key, {}).get("results"):
            bad.append(f"Home's shelf {key} holds no track — the shelf would be empty")
    ordered, _ = tracks_of(answers)
    if [t["id"] for t in ordered] != meta["tracks"]:
        bad.append(f"{META} names {len(meta['tracks'])} tracks and the album answers hold "
                   f"{len(ordered)} of them")
    for t in meta["tracks"]:
        named.add(f"t{t}.mp3")
    for i in meta["albums"]:
        named.update(f"album-{i}-{w}.jpg" for w in WIDTHS["album"])
    covers = meta.get("artist_images", {})
    for artist in meta["artists"]:
        try:
            want_cover = artist_cover(artist, snapshot_albums(answers))
        except ValueError as e:
            bad.append(str(e))
            continue
        if covers.get(artist) != want_cover:
            bad.append(f"{META}.artist_images names album {covers.get(artist)} for artist "
                       f"{artist}, and the rule names {want_cover}")
    on_disk = {p.name for p in family.iterdir() if p.is_file()}
    want = named | {catalogue.ANSWERS, *DOCS}
    bad += [f"{n}: in {family.name} and named by no answer" for n in sorted(on_disk - want)]
    bad += [f"{n}: named by the snapshot and not in {family.name}" for n in sorted(want - on_disk)]
    for n in sorted(on_disk & named):
        data = (family / n).read_bytes()
        if n.endswith(".jpg") and not is_jpeg(data):
            bad.append(f"{n}: is not a JPEG")
        framed = len(data) > 2 and data[0] == 0xFF and data[1] & 0xE0 == 0xE0
        if n.endswith(".mp3") and not framed:
            bad.append(f"{n}: does not begin with an MPEG audio frame")
    for name, body in docs(answers).items():
        p = family / name
        if not p.is_file() or p.read_text(encoding="utf-8") != body:
            bad.append(f"{name}: differs from what tools/gen-catalogue.py writes for this "
                       f"{catalogue.ANSWERS}")
    if held < len(meta["tracks"]):
        bad.append(f"read {held} licence(s) for {len(meta['tracks'])} tracks — a reader that "
                   f"reads no licence refuses none")
    return bad, len(on_disk)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--against", type=pathlib.Path, default=FAMILY)
    ap.add_argument("--dry", action="store_true")
    ap.add_argument("--add-searches", action="store_true")
    args = ap.parse_args()
    if args.check:
        bad, n = check(args.against)
        if bad:
            for b in bad:
                print(f"gen-catalogue: {b}", file=sys.stderr)
            print(f"gen-catalogue: FAIL — {len(bad)} finding(s) over {n} files", file=sys.stderr)
            raise SystemExit(1)
        print(f"gen-catalogue: OK — {n} files, every address resolved, every licence BY or BY-SA")
        return
    j = Jamendo(client_id())

    def log(line):
        print(f"gen-catalogue: {j.scrub(line)}", flush=True)

    if args.add_searches:
        answers = add_searches(j, log)
        text = json.dumps(answers, ensure_ascii=False, indent=1, sort_keys=True) + "\n"
        with scratch_dir("kaya-gen-catalogue-") as d:
            fresh = d / "catalogue"
            shutil.copytree(FAMILY, fresh)
            (fresh / catalogue.ANSWERS).write_text(text, encoding="utf-8")
            for name, body in docs(answers).items():
                (fresh / name).write_text(body, encoding="utf-8")
            if any(j.cid.encode() in p.read_bytes() for p in fresh.iterdir()):
                raise SystemExit("gen-catalogue: the client id reached the snapshot; "
                                 "nothing was written")
            bad, n = check(fresh)
            if bad:
                for b in bad:
                    print(f"gen-catalogue: {b}", file=sys.stderr)
                raise SystemExit("gen-catalogue: the snapshot with the searches added fails "
                                 "its own --check; nothing was written")
            for name in (catalogue.ANSWERS, *DOCS):
                shutil.copyfile(fresh / name, FAMILY / name)
        log(f"wrote {catalogue.ANSWERS} and the docs in {j.calls} API calls")
        return
    if args.dry:
        s = select(j, log)
        log(f"{len(s['tracks'])} tracks, {len(s['albums'])} albums, {len(s['artists'])} artists, "
            f"{j.calls} API calls")
        return
    with scratch_dir("kaya-gen-catalogue-") as d:
        fresh = d / "catalogue"
        generate(j, fresh, log)
        bad, n = check(fresh)
        if bad:
            for b in bad:
                print(f"gen-catalogue: {b}", file=sys.stderr)
            raise SystemExit("gen-catalogue: the fresh snapshot fails its own --check; "
                             "nothing was written")
        if FAMILY.exists():
            shutil.rmtree(FAMILY)
        shutil.copytree(fresh, FAMILY)
    total = sum(p.stat().st_size for p in FAMILY.iterdir())
    log(f"wrote {n} files, {total} bytes, to {FAMILY.relative_to(ROOT)} in {j.calls} API calls")


main()
