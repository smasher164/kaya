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
# CLAUDE.md and AGENTS.md are true mirrors; only line 3 (the mirror
# comment) may differ.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

compare() {
    python3 - "$1" "$2" <<'EOF'
import sys

a, b = (open(p, encoding="utf-8").read().splitlines() for p in sys.argv[1:3])
# Line 3 (index 2) is the mirror comment and differs by design.
if len(a) > 2: a[2] = ""
if len(b) > 2: b[2] = ""
if a == b:
    sys.exit(0)
for i, (x, y) in enumerate(zip(a, b), 1):
    if x != y:
        print(f"first divergence at line {i}:")
        print(f"  {sys.argv[1]}: {x}")
        print(f"  {sys.argv[2]}: {y}")
        break
else:
    print(f"line counts differ: {len(a)} vs {len(b)}")
sys.exit(1)
EOF
}

# Self-test: divergence beyond line 3 flagged, a line-3-only diff not.
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
printf 'title\n\n<!-- mirror A -->\nsame\n' >"$T/a.md"
printf 'title\n\n<!-- mirror B -->\nsame\n' >"$T/b.md"
printf 'title\n\n<!-- mirror B -->\ndrifted\n' >"$T/c.md"
compare "$T/a.md" "$T/b.md" >/dev/null \
    || { echo "check-mirror: self-test failed (mirror-comment diff flagged)"; exit 1; }
if compare "$T/a.md" "$T/c.md" >/dev/null; then
    echo "check-mirror: self-test failed (real drift not flagged)"
    exit 1
fi

if compare CLAUDE.md AGENTS.md; then
    echo "check-mirror: OK"
else
    echo "check-mirror: CLAUDE.md and AGENTS.md have drifted — edit both together"
    exit 1
fi
