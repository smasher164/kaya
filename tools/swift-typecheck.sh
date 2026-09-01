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
# Typecheck every Swift layer — the bindings, the guests (macOS AND
# iOS), the SwiftUI interpreter and the lane's host-side tools — without
# booting a simulator.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

# shellcheck source=tools/lib/swift-toolchain.sh
source "$ROOT/tools/lib/swift-toolchain.sh"
kaya_resolve_swiftc || exit 1

# swiftc requires top-level code to live in a file named main.swift, so
# each guest typechecks in its own pass.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# WHAT EACH PASS COMPILED, said out loud at the end: an "OK" over an
# unstated file set is how this gate twice claimed a layer it had never
# compiled (docs/traps.md). Passes that count files refuse a verdict
# rather than report a pass over nothing.
PASSES=()
refuse() {
    echo "swift-typecheck: REFUSING A VERDICT — $1" >&2
    exit 1
}

# Globbed, not listed: a hand-maintained list here once skipped a guest
# silently.
GUESTS=()
for example in guests/swift/*.swift; do
    case "$example" in *+*) continue ;; esac
    # A glob that matches nothing comes back as the PATTERN.
    [ -f "$example" ] || continue
    GUESTS+=("$example")
done
# Ten is a plausibility floor, not a count: an empty loop agrees with
# everything, so a handful means the sources moved out from under the
# gate.
[ "${#GUESTS[@]}" -ge 10 ] ||
    refuse "guests/swift/*.swift matched ${#GUESTS[@]} files; a pass over that is not a check"
mac_guests=0
for example in "${GUESTS[@]}"; do
    cp "$example" "$TMP/main.swift"
    # A guest with generated sum surfaces has a checked-in
    # <name>+Kaya.swift companion; compile it alongside.
    companions=$(ls "${example%.swift}"+*.swift 2>/dev/null || true)
    # shellcheck disable=SC2086
    if ! kaya_swiftc -typecheck \
        -import-objc-header crates/kaya/include/kaya.h \
        bindings/swift/KayaWire.swift bindings/swift/KayaApp.swift bindings/swift/KayaRecords.swift bindings/swift/KayaSums.swift $companions "$TMP/main.swift"; then
        echo "swift-typecheck: FAIL ($example, the macOS guest pass)"
        exit 1
    fi
    mac_guests=$((mac_guests + 1))
done
[ "$mac_guests" = "${#GUESTS[@]}" ] ||
    refuse "the macOS guest pass compiled $mac_guests of ${#GUESTS[@]} guests"
PASSES+=("guests/swift: $mac_guests files, macOS SDK")

# THE DYNAMIC-TABLE SURFACE, which no guest spells: a table per stamped
# row (KayaTpl.columns, the node-flavoured KayaApp.onSort, and
# KayaAppTx.columns(_:at:_:_:)). tools/tpl-surfaces.py censuses it as
# TEXT; this is the compiler reading it as types.
NESTED_TABLE=tools/checks/swift-nested-table.swift
[ -f "$NESTED_TABLE" ] ||
    refuse "$NESTED_TABLE is missing — the nested-table spelling would then be compiled by nothing"
if ! kaya_swiftc -typecheck \
    -import-objc-header crates/kaya/include/kaya.h \
    bindings/swift/KayaWire.swift bindings/swift/KayaApp.swift \
    bindings/swift/KayaRecords.swift bindings/swift/KayaSums.swift "$NESTED_TABLE"; then
    echo "swift-typecheck: FAIL ($NESTED_TABLE, the dynamic-table surface)"
    exit 1
fi
PASSES+=("$NESTED_TABLE + bindings/swift: macOS SDK (the nested-table spelling)")
# THE INTERPRETER ITSELF, the historic miss layer (docs/traps.md).
# -warnings-as-errors here as in tools/swiftui/build-dylib.sh: a dropped
# return value is only a warning, and that is how the clipboard seed
# discarded osascript's exit status. If it fires on something else, fix
# the warning — do not remove the flag.
if ! kaya_swiftc -typecheck -warnings-as-errors \
    -import-objc-header crates/kaya/include/kaya.h \
    swift/KayaSwiftUI.swift swift/KayaSwiftUIEntry.swift; then
    echo "swift-typecheck: FAIL (the SwiftUI interpreter, macOS)"
    exit 1
fi
PASSES+=("swift/KayaSwiftUI.swift + swift/KayaSwiftUIEntry.swift: macOS SDK, -warnings-as-errors")

# AND THE HOST-SIDE iOS DRIVER, which no other mac-side gate compiles:
# without this pass the iOS lane is the first compiler to see an edit.
if ! kaya_swiftc -typecheck tools/ios/simdrive/main.swift; then
    echo "swift-typecheck: FAIL (tools/ios/simdrive, the iOS lane's driver)"
    exit 1
fi
PASSES+=("tools/ios/simdrive/main.swift: macOS SDK (it runs on the host)")

# AND FOR iOS. One file serves both Apple platforms behind
# `#if os(macOS)` / `#else`, and a host-target typecheck compiles only
# ONE half — so this is the only compiler the iOS branch sees before the
# simulator. The dev shell's xcrun is a shim with no iOS SDK, so this
# steers through the real toolchain kaya_resolve_swiftc found.
ios_xcrun() {
    if [ -n "${SWIFT_DEVELOPER_DIR:-}" ]; then
        env -u SDKROOT DEVELOPER_DIR="$SWIFT_DEVELOPER_DIR" /usr/bin/xcrun "$@"
    else
        env -u SDKROOT /usr/bin/xcrun "$@"
    fi
}
if ios_xcrun -sdk iphonesimulator --show-sdk-path >/dev/null 2>&1; then
    if ! ios_xcrun -sdk iphonesimulator swiftc -typecheck \
        -target arm64-apple-ios17.0-simulator \
        -import-objc-header crates/kaya/include/kaya.h \
        swift/KayaSwiftUI.swift swift/KayaSwiftUIEntry.swift; then
        echo "swift-typecheck: FAIL (the SwiftUI interpreter, iOS)"
        exit 1
    fi
    PASSES+=("swift/KayaSwiftUI.swift + swift/KayaSwiftUIEntry.swift: iphonesimulator SDK, arm64-apple-ios17.0-simulator (no -warnings-as-errors, unlike the macOS pass)")
    # The lane's foreign clipboard reader: nothing else compiles it.
    if ! ios_xcrun -sdk iphonesimulator swiftc -typecheck \
        -target arm64-apple-ios17.0-simulator \
        tools/ios/clipctl/main.swift; then
        echo "swift-typecheck: FAIL (tools/ios/clipctl, the iOS lane's foreign clipboard process)"
        exit 1
    fi
    PASSES+=("tools/ios/clipctl/main.swift: iphonesimulator SDK, arm64-apple-ios17.0-simulator")

    # AND THE GUESTS FOR iOS: the macOS loop at the top compiles ONE side
    # of every `#if os(...)` a guest carries.
    #
    # THE FILE SET AND THE FLAGS ARE THE LANE'S, never restated here:
    #   - the swift roster is the lane MODULE's SWIFT_ENTRIES (entries
    #     `scene` or `scene:guest`, the SOURCE after the colon) since
    #     the runner conversion — IMPORTED, the same table the runner
    #     iterates. The rest are desktop-only by design.
    #   - IOS_MIN (16.0) is the runner's, and NOT the 17.0 the
    #     interpreter passes use: the older target is STRICTER for
    #     availability diagnostics, so a hardcoded 17.0 would make this
    #     gate looser than the lane.
    # No -warnings-as-errors: the lane's guest builds do not use it, and
    # a gate stricter than the lane fails builds that would have shipped.
    #
    # The reader refuses rather than returning nothing — an empty parse
    # would agree with everything.
    if ! ios_lane_spec="$(python3 - tools/ios/run-sim.py <<'PY'
import pathlib
import re
import sys

sys.path.insert(0, "tools/lib")
from lanes import ios as lane

src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
target = re.search(r'^IOS_MIN = "([0-9][0-9.]*)"$', src, re.M)
if not target:
    sys.exit("cannot read IOS_MIN out of tools/ios/run-sim.py; the iOS "
             "lane's floor moved and this gate no longer knows which "
             "target the guests build against")
sources = []
for entry in lane.SWIFT_ENTRIES:
    name = entry.split(":")[-1]
    if name not in sources:
        sources.append(name)
if not sources:
    sys.exit("the lane module's SWIFT_ENTRIES named no guests")
print(target.group(1))
print(" ".join(sources))
PY
    )"; then
        # The reader printed WHICH half it could not read, on stderr.
        refuse "the iOS lane's guest set is unreadable (see the line above)"
    fi
    { read -r ios_min; read -r ios_scene_sources; } <<<"$ios_lane_spec"
    read -r -a ios_names <<<"$ios_scene_sources"
    ios_srcs=()
    for name in "${ios_names[@]}"; do
        [ -f "guests/swift/$name.swift" ] ||
            refuse "the ios lane module ships guest '$name' to iOS and guests/swift/$name.swift does not exist"
        ios_srcs+=("guests/swift/$name.swift")
    done
    [ "${#ios_srcs[@]}" -ge 10 ] ||
        refuse "the iOS guest pass was handed ${#ios_srcs[@]} guests by the ios lane module; a pass over that is not a check"
    # Pooled: each compile re-reads the four binding files, so serially
    # this pass costs ~35s of a ~35s gate and parallel ~3s (measured
    # 2026-08-18).
    ios_pids=()
    for src in "${ios_srcs[@]}"; do
        (
            stage="$TMP/ios-$(basename "$src" .swift)"
            mkdir -p "$stage"
            cp "$src" "$stage/main.swift"
            companions=$(ls "${src%.swift}"+*.swift 2>/dev/null || true)
            # shellcheck disable=SC2086
            ios_xcrun -sdk iphonesimulator swiftc -typecheck \
                -target "arm64-apple-ios$ios_min-simulator" \
                -import-objc-header crates/kaya/include/kaya.h \
                bindings/swift/KayaWire.swift bindings/swift/KayaApp.swift \
                bindings/swift/KayaRecords.swift bindings/swift/KayaSums.swift \
                $companions "$stage/main.swift" >"$stage/log" 2>&1
        ) &
        ios_pids+=($!)
    done
    ios_status=0
    ios_guests=0
    i=0
    for pid in "${ios_pids[@]}"; do
        wait "$pid"
        pid_status=$?
        if [ "$pid_status" != 0 ]; then
            echo "swift-typecheck: FAIL (${ios_srcs[$i]}, the iOS guest pass — arm64-apple-ios$ios_min-simulator)"
            cat "$TMP/ios-$(basename "${ios_srcs[$i]}" .swift)/log"
            ios_status=1
        fi
        ios_guests=$((ios_guests + 1))
        i=$((i + 1))
    done
    [ "$ios_status" = 0 ] || exit 1
    [ "$ios_guests" = "${#ios_srcs[@]}" ] ||
        refuse "the iOS guest pass compiled $ios_guests of ${#ios_srcs[@]} guests"
    PASSES+=("guests/swift: $ios_guests of ${#GUESTS[@]} files (the ios lane module's SWIFT_ENTRIES; the rest are desktop-only), iphonesimulator SDK, arm64-apple-ios$ios_min-simulator")
else
    echo "swift-typecheck: note — no iphonesimulator SDK; the iOS half went unchecked" >&2
    PASSES+=("SKIPPED: everything iOS — the interpreter, tools/ios/clipctl and the lane's guests (no iphonesimulator SDK)")
fi

for pass in "${PASSES[@]}"; do
    echo "swift-typecheck:   $pass"
done
echo "swift-typecheck: OK (${#PASSES[@]} passes)"
