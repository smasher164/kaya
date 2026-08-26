#!/usr/bin/env bash

kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi

# Every dependency this repo resolves over the network names an exact
# version. Gradle, NuGet, SwiftPM, the container's opam index and the
# Windows App SDK curl have no lockfile the way cargo and nix do, so one
# dynamic version (`1.9.+`, `latest.release`, `*`, a range) and the lane
# depends on what a server chose today. NOT a lockfile mechanism — the
# guard that keeps the existing exact versions exact.
#
# The fifth clause carries a second rule the other four do not: a curl
# names bytes as well as a version, so tools/fetch-winappsdk.sh records
# each package's sha256 and this gate holds BOTH, plus the verification
# itself — cut out of that script and run against wrong bytes on every
# sweep.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

findings=$(python3 - "$ROOT" <<'PY'
import hashlib
import pathlib
import re
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
out = []

# A version is concrete when it is literally the version. Anything that
# asks a server to choose — a range, a wildcard, a "latest" — is not.
DYNAMIC = re.compile(r"[+*]|latest\.|^[\[(]|,")


def concrete(v):
    return bool(v) and not DYNAMIC.search(v)


def logical_lines(text):
    """Shell continuations joined, each yielded with its FIRST physical
    line number. A scanner that reads physical lines judges a
    backslash-continued command and its flags as separate statements —
    which is how a flag two lines down reads as a flag that is not
    there. Not hypothetical: this clause shipped that way for ten
    minutes and reported OK on an invocation missing its flag."""
    joined, start, buf = [], None, []
    for n, line in enumerate(text.splitlines(), 1):
        if start is None:
            start = n
        if line.endswith("\\"):
            buf.append(line[:-1])
            continue
        buf.append(line)
        joined.append((start, " ".join(p.strip() for p in buf)))
        start, buf = None, []
    if buf:
        joined.append((start, " ".join(p.strip() for p in buf)))
    return joined


# --- Gradle: plugin ids and dependency coordinates ---------------------
PLUGIN = re.compile(r'id\("([^"]+)"\)\s+version\s+"([^"]+)"')
COORD = re.compile(r'"([A-Za-z0-9_.\-]+:[A-Za-z0-9_.\-]+(?::[^"]*)?)"')

for f in sorted(root.glob("android/**/*.gradle.kts")):
    text = f.read_text()
    # A platform(...) BOM supplies versions for coordinates that omit
    # one, so a version-less coordinate is legal only alongside a BOM.
    has_bom = "platform(" in text
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("//"):
            continue
        for name, version in PLUGIN.findall(line):
            if not concrete(version):
                out.append(f"{f}:{n}: plugin {name} version {version!r} is not a fixed version")
        for coord in COORD.findall(line):
            parts = coord.split(":")
            if len(parts) == 3:
                if not concrete(parts[2]):
                    out.append(f"{f}:{n}: {coord} is not a fixed version")
            elif len(parts) == 2 and not has_bom:
                out.append(f"{f}:{n}: {coord} has no version and no platform() BOM in this file")

# --- NuGet: PackageReference ------------------------------------------
PKGREF = re.compile(r'<PackageReference\s+Include="([^"]+)"\s+Version="([^"]+)"')
for f in sorted(root.rglob("*.csproj")):
    if "target" in f.relative_to(root).parts or "obj" in f.relative_to(root).parts:
        continue
    for n, line in enumerate(f.read_text().splitlines(), 1):
        for name, version in PKGREF.findall(line):
            if not concrete(version):
                out.append(f"{f}:{n}: nuget {name} version {version!r} is not a fixed version")

# --- opam: the container's OCaml packages ------------------------------
# opam-repository is a ROLLING index: every name must carry its version
# (pkg.version), and the index itself must be pinned to a commit — the
# version pins alone do not constrain transitive resolution.
dockerfile = root / "tools/linux/Dockerfile"
text = dockerfile.read_text()
# Join continuations so a wrapped install line reads as one.
joined = text.replace("\\\n", " ")
for n, line in enumerate(joined.splitlines(), 1):
    if line.lstrip().startswith("#") or "opam install" not in line:
        continue
    args = line.split("opam install", 1)[1].split()
    for a in args:
        if a.startswith("-"):
            continue
        if "." not in a:
            out.append(f"{dockerfile}: opam install {a} does not name a version (want {a}.X.Y.Z)")
if not re.search(r"opam-repository/archive/[0-9a-f]{40}\.tar\.gz", text):
    out.append(f"{dockerfile}: the opam index is not pinned to a commit")

# --- SwiftPM: Package.resolved is the pin, so it must be honoured -----
# Package.swift declares RANGES, so Package.resolved is the pin. Two
# halves: it is checked in, and every invocation refuses to resolve
# around it.
for f in sorted(root.rglob("Package.swift")):
    if ".build" in f.parts:
        continue
    if 'url:' in f.read_text() and not (f.parent / "Package.resolved").is_file():
        out.append(f"{f}: remote dependencies with no checked-in Package.resolved")

SWIFTPM = re.compile(r"swift\s+(?:run|build|test)\b")
for f in sorted(root.glob("tools/**/*.sh")):
    for n, line in logical_lines(f.read_text()):
        if line.lstrip().startswith("#") or not SWIFTPM.search(line):
            continue
        if "--disable-automatic-resolution" not in line:
            out.append(f"{f}:{n}: swiftpm invocation may re-resolve "
                       "(want --disable-automatic-resolution)")

# --- NuGet flat container: the Windows App SDK arrives by curl --------
# tools/fetch-winappsdk.sh resolves five packages straight out of nuget's
# flat container. No lockfile covers a curl and the PackageReference
# clause above cannot see it — the .csproj files in this tree are
# guest-side and tooling, not the backend (docs/canvas-plan.md §3.1) — so
# until this clause the Windows dependency door was guarded by nobody.
# Three rules: an exact version, a recorded sha256, and a script that
# still checks the hash it recorded, cache included.
FETCHER = root / "tools/fetch-winappsdk.sh"
SHA256 = re.compile(r"^[0-9a-f]{64}$")
CALL = re.compile(r"^fetch\s+\S")


def code_only(text):
    """Whole-line comments dropped. A commented-out call is not a call,
    and a comment naming curl is not a download."""
    return "\n".join(ln for ln in text.splitlines() if not ln.strip().startswith("#"))


def shell_body(text, name):
    """One shell function's body, brace-matched. `${...}` is stepped
    over so a parameter expansion cannot close the body early."""
    m = re.search(r"^" + name + r"\(\)\s*\{", text, re.M)
    if not m:
        return None
    i, depth, start = m.end() - 1, 0, None
    while i < len(text):
        if text[i] == "$" and text[i + 1:i + 2] == "{":
            i += 2
            continue
        if text[i] == "{":
            depth += 1
            if depth == 1:
                start = i + 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i]
        i += 1
    return None


def scan_fetcher(path, text):
    """Findings for one fetch script. A function because the watched
    negatives below run it against doctored copies of the real file."""
    bad, packages = [], 0
    for n, line in logical_lines(text):
        s = line.strip()
        if s.startswith("#") or not CALL.match(s):
            continue
        parts = s.split()
        if len(parts) != 4:
            # A call this cannot read is a finding naming the site, never
            # a skip: silence would read as clean.
            bad.append(f"{path}:{n}: `{s[:90]}` is not `fetch <Id> <version> <sha256>`")
            continue
        _, pid, version, sha = parts
        packages += 1
        if "$" in version or not concrete(version):
            bad.append(f"{path}:{n}: {pid} version {version!r} is not a fixed version")
        if "$" in sha or not SHA256.match(sha):
            bad.append(f"{path}:{n}: {pid} {version} records no sha256 (got {sha!r}) — "
                       "a version names a release, not the bytes that arrived")
    if packages < 3:
        bad.append(f"{path}: read {packages} package(s) — a census that reads almost "
                   "nothing agrees with almost anything, so this is the scan failing, "
                   "not the file passing")

    verify = shell_body(text, "verify_sha256")
    if verify is None:
        bad.append(f"{path}: no verify_sha256() — a hash nothing compares against is a comment")
    else:
        v = code_only(verify)
        if "shasum -a 256" not in v and "sha256sum" not in v:
            bad.append(f"{path}: verify_sha256() computes no sha256 — a size or mtime "
                       "check passes the same-length corruption a half-written body "
                       "produces (the tools/check-assets.sh staging rule)")
        if "return 1" not in v:
            bad.append(f"{path}: verify_sha256() never refuses (no `return 1`)")

    body = shell_body(text, "fetch")
    if body is None:
        bad.append(f"{path}: no fetch() to read")
    else:
        b = code_only(body)
        if "verify_sha256" not in b:
            bad.append(f"{path}: fetch() downloads without verifying — every package's "
                       "bytes are checked against the sha256 recorded beside its version")
        else:
            first_return = re.search(r"(?m)^\s*return\b", b)
            if first_return and first_return.start() < b.index("verify_sha256"):
                bad.append(f"{path}: fetch() can return before verify_sha256 — the CACHED "
                           "path is exactly the one a stale or doctored tree takes")
        inside = len(re.findall(r"\bcurl\b", b))
        total = len(re.findall(r"\bcurl\b", code_only(text)))
        if inside == 0:
            bad.append(f"{path}: fetch() runs no curl — this clause is reading the wrong function")
        if total != inside:
            bad.append(f"{path}: {total - inside} curl invocation(s) outside fetch(), "
                       "where no recorded hash is checked against what arrives")
    return bad


if not FETCHER.is_file():
    out.append(f"{FETCHER}: gone — the fifth clause reads it by name; if the Windows "
               "packages now arrive some other way, that way needs this clause")
    fetch_text = ""
else:
    fetch_text = FETCHER.read_text()
    out += scan_fetcher(FETCHER, fetch_text)

# THE VERIFIER ITSELF, CUT OUT AND RUN. Static text says a hash is
# compared; only running it says the comparison refuses. Both outcomes,
# and the refusal must print what it MEASURED (invariant 3).
verify_body = shell_body(fetch_text, "verify_sha256") if fetch_text else None
if verify_body is not None:
    payload = b"the bytes a download would have brought"
    good, wrong = hashlib.sha256(payload).hexdigest(), "0" * 64
    with tempfile.TemporaryDirectory() as td:
        pkg = pathlib.Path(td) / "package.nupkg"
        pkg.write_bytes(payload)
        probe = pathlib.Path(td) / "verify.sh"
        probe.write_text("set -uo pipefail\nverify_sha256() {" + verify_body + "}\n"
                         'verify_sha256 "$1" "$2" "probe-package 9.9.9"\n')
        accept = subprocess.run(["bash", str(probe), str(pkg), good],
                                capture_output=True, text=True)
        refuse = subprocess.run(["bash", str(probe), str(pkg), wrong],
                                capture_output=True, text=True)
    if accept.returncode != 0:
        out.append(f"{FETCHER}: verify_sha256 refused bytes that DO match their hash "
                   f"(exit {accept.returncode}): {(accept.stdout + accept.stderr).strip()[:200]}")
    if refuse.returncode == 0:
        out.append(f"{FETCHER}: verify_sha256 ACCEPTED bytes that do not match their hash")
    said = refuse.stdout + refuse.stderr
    for token, what in ((good, "the hash it measured"),
                        (wrong, "the hash it was handed"),
                        ("probe-package 9.9.9", "the package")):
        if token not in said:
            out.append(f"{FETCHER}: verify_sha256's refusal does not name {what} — a "
                       "diagnostic prints what it measured, or the next reader chases "
                       f"a sentence that cannot discriminate: {said.strip()[:200]}")

# A NEW DOOR. This clause reads ONE script by name, so a second script
# that resolves a package from the same flat container would be invisible
# to it — the shape the whole finding is about.
KNOWN_FETCHERS = {"tools/fetch-winappsdk.sh"}
for f in sorted(root.glob("tools/**/*.sh")):
    rel = f.relative_to(root).as_posix()
    # This file names the host in its own clause; a gate that scans a
    # directory scans itself (docs/traps.md).
    if rel in KNOWN_FETCHERS or rel == "tools/check-pins.sh":
        continue
    if "api.nuget.org" in f.read_text():
        out.append(f"{f}: resolves a package from nuget's flat container, and check-pins "
                   "reads " + " ".join(sorted(KNOWN_FETCHERS)) + " only — give it the "
                   "same `fetch <Id> <version> <sha256>` shape and add it to "
                   "KNOWN_FETCHERS, or route the download through the existing fetcher")

# WATCHED NEGATIVES, on doctored copies of the real file: every
# perturbation is proven to have applied (counts printed) and every one
# must be refused. A hash rule believed but never watched failing is the
# shape invariant 3 forbids.
NEGATIVES = [
    ("version loosened",
     "fetch Microsoft.WindowsAppSDK.WinUI 2.2.1",
     "fetch Microsoft.WindowsAppSDK.WinUI 2.2.*",
     "Microsoft.WindowsAppSDK.WinUI"),
    ("version by variable",
     "fetch Microsoft.WindowsAppSDK.WinUI 2.2.1",
     "fetch Microsoft.WindowsAppSDK.WinUI $WINUI_VERSION",
     "Microsoft.WindowsAppSDK.WinUI"),
    ("hash dropped",
     "fetch Microsoft.WindowsAppSDK.Base 2.0.4 \\\n    "
     "e3e13478c4c80c59ed5f8f89542fe49a2985daa484753e93a5858e90c2d46a4d",
     "fetch Microsoft.WindowsAppSDK.Base 2.0.4",
     "Microsoft.WindowsAppSDK.Base"),
    ("hash mangled",
     "e3e13478c4c80c59ed5f8f89542fe49a2985daa484753e93a5858e90c2d46a4d",
     "deadbeef",
     "Microsoft.WindowsAppSDK.Base"),
    ("verification deleted",
     '    if ! verify_sha256 "$pkg" "$want" "$id $version"; then\n        exit 1\n    fi\n',
     "",
     "without verifying"),
    ("verification skipped by the cache",
     "    if ! verify_sha256",
     '    if [ -d "$dir/extracted" ]; then\n        return\n    fi\n    if ! verify_sha256',
     "before verify_sha256"),
    # The full line, not the bare tool name: `shasum -a 256` also spells
    # the dev-shell fingerprint at the top of the file, and a first-match
    # replace landed there with the count still reading 1 — a
    # perturbation that applies SOMEWHERE ELSE is the vacuous negative
    # this rule exists to catch.
    ("hash swapped for a size check",
     'got=$(shasum -a 256 "$path" | cut -d\' \' -f1)',
     'got=$(wc -c < "$path")',
     "computes no sha256"),
    ("a second download outside the door",
     "echo \"== winmd files ==\"",
     'curl -sSfL "https://api.nuget.org/v3-flatcontainer/x/1/x.1.nupkg" -o /tmp/x\n'
     "echo \"== winmd files ==\"",
     "outside fetch()"),
]
counts, refused = [], 0
if fetch_text:
    for label, old, new, expect in NEGATIVES:
        # AMBIGUITY IS A FAILED TEST TOO: a pattern matching twice would
        # let a first-match replace doctor a line nobody meant, with the
        # count still reading 1 (measured while writing this clause —
        # `shasum -a 256` also spells the dev-shell fingerprint above).
        sites = fetch_text.count(old)
        counts.append(f"{min(sites, 1)}")
        if sites != 1:
            out.append(f"check-pins: watched negative '{label}' matches {sites} sites — "
                       "an unchanged file is a failed test, and an ambiguous one doctors "
                       "somewhere nobody meant")
            continue
        doctored = fetch_text.replace(old, new, 1)
        got = scan_fetcher(FETCHER, doctored)
        if any(expect in g for g in got):
            refused += 1
        else:
            out.append(f"check-pins: watched negative '{label}' was NOT refused naming "
                       f"{expect!r} (findings: {got})")
    print(f"check-pins: fetch-winappsdk: "
          f"{len([1 for n, l in logical_lines(fetch_text) if CALL.match(l.strip())])} "
          f"packages read, {refused}/{len(NEGATIVES)} watched negatives refused "
          f"(substitutions {'/'.join(counts)})", file=sys.stderr)

print("\n".join(out))
PY
)

status=0
if [ -n "$findings" ]; then
    echo "check-pins: dependencies that a server, not this repo, would choose:" >&2
    echo "$findings" >&2
    status=1
fi

# Self-test: the scan has to see each defect shape.
probe=$(python3 - <<'PY'
import re
DYNAMIC = re.compile(r"[+*]|latest\.|^[\[(]|,")
cases = ["1.9.+", "latest.release", "*", "[1.0,2.0)", "2024.10.01", "8.7.3"]
bad = [c for c in cases if DYNAMIC.search(c)]
good = [c for c in cases if not DYNAMIC.search(c)]

# A continued invocation must read as ONE command.
split = "swift " "run \\\n    --package-path tools/x kaya-gen"
joined = split.replace("\\\n", " ")
seen = 1 if re.search(r"swift\s+run\b", joined) and "--package-path" in joined else 0
print(f"{len(bad)}/{len(good)}/{seen}")
PY
)
if [ "$probe" != "4/2/1" ]; then
    echo "check-pins: self-test failed (detectors scored $probe, want 4/2/1)" >&2
    status=1
fi

if [ "$status" = 0 ]; then
    echo "check-pins: OK"
else
    echo "check-pins: FINDINGS ABOVE"
fi
exit "$status"
