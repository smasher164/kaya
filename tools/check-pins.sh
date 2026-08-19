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
# version. Gradle, NuGet, SwiftPM and the container's opam index have no
# lockfile the way cargo and nix do, so one dynamic version (`1.9.+`,
# `latest.release`, `*`, a range) and the lane depends on what a server
# chose today. NOT a lockfile mechanism — the guard that keeps the
# existing exact versions exact.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

findings=$(python3 - "$ROOT" <<'PY'
import pathlib
import re
import sys

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
