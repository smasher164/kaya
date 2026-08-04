#!/usr/bin/env bash

# Everything runs inside the dev shell: the flake pins every toolchain
# (rust + cross targets, swiftc, ffmpeg, the android sdk). Running
# against anything else is an error, not something to paper over — and
# a shell entered before the flake last changed is just as much a
# bystander toolchain, so the marker carries the fingerprint of
# flake.nix+flake.lock the shell was actually built from.
kaya_flake="$(cd "$(dirname "$0")/../../.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi

# Build and run UndoProbe TWICE — once with the window delegate NOT
# implementing windowWillReturnUndoManager (mode=plain, what kaya ships
# today) and once with it supplying a logging manager (mode=hook, D6's
# candidate plumbing). Print both transcripts.
#
# NOT A LANE. It answers whether a kaya programmatic write enters the
# native undo stack on macOS before D7's mac arm is written; see
# main.swift's header for the questions and docs/undo-plan.md §0 for
# what it decides. THROWAWAY.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$ROOT"

# Inside the dev shell DEVELOPER_DIR/SDKROOT point at a nix apple-sdk
# where xcrun finds no swiftc. tools/lib/swift-toolchain.sh is the
# single source of truth for steering back to a real Apple toolchain.
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

# A BUNDLE, not the bare binary: the key window and the main menu are
# what the responder-chain question is about, and an unbundled binary
# cannot become the active app.
for mode in plain hook; do
    echo "=== mode=$mode ==="
    # `if !` and not an rc capture: set -e is on, so the failing command
    # would take the script down before anything could read $?.
    if ! KAYA_UNDOPROBE_MODE="$mode" "$APP/Contents/MacOS/UndoProbe"; then
        echo "UndoProbe: exited nonzero in mode=$mode"
    fi
    echo
done
