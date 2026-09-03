# shellcheck shell=bash
# Shared Swift/macOS toolchain resolution — source, don't execute. No
# shebang for that reason; line 1's directive names the dialect, and
# without it check-shell errors out.
#
# Inside the nix dev shell DEVELOPER_DIR/SDKROOT point at a nix apple-sdk
# where `xcrun` finds no swiftc, so every Swift build steers back to a
# real Apple toolchain: source this, then invoke `kaya_swiftc <args>`.
# Resolution prefers the fullest SDK (the SwiftUI dylib build needs
# frameworks CommandLineTools may not carry). Sets SWIFTC, SWIFT_SDK_ARGS
# and SWIFT_DEVELOPER_DIR; memoized.

kaya_resolve_swiftc() {
    [ -n "${SWIFTC:-}" ] && return 0
    local app dev="" sdk=""
    for app in /Applications/Xcode.app /Applications/Xcode-*.app; do
        if [ -d "$app/Contents/Developer" ]; then
            dev="$app/Contents/Developer"
            break
        fi
    done
    if [ -n "$dev" ]; then
        SWIFTC="$(DEVELOPER_DIR="$dev" /usr/bin/xcrun --find swiftc 2>/dev/null || true)"
        sdk="$(DEVELOPER_DIR="$dev" /usr/bin/xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
        SWIFT_DEVELOPER_DIR="$dev"
    fi
    if [ -z "${SWIFTC:-}" ] || [ ! -d "${sdk:-/nonexistent}" ]; then
        SWIFT_DEVELOPER_DIR=""
        if SWIFTC="$(env -u DEVELOPER_DIR -u SDKROOT /usr/bin/xcrun --find swiftc 2>/dev/null)"; then
            sdk="$(env -u DEVELOPER_DIR -u SDKROOT /usr/bin/xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
        else
            SWIFTC=/usr/bin/swiftc
            sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
        fi
    fi
    if [ ! -x "${SWIFTC:-/nonexistent}" ] || [ ! -d "${sdk:-/nonexistent}" ]; then
        echo "swift-toolchain: no usable swiftc + macOS SDK (swiftc=${SWIFTC:-} sdk=${sdk:-})" >&2
        return 1
    fi
    SWIFT_SDK_ARGS=(-sdk "$sdk")
}

# DEVELOPER_DIR is set for a full Xcode and unset otherwise, so the nix
# apple-sdk cannot shadow it; SDKROOT is always cleared so -sdk wins.
kaya_swiftc() {
    kaya_resolve_swiftc || return 1
    if [ -n "${SWIFT_DEVELOPER_DIR:-}" ]; then
        env -u SDKROOT DEVELOPER_DIR="$SWIFT_DEVELOPER_DIR" \
            "$SWIFTC" "${SWIFT_SDK_ARGS[@]}" "$@"
    else
        env -u DEVELOPER_DIR -u SDKROOT "$SWIFTC" "${SWIFT_SDK_ARGS[@]}" "$@"
    fi
}
