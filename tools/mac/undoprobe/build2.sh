#!/usr/bin/env bash

# Dev-shell guard; the marker is the flake fingerprint (CLAUDE.md).
kaya_flake="$(cd "$(dirname "$0")/../../.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi

# Mac undo probe, three hook modes. Throwaway, not a lane. See
# main2.swift's header.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$ROOT"

# shellcheck source=tools/lib/swift-toolchain.sh
. "$ROOT/tools/lib/swift-toolchain.sh"
kaya_resolve_swiftc || exit 1
[ -n "${SWIFT_DEVELOPER_DIR:-}" ] && export DEVELOPER_DIR="$SWIFT_DEVELOPER_DIR"

OUT="$ROOT/target/mac-undoprobe2"
APP="$OUT/UndoProbe2.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS"

kaya_swiftc -O -o "$OUT/undoprobe2" "$HERE/main2.swift"
cp "$OUT/undoprobe2" "$APP/Contents/MacOS/UndoProbe2"

cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>UndoProbe2</string>
  <key>CFBundleIdentifier</key><string>dev.kaya.undoprobe2</string>
  <key>CFBundleName</key><string>UndoProbe2</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict>
</plist>
PLIST

for mode in "${@:-nohook plainhook hook}"; do
    for m in $mode; do
        echo "=== mode=$m ==="
        # `if !` and not an rc capture: set -e would take the script down.
        if ! KAYA_UNDOPROBE_MODE="$m" "$APP/Contents/MacOS/UndoProbe2"; then
            echo "UndoProbe2: exited nonzero in mode=$m"
        fi
        echo
    done
done
