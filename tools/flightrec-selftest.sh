#!/usr/bin/env bash

# Dev-shell guard; the marker is the flake fingerprint (CLAUDE.md).
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi

# THE FLIGHT RECORDER'S CAPTURE PATHS, WATCHED FIRING.
#
# NOT a numbered gate, and the name says so — tools/check-gates.sh's census
# reads `tools/check-*.sh` and `tools/gen-*.sh` as gates and would demand
# this be registered in gates.sh, CLAUDE.md and AGENTS.md; worse, its
# delegation clause forbids tools/validate-mac.sh from invoking anything
# gate-shaped at all, and the mac runner is exactly who needs to run this.
# What it proves is a RUNTIME property of a host — that the capture
# commands on THIS machine actually answer — which a static gate cannot
# see anyway.
#
# It drives the REAL run() cut out of tools/validate-mac.sh, the shape
# tools/check-harness-ceiling.sh uses when it cuts the watchdog out of
# KayaSwiftUI.swift and compiles it: a paraphrase of the runner would
# prove only that the paraphrase works.
#
# The tree is never modified. Every perturbation lands on a COPY, the
# substitution count is printed, and the real files' hashes are compared
# before and after — an unchanged copy is a failed test, not a passed one.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

fail() {
    echo "flightrec-selftest: $*" >&2
    exit 1
}

applied() { # <count> <label>
    echo "flightrec-selftest: $2, $1 substitution(s)"
    if [ "$1" != 1 ]; then
        fail "SELF-TEST BROKEN ($2 applied $1, want 1) — a perturbation that changed nothing is a passed test that proves nothing"
    fi
}

doctor() { # <file> <pattern> <replacement> -> prints the count
    python3 - "$@" <<'PY'
import pathlib
import re
import sys

path, pattern, repl = sys.argv[1:4]
p = pathlib.Path(path)
text = p.read_text(encoding="utf-8")
out, n = re.subn(pattern, repl, text, count=1, flags=re.M)
p.write_text(out, encoding="utf-8")
print(n)
PY
}

# The real run() function, cut out of the real runner by brace depth.
extract_run() { # <validate-mac.sh> <dest>
    python3 - "$@" <<'PY'
import pathlib
import sys

src, dest = sys.argv[1], sys.argv[2]
lines = pathlib.Path(src).read_text(encoding="utf-8").splitlines(keepends=True)
start = None
for i, line in enumerate(lines):
    if line.startswith("run() {"):
        start = i
        break
if start is None:
    sys.exit("flightrec-selftest: no run() in the runner — the extraction anchor moved")
depth = 0
end = None
for i in range(start, len(lines)):
    depth += lines[i].count("{") - lines[i].count("}")
    if depth == 0 and i > start:
        end = i
        break
if end is None:
    sys.exit("flightrec-selftest: run() never closed")
pathlib.Path(dest).write_text("".join(lines[start : end + 1]), encoding="utf-8")
print(end - start + 1)
PY
}

# A harness that gives the extracted run() the handful of names the runner
# would have given it, and nothing else.
write_driver() { # <dest> <lib> <run-body> [<leg-name> <leg-cmd>]
    cat >"$1" <<DRIVER
#!/usr/bin/env bash
set -uo pipefail
FLIGHTREC_ROOT="$ROOT"
export FLIGHTREC_ROOT
# The runner has this sourced, and without it kaya_swiftc is undefined,
# the window list cannot be built and two sections skip for a reason
# belonging to the harness rather than to the host.
source "$ROOT/tools/lib/swift-toolchain.sh"
source "$2"
flightrec_start mac
JOBS=1
status=0
LEGS_DIR="\$(mktemp -d)"
FLIGHTREC_SCRATCH="\$(mktemp -d)"
leg_names=()
leg_pids=()
running_legs() { echo 0; }
source "$3"
run ${4:-alwaysfail} ${5:-/usr/bin/false}
# The journal is SPOOLED on the leg path and turned into records once,
# exactly as the runner's lane end and EXIT trap do it.
flightrec_flush
echo "driver: status=\$status"
echo "driver: run=\$FLIGHTREC_RUN"
rm -rf "\$LEGS_DIR" "\$FLIGHTREC_SCRATCH"
DRIVER
    chmod +x "$1"
}

# Every section the mac capture is supposed to account for. A section that
# stops being collected must be a RED here, not a quietly shorter bundle —
# which is the whole failure class this file exists for.
WANT_SECTIONS="sampler sample leg-log windowserver windows shot unified-log"

check_bundle() { # <journal-home> -> prints the manifest path, or fails
    local home="$1"
    local manifest
    manifest="$(find "$home" -name MANIFEST -type f | head -1)"
    if [ -z "$manifest" ]; then
        fail "no bundle was written for a FAILING leg — the capture never fired"
    fi
    echo "$manifest"
}

sections_present() { # <manifest> -> prints missing sections, empty if none
    python3 - "$1" "$WANT_SECTIONS" <<'PY'
import pathlib
import sys

manifest, want = sys.argv[1], sys.argv[2].split()
seen = set()
for line in pathlib.Path(manifest).read_text(encoding="utf-8").splitlines():
    parts = line.split()
    if parts:
        seen.add(parts[0])
print(" ".join(s for s in want if s not in seen))
PY
}

# ---------------------------------------------------------------------
# The real files' hashes, before anything. Nothing here may modify the
# tree, and this is what proves it rather than asserting it.
REAL_LIB="$ROOT/tools/lib/flightrec.sh"
REAL_MAC="$ROOT/tools/validate-mac.sh"
REAL_PY="$ROOT/tools/lib/flightrec.py"
before_sha="$(shasum -a 256 "$REAL_LIB" "$REAL_MAC" "$REAL_PY" | shasum -a 256)"

lines="$(extract_run "$REAL_MAC" "$T/run.sh")" || fail "could not cut run() out of the runner"
echo "flightrec-selftest: cut run() out of tools/validate-mac.sh ($lines lines)"

# --- N0: the untouched shape must PASS, or every refusal below could be
# an artifact of the extraction rather than of a perturbation. ----------
mkdir -p "$T/n0"
cp "$REAL_LIB" "$T/n0/flightrec.sh"
write_driver "$T/n0/driver.sh" "$T/n0/flightrec.sh" "$T/run.sh"
KAYA_FLIGHTREC_DIR="$T/n0/journal" bash "$T/n0/driver.sh" >"$T/n0.log" 2>&1
n0_rc=$?
if [ "$n0_rc" != 0 ]; then
    cat "$T/n0.log" >&2
    fail "N0: the untouched driver exited $n0_rc — this is the tree, not the self-test"
fi
if ! grep -q "driver: status=1" "$T/n0.log"; then
    cat "$T/n0.log" >&2
    fail "N0: an always-failing leg did not produce status=1"
fi
manifest="$(check_bundle "$T/n0/journal")" || exit 1
missing="$(sections_present "$manifest")"
if [ -n "$missing" ]; then
    cat "$manifest" >&2
    fail "N0: the bundle is missing sections: $missing"
fi
count="$(wc -l <"$manifest" | tr -d ' ')"
echo "flightrec-selftest: N0 bundle accounted for $count section(s): $(tr '\n' ' ' <"$manifest")"
if ! grep -q "flightrec: bundle .* sections" "$T/n0.log"; then
    fail "N0: the bundle's counts were never printed — a capture nobody can see stopped working is a capture nobody notices"
fi
# The journal must carry the leg, with the verdict and the bundle path.
journal="$(find "$T/n0/journal" -name journal.jsonl | head -1)"
if ! grep -q '"leg":"alwaysfail"' "$journal" || ! grep -q '"verdict":"FAIL"' "$journal"; then
    cat "$journal" >&2
    fail "N0: the journal has no FAIL record for the leg"
fi
echo "flightrec-selftest: N0 journal recorded the leg"

# --- N1: a section that stops being collected must be caught. ----------
mkdir -p "$T/n1"
cp "$REAL_LIB" "$T/n1/flightrec.sh"
hits="$(doctor "$T/n1/flightrec.sh" \
    '^    flightrec_section "\$bundle" "windowserver" ps \\$' \
    '    : \\')"
applied "$hits" "N1 removed the windowserver section"
write_driver "$T/n1/driver.sh" "$T/n1/flightrec.sh" "$T/run.sh"
KAYA_FLIGHTREC_DIR="$T/n1/journal" bash "$T/n1/driver.sh" >"$T/n1.log" 2>&1
manifest="$(check_bundle "$T/n1/journal")" || exit 1
missing="$(sections_present "$manifest")"
case "$missing" in
    *windowserver*) echo "flightrec-selftest: N1 refused — the missing section was named" ;;
    *) fail "N1: a bundle with the windowserver section deleted was accepted (missing='$missing')" ;;
esac

# --- N2: the honest skip. A capture tool this host does not have must
# leave a .skip naming it, never a silently absent section. -------------
mkdir -p "$T/n2"
cp "$REAL_LIB" "$T/n2/flightrec.sh"
hits="$(doctor "$T/n2/flightrec.sh" \
    '^    flightrec_section "\$bundle" "unified-log" log \\$' \
    '    flightrec_section "$bundle" "unified-log" no-such-tool-on-any-host \\')"
applied "$hits" "N2 pointed the unified-log section at an absent tool"
write_driver "$T/n2/driver.sh" "$T/n2/flightrec.sh" "$T/run.sh"
KAYA_FLIGHTREC_DIR="$T/n2/journal" bash "$T/n2/driver.sh" >"$T/n2.log" 2>&1
manifest="$(check_bundle "$T/n2/journal")" || exit 1
skipfile="$(dirname "$manifest")/unified-log.skip"
if [ ! -s "$skipfile" ]; then
    fail "N2: an absent capture tool left no .skip — the section would be silently missing"
fi
if ! grep -q "no-such-tool-on-any-host" "$skipfile"; then
    cat "$skipfile" >&2
    fail "N2: the skip sentence does not name the tool that was missing"
fi
if ! grep -q "^unified-log skip" "$manifest"; then
    fail "N2: the manifest did not record the skip"
fi
echo "flightrec-selftest: N2 the honest skip named the absent tool"

# --- N3: retention is real, and the cap is printed. --------------------
mkdir -p "$T/n3"
for i in 1 2 3 4; do
    KAYA_FLIGHTREC_DIR="$T/n3/journal" KAYA_FLIGHTREC_KEEP=2 \
        python3 "$REAL_PY" start mac "$ROOT" >"$T/n3-$i.out" 2>"$T/n3-$i.err"
done
kept="$(find "$T/n3/journal/runs" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
if [ "$kept" != 2 ]; then
    fail "N3: retention kept $kept run(s) with the cap at 2"
fi
if ! grep -q "retention: newest 2 runs" "$T/n3-4.err"; then
    cat "$T/n3-4.err" >&2
    fail "N3: the retention cap was never printed"
fi
if ! grep -q "pruned" "$T/n3-4.err"; then
    fail "N3: the prune count was never printed"
fi
echo "flightrec-selftest: N3 retention held 4 runs to 2, cap printed"

# --- N4: a runner that cannot open the journal still runs its legs, and
# says so ONCE. ---------------------------------------------------------
mkdir -p "$T/n4"
cp "$REAL_LIB" "$T/n4/flightrec.sh"
write_driver "$T/n4/driver.sh" "$T/n4/flightrec.sh" "$T/run.sh"
# A journal home that cannot be created: a path under a FILE.
: >"$T/n4/blocker"
KAYA_FLIGHTREC_DIR="$T/n4/blocker/journal" bash "$T/n4/driver.sh" >"$T/n4.log" 2>&1
n4_rc=$?
if [ "$n4_rc" != 0 ]; then
    cat "$T/n4.log" >&2
    fail "N4: an unwritable journal took the leg down with it — the recorder must never cost a lane its legs"
fi
if ! grep -q "driver: status=1" "$T/n4.log"; then
    cat "$T/n4.log" >&2
    fail "N4: the leg did not run when the journal was unavailable"
fi
misses="$(grep -c "flightrec: the journal could not be opened" "$T/n4.log")"
if [ "$misses" != 1 ]; then
    cat "$T/n4.log" >&2
    fail "N4: the journal miss was printed $misses times, want exactly 1"
fi
echo "flightrec-selftest: N4 an unwritable journal cost no leg and printed the miss once"

# --- N6: A PASSING LEG COSTS THE OBSERVER NOTHING. ---------------------
#
# THE REGRESSION THIS EXISTS FOR: the first version spent three ssh round
# trips and a python3 spawn on EVERY leg, pass or fail — measured 304ms on
# a quiescent VM — and took the windows lane 110s past its duration ceiling
# on the recorder's first matrix. A lane's ceiling is the only thing that
# noticed, and only once the whole matrix had run. This is the wall that
# notices in seconds.
mkdir -p "$T/n6"
cp "$REAL_LIB" "$T/n6/flightrec.sh"
write_driver "$T/n6/driver.sh" "$T/n6/flightrec.sh" "$T/run.sh" alwayspass /usr/bin/true
KAYA_FLIGHTREC_DIR="$T/n6/journal" bash "$T/n6/driver.sh" >"$T/n6.log" 2>&1
n6_rc=$?
if [ "$n6_rc" != 0 ]; then
    cat "$T/n6.log" >&2
    fail "N6: the passing-leg driver exited $n6_rc"
fi
if ! grep -q "driver: status=0" "$T/n6.log"; then
    cat "$T/n6.log" >&2
    fail "N6: the passing leg did not report status=0"
fi
# NOTHING BUNDLE-SHAPED on the pass path.
if [ -n "$(find "$T/n6/journal" -type d -name 'mac-*' 2>/dev/null)" ]; then
    find "$T/n6/journal" -type d -name 'mac-*' >&2
    fail "N6: a PASSING leg scaffolded a bundle — the pass path must create nothing"
fi
# The record still exists, via the spool.
journal="$(find "$T/n6/journal" -name journal.jsonl | head -1)"
if ! grep -q '"leg":"alwayspass"' "$journal" || ! grep -q '"verdict":"PASS"' "$journal"; then
    cat "$journal" >&2
    fail "N6: the passing leg was not journalled"
fi
# And the spool was truncated by the flush, so a second flush cannot
# double every record.
spool="$(find "$T/n6/journal" -name spool.tsv | head -1)"
if [ -n "$spool" ] && [ -s "$spool" ]; then
    fail "N6: the spool survived the flush — a second flush would write every record twice"
fi
# THE STATIC HALF: the leg-record path may not spawn or speak to the VM.
body="$(python3 - "$REAL_LIB" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
m = re.search(r"^flightrec_leg\(\) \{.*?^\}", text, re.S | re.M)
print(m.group(0) if m else "")
PY
)"
if [ -z "$body" ]; then
    fail "N6: flightrec_leg could not be read out of the library — the anchor moved"
fi
for banned in python3 run_ssh scp mkdir; do
    if printf '%s\n' "$body" | grep -v '^\s*#' | grep -q "\\b$banned\\b"; then
        printf '%s\n' "$body" >&2
        fail "N6: flightrec_leg calls '$banned' — it runs on every leg of two lanes and must not spawn or speak to the VM"
    fi
done
echo "flightrec-selftest: N6 a passing leg made no bundle, spawned nothing, and was journalled through the spool"

# --- N5: every shipped .ps1 is pure ASCII. -----------------------------
#
# MEASURED, on the first run against the VM: Windows PowerShell 5.1 reads a
# .ps1 as the machine's ANSI CODEPAGE, not as UTF-8. An em-dash then
# arrives as the three bytes CP1252 shows as `a€"` — and that sequence
# CONTAINS A DOUBLE QUOTE. Inside a string literal it closes the string
# early and the file dies with "Unexpected token" before its first
# statement; the scheduled task exits having created nothing, and the
# runner sees only missing files, which is indistinguishable from a
# capture that had nothing to collect.
#
# THE RULE IS CODE LINES, NOT ALL LINES, and the difference is measured
# too: tools/guest/desk-warm.ps1 and wait-exit.ps1 have carried em-dashes
# for months and work, because theirs are in WHOLE-LINE COMMENTS, where
# PowerShell ignores the rest of the line and the stray quote never
# tokenizes. A blanket ASCII rule would redden two files that are fine and
# would be turned off; this refuses non-ASCII only where it can bite.
# Nothing else in the tree looks: check-shell walks tools/ for .sh and
# .cmd and never .ps1.
nonascii="$(python3 - "$ROOT" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
findings = []
for p in sorted((root / "tools" / "guest").glob("*.ps1")):
    for n, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        for ch in line:
            if ord(ch) > 127:
                findings.append(f"{p.relative_to(root)}:{n}: U+{ord(ch):04X} {ch!r}")
                break
print("\n".join(findings))
PY
)"
if [ -n "$nonascii" ]; then
    echo "$nonascii" >&2
    fail "N5: a shipped .ps1 carries non-ASCII — Windows PowerShell reads it in the ANSI codepage and the file will not parse on the guest"
fi
checked="$(find "$ROOT/tools/guest" -name '*.ps1' | wc -l | tr -d ' ')"
if [ "$checked" -lt 1 ]; then
    fail "N5: no .ps1 was read — a census that reads nothing agrees with everything"
fi
echo "flightrec-selftest: N5 $checked shipped .ps1 file(s) carry no non-ASCII on a code line"

# N5's own negative, on a shadow: the exact shape that broke on the VM —
# an em-dash inside a string literal — must be refused, while an em-dash in
# a whole-line COMMENT must not be, or the clause is either blind or
# unusable. Both directions are perturbed here.
#
# APPENDED RATHER THAN SUBSTITUTED, deliberately. An anchor onto some
# particular line of flightrec.ps1 goes stale the moment that line is
# reworded — it did, on this very clause, the first time the guest half was
# rewritten, and the `applied 0` check is what caught it. What this rule is
# about is CHARACTERS, not a construct, so there is no spelling it needs to
# be proven against.
mkdir -p "$T/n5"
cp "$ROOT/tools/guest/flightrec.ps1" "$T/n5/flightrec.ps1"
hits="$(python3 - "$T/n5/flightrec.ps1" <<'PY'
import pathlib
import sys

p = pathlib.Path(sys.argv[1])
p.write_text(
    p.read_text(encoding="utf-8")
    + "# a comment em-dash — must be tolerated\n"
    + 'Emit $out "a literal em-dash — must not be"\n',
    encoding="utf-8",
)
print(1)
PY
)"
applied "$hits" "N5 appended an em-dash in a comment AND in a string literal"
n5="$(python3 - "$T/n5" <<'PY'
import pathlib
import sys

findings = []
for p in sorted(pathlib.Path(sys.argv[1]).glob("*.ps1")):
    for n, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        for ch in line:
            if ord(ch) > 127:
                findings.append(f"{p.name}:{n}: U+{ord(ch):04X}")
                break
print("\n".join(findings))
PY
)"
if [ -z "$n5" ]; then
    fail "SELF-TEST FAIL (N5: an em-dash in a string literal was not refused — the clause is blind)"
fi
# EXACTLY ONE. Two findings would mean the comment line was refused as
# well, which is the direction that would redden desk-warm.ps1 and
# wait-exit.ps1 — files that have carried em-dashes for months and work.
n5count="$(printf '%s\n' "$n5" | wc -l | tr -d ' ')"
if [ "$n5count" != 1 ]; then
    printf '%s\n' "$n5" >&2
    fail "SELF-TEST FAIL (N5: $n5count findings, want exactly 1 — the comment line must be tolerated and only the literal refused)"
fi
echo "flightrec-selftest: N5 refused the literal and tolerated the comment ($n5)"

# --- the tree is as it was found. --------------------------------------
after_sha="$(shasum -a 256 "$REAL_LIB" "$REAL_MAC" "$REAL_PY" | shasum -a 256)"
if [ "$after_sha" != "$before_sha" ]; then
    fail "REFUSING A VERDICT — this self-test modified the tree it was testing"
fi
echo "flightrec-selftest: the tree is unchanged ($before_sha)"
echo "flightrec-selftest: OK (7 clauses, 4 watched perturbations)"
