"""The Jamendo mirror's one resolver (docs/media-player-plan.md M2): a
mirror address to the file in guests/assets/catalogue that answers it.
tools/media-server.py serves through it and tools/gen-catalogue.py --check
resolves every address the snapshot names through it, so the two cannot
disagree about what the mirror answers."""

import json
import pathlib
import re
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
FAMILY = ROOT / "guests" / "assets" / "catalogue"
PREFIX = "/catalogue/"
API = PREFIX + "v3.0/"
ANSWERS = "api.json"
DROPPED = ("client_id", "format")
KIND = re.compile(r"^(album|artist)$")
NUMBER = re.compile(r"^\d{1,12}$")


def canonical(endpoint, query):
    """The answers' key for one API request: the endpoint without slashes
    and the query sorted, with the client id and `format` (json, the only
    one the mirror holds) dropped."""
    pairs = [(k, v) for k, v in urllib.parse.parse_qsl(query, keep_blank_values=True)
             if k not in DROPPED]
    q = urllib.parse.urlencode(sorted(pairs), quote_via=urllib.parse.quote)
    return endpoint.strip("/") + ("?" + q if q else "")


def resolve(address, answers=None, family=FAMILY):
    """(kind, payload, content type) for a mirror address, or None.

    kind "file" carries a path, kind "answer" the JSON bytes. `answers`
    is the parsed api.json, read from `family` when not given. An artist's
    image is the cover of the album `_snapshot.artist_images` names for it
    (docs/media-player-plan.md M2)."""
    parts = urllib.parse.urlsplit(address)
    path, query = parts.path, parts.query
    if not path.startswith(PREFIX):
        return None
    if answers is None:
        f = family / ANSWERS
        if not f.is_file():
            return None
        answers = json.loads(f.read_text(encoding="utf-8"))
    if path.startswith(API):
        key = canonical(path[len(API):], query)
        if key not in answers:
            return None
        body = json.dumps(answers[key], ensure_ascii=False, indent=1).encode("utf-8")
        return "answer", body, "application/json"
    q = dict(urllib.parse.parse_qsl(query))
    rest = path[len(PREFIX):].strip("/")
    if rest == "storage":
        if not NUMBER.match(q.get("trackid", "")) or q.get("format") != "mp31":
            return None
        name, ctype = f"t{q['trackid']}.mp3", "audio/mpeg"
    elif rest == "usercontent":
        if (not KIND.match(q.get("type", "")) or not NUMBER.match(q.get("id", ""))
                or not NUMBER.match(q.get("width", ""))):
            return None
        album = q["id"]
        if q["type"] == "artist":
            album = answers.get("_snapshot", {}).get("artist_images", {}).get(q["id"])
            if album is None:
                return None
        name, ctype = f"album-{album}-{q['width']}.jpg", "image/jpeg"
    else:
        return None
    f = family / name
    return ("file", f, ctype) if f.is_file() else None


def key_of(address):
    """The answers' key a miss would have needed, for the server's log."""
    parts = urllib.parse.urlsplit(address)
    if parts.path.startswith(API):
        return canonical(parts.path[len(API):], parts.query)
    return parts.path
