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

# The automated LocalStorage admission probe used by run-sim.py.
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

import plistlib

text = pathlib.Path(sys.argv[1]).read_text()
out = (text.replace("@EXECUTABLE@", "KayaExportProbe")
           .replace("@BUNDLE_ID@", "dev.kaya.exportpreflight")
           .replace("@NAME@", "KayaExportProbe")
           .replace("@IDENTITY@", "")
           .replace("@LAUNCH@", "<dict/>")
           # The probe claims NO scheme: it is not a kaya app and two
           # claimants make a link's destination the platform's pick
           # (docs/app-links-plan.md L5).
           .replace("@URLTYPES@", "<array/>"))
# The template is TEXT: a placeholder nobody substituted ships a plist the
# simulator refuses to install with no reason printed (2026-09-07, @LAUNCH@).
try:
    plistlib.loads(out.encode())
except Exception as exc:
    sys.exit(f"exportprobe: the rendered Info.plist does not parse ({exc}); "
             f"a template placeholder was left unsubstituted")
left = [tok for tok in ("@EXECUTABLE@", "@BUNDLE_ID@", "@NAME@", "@IDENTITY@", "@LAUNCH@", "@URLTYPES@") if tok in out]
if left:
    sys.exit(f"exportprobe: Info.plist.in placeholders left unsubstituted: {left}")
print(out, end="")
PY

echo "$APP"
