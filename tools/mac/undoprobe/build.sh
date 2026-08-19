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

# Build and run UndoProbe twice: mode=plain (no
# windowWillReturnUndoManager) and mode=hook (a logging manager). Prints
# both transcripts.
#
# NOT A LANE, THROWAWAY. Questions in main.swift's header; what it
# decides is docs/undo-plan.md §0.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$ROOT"

# shellcheck source=tools/lib/swift-toolchain.sh
. "$ROOT/tools/lib/swift-toolchain.sh"
kaya_resolve_swiftc || exit 1
[ -n "${SWIFT_DEVELOPER_DIR:-}" ] && export DEVELOPER_DIR="$SWIFT_DEVELOPER_DIR"

OUT="$ROOT/target/mac-undoprobe"
APP="$OUT/UndoProbe.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS"

kaya_swiftc -O -o "$OUT/undoprobe" "$HERE/main.swift"
cp "$OUT/undoprobe" "$APP/Contents/MacOS/UndoProbe"

cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>UndoProbe</string>
  <key>CFBundleIdentifier</key><string>dev.kaya.undoprobe</string>
  <key>CFBundleName</key><string>UndoProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict>
</plist>
PLIST

# A BUNDLE, not the bare binary: an unbundled binary cannot become the
# active app, and the key window is what the question is about.
for mode in plain hook; do
    echo "=== mode=$mode ==="
    # `if !` and not an rc capture: set -e would take the script down
    # before anything could read $?.
    if ! KAYA_UNDOPROBE_MODE="$mode" "$APP/Contents/MacOS/UndoProbe"; then
        echo "UndoProbe: exited nonzero in mode=$mode"
    fi
    echo
done
