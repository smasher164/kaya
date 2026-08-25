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
# Build the Linux validation image and run the suites in it (GTK under
# Xvfb). Requires docker.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# ONE FILE UNDER THE ASSET ROOT IS DERIVED and never committed
# (guests/assets/market/README.md), so a fresh clone bind-mounts an
# incomplete root at /work. HERE AND NOT IN run-suites.sh, which is the
# lane's asset site: this is the only half that runs as the host user,
# and a stamp written by the container's root would then be one the gate
# sweep cannot rewrite.
if ! python3 "$ROOT/tools/gen-market.py" --ensure; then
    echo "validate-linux: python3 tools/gen-market.py --ensure failed — the market" >&2
    echo "  family's transactions.csv is derived, so the root mounted at /work is" >&2
    echo "  incomplete and every guest that reads it fails inside its build closure" >&2
    exit 1
fi
T0=$SECONDS
docker build -q -t kaya-linux "$ROOT/tools/linux" >/dev/null
echo "TIMING image-build $((SECONDS - T0))s"
T0=$SECONDS
# Hard ceiling on a suite that never returns. Generous: a cold container
# compiles everything from scratch.
rc=0
timeout 1800 docker run --rm -v "$ROOT:/work" \
    -e KAYA_RECORD="${KAYA_RECORD:-}" -e KAYA_JOBS="${KAYA_JOBS:-}" \
    -e KAYA_ONLY="${KAYA_ONLY:-}" \
    kaya-linux bash /work/tools/linux/run-suites.sh || rc=$?
echo "TIMING container-suites $((SECONDS - T0))s"
exit "$rc"
