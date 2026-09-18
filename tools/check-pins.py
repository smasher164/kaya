#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# Every dependency this repo resolves over the network names an exact
# version: gradle, NuGet, SwiftPM, the container's opam index and the
# Windows App SDK curl have no lockfile the way cargo and nix do. NOT a
# lockfile mechanism — the guard that keeps the existing pins exact.
# The curl clauses hold BYTES as well as a version, and cut the verifier
# out of its script to run it against wrong bytes on every sweep.

import ast
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
    line number (docs/traps.md: "A gate that reads PHYSICAL lines cannot
    see a continued command")."""
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
# opam-repository is a ROLLING index, so the index itself must be pinned
# to a commit: version pins alone do not constrain transitive resolution.
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
# Package.swift declares RANGES. Two halves: the resolved file is checked
# in, and every invocation refuses to resolve around it.
for f in sorted(root.rglob("Package.swift")):
    if ".build" in f.parts:
        continue
    if ('url:' in f.read_text(encoding="utf-8")
            and not (f.parent / "Package.resolved").is_file()):
        out.append(f"{f}: remote dependencies with no checked-in "
                   f"Package.resolved")

# The `swift build` half of this clause runs at the END of this file,
# where the tools/ bodies the java census reads are already in hand.

# --- NuGet flat container: the Windows App SDK arrives by curl --------
# The PackageReference clause above cannot see it: the .csproj files in
# this tree are guest-side and tooling, not the backend
# (docs/canvas-plan.md §3.1). Three rules — an exact version, a recorded
# sha256, and a script that still checks the hash it recorded, cache
# included.
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
    """Findings for one fetch script. A function so the watched negatives
    below can run it against doctored copies."""
    bad, packages = [], 0
    for n, line in logical_lines(text):
        s = line.strip()
        if s.startswith("#") or not CALL.match(s):
            continue
        parts = s.split()
        if len(parts) != 4:
            # A call this cannot read is a finding naming the site,
            # never a skip.
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
                       "tools/check-assets.py staging rule)")
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

# THE VERIFIER ITSELF, CUT OUT AND RUN: static text saying a hash is
# compared is not the comparison refusing. Both outcomes, and the refusal
# must name what it measured (invariant 3).
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

# A NEW DOOR: this clause reads ONE script by name, so a second script
# resolving from the same flat container would be invisible to it.
KNOWN_FETCHERS = {"tools/fetch-winappsdk.sh"}
for f in sorted(root.glob("tools/**/*.sh")):
    rel = f.relative_to(root).as_posix()
    # A gate that scans a directory scans itself (docs/traps.md: "A gate
    # that reads PHYSICAL lines…", its closing paragraph).
    if rel in KNOWN_FETCHERS or rel == "tools/check-pins.py":
        continue
    if "api.nuget.org" in f.read_text(encoding="utf-8"):
        out.append(f"{f}: resolves a package from nuget's flat container, "
                   "and check-pins reads "
                   + " ".join(sorted(KNOWN_FETCHERS)) + " only — give it "
                   "the same `fetch <Id> <version> <sha256>` shape and "
                   "add it to KNOWN_FETCHERS, or route the download "
                   "through the existing fetcher")

# WATCHED NEGATIVES on doctored copies of the real file: every
# perturbation proven applied (counts printed), every one refused.
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
    # the dev-shell fingerprint above (docs/traps.md: "A substitution
    # count of 1 does not say WHERE it applied").
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
        # AMBIGUITY IS A FAILED TEST TOO (docs/traps.md: "A substitution
        # count of 1 does not say WHERE it applied").
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
# tools/deploy-win.py with a version and a sha256 beside it. The inline
# `powershell -Command` route is refused by name: through ssh and cmd it
# arrives as a string PowerShell PRINTS, which is how the go1.27.0 pin was
# echoed and never installed (docs/traps.md).
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
    # The escaped quotes are the tell: only the shape NESTED in a
    # `cmd /c "..."` string is the defect. A direct
    # `ssh host 'powershell -Command "..."'` arrives as a command.
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

# --- The Java language level: ONE number across four lanes -------------
# The Go pin's fiction was one lane quietly on another toolchain
# (docs/traps.md, 2026-09-01). A javac with no `--release` is the same
# defect with no version to read: it compiles at whatever level the javac
# on PATH defaults to, so a lane whose JDK moves changes language silently
# and every other gate stays green. HERE and not in check-gates.py because
# this gate already reads all four files involved — android/**/*.gradle.kts,
# tools/linux/Dockerfile, tools/deploy-win.py and tools/**/*.sh — and its
# subject IS a toolchain version that no lockfile pins; check-gates' subject
# is the gate roster and the lane launch topology, and it reads no javac
# line at all.
JAVA_RELEASE = "21"
ANDROID_COMPILE_SDK = "36"
# Every file in this repo that compiles Java, and how it spells the flag.
# A javac found anywhere else is a finding naming the site (the census
# below), never a skip.
JAVAC_SITES = {
    "tools/java-typecheck.py": "the fast gate over the binding and every guest",
    "tools/gen-guests.py": "the annotation processor that writes *Kaya.java",
    "tools/check-abort.py": "the abort exerciser",
    "tools/lib/lanes/mac.py": "the mac lane's guest build",
    "tools/linux/run-suites.sh": "the linux container's guest build",
    "tools/deploy-win.py": "the javac that runs ON the Windows guest",
}
# compileSdk 36 is not a nicety on these five: pattern matching for switch
# needs java.lang.runtime.SwitchBootstraps on the compile classpath and
# android-35's android.jar has none (measured 2026-09-17; D8 desugars the
# typeSwitch for minSdk 26, so the APKs still run on the API-35 image).
# Dropping one back to 35 fails the javahost compile — but only on the
# android lane, a whole matrix away, which is why it is held here.
ANDROID_SDK36_MODULES = ("android/kaya/build.gradle.kts",
                         "android/javahost/build.gradle.kts",
                         "android/gohost/build.gradle.kts",
                         "android/pyhost/build.gradle.kts",
                         "android/rusthost/build.gradle.kts")

JAVAC_CALL = re.compile(r"\bjavac\b")


def scan_java_level(texts, gradle_texts):
    """Findings for the java language level. A function so the watched
    negatives below can run it against doctored copies."""
    bad, read = [], 0
    for rel, what in sorted(JAVAC_SITES.items()):
        text = texts.get(rel)
        if text is None:
            bad.append(f"{rel}: gone — the java language-level clause reads "
                       f"it by name as {what}; if Java is compiled some "
                       f"other way now, that way needs this clause")
            continue
        code = code_only(text)
        if not JAVAC_CALL.search(code):
            bad.append(f"{rel}: names no javac, but this clause lists it as "
                       f"{what} — the census is reading the wrong file")
            continue
        read += 1
        # Both spellings: an argv list ("--release", "21") and embedded
        # shell (`javac --release 21 …`). Adjacency is what makes it a
        # flag rather than two unrelated tokens.
        argv = f'"--release", "{JAVA_RELEASE}"'
        shell = f"--release {JAVA_RELEASE}"
        if argv not in code and shell not in code:
            bad.append(f"{rel}: compiles Java without `--release "
                       f"{JAVA_RELEASE}` — {what}. The level would be "
                       f"whatever the javac on PATH defaults to, so this "
                       f"lane can compile a different language from the "
                       f"other three with nothing red (CLAUDE.md "
                       f"invariant 3; the Go pin's fiction, docs/traps.md)")
    if read < len(JAVAC_SITES):
        bad.append(f"check-pins: read {read} of {len(JAVAC_SITES)} javac "
                   f"sites — a census that reads almost nothing agrees "
                   f"with almost anything")
    for rel, text in sorted(gradle_texts.items()):
        code = code_only(text)
        # EVERY occurrence, not "at least one right one": a module with
        # sourceCompatibility 17 beside targetCompatibility 21 satisfies a
        # membership test and compiles at 17 (watched negative below).
        for spelled in set(re.findall(r"JavaVersion\.VERSION_(\w+)", code)):
            if spelled != JAVA_RELEASE:
                bad.append(f"{rel}: JavaVersion.VERSION_{spelled} — every "
                           f"javac site in this repo states `--release "
                           f"{JAVA_RELEASE}`, so this module compiles the "
                           f"guests at a level the other lanes do not")
        for spelled in set(re.findall(r'jvmTarget\s*=\s*"([^"]+)"', code)):
            if spelled != JAVA_RELEASE:
                bad.append(f"{rel}: jvmTarget = \"{spelled}\" — the Kotlin "
                           f"half of this module targets a bytecode level "
                           f"the Java half does not")
        if rel in ANDROID_SDK36_MODULES:
            if f"compileSdk = {ANDROID_COMPILE_SDK}" not in code:
                bad.append(f"{rel}: not at `compileSdk = "
                           f"{ANDROID_COMPILE_SDK}` — pattern matching for "
                           f"switch needs java.lang.runtime.SwitchBootstraps "
                           f"on the compile classpath and android-35's "
                           f"android.jar has none (measured 2026-09-17). "
                           f"Below 36 the javahost compile dies with "
                           f"`class file for java.lang.runtime."
                           f"SwitchBootstraps not found`, on the android "
                           f"lane and nowhere else")
    # THE NEW DOOR: this clause reads its files BY NAME, so a javac that
    # appears anywhere else in tools/ is invisible to it.
    return bad, read


# Files that NAME javac without compiling: the two command-hygiene gates
# that read other files' javac lines, the gradle wrapper's prose, and the
# prelude's docstring. Each must still name javac, or the exemption is
# stale and says so.
JAVAC_EXEMPT = {
    "tools/check-python.py": "rule 11 reads OTHER files' javac argv lists",
    "tools/check-shell.py": "the same rule, shell side",
    "tools/check-compose.py": "names gradle's compileDebugJavaWithJavac task",
    "tools/lib/kaya_gate.py": "the -encoding trap, in a docstring",
}
# An INVOCATION, not the word: `javac` as an argv element, or at the head
# of a shell command. The bare word also appears in prose and in the two
# gates that police other files' javac lines (JAVAC_EXEMPT).
JAVAC_INVOCATION = re.compile(
    r"""["']javac["']|(?:^|[;&|(]|\bthen\b|\bdo\b)\s*javac\s""", re.M)


def java_level_census(bodies):
    """Every tools/ file that INVOKES javac, so a NEW compile site is a
    finding rather than a silence. Takes the bodies rather than reading
    them, so the watched negative below can inject one."""
    found = [rel for rel, body in sorted(bodies.items())
             if JAVAC_INVOCATION.search(code_only(body))]
    stale = [rel for rel in sorted(JAVAC_EXEMPT)
             if rel not in bodies
             or not JAVAC_CALL.search(code_only(bodies[rel]))]
    return found, stale


def tools_bodies(root_dir):
    out_ = {}
    for pattern in ("tools/**/*.py", "tools/**/*.sh"):
        for f in sorted(root_dir.glob(pattern)):
            rel = f.relative_to(root_dir).as_posix()
            if rel == "tools/check-pins.py":
                continue
            out_[rel] = f.read_text(encoding="utf-8")
    return out_


def census_findings(found, stale):
    bad = []
    for rel in found:
        if rel not in JAVAC_SITES and rel not in JAVAC_EXEMPT:
            bad.append(f"{rel}: invokes javac and is not in check-pins' "
                       f"JAVAC_SITES, so nothing holds its `--release "
                       f"{JAVA_RELEASE}` — add it there with what it is "
                       f"for")
    for rel in stale:
        bad.append(f"{rel}: is in check-pins' JAVAC_EXEMPT ("
                   f"{JAVAC_EXEMPT[rel]}) but no longer names javac — a "
                   f"stale exemption is the next stale audit")
    return bad


java_texts = {}
for rel in JAVAC_SITES:
    f = root / rel
    if f.is_file():
        java_texts[rel] = f.read_text(encoding="utf-8")
gradle_texts = {
    f.relative_to(root).as_posix(): f.read_text(encoding="utf-8")
    for f in sorted(list(root.glob("android/**/*.gradle.kts"))
                    + list(root.glob("tools/android/**/*.gradle.kts")))}
_java_out, _java_read = scan_java_level(java_texts, gradle_texts)
out += _java_out
_tools_bodies = tools_bodies(root)
out += census_findings(*java_level_census(_tools_bodies))
# TWO WATCHED NEGATIVES ON THE CENSUS ITSELF, because a census nobody has
# seen fire is a guess: a NEW javac site that nothing holds, and an
# exemption that stopped naming javac.
_planted = dict(_tools_bodies)
_planted["tools/a-new-lane.py"] = (
    'subprocess.run(["javac", "-encoding", "UTF-8", "-d", out, src])\n')
_blanked = dict(_tools_bodies)
_blanked["tools/check-shell.py"] = "# nothing here compiles anything\n"
_census_negatives = [
    ("a new javac site", _planted, "a-new-lane.py", "JAVAC_SITES"),
    ("a stale javac exemption", _blanked, "check-shell.py",
     "stale exemption"),
]
_crefused = 0
for _label, _bodies, _who, _what in _census_negatives:
    _got = census_findings(*java_level_census(_bodies))
    if any(_who in f and _what in f for f in _got):
        _crefused += 1
    else:
        out.append(f"check-pins: watched negative {_label!r} was NOT "
                   f"refused naming {_what!r} (findings: {_got})")
print(f"check-pins: javac census: {len(_tools_bodies)} tools file(s) read, "
      f"{_crefused}/{len(_census_negatives)} watched negatives refused",
      file=sys.stderr)

# WATCHED NEGATIVES on doctored copies of the real files.
JAVA_NEGATIVES = [
    ("the mac lane's release flag dropped", "tools/lib/lanes/mac.py",
     '"javac", "--release", "21",', '"javac",',
     "without `--release 21`"),
    ("the linux container's release flag dropped",
     "tools/linux/run-suites.sh",
     "javac --release 21 -encoding UTF-8", "javac -encoding UTF-8",
     "without `--release 21`"),
    ("the windows guest's release flag dropped", "tools/deploy-win.py",
     "javac --release 21 -encoding UTF-8", "javac -encoding UTF-8",
     "without `--release 21`"),
    ("the gate's own release flag dropped", "tools/java-typecheck.py",
     'RELEASE = ["--release", "21"]', 'RELEASE = []',
     "without `--release 21`"),
    ("a gradle module left at 17", "android/javahost/build.gradle.kts",
     "sourceCompatibility = JavaVersion.VERSION_21",
     "sourceCompatibility = JavaVersion.VERSION_17",
     "JavaVersion.VERSION_17"),
    ("a gradle module's kotlin target left at 17",
     "android/kaya/build.gradle.kts",
     'jvmTarget = "21"', 'jvmTarget = "17"', 'jvmTarget = "17"'),
    ("compileSdk dropped back to 35", "android/javahost/build.gradle.kts",
     "compileSdk = 36", "compileSdk = 35", "SwitchBootstraps not found"),
    ("a probe app's kotlin target left at 17",
     "tools/android/clipprobe/app/build.gradle.kts",
     'jvmTarget = "21"', 'jvmTarget = "17"', 'jvmTarget = "17"'),
]
jcounts, jrefused = [], 0
for label, rel, old, new, expect in JAVA_NEGATIVES:
    src = java_texts.get(rel) or gradle_texts.get(rel)
    if src is None:
        out.append(f"check-pins: watched negative '{label}' names {rel}, "
                   f"which this clause never read")
        jcounts.append("0")
        continue
    sites = src.count(old)
    jcounts.append(f"{min(sites, 1)}")
    if sites != 1:
        out.append(f"check-pins: watched negative '{label}' matches "
                   f"{sites} sites in {rel} — an unchanged file is a "
                   f"failed test, and an ambiguous one doctors somewhere "
                   f"nobody meant")
        continue
    doctored = src.replace(old, new, 1)
    jt = dict(java_texts)
    gt = dict(gradle_texts)
    if rel in jt:
        jt[rel] = doctored
    else:
        gt[rel] = doctored
    got, _ = scan_java_level(jt, gt)
    if any(expect in g for g in got):
        jrefused += 1
    else:
        out.append(f"check-pins: watched negative '{label}' was NOT "
                   f"refused naming {expect!r} (findings: {got})")
print(f"check-pins: java language level: {_java_read} javac site(s) and "
      f"{len(gradle_texts)} gradle module(s) read, {jrefused}/"
      f"{len(JAVA_NEGATIVES)} watched negatives refused (substitutions "
      f"{'/'.join(jcounts)})", file=sys.stderr)

# --- The linux image's JDK: by version AND by bytes --------------------
# The Dockerfile's own apt policy leaves package versions to trixie on
# purpose, and exempts nothing that decides a LANGUAGE LEVEL: this is the
# node/Go/winappsdk rule one toolchain over.
JDK_FETCH = re.compile(
    r"OpenJDK(\d+)U-jdk_(?:aarch64|x64)_linux_hotspot_"
    r"(\d+(?:\.\d+)+)_(\d+)\.tar\.gz")


def scan_jdk_pin(text):
    bad = []
    body = code_only(text)
    names = JDK_FETCH.findall(body)
    if len(names) < 2:
        bad.append(f"{dockerfile}: read {len(names)} pinned JDK tarball "
                   f"name(s) — the image fetches one per container arch, "
                   f"and a census that reads almost nothing agrees with "
                   f"almost anything")
    for major, version, _build in names:
        if major != JAVA_RELEASE:
            bad.append(f"{dockerfile}: a JDK tarball for major {major}, "
                       f"but every javac in this repo states `--release "
                       f"{JAVA_RELEASE}` — the container would compile at "
                       f"21 and RUN on {major}")
        if not re.match(r"^\d+(\.\d+)+$", version):
            bad.append(f"{dockerfile}: JDK version {version!r} is not a "
                       f"fixed version")
    joined = body.replace("\\\n", " ")
    hashes = re.findall(r"sum=([0-9a-fA-F]+)", joined)
    jdk_hashes = [h for h in hashes if SHA256.match(h)]
    if len(jdk_hashes) < 4:
        # node's two plus the JDK's two: a bare count is enough to catch a
        # hash dropped or shortened, and the shape check below says which.
        bad.append(f"{dockerfile}: {len(jdk_hashes)} 64-hex sha256(s) "
                   f"beside the tarball fetches — a version names a "
                   f"release, not the bytes that arrive")
    for stanza in re.findall(r"tarball=(OpenJDK\S+)", joined):
        idx = joined.index(stanza)
        window = joined[idx:idx + 400]
        if not re.search(r"sum=[0-9a-f]{64}", window):
            bad.append(f"{dockerfile}: the JDK tarball {stanza} records no "
                       f"sha256 beside it")
    if "OpenJDK" in body:
        # The verification must be unreachable-around: the compare comes
        # before the unpack, and the unpacked compiler is read back.
        order = [body.find("sha256sum -c -", body.find("OpenJDK21U")),
                 body.find("tar -xzf \"/tmp/$tarball\" -C /usr/local/jdk21")]
        if min(order) < 0:
            bad.append(f"{dockerfile}: the JDK fetch lacks the sha256 "
                       f"compare or the unpack")
        elif order[0] > order[1]:
            bad.append(f"{dockerfile}: the JDK unpacks before it verifies "
                       f"— the order is compare, then unpack")
        if "/usr/local/jdk21/bin/javac -version" not in body:
            bad.append(f"{dockerfile}: the JDK is never read back after "
                       f"the unpack — a provisioning step that 'succeeded' "
                       f"without producing the toolchain is how the Go pin "
                       f"went uninstalled for weeks (docs/traps.md)")
    if "default-jdk" in body:
        bad.append(f"{dockerfile}: installs `default-jdk`, whose major "
                   f"follows the base image's default-java — the language "
                   f"level would move with a base bump and nothing here "
                   f"would be red")
    return bad


out += scan_jdk_pin(text)

JDK_NEGATIVES = [
    ("the jdk hash shortened",
     "sum=23e37e026f12f3e706f18938ff611db3032d075b09d0879a25d06718c773e223",
     "sum=23e37e026f12f3e706f18938ff611db3032d075b09d0879a25d06718c773e2",
     "sha256"),
    ("the jdk unpacked before it verifies",
     '    echo "$sum  /tmp/$tarball" | sha256sum -c -; \\\n'
     "    mkdir -p /usr/local/jdk21; \\\n",
     "    mkdir -p /usr/local/jdk21; \\\n",
     "unpacks before it verifies"),
    ("the read-back removed",
     "    /usr/local/jdk21/bin/javac -version; "
     "/usr/local/jdk21/bin/java -version\n",
     "\n",
     "never read back"),
    ("default-jdk back in the apt list",
     "    grim \\\n",
     "    grim default-jdk-headless \\\n",
     "default-jdk"),
    ("the jdk major moved without the javac sites",
     "OpenJDK21U-jdk_aarch64_linux_hotspot_21.0.12.1_1.tar.gz",
     "OpenJDK25U-jdk_aarch64_linux_hotspot_25.0.1.1_1.tar.gz",
     "RUN on 25"),
]
dcounts, drefused = [], 0
for label, old, new, expect in JDK_NEGATIVES:
    sites = text.count(old)
    dcounts.append(f"{min(sites, 1)}")
    if sites != 1:
        out.append(f"check-pins: watched negative '{label}' matches "
                   f"{sites} sites in the Dockerfile — an unchanged file "
                   f"is a failed test")
        continue
    got = scan_jdk_pin(text.replace(old, new, 1))
    if any(expect in g for g in got):
        drefused += 1
    else:
        out.append(f"check-pins: watched negative '{label}' was NOT "
                   f"refused naming {expect!r} (findings: {got})")
print(f"check-pins: linux jdk: {drefused}/{len(JDK_NEGATIVES)} watched "
      f"negatives refused (substitutions {'/'.join(dcounts)})",
      file=sys.stderr)

SWIFTPM = re.compile(r"swift\s+(?:run|build|test)\b")
SWIFTPM_VERBS = {"run", "build", "test"}
# THE POPULATION IS BOTH LANGUAGES since 2026-09-18: bindings/swift is a
# package target (Package.swift) and the three builds that compile it are
# tools/swift-typecheck.sh (shell) plus tools/lib/lanes/mac.py and
# tools/ios/run-sim.py (PYTHON, where the command is an argv list and the
# shell rule was policed by nothing).


def docstrings(tree):
    """The Constant nodes that are documentation, not commands — a
    docstring saying what `swift build --triple` does is prose."""
    out_ = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef,
                             ast.ClassDef)) and node.body:
            first = node.body[0]
            if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) \
                    and isinstance(first.value.value, str):
                out_.add(id(first.value))
    return out_


def swiftpm_findings(rel, text):
    """Every `swift build|run|test` in one tools/ body, in either
    spelling. A function so the watched negatives below can run it
    against doctored copies."""
    bad = []
    if not rel.endswith(".py"):
        for n, line in logical_lines(text):
            if line.lstrip().startswith("#") or not SWIFTPM.search(line):
                continue
            if "--disable-automatic-resolution" not in line:
                bad.append(f"{rel}:{n}: swiftpm invocation may re-resolve "
                           "(want --disable-automatic-resolution)")
        return bad
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return bad
    docs = docstrings(tree)
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str) \
                and id(node) not in docs:
            for n, line in logical_lines(node.value):
                if line.lstrip().startswith("#") or not SWIFTPM.search(line):
                    continue
                if "--disable-automatic-resolution" not in line:
                    bad.append(f"{rel}:{node.lineno}: line {n} of a string "
                               f"holds a swiftpm invocation that may "
                               f"re-resolve (want "
                               f"--disable-automatic-resolution) — embedded "
                               f"shell is still shell.")
    for node in ast.walk(tree):
        if not isinstance(node, (ast.List, ast.Tuple)):
            continue
        elems = [e.value for e in node.elts
                 if isinstance(e, ast.Constant) and isinstance(e.value, str)]
        if not any(e == "swift" or e.endswith("/swift") or "kaya_swift" in e
                   for e in elems):
            continue
        if not (SWIFTPM_VERBS & set(elems)):
            continue
        if "--disable-automatic-resolution" not in elems:
            bad.append(f"{rel}:{node.lineno}: a swiftpm argv without "
                       f"--disable-automatic-resolution — the shell rule "
                       f"follows the command into python.")
    return bad


_swiftpm_bodies = _tools_bodies
_swiftpm_read = 0
for _rel, _text in sorted(_swiftpm_bodies.items()):
    out += swiftpm_findings(_rel, _text)
    _swiftpm_read += 1
# WATCHED NEGATIVES, one per spelling, plus the over-eagerness check.
SWIFTPM_NEGATIVES = [
    ("the shell package build without the flag", "tools/swift-typecheck.sh",
     "kaya_swift build --disable-automatic-resolution \\\n"
     "    --scratch-path target/swiftpm;",
     "kaya_swift build \\\n    --scratch-path target/swiftpm;",
     "may re-resolve"),
    ("the mac lane's argv without the flag", "tools/lib/lanes/mac.py",
     '"--disable-automatic-resolution",\n               "--scratch-path", "target/swiftpm"',
     '"--scratch-path", "target/swiftpm"',
     "a swiftpm argv without"),
    ("the iOS lane's argv without the flag", "tools/ios/run-sim.py",
     '"--disable-automatic-resolution",\n            "--scratch-path", str(PKG_SCRATCH)',
     '"--scratch-path", str(PKG_SCRATCH)',
     "a swiftpm argv without"),
]
_srefused, _scounts = 0, []
for _label, _rel, _old, _new, _expect in SWIFTPM_NEGATIVES:
    _text = _swiftpm_bodies.get(_rel, "")
    _n = _text.count(_old)
    _scounts.append(str(_n))
    if _n != 1:
        out.append(f"check-pins: watched negative {_label!r} applied {_n} "
                   f"substitution(s) to {_rel}; an unperturbed copy is a "
                   f"failed test")
        continue
    _got = swiftpm_findings(_rel, _text.replace(_old, _new, 1))
    if any(_expect in g for g in _got):
        _srefused += 1
    else:
        out.append(f"check-pins: watched negative {_label!r} was NOT "
                   f"refused naming {_expect!r} (findings: {_got})")
# The compliant spellings, unperturbed, must be QUIET — a clause that
# fires on everything says nothing.
_quiet = [g for _rel, _text in sorted(_swiftpm_bodies.items())
          for g in swiftpm_findings(_rel, _text)]
print(f"check-pins: swiftpm: {_swiftpm_read} tools file(s) read, "
      f"{_srefused}/{len(SWIFTPM_NEGATIVES)} watched negatives refused "
      f"(substitutions {'/'.join(_scounts)}), {len(_quiet)} finding(s) on "
      f"the real tree", file=sys.stderr)

# --- Swift's LANGUAGE MODE: the package is v6, NOTHING ELSE IS --------
# `.swiftLanguageMode(.v6)` in Package.swift is the ONLY place a Swift
# language mode is declared, and no tools/ compile may pass
# `-swift-version`. Both layers outside the package trap on kaya's app
# thread under Swift 6, measured on 2026-09-18:
#   - the GUESTS, because swiftc allows top-level code only in main.swift
#     and SE-0343 makes top-level code @MainActor, so every closure a
#     guest hands the binding is main-actor-isolated; Swift 6 emits a
#     dynamic isolation check at such a closure's entry, kaya calls it on
#     the app thread, and `dispatch_assert_queue` fails — SIGTRAP with
#     nothing on stderr, at the first handler of the first scene.
#     `-default-isolation nonisolated` does not lift it (measured).
#   - the INTERPRETER, which waits for the same custom SerialExecutor
#     (docs/async-dialogs-plan.md §2.1): `MainActor.assumeIsolated`
#     SIGTRAPs on that thread too.
# A waiver is a debt, and NONISOLATED_SITES is its ledger: every
# `nonisolated(unsafe)` in the Swift tier is named here, so a new one is a
# finding rather than a silence.
MANIFEST = "Package.swift"
SWIFT_VERSION = re.compile(r"-swift-version")
NONISOLATED = re.compile(r"nonisolated\(unsafe\)\s+"
                         r"(?:public\s+|private\s+|internal\s+)?"
                         r"(?:static\s+)?(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)")
NONISOLATED_SITES = {
    ("bindings/swift/KayaApp.swift", "ambient"):
        "the process's one app object, written once and read on the app thread",
    ("bindings/swift/KayaApp.swift", "appThread"):
        "claimed by dispatchLoop, read at every transaction gate",
    ("bindings/swift/KayaApp.swift", "app"):
        "run() hands the app object to the app thread and the calling "
        "thread then enters kaya_run and never returns",
    ("bindings/swift/KayaRecords.swift", "kayaFieldIndexes"):
        "key path -> wire index, app-thread only",
}


def swift_mode_findings(bodies, manifest):
    """Findings for the Swift language mode. Takes the texts so the
    watched negatives below can hand it doctored ones."""
    bad = []
    if ".swiftLanguageMode(.v6)" not in manifest:
        bad.append(f"{MANIFEST}: the Kaya target does not declare "
                   f".swiftLanguageMode(.v6) — the binding's language "
                   f"mode is declared in the manifest and nowhere else")
    if "swift-tools-version: 6" not in manifest:
        bad.append(f"{MANIFEST}: swift-tools-version is not 6.x, so "
                   f".swiftLanguageMode is not even spellable")
    for rel, text in sorted(bodies.items()):
        for n, line in logical_lines(text):
            if line.lstrip().startswith("#") or not SWIFT_VERSION.search(line):
                continue
            bad.append(
                f"{rel}:{n}: passes -swift-version. The Swift 6 language "
                f"mode is Package.swift's `.swiftLanguageMode(.v6)` and "
                f"nothing else: a guest compiled in Swift 6 SIGTRAPs at "
                f"its first handler (top-level code is @MainActor by "
                f"SE-0343, and Swift 6's dynamic isolation check fires "
                f"when kaya calls that closure on the app thread), and "
                f"the SwiftUI interpreter waits for the app-thread "
                f"SerialExecutor (docs/async-dialogs-plan.md §2.1). Both "
                f"measured 2026-09-18.")
    return bad


def waiver_findings(sources):
    """Every nonisolated(unsafe) in the Swift tier is in the ledger."""
    bad, seen = [], set()
    for rel, text in sorted(sources.items()):
        for name in NONISOLATED.findall(text):
            seen.add((rel, name))
            if (rel, name) not in NONISOLATED_SITES:
                bad.append(f"{rel}: `{name}` is nonisolated(unsafe) and is "
                           f"not in check-pins' NONISOLATED_SITES. A waiver "
                           f"is a debt and this table is its ledger: add it "
                           f"with the external synchronisation that makes "
                           f"the claim true, or make the claim unnecessary")
    for rel, name in sorted(NONISOLATED_SITES):
        if (rel, name) not in seen:
            bad.append(f"{rel}: check-pins' NONISOLATED_SITES names `{name}` "
                       f"({NONISOLATED_SITES[(rel, name)]}) and the file no "
                       f"longer carries it — a stale waiver is the next "
                       f"stale audit")
    return bad


_manifest = (root / MANIFEST).read_text(encoding="utf-8")
_swift_sources = {
    f.relative_to(root).as_posix(): f.read_text(encoding="utf-8")
    for f in sorted(list((root / "bindings/swift").glob("*.swift"))
                    + list((root / "guests/swift").glob("*.swift")))}
out += swift_mode_findings(_swiftpm_bodies, _manifest)
out += waiver_findings(_swift_sources)

SWIFT_MODE_NEGATIVES = [
    ("the manifest's language mode dropped", "manifest",
     ".swiftLanguageMode(.v6)", ".swiftLanguageMode(.v5)",
     "does not declare .swiftLanguageMode"),
    ("the tools version dropped", "manifest",
     "swift-tools-version: 6.0", "swift-tools-version: 5.10",
     "swift-tools-version is not 6.x"),
    ("a guest compile asking for Swift 6", "tools/swift-typecheck.sh",
     "    if ! kaya_swiftc -typecheck \\\n",
     "    if ! kaya_swiftc -typecheck -swift-version 6 \\\n",
     "passes -swift-version"),
    ("the interpreter compiled in Swift 6", "tools/swiftui/build-dylib.sh",
     "\n    -warnings-as-errors \\\n",
     "\n    -warnings-as-errors -swift-version 6 \\\n",
     "passes -swift-version"),
    ("a fourth compile site", "tools/a-new-lane.py",
     None, 'PAYLOAD = """\nswiftc -swift-version 6 x.swift\n"""\n',
     "passes -swift-version"),
]
_mrefused, _mcounts = 0, []
for _label, _who, _old, _new, _expect in SWIFT_MODE_NEGATIVES:
    _bodies = dict(_swiftpm_bodies)
    _man = _manifest
    if _who == "manifest":
        _n = _man.count(_old)
        _man = _man.replace(_old, _new, 1)
    elif _old is None:
        _n = 1
        _bodies[_who] = _new
    else:
        _n = _bodies.get(_who, "").count(_old)
        _bodies[_who] = _bodies.get(_who, "").replace(_old, _new, 1)
    _mcounts.append(str(_n))
    if _n != 1:
        out.append(f"check-pins: watched negative {_label!r} applied {_n} "
                   f"substitution(s); an unperturbed copy is a failed test")
        continue
    _got = swift_mode_findings(_bodies, _man)
    if any(_expect in g for g in _got):
        _mrefused += 1
    else:
        out.append(f"check-pins: watched negative {_label!r} was NOT "
                   f"refused naming {_expect!r} (findings: {_got})")
WAIVER_NEGATIVES = [
    ("a fifth waiver in the binding", "bindings/swift/KayaSums.swift",
     "import Foundation",
     "import Foundation\n\nnonisolated(unsafe) var kayaSneak = 0",
     "not in check-pins' NONISOLATED_SITES"),
    ("a waiver in a guest", "guests/swift/todos.swift",
     "import Foundation",
     "import Foundation\n\nnonisolated(unsafe) var kayaSneak = 0",
     "not in check-pins' NONISOLATED_SITES"),
    ("a declared waiver removed", "bindings/swift/KayaRecords.swift",
     "nonisolated(unsafe) private var kayaFieldIndexes",
     "private var kayaFieldIndexes",
     "no longer carries it"),
]
for _label, _who, _old, _new, _expect in WAIVER_NEGATIVES:
    _srcs = dict(_swift_sources)
    _n = _srcs.get(_who, "").count(_old)
    _mcounts.append(str(_n))
    if _n != 1:
        out.append(f"check-pins: watched negative {_label!r} applied {_n} "
                   f"substitution(s); an unperturbed copy is a failed test")
        continue
    _srcs[_who] = _srcs[_who].replace(_old, _new, 1)
    _got = waiver_findings(_srcs)
    if any(_expect in g for g in _got):
        _mrefused += 1
    else:
        out.append(f"check-pins: watched negative {_label!r} was NOT "
                   f"refused naming {_expect!r} (findings: {_got})")
print(f"check-pins: swift language mode: the manifest alone, "
      f"{len(_swiftpm_bodies)} tools file(s) read for -swift-version, "
      f"{len(NONISOLATED_SITES)} waiver(s) in the ledger over "
      f"{len(_swift_sources)} Swift file(s), "
      f"{_mrefused}/{len(SWIFT_MODE_NEGATIVES) + len(WAIVER_NEGATIVES)} "
      f"watched negatives refused (substitutions {'/'.join(_mcounts)})",
      file=sys.stderr)

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
