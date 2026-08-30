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
set -u

# A LEG'S ARTIFACT MUST BE IN THE STAGING DERIVATION (maintainer,
# 2026-08-25): a runner that wires a leg whose binary the same file
# never stages fails ten minutes into a matrix with "No such file",
# when a census over the runner's own text can say it in seconds — the
# windowed-rust mac leg is the measured instance (wired hand-queued,
# absent from the SCENES/DEPTH_SCENES derivation that populates
# $RUST_GUESTS). Every finding names the leg AND the list to extend.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

check() { # <root>
    python3 - "$1" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
findings = []


def fail(text):
    findings.append("check-staging: " + text)


def words(text, name):
    m = re.search(rf'^{name}="([^"]*)"', text, re.M)
    if not m:
        return None
    # ${VAR:-default} spellings keep their default.
    body = re.sub(r"\$\{[A-Z_]+:-([^}]*)\}", r"\1", m.group(1))
    return set(body.split())


# --- validate-mac: $RUST_GUESTS refs vs SCENES + DEPTH_SCENES --------
mac = (root / "tools" / "validate-mac.sh").read_text(encoding="utf-8")
scenes = words(mac, "SCENES")
depth = words(mac, "DEPTH_SCENES")
if scenes is None or depth is None:
    fail("tools/validate-mac.sh no longer declares SCENES/DEPTH_SCENES where "
         "this census reads them — the staging derivation is unreadable")
else:
    staged = scenes | depth
    for m in re.finditer(r'"\$RUST_GUESTS"/([A-Za-z0-9_-]+)', mac):
        name = m.group(1)
        if name not in staged:
            fail(f"tools/validate-mac.sh runs \"$RUST_GUESTS\"/{name} but "
                 f"{name} is in neither SCENES nor DEPTH_SCENES, so the "
                 f"staging loop never copies it and the leg dies at run "
                 f"time with 'No such file' — add {name} to DEPTH_SCENES "
                 f"(or SCENES if every language has the guest)")

# --- deploy-win: run_suite scenes vs its build lists -----------------
win = (root / "tools" / "deploy-win.sh").read_text(encoding="utf-8")
wscenes = words(win, "SCENES")
wdepth = words(win, "DEPTH_SCENES")
wgo = words(win, "GO_ONLY_SCENES")
wpy = words(win, "PY_ONLY_SCENES")
if None in (wscenes, wdepth, wgo, wpy):
    fail("tools/deploy-win.sh no longer declares its four scene lists where "
         "this census reads them")
else:
    # A suite's ARTIFACT is what its checked-in launcher names, not the
    # suite's own word: listdetail runs split.exe (two scenes, one
    # guest), so the launcher is the only honest derivation source.
    exes = wscenes | wdepth | wgo
    pys = wscenes | wpy
    for m in re.finditer(r"^\s*run_suite ([a-z0-9]+_[a-z0-9]+)\b", win, re.M):
        suite = m.group(1)
        launcher = root / "tools" / "guest" / f"run_{suite}.cmd"
        if not launcher.is_file():
            fail(f"tools/deploy-win.sh runs run_suite {suite} but "
                 f"tools/guest/run_{suite}.cmd does not exist — the "
                 f"scheduled task would start nothing and the leg waits "
                 f"out its whole deadline")
            continue
        body = launcher.read_text(encoding="utf-8", errors="replace")
        for e in re.finditer(r"(?:^|[\s\\])([a-z0-9_]+)\.exe\b", body, re.M):
            base = e.group(1)
            # Runtimes are not guest artifacts: what python.exe RUNS is
            # the .py clause's business, and dotnet/java ship their own
            # guest trees whole.
            if base in ("python", "pythonw", "java", "dotnet", "cmd",
                        "wscript", "cscript", "schtasks", "taskkill"):
                continue
            scene = base[:-3] if base.endswith("_go") else base
            if scene not in exes:
                fail(f"tools/guest/run_{suite}.cmd runs {base}.exe but "
                     f"{scene} is in none of deploy-win's SCENES / "
                     f"DEPTH_SCENES / GO_ONLY_SCENES, so the deploy never "
                     f"builds or ships it — add {scene} to the matching "
                     f"list")
        for p in re.finditer(r"C:\\kaya\\([a-z0-9_]+)\.py\b", body):
            name = p.group(1)
            if name not in pys or not (
                root / "guests" / "python" / f"{name}.py"
            ).is_file():
                fail(f"tools/guest/run_{suite}.cmd runs {name}.py but "
                     f"{name} is not a shipped python guest (SCENES / "
                     f"PY_ONLY_SCENES with guests/python/{name}.py) — the "
                     f"deploy never stages it")

# --- every runner: a wired scene has its .steps, a python leg its file
runners = [
    "tools/validate-mac.sh",
    "tools/deploy-win.sh",
    "tools/linux/run-suites.sh",
]
for rel in runners:
    text = (root / rel).read_text(encoding="utf-8")
    for m in re.finditer(r"KAYA_SELFTEST=([a-z0-9_]+)\b", text):
        scene = m.group(1)
        if scene in ("1",):
            continue
        if not (root / "tools" / "scenes" / f"{scene}.steps").is_file():
            fail(f"{rel} wires KAYA_SELFTEST={scene} but "
                 f"tools/scenes/{scene}.steps does not exist — the leg "
                 f"would run against a missing script")
    for m in re.finditer(r"guests/python/([a-z0-9_]+\.py)\b", text):
        if not (root / "guests" / "python" / m.group(1)).is_file():
            fail(f"{rel} runs guests/python/{m.group(1)}, which does not "
                 f"exist")

# --- the iOS bundle: a leg's WINDOW GEOMETRY is not unpinned state ----
# An app declaring no supported orientations inherits the DEVICE's, and
# the same phone then reports 375x734 or 724x355 depending on how the
# simulator happens to be turned. `adaptive`'s breakpoint is declared at
# 520, so one of those two widths makes `expect_axis row@narrow
# "vertical"` true and the other makes it false — same build, no code in
# between, and the verdict is CORRECT both times, which is why no rerun
# could ever explain it (measured 2026-08-29, docs/traps.md). The pool's
# device TYPE is pinned in run-sim.sh; this is its geometry.
plist = (root / "tools/ios/Info.plist.in").read_text(encoding="utf-8")
for key in ("UISupportedInterfaceOrientations",
            "UISupportedInterfaceOrientations~ipad"):
    m = re.search(rf"<key>{re.escape(key)}</key>\s*<array>(.*?)</array>",
                  plist, re.S)
    if not m:
        fail(f"tools/ios/Info.plist.in declares no <{key}> — every iOS leg's "
             f"window width would then follow the simulator's orientation, "
             f"which nothing in the lane sets")
        continue
    orientations = re.findall(r"<string>([^<]+)</string>", m.group(1))
    if len(orientations) != 1:
        fail(f"tools/ios/Info.plist.in lets <{key}> take {orientations} — a "
             f"leg's width must not depend on how the device is turned, so "
             f"exactly one orientation is declared")

# --- every guest .ps1 is in BOTH windows lists ------------------------
# The .cmd and .vbs families ride GLOBS, so a new one ships itself; a
# .ps1 is named individually in deploy_stamp AND in DEPLOY_ARTIFACTS,
# and deploy-win.sh's own comment says which half is worse — missing
# from the STAMP, the stamp does not move, the whole deploy block is
# skipped, and the lane runs against a file that is not there. That
# comment was the only thing holding the rule: shot-window.ps1 shipped
# with its .cmd riding the glob beside it and the .ps1 in NEITHER list,
# so the launcher was staged and the script it runs was not.
win = (root / "tools/deploy-win.sh").read_text(encoding="utf-8")


def block(text, opener, closer):
    start = text.find(opener)
    if start < 0:
        return None
    end = text.find(closer, start + len(opener))
    return text[start:end] if end > 0 else None


stamp_block = block(win, 'shasum -a 256 "$0"', "\n    }")
artifacts_block = block(win, "DEPLOY_ARTIFACTS=(", "\n    )")
guest_dir = root / "tools" / "guest"
ps1s = sorted(p.name for p in guest_dir.glob("*.ps1")) if guest_dir.is_dir() else []
if stamp_block is None or artifacts_block is None:
    fail("tools/deploy-win.sh no longer spells deploy_stamp's shasum list or "
         "DEPLOY_ARTIFACTS where this census reads them — re-point the clause")
elif not ps1s:
    fail("tools/guest holds no .ps1 at all — a census that reads nothing "
         "agrees with everything")
else:
    for where, body in (("deploy_stamp", stamp_block),
                        ("DEPLOY_ARTIFACTS", artifacts_block)):
        if "tools/guest/*.ps1" in body:
            continue  # a glob covers the whole family
        for name in ps1s:
            if f"tools/guest/{name}" not in body:
                fail(f"tools/guest/{name} is staged to the Windows guest by "
                     f"neither glob nor name in {where} — a .ps1 is named "
                     f"individually in BOTH deploy_stamp and "
                     f"DEPLOY_ARTIFACTS, and missing it from the stamp means "
                     f"the deploy block never runs at all")

for f in findings:
    print(f, file=sys.stderr)
sys.exit(1 if findings else 0)
PY
}

# --- self-tests: each perturbation applied to a COPY, count printed --
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

shadow() {
    mkdir -p "$T/$1/tools/linux" "$T/$1/tools/scenes" "$T/$1/tools/ios" \
        "$T/$1/guests/python"
    cp tools/validate-mac.sh tools/deploy-win.sh "$T/$1/tools/"
    cp tools/linux/run-suites.sh "$T/$1/tools/linux/"
    cp tools/ios/Info.plist.in "$T/$1/tools/ios/"
    cp -R tools/scenes "$T/$1/tools/" 2>/dev/null
    cp -R tools/guest "$T/$1/tools/" 2>/dev/null
    cp -R guests/python "$T/$1/guests/" 2>/dev/null
    echo "$T/$1"
}

doctor() { # <root> <rel> <pattern> <replacement>
    python3 - "$@" <<'PY'
import pathlib
import re
import sys
root, rel, pattern, repl = sys.argv[1:5]
p = pathlib.Path(root) / rel
text = p.read_text(encoding="utf-8")
out, n = re.subn(pattern, repl, text, count=1, flags=re.M)
p.write_text(out, encoding="utf-8")
print(n)
PY
}

refuses() { # <root> <fragment> <label>
    local out
    if out="$(check "$1" 2>&1)"; then
        echo "check-staging: SELF-TEST FAIL ($3 passed)" >&2
        exit 1
    fi
    case "$out" in
        *"$2"*) ;;
        *)
            echo "check-staging: SELF-TEST FAIL ($3 reddened without naming '$2'):" >&2
            echo "$out" >&2
            exit 1
            ;;
    esac
    echo "check-staging: self-test — $3 refused"
}

s="$(shadow n1)"
hits="$(doctor "$s" tools/validate-mac.sh \
    'run windowed-rust-swiftui env KAYA_SELFTEST=windowed "\$RUST_GUESTS"/windowed' \
    'run windowed-rust-swiftui env KAYA_SELFTEST=windowed "$RUST_GUESTS"/windowed
run ghost-rust-swiftui env KAYA_SELFTEST=windowed "$RUST_GUESTS"/ghost')"
echo "check-staging: self-test N1 wired an unstaged mac rust leg, $hits substitution(s)"
[ "$hits" = 1 ] || { echo "check-staging: SELF-TEST BROKEN (N1 applied $hits)" >&2; exit 1; }
refuses "$s" 'ghost is in neither SCENES nor DEPTH_SCENES' \
    "N1 (a mac leg whose binary the staging loop never copies)"

s="$(shadow n2)"
hits="$(doctor "$s" tools/deploy-win.sh \
    '^        run_suite windowed_rust$' \
    '        run_suite windowed_rust\n        run_suite ghost_python')"
echo "check-staging: self-test N2 wired a suite with no launcher, $hits substitution(s)"
[ "$hits" = 1 ] || { echo "check-staging: SELF-TEST BROKEN (N2 applied $hits)" >&2; exit 1; }
refuses "$s" 'run_ghost_python.cmd does not exist' \
    "N2 (a windows suite whose scheduled task would start nothing)"

s="$(shadow n2b)"
hits="$(doctor "$s" tools/guest/run_listdetail_rust.cmd \
    'split\.exe' 'ghostexe.exe')"
echo "check-staging: self-test N2b pointed a launcher at an unbuilt exe, $hits substitution(s)"
[ "$hits" = 1 ] || { echo "check-staging: SELF-TEST BROKEN (N2b applied $hits)" >&2; exit 1; }
refuses "$s" 'ghostexe is in none of' \
    "N2b (a launcher naming an exe the deploy never builds)"

s="$(shadow n3)"
hits="$(doctor "$s" tools/validate-mac.sh \
    'KAYA_SELFTEST=portfolio python3 guests/python/portfolio\.py' \
    'KAYA_SELFTEST=portfolio python3 guests/python/ghostledger.py')"
echo "check-staging: self-test N3 pointed a leg at a missing guest, $hits substitution(s)"
[ "$hits" = 1 ] || { echo "check-staging: SELF-TEST BROKEN (N3 applied $hits)" >&2; exit 1; }
refuses "$s" 'guests/python/ghostledger.py, which does not' \
    "N3 (a python leg whose guest file is gone)"

s="$(shadow n4)"
hits="$(doctor "$s" tools/ios/Info.plist.in \
    '^        <string>UIInterfaceOrientationPortrait</string>$' \
    '        <string>UIInterfaceOrientationPortrait</string>\n        <string>UIInterfaceOrientationLandscapeLeft</string>')"
echo "check-staging: self-test N4 let the phone bundle turn, $hits substitution(s)"
[ "$hits" = 1 ] || { echo "check-staging: SELF-TEST BROKEN (N4 applied $hits)" >&2; exit 1; }
refuses "$s" 'must not depend on how the device is turned' \
    "N4 (an iOS bundle whose window width follows the simulator)"

s="$(shadow n5)"
hits="$(doctor "$s" tools/ios/Info.plist.in \
    '    <key>UISupportedInterfaceOrientations</key>' \
    '    <key>UIGhostOrientations</key>')"
echo "check-staging: self-test N5 removed the phone pin, $hits substitution(s)"
[ "$hits" = 1 ] || { echo "check-staging: SELF-TEST BROKEN (N5 applied $hits)" >&2; exit 1; }
refuses "$s" 'declares no <UISupportedInterfaceOrientations>' \
    "N5 (an iOS bundle that inherits the device's orientation)"

# The two halves separately, because they fail differently: dropped from
# DEPLOY_ARTIFACTS the file simply never ships, dropped from the STAMP
# the whole deploy block is skipped and the lane runs against what the
# VM happened to hold.
s="$(shadow n6)"
hits="$(doctor "$s" tools/deploy-win.sh \
    '^ {12}"\$ROOT/tools/guest/shot-window\.ps1" \\\n' '')"
echo "check-staging: self-test N6 dropped a guest .ps1 from the stamp, $hits substitution(s)"
[ "$hits" = 1 ] || { echo "check-staging: SELF-TEST BROKEN (N6 applied $hits)" >&2; exit 1; }
refuses "$s" 'neither glob nor name in deploy_stamp' \
    "N6 (a guest .ps1 the deploy stamp cannot see, so the ship is skipped)"

s="$(shadow n7)"
hits="$(doctor "$s" tools/deploy-win.sh \
    '^ {8}"\$ROOT/tools/guest/shot-window\.ps1"\n' '')"
echo "check-staging: self-test N7 dropped a guest .ps1 from the artifacts, $hits substitution(s)"
[ "$hits" = 1 ] || { echo "check-staging: SELF-TEST BROKEN (N7 applied $hits)" >&2; exit 1; }
refuses "$s" 'neither glob nor name in DEPLOY_ARTIFACTS' \
    "N7 (a guest .ps1 that never rides the wire)"

if ! out="$(check "$ROOT" 2>&1)"; then
    echo "$out" >&2
    echo "check-staging: FINDINGS ABOVE" >&2
    exit 1
fi
echo "check-staging: OK (mac rust staging, windows suite lists, scene scripts and python guests all derive; the iOS bundle pins one orientation per family)"
