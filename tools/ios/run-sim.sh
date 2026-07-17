#!/usr/bin/env bash
# Build, install, and self-test the milestone scene in the iOS Simulator.
# Usage: tools/ios/run-sim.sh [rust|swift|rust-swiftui|all]
#
# rust         - the kaya example app (UIKit backend)
# swift        - Swift over the C ABI function floor (UIKit backend)
# rust-swiftui - the Rust example with the SwiftUI backend selected at
#                runtime (dylib embedded in the bundle)
#
# Requires full Xcode (simctl, the iOS SDK, and a downloaded simulator
# runtime); simulator builds are unsigned, so no developer account is
# involved. The Rust leg is the kaya example app; the Swift leg validates
# the C ABI's function floor, importing kaya.h directly.
set -euo pipefail

ROOT_FOR_CHECK="$(cd "$(dirname "$0")/../.." && pwd)"
# Compile the ios target and typecheck the Swift guest before the
# simulator is involved.
"$ROOT_FOR_CHECK/tools/check-targets.sh" ios || exit 1
"$ROOT_FOR_CHECK/tools/swift-typecheck.sh" || exit 1

SUITE="${1:-all}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# The active developer dir may still be the Command Line Tools (simctl and
# the iOS SDK live only in Xcode); point at Xcode without needing sudo.
# Handles versioned installs (Xcode-26.6.0.app, the xcodes convention).
if ! xcrun simctl help >/dev/null 2>&1; then
    for app in /Applications/Xcode.app /Applications/Xcode-*.app; do
        if [ -d "$app/Contents/Developer" ]; then
            export DEVELOPER_DIR="$app/Contents/Developer"
            break
        fi
    done
fi
TARGET_DIR="$ROOT/target/aarch64-apple-ios-sim/debug"
BUNDLES="$ROOT/target/ios-bundles"
IOS_MIN="16.0"

cd "$ROOT"

# The swift and rust-swiftui suites compile against kaya.h and the
# generated Swift bindings; fail loudly if either has drifted from the
# Rust source.
tools/gen-header.sh --check
tools/gen-bindings.sh --check

make_bundle() {
    local name="$1" bundle_id="$2" executable_path="$3"
    local app="$BUNDLES/$name.app"
    rm -rf "$app"
    mkdir -p "$app"
    sed -e "s/@EXECUTABLE@/$name/" \
        -e "s/@BUNDLE_ID@/$bundle_id/" \
        -e "s/@NAME@/$name/" \
        tools/ios/Info.plist.in > "$app/Info.plist"
    cp "$executable_path" "$app/$name"
    echo "$app"
}

boot_simulator() {
    local udid
    udid=$(xcrun simctl list devices available | grep -m1 -oE 'iPhone[^(]*\(([0-9A-F-]{36})\)' | grep -oE '[0-9A-F-]{36}' || true)
    [ -n "$udid" ] || { echo "no available iPhone simulator; install a runtime in Xcode" >&2; exit 1; }
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b >/dev/null
    echo "$udid"
}

run_bundle() {
    local udid="$1" app="$2" bundle_id="$3" name="$4" script="${5:-1}"
    xcrun simctl install "$udid" "$app"
    echo "== $name =="
    local out
    out=$(SIMCTL_CHILD_KAYA_SELFTEST="$script" timeout 120 \
        xcrun simctl launch --console-pty "$udid" "$bundle_id" 2>&1 | tee /dev/stderr) || true
    xcrun simctl io "$udid" screenshot "$ROOT/target/ios-shot-$name.png" >/dev/null 2>&1 || true
    if grep -q "KAYA_SELFTEST: OK" <<<"$out"; then
        echo "$name: PASS"
    else
        echo "$name: FAIL"
        return 1
    fi
}

status=0
UDID=$(boot_simulator)

SDKROOT_SIM=$(xcrun -sdk iphonesimulator --show-sdk-path)

if [ "$SUITE" = rust ] || [ "$SUITE" = all ]; then
    SDKROOT="$SDKROOT_SIM" cargo build --target aarch64-apple-ios-sim \
        --example milestone2 --example entry --example gallery --example todos
    APP=$(make_bundle milestone2 dev.kaya.milestone2 "$TARGET_DIR/examples/milestone2")
    run_bundle "$UDID" "$APP" dev.kaya.milestone2 rust || status=1
    APP=$(make_bundle entry dev.kaya.entry "$TARGET_DIR/examples/entry")
    run_bundle "$UDID" "$APP" dev.kaya.entry entry-rust entry || status=1
    APP=$(make_bundle gallery dev.kaya.gallery "$TARGET_DIR/examples/gallery")
    run_bundle "$UDID" "$APP" dev.kaya.gallery gallery-rust gallery || status=1
    APP=$(make_bundle todos dev.kaya.todos "$TARGET_DIR/examples/todos")
    run_bundle "$UDID" "$APP" dev.kaya.todos todos-rust todos || status=1
fi

if [ "$SUITE" = swift ] || [ "$SUITE" = all ]; then
    SDKROOT="$SDKROOT_SIM" cargo build --target aarch64-apple-ios-sim --lib
    mkdir -p "$BUNDLES"
    # With more than one input file, swiftc only allows top-level code in
    # a file named main.swift; the example is that file.
    cp guests/swift/milestone2.swift "$BUNDLES/main.swift"
    xcrun -sdk iphonesimulator swiftc \
        -target "arm64-apple-ios$IOS_MIN-simulator" \
        -import-objc-header crates/kaya/include/kaya.h \
        bindings/swift/KayaWire.swift bindings/swift/KayaApp.swift bindings/swift/KayaRecords.swift "$BUNDLES/main.swift" \
        -L "$TARGET_DIR" -lkaya \
        -framework UIKit -framework Foundation -framework CoreFoundation \
        -framework CoreGraphics -framework QuartzCore \
        -o "$BUNDLES/milestone2swift-bin"
    APP=$(make_bundle milestone2swift dev.kaya.milestone2swift "$BUNDLES/milestone2swift-bin")
    run_bundle "$UDID" "$APP" dev.kaya.milestone2swift swift || status=1

    cp guests/swift/entry.swift "$BUNDLES/main.swift"
    xcrun -sdk iphonesimulator swiftc \
        -target "arm64-apple-ios$IOS_MIN-simulator" \
        -import-objc-header crates/kaya/include/kaya.h \
        bindings/swift/KayaWire.swift bindings/swift/KayaApp.swift bindings/swift/KayaRecords.swift "$BUNDLES/main.swift" \
        -L "$TARGET_DIR" -lkaya \
        -framework UIKit -framework Foundation -framework CoreFoundation \
        -framework CoreGraphics -framework QuartzCore \
        -o "$BUNDLES/entryswift-bin"
    APP=$(make_bundle entryswift dev.kaya.entryswift "$BUNDLES/entryswift-bin")
    run_bundle "$UDID" "$APP" dev.kaya.entryswift entry-swift entry || status=1

    cp guests/swift/gallery.swift "$BUNDLES/main.swift"
    xcrun -sdk iphonesimulator swiftc \
        -target "arm64-apple-ios$IOS_MIN-simulator" \
        -import-objc-header crates/kaya/include/kaya.h \
        bindings/swift/KayaWire.swift bindings/swift/KayaApp.swift bindings/swift/KayaRecords.swift "$BUNDLES/main.swift" \
        -L "$TARGET_DIR" -lkaya \
        -framework UIKit -framework Foundation -framework CoreFoundation \
        -framework CoreGraphics -framework QuartzCore \
        -o "$BUNDLES/galleryswift-bin"
    APP=$(make_bundle galleryswift dev.kaya.galleryswift "$BUNDLES/galleryswift-bin")
    run_bundle "$UDID" "$APP" dev.kaya.galleryswift gallery-swift gallery || status=1

    cp guests/swift/todos.swift "$BUNDLES/main.swift"
    xcrun -sdk iphonesimulator swiftc \
        -target "arm64-apple-ios$IOS_MIN-simulator" \
        -import-objc-header crates/kaya/include/kaya.h \
        bindings/swift/KayaWire.swift bindings/swift/KayaApp.swift bindings/swift/KayaRecords.swift "$BUNDLES/main.swift" \
        -L "$TARGET_DIR" -lkaya \
        -framework UIKit -framework Foundation -framework CoreFoundation \
        -framework CoreGraphics -framework QuartzCore \
        -o "$BUNDLES/todosswift-bin"
    APP=$(make_bundle todosswift dev.kaya.todosswift "$BUNDLES/todosswift-bin")
    run_bundle "$UDID" "$APP" dev.kaya.todosswift todos-swift todos || status=1
fi

if [ "$SUITE" = rust-swiftui ] || [ "$SUITE" = all ]; then
    # Rust entrypoint + SwiftUI backend: the bundle executable is the Rust
    # example's main; KAYA_BACKEND=swiftui makes kaya::run dlopen the
    # SwiftUI dylib embedded in the bundle.
    SDKROOT="$SDKROOT_SIM" cargo build --target aarch64-apple-ios-sim --example milestone2
    mkdir -p "$BUNDLES"
    xcrun -sdk iphonesimulator swiftc \
        -emit-library \
        -target "arm64-apple-ios17.0-simulator" \
        -import-objc-header crates/kaya/include/kaya.h \
        swift/KayaSwiftUI.swift swift/KayaSwiftUIEntry.swift \
        -framework UIKit -framework Foundation \
        -o "$BUNDLES/libkaya_swiftui_ios.dylib"
    APP=$(make_bundle milestone2rs-swiftui dev.kaya.rustswiftui "$TARGET_DIR/examples/milestone2")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    xcrun simctl install "$UDID" "$APP"
    CONTAINER=$(xcrun simctl get_app_container "$UDID" dev.kaya.rustswiftui app)
    echo "== rust-swiftui =="
    out=$(SIMCTL_CHILD_KAYA_SELFTEST=1 \
        SIMCTL_CHILD_KAYA_SELFTEST_SCRIPT="$(grep -v '^#' "$ROOT/tools/scenes/milestone2.steps")" \
        SIMCTL_CHILD_KAYA_BACKEND=swiftui \
        SIMCTL_CHILD_KAYA_SWIFTUI_LIB="$CONTAINER/libkaya_swiftui.dylib" \
        timeout 120 xcrun simctl launch --console-pty "$UDID" dev.kaya.rustswiftui 2>&1 | tee /dev/stderr) || true
    xcrun simctl io "$UDID" screenshot "$ROOT/target/ios-shot-rust-swiftui.png" >/dev/null 2>&1 || true
    if grep -q "KAYA_SELFTEST: OK" <<<"$out"; then
        echo "rust-swiftui: PASS"
    else
        echo "rust-swiftui: FAIL"
        status=1
    fi

    # The entry scene against the SwiftUI backend, same embedded dylib.
    SDKROOT="$SDKROOT_SIM" cargo build --target aarch64-apple-ios-sim --example entry
    APP=$(make_bundle entryrs-swiftui dev.kaya.entryswiftui "$TARGET_DIR/examples/entry")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    xcrun simctl install "$UDID" "$APP"
    CONTAINER=$(xcrun simctl get_app_container "$UDID" dev.kaya.entryswiftui app)
    echo "== entry-swiftui =="
    out=$(SIMCTL_CHILD_KAYA_SELFTEST=entry \
        SIMCTL_CHILD_KAYA_SELFTEST_SCRIPT="$(grep -v '^#' "$ROOT/tools/scenes/entry.steps")" \
        SIMCTL_CHILD_KAYA_BACKEND=swiftui \
        SIMCTL_CHILD_KAYA_SWIFTUI_LIB="$CONTAINER/libkaya_swiftui.dylib" \
        timeout 120 xcrun simctl launch --console-pty "$UDID" dev.kaya.entryswiftui 2>&1 | tee /dev/stderr) || true
    xcrun simctl io "$UDID" screenshot "$ROOT/target/ios-shot-entry-swiftui.png" >/dev/null 2>&1 || true
    if grep -q "KAYA_SELFTEST: OK" <<<"$out"; then
        echo "entry-swiftui: PASS"
    else
        echo "entry-swiftui: FAIL"
        status=1
    fi

    # The todos scene against the SwiftUI backend, same embedded dylib.
    SDKROOT="$SDKROOT_SIM" cargo build --target aarch64-apple-ios-sim --example todos
    APP=$(make_bundle todosrs-swiftui dev.kaya.todosswiftui "$TARGET_DIR/examples/todos")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    xcrun simctl install "$UDID" "$APP"
    CONTAINER=$(xcrun simctl get_app_container "$UDID" dev.kaya.todosswiftui app)
    echo "== todos-swiftui =="
    out=$(SIMCTL_CHILD_KAYA_SELFTEST=todos \
        SIMCTL_CHILD_KAYA_SELFTEST_SCRIPT="$(grep -v '^#' "$ROOT/tools/scenes/todos.steps")" \
        SIMCTL_CHILD_KAYA_BACKEND=swiftui \
        SIMCTL_CHILD_KAYA_SWIFTUI_LIB="$CONTAINER/libkaya_swiftui.dylib" \
        timeout 120 xcrun simctl launch --console-pty "$UDID" dev.kaya.todosswiftui 2>&1 | tee /dev/stderr) || true
    xcrun simctl io "$UDID" screenshot "$ROOT/target/ios-shot-todos-swiftui.png" >/dev/null 2>&1 || true
    if grep -q "KAYA_SELFTEST: OK" <<<"$out"; then
        echo "todos-swiftui: PASS"
    else
        echo "todos-swiftui: FAIL"
        status=1
    fi

    # The gallery scene against the SwiftUI backend, same embedded dylib.
    SDKROOT="$SDKROOT_SIM" cargo build --target aarch64-apple-ios-sim --example gallery
    APP=$(make_bundle galleryrs-swiftui dev.kaya.galleryswiftui "$TARGET_DIR/examples/gallery")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    xcrun simctl install "$UDID" "$APP"
    CONTAINER=$(xcrun simctl get_app_container "$UDID" dev.kaya.galleryswiftui app)
    echo "== gallery-swiftui =="
    out=$(SIMCTL_CHILD_KAYA_SELFTEST=gallery \
        SIMCTL_CHILD_KAYA_SELFTEST_SCRIPT="$(grep -v '^#' "$ROOT/tools/scenes/gallery.steps")" \
        SIMCTL_CHILD_KAYA_BACKEND=swiftui \
        SIMCTL_CHILD_KAYA_SWIFTUI_LIB="$CONTAINER/libkaya_swiftui.dylib" \
        timeout 120 xcrun simctl launch --console-pty "$UDID" dev.kaya.galleryswiftui 2>&1 | tee /dev/stderr) || true
    xcrun simctl io "$UDID" screenshot "$ROOT/target/ios-shot-gallery-swiftui.png" >/dev/null 2>&1 || true
    if grep -q "KAYA_SELFTEST: OK" <<<"$out"; then
        echo "gallery-swiftui: PASS"
    else
        echo "gallery-swiftui: FAIL"
        status=1
    fi
fi

exit "$status"
