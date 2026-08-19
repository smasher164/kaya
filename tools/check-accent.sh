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
# THE WINDOWS ACCENT NEAR-NO-OP HAS A WALL. Fluent control styles never
# read `SystemAccentColor` for a fill — they read the six derived stops
# (`SystemAccentColorDark1..3`, `...Light1..3`), theme-crossed — so an
# app that writes the bare key changes the text-selection highlight and
# NOTHING ELSE, silently (microsoft-ui-xaml#6394; the measurement and
# the crossed-stops table live on crates/kaya/src/winui/mod.rs's
# brand_dictionary). The styling scene deliberately reads no pixels for
# this, so no lane can catch the mistake — the ledger filed "this wants
# a gate, not a comment" and this is that gate.
#
# THE DISCRIMINATOR IS THE ELEMENT MARKER: prose says SystemAccentColor
# bare all the time, and the module's own unit test holds the bare key
# as a forbidden NEEDLE (`"x:Key=\"SystemAccentColor\""` in a list) —
# only EMITTED XAML spells `<Color x:Key="SystemAccentColor...`. Every
# such element must carry one of the six derived suffixes, all six
# present exactly once. That unit test is this wall's RENDERED-output
# sibling on the windows guest's unit phase; this one runs in the fast
# sweep on every host.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

WINUI=crates/kaya/src/winui/mod.rs

check() { # $1: the backend source, BY PATH
    python3 - "$1" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
WANT = {"Dark1", "Dark2", "Dark3", "Light1", "Light2", "Light3"}
hits = re.findall(r'<Color x:Key=\\?"SystemAccentColor([A-Za-z0-9]*)\\?"', text)
if not hits:
    print("no <Color x:Key=\"SystemAccentColor...\" markup in the file at all — either "
          "the brand dictionary moved (and this gate is blind) or the accent "
          "override is gone entirely")
    sys.exit(2)
bad = []
seen = {}
for suffix in hits:
    if suffix == "":
        bad.append('x:Key="SystemAccentColor" BARE: the documented near-no-op — '
                   "it moves the text-selection highlight and nothing else, and "
                   "no scene or lane can see the difference")
    elif suffix not in WANT:
        bad.append(f'x:Key="SystemAccentColor{suffix}": not one of the six '
                   f"derived stops Fluent actually reads")
    else:
        seen[suffix] = seen.get(suffix, 0) + 1
for stop in sorted(WANT):
    n = seen.get(stop, 0)
    if n != 1:
        bad.append(f"SystemAccentColor{stop} appears {n} times in emitted "
                   f"markup, want exactly 1 — a missing stop is a fill that "
                   f"silently stays the platform's")
if bad:
    print("\n".join(bad))
    sys.exit(1)
print(f"{len(hits)} accent stops, all six derived, no bare key")
PY
}

status=0
out="$(check "$WINUI")"
rc=$?
if [ "$rc" = 2 ]; then
    echo "check-accent: REFUSED A VERDICT:" >&2
    echo "$out" >&2
    exit 2
elif [ "$rc" != 0 ]; then
    echo "check-accent: the WinUI accent markup is wrong:" >&2
    echo "$out" >&2
    status=1
fi

# THE GUARD GUARDS ITSELF, perturbed out of the real file, counts
# printed, the red demanded — both failure directions.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

hits="$(python3 -c '
import re, sys
text = open(sys.argv[1]).read()
drifted, n = re.subn(r"<Color x:Key=(\\\\?\")SystemAccentColorDark1(\\\\?\")",
                     r"<Color x:Key=\1SystemAccentColor\2", text, count=1)
open(sys.argv[2], "w").write(drifted)
print(n)
' "$WINUI" "$T/bare.rs")"
if [ "$hits" != 1 ]; then
    echo "check-accent: SELF-TEST N1 applied $hits perturbation(s), want 1" >&2
    exit 1
fi
drift="$(check "$T/bare.rs")"
case "$drift" in
    *"BARE"*) echo "check-accent: self-test N1 (bare key), 1 substitution(s), red as demanded" ;;
    *)
        echo "check-accent: SELF-TEST N1 FAIL — a bare SystemAccentColor was not refused: $drift" >&2
        exit 1
        ;;
esac

hits="$(python3 -c '
import re, sys
text = open(sys.argv[1]).read()
drifted, n = re.subn(r"<Color x:Key=(\\\\?\")SystemAccentColorLight2(\\\\?\")",
                     r"<Color x:Key=\1KayaGoneStop\2", text, count=1)
open(sys.argv[2], "w").write(drifted)
print(n)
' "$WINUI" "$T/missing.rs")"
if [ "$hits" != 1 ]; then
    echo "check-accent: SELF-TEST N2 applied $hits perturbation(s), want 1" >&2
    exit 1
fi
drift="$(check "$T/missing.rs")"
case "$drift" in
    *"appears 0 times"*) echo "check-accent: self-test N2 (missing stop), 1 substitution(s), red as demanded" ;;
    *)
        echo "check-accent: SELF-TEST N2 FAIL — a missing derived stop was not refused: $drift" >&2
        exit 1
        ;;
esac

[ "$status" = 0 ] && echo "check-accent: OK ($out)"
exit "$status"
