"""The site arm: the two files each declared web host serves
(docs/app-links-plan.md L1, docs/autofill-plan.md A8). No lane serves
them; the DEFER web-links entry in docs/deferred.md says what a hand
measurement needs."""

import json
import pathlib
import re

from .identity import Undeclared, apple_site_association, asset_links, load

FINGERPRINT = re.compile(r"([0-9A-F]{2}:){31}[0-9A-F]{2}")
TEAM_ID = re.compile(r"[A-Z0-9]{10}")


def write(root, out_dir, team_id, package, fingerprints):
    """`<out>/<host>/.well-known/{apple-app-site-association,
    assetlinks.json}` for every declared host; the paths written."""
    declared = load(root)
    if not declared.hosts:
        raise Undeclared(
            "package site: guests/assets/identity.toml declares no "
            "`[links] hosts`, so there is no site to write files for")
    if not TEAM_ID.fullmatch(team_id or ""):
        raise Undeclared(
            f"package site: --team-id {team_id!r} is not an Apple team id "
            f"(ten capitals and digits); the association names "
            f"<team>.{declared.id}")
    bad = [f for f in fingerprints if not FINGERPRINT.fullmatch(f)]
    if not package or not fingerprints or bad:
        raise Undeclared(
            f"package site: assetlinks.json needs the APK's package and "
            f"its signing certificate's SHA-256 as 32 colon-separated hex "
            f"pairs (`keytool -list -v`); got package {package!r} and "
            f"{bad or fingerprints or 'no fingerprint'}")
    written = []
    for host in declared.hosts:
        well_known = pathlib.Path(out_dir) / host.removeprefix("*.") \
            / ".well-known"
        well_known.mkdir(parents=True, exist_ok=True)
        for name, body in (
                ("apple-app-site-association",
                 apple_site_association(declared, team_id)),
                ("assetlinks.json",
                 asset_links(declared, host.removeprefix("*."), package,
                             fingerprints))):
            path = well_known / name
            path.write_text(json.dumps(body, indent=2) + "\n",
                            encoding="utf-8")
            written.append(path)
    return written
