#!/usr/bin/env bash
# Build the Linux validation image and run all four milestone-0 suites in
# it (GTK backend under Xvfb). Requires docker.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
docker build -q -t kaya-linux "$ROOT/tools/linux" >/dev/null
docker run --rm -v "$ROOT:/work" kaya-linux bash /work/tools/linux/run-suites.sh
