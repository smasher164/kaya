#!/usr/bin/env bash

kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — re-enter \`nix develop\`" >&2
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

for f in findings:
    print(f, file=sys.stderr)
sys.exit(1 if findings else 0)
PY
}

# --- self-tests: each perturbation applied to a COPY, count printed --
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

shadow() {
    mkdir -p "$T/$1/tools/linux" "$T/$1/tools/scenes" "$T/$1/guests/python"
    cp tools/validate-mac.sh tools/deploy-win.sh "$T/$1/tools/"
    cp tools/linux/run-suites.sh "$T/$1/tools/linux/"
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

if ! out="$(check "$ROOT" 2>&1)"; then
    echo "$out" >&2
    echo "check-staging: FINDINGS ABOVE" >&2
    exit 1
fi
echo "check-staging: OK (mac rust staging, windows suite lists, scene scripts and python guests all derive)"
