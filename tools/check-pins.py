#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

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

import hashlib
import re
import subprocess
import tempfile

root = ROOT
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
    text = f.read_text(encoding="utf-8")
    # A platform(...) BOM supplies versions for coordinates that omit
    # one, so a version-less coordinate is legal only alongside a BOM.
    has_bom = "platform(" in text
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("//"):
            continue
        for name, version in PLUGIN.findall(line):
            if not concrete(version):
                out.append(f"{f}:{n}: plugin {name} version {version!r} is "
                           f"not a fixed version")
        for coord in COORD.findall(line):
            parts = coord.split(":")
            if len(parts) == 3:
                if not concrete(parts[2]):
                    out.append(f"{f}:{n}: {coord} is not a fixed version")
            elif len(parts) == 2 and not has_bom:
                out.append(f"{f}:{n}: {coord} has no version and no "
                           f"platform() BOM in this file")

# --- NuGet: PackageReference ------------------------------------------
PKGREF = re.compile(
    r'<PackageReference\s+Include="([^"]+)"\s+Version="([^"]+)"')
for f in sorted(root.rglob("*.csproj")):
    if ("target" in f.relative_to(root).parts
            or "obj" in f.relative_to(root).parts):
        continue
    for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(),
                             1):
        for name, version in PKGREF.findall(line):
            if not concrete(version):
                out.append(f"{f}:{n}: nuget {name} version {version!r} is "
                           f"not a fixed version")

# --- opam: the container's OCaml packages ------------------------------
# opam-repository is a ROLLING index: every name must carry its version
# (pkg.version), and the index itself must be pinned to a commit — the
# version pins alone do not constrain transitive resolution.
dockerfile = root / "tools/linux/Dockerfile"
text = dockerfile.read_text(encoding="utf-8")
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
            out.append(f"{dockerfile}: opam install {a} does not name a "
                       f"version (want {a}.X.Y.Z)")
if not re.search(r"opam-repository/archive/[0-9a-f]{40}\.tar\.gz", text):
    out.append(f"{dockerfile}: the opam index is not pinned to a commit")

# --- SwiftPM: Package.resolved is the pin, so it must be honoured -----
# Package.swift declares RANGES, so Package.resolved is the pin. Two
# halves: it is checked in, and every invocation refuses to resolve
# around it.
for f in sorted(root.rglob("Package.swift")):
    if ".build" in f.parts:
        continue
    if ('url:' in f.read_text(encoding="utf-8")
            and not (f.parent / "Package.resolved").is_file()):
        out.append(f"{f}: remote dependencies with no checked-in "
                   f"Package.resolved")

SWIFTPM = re.compile(r"swift\s+(?:run|build|test)\b")
for f in sorted(root.glob("tools/**/*.sh")):
    for n, line in logical_lines(f.read_text(encoding="utf-8")):
        if line.lstrip().startswith("#") or not SWIFTPM.search(line):
            continue
        if "--disable-automatic-resolution" not in line:
            out.append(f"{f}:{n}: swiftpm invocation may re-resolve "
                       "(want --disable-automatic-resolution)")

# --- NuGet flat container: the Windows App SDK arrives by curl --------
# tools/fetch-winappsdk.sh resolves five packages straight out of
# nuget's flat container. No lockfile covers a curl and the
# PackageReference clause above cannot see it — the .csproj files in
# this tree are guest-side and tooling, not the backend
# (docs/canvas-plan.md §3.1) — so until this clause the Windows
# dependency door was guarded by nobody. Three rules: an exact version,
# a recorded sha256, and a script that still checks the hash it
# recorded, cache included.
FETCHER = root / "tools/fetch-winappsdk.sh"
SHA256 = re.compile(r"^[0-9a-f]{64}$")
CALL = re.compile(r"^fetch\s+\S")


def code_only(text):
    """Whole-line comments dropped. A commented-out call is not a call,
    and a comment naming curl is not a download."""
    return "\n".join(ln for ln in text.splitlines()
                     if not ln.strip().startswith("#"))


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
            # A call this cannot read is a finding naming the site,
            # never a skip: silence would read as clean.
            bad.append(f"{path}:{n}: `{s[:90]}` is not "
                       f"`fetch <Id> <version> <sha256>`")
            continue
        _, pid, version, sha = parts
        packages += 1
        if "$" in version or not concrete(version):
            bad.append(f"{path}:{n}: {pid} version {version!r} is not a "
                       f"fixed version")
        if "$" in sha or not SHA256.match(sha):
            bad.append(f"{path}:{n}: {pid} {version} records no sha256 "
                       f"(got {sha!r}) — a version names a release, not "
                       f"the bytes that arrived")
    if packages < 3:
        bad.append(f"{path}: read {packages} package(s) — a census that "
                   "reads almost nothing agrees with almost anything, so "
                   "this is the scan failing, not the file passing")

    verify = shell_body(text, "verify_sha256")
    if verify is None:
        bad.append(f"{path}: no verify_sha256() — a hash nothing compares "
                   f"against is a comment")
    else:
        v = code_only(verify)
        if "shasum -a 256" not in v and "sha256sum" not in v:
            bad.append(f"{path}: verify_sha256() computes no sha256 — a "
                       "size or mtime check passes the same-length "
                       "corruption a half-written body produces (the "
                       "tools/check-assets.sh staging rule)")
        if "return 1" not in v:
            bad.append(f"{path}: verify_sha256() never refuses "
                       f"(no `return 1`)")

    body = shell_body(text, "fetch")
    if body is None:
        bad.append(f"{path}: no fetch() to read")
    else:
        b = code_only(body)
        if "verify_sha256" not in b:
            bad.append(f"{path}: fetch() downloads without verifying — "
                       "every package's bytes are checked against the "
                       "sha256 recorded beside its version")
        else:
            first_return = re.search(r"(?m)^\s*return\b", b)
            if (first_return
                    and first_return.start() < b.index("verify_sha256")):
                bad.append(f"{path}: fetch() can return before "
                           "verify_sha256 — the CACHED path is exactly "
                           "the one a stale or doctored tree takes")
        inside = len(re.findall(r"\bcurl\b", b))
        total = len(re.findall(r"\bcurl\b", code_only(text)))
        if inside == 0:
            bad.append(f"{path}: fetch() runs no curl — this clause is "
                       f"reading the wrong function")
        if total != inside:
            bad.append(f"{path}: {total - inside} curl invocation(s) "
                       "outside fetch(), where no recorded hash is "
                       "checked against what arrives")
    return bad


if not FETCHER.is_file():
    out.append(f"{FETCHER}: gone — the fifth clause reads it by name; if "
               "the Windows packages now arrive some other way, that way "
               "needs this clause")
    fetch_text = ""
else:
    fetch_text = FETCHER.read_text(encoding="utf-8")
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
        probe.write_text(
            "set -uo pipefail\nverify_sha256() {" + verify_body + "}\n"
            'verify_sha256 "$1" "$2" "probe-package 9.9.9"\n',
            encoding="utf-8")
        accept = subprocess.run(["bash", str(probe), str(pkg), good],
                                capture_output=True, text=True,
                                check=False)
        refuse = subprocess.run(["bash", str(probe), str(pkg), wrong],
                                capture_output=True, text=True,
                                check=False)
    if accept.returncode != 0:
        out.append(f"{FETCHER}: verify_sha256 refused bytes that DO match "
                   f"their hash (exit {accept.returncode}): "
                   f"{(accept.stdout + accept.stderr).strip()[:200]}")
    if refuse.returncode == 0:
        out.append(f"{FETCHER}: verify_sha256 ACCEPTED bytes that do not "
                   f"match their hash")
    said = refuse.stdout + refuse.stderr
    for token, what in ((good, "the hash it measured"),
                        (wrong, "the hash it was handed"),
                        ("probe-package 9.9.9", "the package")):
        if token not in said:
            out.append(f"{FETCHER}: verify_sha256's refusal does not name "
                       f"{what} — a diagnostic prints what it measured, "
                       "or the next reader chases a sentence that cannot "
                       f"discriminate: {said.strip()[:200]}")

# A NEW DOOR. This clause reads ONE script by name, so a second script
# that resolves a package from the same flat container would be
# invisible to it — the shape the whole finding is about.
KNOWN_FETCHERS = {"tools/fetch-winappsdk.sh"}
for f in sorted(root.glob("tools/**/*.sh")):
    rel = f.relative_to(root).as_posix()
    # This file names the host in its own clause; a gate that scans a
    # directory scans itself (docs/traps.md).
    if rel in KNOWN_FETCHERS or rel == "tools/check-pins.sh":
        continue
    if "api.nuget.org" in f.read_text(encoding="utf-8"):
        out.append(f"{f}: resolves a package from nuget's flat container, "
                   "and check-pins reads "
                   + " ".join(sorted(KNOWN_FETCHERS)) + " only — give it "
                   "the same `fetch <Id> <version> <sha256>` shape and "
                   "add it to KNOWN_FETCHERS, or route the download "
                   "through the existing fetcher")

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
     '    if ! verify_sha256 "$pkg" "$want" "$id $version"; then\n'
     "        exit 1\n    fi\n",
     "",
     "without verifying"),
    ("verification skipped by the cache",
     "    if ! verify_sha256",
     '    if [ -d "$dir/extracted" ]; then\n        return\n    fi\n'
     "    if ! verify_sha256",
     "before verify_sha256"),
    # The full line, not the bare tool name: `shasum -a 256` also spells
    # the dev-shell fingerprint at the top of the file, and a
    # first-match replace landed there with the count still reading 1 —
    # a perturbation that applies SOMEWHERE ELSE is the vacuous negative
    # this rule exists to catch.
    ("hash swapped for a size check",
     'got=$(shasum -a 256 "$path" | cut -d\' \' -f1)',
     'got=$(wc -c < "$path")',
     "computes no sha256"),
    ("a second download outside the door",
     'echo "== winmd files =="',
     'curl -sSfL "https://api.nuget.org/v3-flatcontainer/x/1/x.1.nupkg" '
     "-o /tmp/x\n"
     'echo "== winmd files =="',
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
            out.append(f"check-pins: watched negative '{label}' matches "
                       f"{sites} sites — an unchanged file is a failed "
                       "test, and an ambiguous one doctors somewhere "
                       "nobody meant")
            continue
        doctored = fetch_text.replace(old, new, 1)
        got = scan_fetcher(FETCHER, doctored)
        if any(expect in g for g in got):
            refused += 1
        else:
            out.append(f"check-pins: watched negative '{label}' was NOT "
                       f"refused naming {expect!r} (findings: {got})")
    npkgs = len([1 for n, ln in logical_lines(fetch_text)
                 if CALL.match(ln.strip())])
    print(f"check-pins: fetch-winappsdk: {npkgs} packages read, "
          f"{refused}/{len(NEGATIVES)} watched negatives refused "
          f"(substitutions {'/'.join(counts)})", file=sys.stderr)

# --- The zips the Windows VM fetches: go and node arrive by ------------
# Invoke-WebRequest inside tools/guest/fetch-zip.ps1, called from
# tools/deploy-win.py with a version and a sha256 recorded beside it.
# The inline `powershell -Command` route is refused by name: through ssh
# and cmd it arrives as one quoted string PowerShell PRINTS instead of
# running — the go1.27.0 pin was echoed and never installed while the go
# legs built with the VM's system Go (2026-09-01, docs/traps.md).
DEPLOY_WIN = root / "tools/deploy-win.py"
FETCH_ZIP = root / "tools/guest/fetch-zip.ps1"


def scan_zip_pins(deploy_text, ps1_text):
    bad = []
    consts = dict(re.findall(r'^([A-Z0-9_]+_SHA256) = "([0-9a-f]{64})"$',
                             deploy_text, re.M))
    calls = re.findall(r'fetch_zip\(f"([^"]+)",\s*([A-Z0-9_]+),',
                       deploy_text)
    if len(calls) < 2:
        bad.append(f"{DEPLOY_WIN}: read {len(calls)} fetch_zip call(s) — "
                   "a census that reads almost nothing agrees with "
                   "almost anything")
    for url, name in calls:
        if name not in consts:
            bad.append(f"{DEPLOY_WIN}: fetch_zip for {url} names {name}, "
                       f"which is not a 64-hex sha256 constant of this "
                       f"file — a version names a release, not the bytes "
                       f"that arrive")
        if "{" not in url:
            bad.append(f"{DEPLOY_WIN}: fetch_zip url {url} carries no "
                       f"version constant")
    versions = re.findall(r'^[A-Z0-9_]+_VERSION = "[0-9]+\.[0-9]+\.[0-9]+"$',
                          deploy_text, re.M)
    if len(versions) < 2:
        bad.append(f"{DEPLOY_WIN}: fewer than two concrete *_VERSION "
                   f"constants")
    code = "\n".join(ln for ln in deploy_text.splitlines()
                     if not ln.strip().startswith("#"))
    # The inline shape is `powershell -Command \"...\"` NESTED in a
    # `cmd /c "..."` string — the escaped quotes are the tell; a direct
    # `ssh host 'powershell -Command "..."'` (verify_deployed's hash read)
    # arrives as a command and is not this defect.
    if 'powershell -Command \\\\"' in code:
        bad.append(f"{DEPLOY_WIN}: an inline `powershell -Command "
                   f"\\\"...\\\"` nested in a cmd /c string survives — "
                   f"through ssh and cmd it is a string PowerShell prints, "
                   f"not a command it runs")
    if "Invoke-WebRequest" in code:
        bad.append(f"{DEPLOY_WIN}: a download outside fetch-zip.ps1, "
                   f"where no recorded hash is checked")
    marks = [ps1_text.find("Get-FileHash -Algorithm SHA256"),
             ps1_text.find("-ne $Sha256"), ps1_text.find("exit 1"),
             ps1_text.find("Expand-Archive")]
    if min(marks) < 0:
        bad.append(f"{FETCH_ZIP}: lacks the hash, the compare, the "
                   f"refusal or the expand")
    elif not (marks[0] < marks[1] < marks[2] < marks[3]):
        bad.append(f"{FETCH_ZIP}: expands before it refuses — the order "
                   f"is hash, compare, exit 1, expand")
    return bad


ZIP_NEGATIVES = [
    ("a sha256 constant shortened", "deploy",
     '"8502f4a50b458d4cc38ed8f2001556c2cd239d464920f74017926ccb1e1c157f"',
     '"8502f4a50b458d4cc38ed8f2001556c2cd239d464920f74017926ccb1e1c1"',
     "not a 64-hex sha256 constant"),
    ("an inline powershell download restored", "deploy",
     "def fetch_zip(url, sha256, dest):",
     'must_ssh(\'cmd /c "x || powershell -Command \\\\"Invoke-WebRequest '
     '-Uri x\\\\""\')\n'
     "def fetch_zip(url, sha256, dest):",
     "PowerShell prints"),
    ("the compare removed from the script", "ps1",
     "if ($got -ne $Sha256.ToLower()) {", "if ($false) {",
     "lacks the hash, the compare"),
    ("the expand moved ahead of the refusal", "ps1",
     "$got = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()",
     "Expand-Archive -Path $zip -DestinationPath $Dest -Force\n"
     "$got = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()",
     "expands before it refuses"),
]
if DEPLOY_WIN.is_file() and FETCH_ZIP.is_file():
    deploy_text = DEPLOY_WIN.read_text(encoding="utf-8")
    ps1_text = FETCH_ZIP.read_text(encoding="utf-8")
    out.extend(scan_zip_pins(deploy_text, ps1_text))
    zcounts, zrefused = [], 0
    for label, which, old, new, expect in ZIP_NEGATIVES:
        src = deploy_text if which == "deploy" else ps1_text
        sites = src.count(old)
        zcounts.append(f"{min(sites, 1)}")
        if sites != 1:
            out.append(f"check-pins: watched negative '{label}' matches "
                       f"{sites} sites — an unchanged file is a failed "
                       "test")
            continue
        doctored = src.replace(old, new, 1)
        got = (scan_zip_pins(doctored, ps1_text) if which == "deploy"
               else scan_zip_pins(deploy_text, doctored))
        if any(expect in g for g in got):
            zrefused += 1
        else:
            out.append(f"check-pins: watched negative '{label}' was NOT "
                       f"refused naming {expect!r} (findings: {got})")
    print(f"check-pins: windows zips: {zrefused}/{len(ZIP_NEGATIVES)} "
          f"watched negatives refused (substitutions "
          f"{'/'.join(zcounts)})", file=sys.stderr)
else:
    out.append(f"{DEPLOY_WIN} or {FETCH_ZIP}: gone — the zip clause reads "
               "them by name")

status = 0
if out:
    print("check-pins: dependencies that a server, not this repo, would "
          "choose:", file=sys.stderr)
    print("\n".join(out), file=sys.stderr)
    status = 1

# Self-test: the scan has to see each defect shape.
cases = ["1.9.+", "latest.release", "*", "[1.0,2.0)", "2024.10.01",
         "8.7.3"]
bad_cases = [c for c in cases if DYNAMIC.search(c)]
good_cases = [c for c in cases if not DYNAMIC.search(c)]
# A continued invocation must read as ONE command.
split = "swift " "run \\\n    --package-path tools/x kaya-gen"
rejoined = split.replace("\\\n", " ")
seen = 1 if (re.search(r"swift\s+run\b", rejoined)
             and "--package-path" in rejoined) else 0
probe_score = f"{len(bad_cases)}/{len(good_cases)}/{seen}"
if probe_score != "4/2/1":
    print(f"check-pins: self-test failed (detectors scored {probe_score}, "
          f"want 4/2/1)", file=sys.stderr)
    status = 1

if status == 0:
    print("check-pins: OK")
else:
    print("check-pins: FINDINGS ABOVE")
sys.exit(status)
