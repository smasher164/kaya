#!/usr/bin/env bash

kaya_flake="$(cd "$(dirname "$0")/../../.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi

# The automated LocalStorage admission probe used by run-sim.sh.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$ROOT"

# shellcheck source=tools/lib/swift-toolchain.sh
. "$ROOT/tools/lib/swift-toolchain.sh"
kaya_resolve_swiftc || exit 1
[ -n "${SWIFT_DEVELOPER_DIR:-}" ] && export DEVELOPER_DIR="$SWIFT_DEVELOPER_DIR"

OUT="$ROOT/target/ios-exportprobe"
APP="$OUT/KayaExportProbe.app"
rm -rf "$APP"
mkdir -p "$APP"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
env -u SDKROOT "$SWIFTC" \
    -target arm64-apple-ios17.0-simulator \
    -sdk "$SDK" \
    -o "$APP/KayaExportProbe" \
    "$HERE/main.swift" >&2

python3 - "$ROOT/tools/ios/Info.plist.in" >"$APP/Info.plist" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
print(text.replace("@EXECUTABLE@", "KayaExportProbe")
          .replace("@BUNDLE_ID@", "dev.kaya.exportpreflight")
          .replace("@NAME@", "KayaExportProbe")
          .replace("@IDENTITY@", ""), end="")
PY

echo "$APP"
