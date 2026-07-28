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

# Build, sign, install and launch ScopeProbe on a PAIRED IPHONE.
# Usage: tools/ios/scopeprobe/build.sh
#
# THIS IS NOT A LANE and must never become one. It needs hardware, a
# developer account, and a human to tap through a document picker. It
# exists because the simulator does not enforce the app sandbox
# (docs/traps.md), which makes an entire class of iOS behaviour
# unobservable in CI: anything whose answer depends on the sandbox
# DENYING something. See main.swift for what it currently measures and
# DESIGN.md's file-dialog section for what those measurements decided.
#
# WHAT IT NEEDS, none of which this repo otherwise wants:
#   - full Xcode (devicectl, the iphoneos SDK)
#   - an Apple ID added to Xcode, so `security find-identity -p
#     codesigning` is non-empty. It is EMPTY on a fresh machine.
#   - one provisioning profile that Xcode has already downloaded. A free
#     account will not mint one until you have built SOME app for the
#     device from Xcode once; there is no way around that from here.
#   - the phone plugged in, unlocked, with developer mode enabled.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The active developer dir may still be the Command Line Tools; devicectl
# and the iOS SDK live only in Xcode. Point at it without needing sudo,
# handling versioned installs (Xcode-26.6.0.app, the xcodes convention).
if ! xcrun devicectl list devices >/dev/null 2>&1; then
    for app in /Applications/Xcode.app /Applications/Xcode-*.app; do
        if [ -d "$app/Contents/Developer" ]; then
            export DEVELOPER_DIR="$app/Contents/Developer"
            break
        fi
    done
fi
if ! xcrun devicectl list devices >/dev/null 2>&1; then
    echo "scopeprobe: devicectl unavailable — full Xcode is required" >&2
    exit 1
fi

IDENTITY="$(security find-identity -p codesigning -v \
    | grep 'Apple Development' | head -1 | cut -d'"' -f2 || true)"
if [ -z "$IDENTITY" ]; then
    echo "scopeprobe: no codesigning identity. Add an Apple ID in" \
        "Xcode > Settings > Accounts, then build any app for the device" \
        "once so a profile is minted." >&2
    exit 1
fi

# Xcode has moved this directory once already, so search both homes —
# and only the ones that EXIST, because `find` on a missing path fails
# the whole pipeline under pipefail with nothing printed. That is how
# this script's first run died silently.
PROFILE=""
for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
    "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    [ -d "$dir" ] || continue
    found="$(find "$dir" -name '*.mobileprovision' -type f | sort | head -1)"
    if [ -n "$found" ]; then
        PROFILE="$found"
        break
    fi
done
if [ -z "$PROFILE" ]; then
    echo "scopeprobe: no provisioning profile on disk. Build any app for" \
        "this device from Xcode once; that is what mints one." >&2
    exit 1
fi

# The profile decides the bundle id, not the other way round — a free
# account's profile is usually pinned to ONE explicit app id, and signing
# against a mismatched id fails at install time with a message that does
# not say so. Read the id out and use it.
security cms -D -i "$PROFILE" >"$WORK/profile.plist"
BUNDLE_ID="$(python3 -c '
import plistlib
import sys

with open(sys.argv[1], "rb") as f:
    ent = plistlib.load(f)["Entitlements"]
appid = ent["application-identifier"]
team = ent.get("com.apple.developer.team-identifier", appid.split(".")[0])
bundle = appid.split(".", 1)[1]
if bundle == "*":
    # A wildcard profile takes any id under the team; pick our own.
    bundle = "cc.akhil.scopeprobe"
    appid = team + "." + bundle
with open(sys.argv[2], "wb") as f:
    plistlib.dump({
        "application-identifier": appid,
        "com.apple.developer.team-identifier": team,
        # Development signing: without this the app cannot be launched
        # by devicectl, only tapped on the device.
        "get-task-allow": True,
    }, f)
print(bundle)
' "$WORK/profile.plist" "$WORK/ent.plist")"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
BUNDLE="$WORK/ScopeProbe.app"
mkdir -p "$BUNDLE"

xcrun --sdk iphoneos swiftc \
    -target arm64-apple-ios16.0 \
    -sdk "$SDK" \
    -o "$BUNDLE/scopeprobe" \
    "$HERE/main.swift"

python3 -c '
import sys

src, dst, bundle_id = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as f:
    text = f.read()
with open(dst, "w") as f:
    f.write(text.replace("@BUNDLE_ID@", bundle_id))
' "$HERE/Info.plist.in" "$BUNDLE/Info.plist" "$BUNDLE_ID"

cp "$PROFILE" "$BUNDLE/embedded.mobileprovision"
codesign --force --sign "$IDENTITY" \
    --entitlements "$WORK/ent.plist" \
    --timestamp=none "$BUNDLE"

# One paired device is the normal case; name another with KAYA_IOS_DEVICE.
DEVICE="${KAYA_IOS_DEVICE:-}"
if [ -z "$DEVICE" ]; then
    xcrun devicectl list devices --json-output "$WORK/devices.json" >/dev/null
    DEVICE="$(python3 -c '
import json
import sys

with open(sys.argv[1]) as f:
    devices = json.load(f)["result"]["devices"]
live = [d for d in devices
        if d.get("connectionProperties", {}).get("tunnelState") != "unavailable"]
if len(live) != 1:
    names = ", ".join(d["deviceProperties"]["name"] for d in live) or "none"
    sys.exit("scopeprobe: expected exactly one connected device, found: "
             + names + " — set KAYA_IOS_DEVICE to an identifier")
print(live[0]["identifier"])
' "$WORK/devices.json")"
fi

xcrun devicectl device install app --device "$DEVICE" "$BUNDLE"

# A LOCKED PHONE INSTALLS FINE AND REFUSES TO LAUNCH, and devicectl says
# so ten lines into a nested error dump. Say it in one line instead: the
# build was good, the phone just needs unlocking.
if ! xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID"; then
    echo "scopeprobe: installed OK but could not launch. If the dump above" \
        "says Locked, unlock the phone and re-run — nothing needs rebuilding." >&2
    exit 1
fi

echo "scopeprobe: launched $BUNDLE_ID on $DEVICE."
echo 'Tap "Pick a file" and choose something OUTSIDE the app: iCloud'
echo 'Drive, or On My iPhone. Pick inside the container and the scope'
echo 'is not real, which step 1 will report as a vacuous run.'
