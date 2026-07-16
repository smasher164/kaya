#!/usr/bin/env bash
# Build the Linux validation image and run all four milestone-0 suites in
# it (GTK backend under Xvfb). Requires docker.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
docker build -q -t kaya-linux "$ROOT/tools/linux" >/dev/null
# The hard ceiling: a suite that never returns (a drain deadlock, a
# hung guest holding the container open) gets cut here instead of
# hanging the caller forever. Generous — a cold container compiles
# everything from scratch.
timeout 1800 docker run --rm -v "$ROOT:/work" kaya-linux bash /work/tools/linux/run-suites.sh
