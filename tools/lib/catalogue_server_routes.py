"""docs/media-player-plan.md M2: the media server answers the Jamendo
snapshot at Jamendo's own address shapes, the audio with no file extension.

A mirror that served `t<id>.mp3` would pass a scene the person's app then
fails against Jamendo, whose storage address has no extension, and a mirror
that dropped Range would pass on a player that never seeks. So the REAL
server is started on a free port and every address the snapshot names is
fetched from it; the resolver's own negatives run against doctored copies of
tools/lib/catalogue.py through the same probes, and the server's routing
lines are held by text with their cuts watched."""

import json
import socket
import urllib.error
import urllib.parse
import urllib.request

import media_server
from kaya_gate import ROOT

RESOLVER = "tools/lib/catalogue.py"
SERVER = "tools/media-server.py"
FAMILY = ROOT / "guests" / "assets" / "catalogue"
SERVER_NEEDS = [
    ("import catalogue", "the resolver's import"),
    ('".json": "application/json"', "the JSON type"),
    ("        elif self.path.startswith(catalogue.PREFIX):\n"
     "            self._catalogue(send_body)\n"
     "        elif self.path.startswith(TRICKLE):",
     "/catalogue/ routed ahead of /trickle/ and the files"),
    ("got = catalogue.resolve(self.path)", "the one resolver asked for every /catalogue/ address"),
    ("            self._head(send_body, payload, ctype)",
     "a snapshot file answered through the Range path"),
]


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind((media_server.HOST, 0))
        return s.getsockname()[1]


def http_fetch(base):
    def fetch(address, headers=None):
        req = urllib.request.Request(base + address, headers=headers or {})
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, r.headers.get("Content-Type", ""), \
                    r.headers.get("Content-Range", ""), r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.headers.get("Content-Type", ""), "", b""
    return fetch


def resolver_fetch(space):
    """The server's answer as tools/media-server.py composes it from a
    resolver, without a socket, for the doctored resolvers."""
    def fetch(address, headers=None):
        got = space["resolve"](address)
        if got is None:
            return 404, "", "", b""
        kind, payload, ctype = got
        if kind == "answer":
            return 200, ctype, "", payload
        data = payload.read_bytes()
        rng = (headers or {}).get("Range", "")
        if rng.startswith("bytes="):
            a, b = rng[6:].split("-")
            end = min(int(b), len(data) - 1)
            return 206, ctype, f"bytes {a}-{end}/{len(data)}", data[int(a):end + 1]
        return 200, ctype, "", data
    return fetch


def named_addresses(node):
    if isinstance(node, dict):
        for v in node.values():
            yield from named_addresses(v)
    elif isinstance(node, list):
        for v in node:
            yield from named_addresses(v)
    elif isinstance(node, str) and node.startswith("/catalogue/"):
        yield node


def findings(fetch, answers, family=FAMILY):
    """(findings, addresses fetched) for one way of answering."""
    out = []
    fetched = 0
    meta = answers["_snapshot"]
    for key, want in sorted(answers.items()):
        if key == "_snapshot":
            continue
        endpoint, _, query = key.partition("?")
        pairs = urllib.parse.parse_qsl(query) + [("client_id", "probe00"), ("format", "json")]
        asked = (f"/catalogue/v3.0/{endpoint}/?"
                 + urllib.parse.urlencode(list(reversed(pairs)), quote_via=urllib.parse.quote))
        status, ctype, _, body = fetch(asked)
        fetched += 1
        if status != 200 or ctype != "application/json":
            out.append(f"{asked} answered {status} {ctype or 'no type'}, wanted 200 "
                       f"application/json: the app's request, with its client id and the "
                       f"parameters in its own order, must find the snapshot's answer {key}")
        elif json.loads(body) != want:
            out.append(f"{asked} answered a body other than the snapshot's {key}")
    addresses = sorted(set(named_addresses({k: v for k, v in answers.items() if k != "_snapshot"})))
    audio = [a for a in addresses if a.startswith("/catalogue/storage")]
    images = [a for a in addresses if a.startswith("/catalogue/usercontent")]
    if len(audio) != len(meta["tracks"]):
        out.append(f"the answers name {len(audio)} audio address(es) for "
                   f"{len(meta['tracks'])} tracks")
    for a in audio:
        path = urllib.parse.urlsplit(a).path
        if "." in path.rsplit("/", 1)[-1] or not path.endswith("/"):
            out.append(f"{a}: an audio address with a file name — Jamendo's has none, so a "
                       f"player that types by extension would pass here and fail there")
        trackid = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(a).query))["trackid"]
        size = (family / f"t{trackid}.mp3").stat().st_size
        status, ctype, crange, body = fetch(a, {"Range": "bytes=0-1"})
        fetched += 1
        if status != 206 or ctype != "audio/mpeg" or crange != f"bytes 0-1/{size}" or len(body) != 2:
            out.append(f"{a} answered a Range request with {status} {ctype or 'no type'} "
                       f"{crange or 'no Content-Range'} and {len(body)} byte(s), wanted 206 "
                       f"audio/mpeg bytes 0-1/{size}: AVPlayer refuses a server without Range")
        wrong = a.replace("format=mp31", "format=mp32")
        if fetch(wrong)[0] != 404:
            out.append(f"{wrong} was answered: the snapshot holds mp31 alone, and answering "
                       f"another format serves the app bytes it did not ask for")
    for a in images:
        status, ctype, _, body = fetch(a)
        fetched += 1
        q = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(a).query))
        album = q["id"] if q["type"] == "album" else meta["artist_images"].get(q["id"])
        cover = family / f"album-{album}-{q['width']}.jpg"
        want = cover.read_bytes() if cover.is_file() else None
        if status != 200 or ctype != "image/jpeg" or body != want:
            out.append(f"{a} answered {status} {ctype or 'no type'} and {len(body)} byte(s), "
                       f"wanted 200 image/jpeg and {cover.name}: an artist's image is the "
                       f"cover of its album in _snapshot.artist_images, never a picture of "
                       f"its own")
    artist_images = [a for a in images if "type=artist" in a]
    if len(artist_images) < len(meta["artists"]):
        out.append(f"the answers name {len(artist_images)} artist image address(es) for "
                   f"{len(meta['artists'])} artists")
    miss = "/catalogue/v3.0/tracks/?id=0&client_id=probe00"
    if fetch(miss)[0] != 404:
        out.append(f"{miss} was answered: a request the snapshot never took must be a 404, "
                   f"which the server logs with the key a scene author would add")
    return out, fetched, len(audio), len(images)


def server_findings(text):
    return [f"{SERVER} lacks {what}: {needle!r}" for needle, what in SERVER_NEEDS
            if needle not in text]


def doctored(g, label, pattern, repl):
    text = g.doctor(f"catalogue server: {label}", g.read(RESOLVER), pattern, repl)
    space = {"__file__": str(ROOT / RESOLVER), "__name__": "catalogue_probe"}
    exec(compile(text, RESOLVER, "exec"), space)
    return space


def run(g):
    answers = json.loads((FAMILY / "api.json").read_text(encoding="utf-8"))
    port = free_port()
    with media_server.serving(port=port) as base:
        out, fetched, audio, images = findings(http_fetch(base), answers)
    g.counted("catalogue server: snapshot addresses fetched from the real server", fetched,
              floor=40)
    g.counted("catalogue server: extensionless audio addresses", audio, floor=12)
    g.counted("catalogue server: image addresses", images, floor=12)
    for line in out:
        g.finding(line)
    server_text = g.read(SERVER)
    for line in server_findings(server_text):
        g.finding(line)
    g.counted("catalogue server: clauses held", len(SERVER_NEEDS) + 6, floor=10)
    space = doctored(g, "the resolver as written", r"^", "")
    if findings(resolver_fetch(space), answers)[0]:
        g.refuse("the in-process resolver probe refuses the real resolver, so its negatives "
                 "below would prove nothing")
    cuts = [
        ("the client id kept in the key", r'DROPPED = \("client_id", "format"\)',
         'DROPPED = ("format",)', "must find the snapshot's answer"),
        ("the key left unsorted", r"urlencode\(sorted\(pairs\)", "urlencode((pairs)",
         "must find the snapshot's answer"),
        ("the audio served as octet-stream", r'"audio/mpeg"', '"application/octet-stream"',
         "wanted 206 audio/mpeg"),
        ("every format answered", r' or q\.get\("format"\) != "mp31"', "",
         "the snapshot holds mp31 alone"),
        ("the storage route keyed on a file name", r'if rest == "storage":',
         'if rest == "storage.mp3":', "answered a Range request with 404"),
        ("the artist served its own picture", r'album = answers\.get\("_snapshot", \{\}\)'
         r'\.get\("artist_images", \{\}\)\.get\(q\["id"\]\)',
         'album = "artist-" + q["id"]', "never a picture of its own"),
    ]
    for label, pattern, repl, want in cuts:
        space = doctored(g, label, pattern, repl)
        g.negative(f"catalogue server: {label}",
                   lambda space=space: findings(resolver_fetch(space), answers)[0], want=want)
    server_cuts = [
        ("no /catalogue/ route",
         r"        elif self\.path\.startswith\(catalogue\.PREFIX\):\n"
         r"            self\._catalogue\(send_body\)\n", "", "routed ahead of /trickle/"),
        ("no JSON type", r'\n    "\.json": "application/json",', "", "lacks the JSON type"),
        ("a snapshot file written without Range",
         r"            self\._head\(send_body, payload, ctype\)",
         "            self.wfile.write(payload.read_bytes())", "through the Range path"),
    ]
    for label, pattern, repl, want in server_cuts:
        broken = g.doctor(f"catalogue server: {label}", server_text, pattern, repl)
        g.negative(f"catalogue server: {label}",
                   lambda broken=broken: server_findings(broken), want=want)
    tampered = dict(answers)
    first = next(k for k in sorted(answers) if k.startswith("albums/tracks?"))
    body = json.loads(json.dumps(answers[first]))
    body["results"][0]["tracks"][0]["audio"] = "/catalogue/storage/t0.mp3?trackid=" + \
        body["results"][0]["tracks"][0]["id"] + "&format=mp31"
    tampered[first] = body
    g.negative("catalogue server: an audio address given a file name",
               lambda: findings(resolver_fetch(doctored(g, "the resolver for the named audio",
                                                        r"^", "")), tampered)[0],
               want="an audio address with a file name")
    return len(cuts) + len(server_cuts) + 1
