#!/usr/bin/env bash

# Everything runs inside the dev shell: the flake pins every toolchain
# (rust + cross targets, swiftc, ffmpeg, the android sdk). Running
# against anything else is an error, not something to paper over — and
# a shell entered before the flake last changed is just as much a
# bystander toolchain, so the marker carries the fingerprint of
# flake.nix+flake.lock the shell was actually built from.
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# Build the Linux validation image and run all four milestone-0 suites in
# it (GTK backend under Xvfb). Requires docker.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T0=$SECONDS
docker build -q -t kaya-linux "$ROOT/tools/linux" >/dev/null
echo "TIMING image-build $((SECONDS - T0))s"
T0=$SECONDS
# The hard ceiling: a suite that never returns (a drain deadlock, a
# hung guest holding the container open) gets cut here instead of
# hanging the caller forever. Generous — a cold container compiles
# everything from scratch.
rc=0
timeout 1800 docker run --rm -v "$ROOT:/work" \
    -e KAYA_RECORD="${KAYA_RECORD:-}" -e KAYA_JOBS="${KAYA_JOBS:-}" \
    kaya-linux bash /work/tools/linux/run-suites.sh || rc=$?
echo "TIMING container-suites $((SECONDS - T0))s"
exit "$rc"
