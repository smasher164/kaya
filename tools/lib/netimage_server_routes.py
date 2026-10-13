"""docs/network-images-plan.md §5: the lanes start the media server for every
scene that fetches from it, and the server answers what those scenes ask.

A lane that tests `startswith("media_")` for itself starts no server for a
`netimage_http` leg, and the leg then reads a refused connection as the
failed phase it expects from /status/: green with nothing served. So every
lane asks tools/lib/media_server.py's `serves`, and the server keeps the
covers family, /status/ and the image types the scene reads."""

import re

from kaya_gate import ROOT

PREDICATE = "tools/lib/media_server.py"
SERVER = "tools/media-server.py"
SELF = "tools/lib/netimage_server_routes.py"
CALLERS = {
    "tools/validate-mac.py": 1,
    "tools/lib/lanes/mac.py": 1,
    "tools/run-leg.py": 1,
    "tools/ios/run-sim.py": 2,
    "tools/android/run-emulator.py": 3,
    "tools/lib/lanes/win.py": 1,
}
SPELLED = re.compile(r"""startswith\(\s*\(?\s*["']media_""")
EXEMPT = {
    ("tools/ios/run-sim.py", 'elif parts and parts[0].startswith("media_"):'):
        "a driver VERB's name (media_key, media_route), not a scene",
}
SERVER_NEEDS = [
    ('".jpg": "image/jpeg"', "the JPEG type"),
    ('".jpeg": "image/jpeg"', "the JPEG type's long suffix"),
    ('".png": "image/png"', "the PNG type"),
    ('FAMILIES = {"covers": ROOT / "guests" / "assets" / "covers"}', "the covers family"),
    ('STATUS = re.compile(r"^/status/(\\d{3})(?:/|$)")', "the /status/<code>/ route"),
    ('        status = STATUS.match(self.path)\n        if status:\n'
     '            self._status(int(status.group(1)))\n        elif self.path.startswith(TRICKLE):',
     "/status/ routed ahead of /trickle/ and the files"),
    ('self.send_header("Content-Length", "0")\n        self.send_header("Connection", "close")',
     "a status answer with no body that closes"),
    ('closed by the client', "the trickle's log of a client that let go"),
]


def predicate_findings(text):
    space = {"__file__": str(ROOT / PREDICATE), "__name__": "media_server_probe"}
    exec(compile(text, PREDICATE, "exec"), space)
    serves = space.get("serves")
    if serves is None:
        return [f"{PREDICATE} no longer defines serves(scene) — every lane asks it"]
    out = []
    for name, want in [("media_formats", True), ("media_formats-rust", True),
                       ("netimage_http", True), ("netimage_http-go", True),
                       ("netimage", False), ("media", False)]:
        if bool(serves(name)) != want:
            out.append(f"{PREDICATE}: serves({name!r}) answers {not want}, wanted {want}")
    return out


def findings(sources):
    out = predicate_findings(sources[PREDICATE])
    for rel, text in sorted(sources.items()):
        if rel in (PREDICATE, SERVER, SELF):
            continue
        for n, line in enumerate(text.splitlines(), 1):
            if SPELLED.search(line):
                if (rel, line.strip()) in EXEMPT:
                    continue
                out.append(f"{rel}:{n} spells the server's condition as a prefix of its own "
                           f"({line.strip()}); ask media_server.serves(scene)")
        if rel in CALLERS:
            got = text.count("media_server.serves(")
            if got != CALLERS[rel]:
                out.append(f"{rel} asks media_server.serves( {got} time(s), wanted "
                           f"{CALLERS[rel]}: a lane site that stopped asking starts no server")
    for (rel, line), why in EXEMPT.items():
        if line not in sources.get(rel, ""):
            out.append(f"stale exemption: {rel} no longer holds {line!r} ({why})")
    for needle, what in SERVER_NEEDS:
        if needle not in sources[SERVER]:
            out.append(f"{SERVER} lacks {what}: {needle!r}")
    if not (ROOT / "guests/assets/covers").is_dir():
        out.append("guests/assets/covers is gone, and the server serves it under /covers/")
    return out


def run(g):
    rels = [PREDICATE, SERVER, *CALLERS]
    walked = g.counted("netimage server: tools/ python files read",
                       g.walk("*.py", under="tools"), floor=100)
    rels += sorted({p.relative_to(ROOT).as_posix() for p in walked} - set(rels))
    sources = {rel: (ROOT / rel).read_text(encoding="utf-8") for rel in rels}
    g.counted("netimage server: clauses held",
              6 + len(CALLERS) + len(EXEMPT) + len(SERVER_NEEDS) + 1, floor=20)
    for line in findings(sources):
        g.finding(line)
    for rel, n in CALLERS.items():
        broken = g.doctor(f"netimage server: {rel} spells media_ itself", sources[rel],
                          r"media_server\.serves\(((?:[^()]|\([^()]*\))*)\)",
                          r'\1.startswith("media_")', want=n)
        g.negative(f"netimage server: {rel} spells media_ itself",
                   lambda rel=rel, broken=broken: findings({**sources, rel: broken}),
                   want="spells the server's condition")
    cuts = [
        (PREDICATE, "the predicate without netimage_http",
         r'SERVED = \("media_", "netimage_http"\)',
         'SERVED = ("media_",)', "serves('netimage_http') answers False"),
        (SERVER, "no JPEG type", r'\n    "\.jpg": "image/jpeg",', "", "lacks the JPEG type"),
        (SERVER, "no PNG type", r'\n    "\.png": "image/png",', "", "lacks the PNG type"),
        (SERVER, "no /status/ route", r"status = STATUS\.match\(self\.path\)",
         "status = None", "lacks /status/ routed"),
        (SERVER, "no covers family", r'FAMILIES = \{"covers": [^}]*\}', "FAMILIES = {}",
         "lacks the covers family"),
        ("tools/ios/run-sim.py", "the exempt verb site renamed",
         r'parts\[0\]\.startswith\("media_"\)', 'parts[0].startswith("mediakey_")',
         "stale exemption"),
    ]
    for rel, label, pattern, repl, want in cuts:
        broken = g.doctor(f"netimage server: {label}", sources[rel], pattern, repl)
        g.negative(f"netimage server: {label}",
                   lambda rel=rel, broken=broken: findings({**sources, rel: broken}), want=want)
