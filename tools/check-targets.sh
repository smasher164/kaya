#!/usr/bin/env bash

# Dev-shell guard; the marker is the flake fingerprint (CLAUDE.md).
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# Cross-target compile check: per-platform Rust breakage in seconds,
# before any emulator, simulator or VM is involved.
#
# Usage: check-targets.sh [native|ios|android|windows|all]   (default all)
#
# The Linux/GTK backend is the one absentee — gtk-sys needs the distro's
# pkg-config world — so tools/check-gtk.sh is what to run after touching
# gtk.rs. Do not read a green here as "every backend compiles".
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

want="${1:-all}"
status=0

check() {
    local name="$1"
    shift
    if [ "$want" != "all" ] && [ "$want" != "$name" ]; then
        return
    fi
    local out
    # BOTH feature configurations: the harness is off by default, so a
    # default-only check compiles neither Stage impl nor any
    # harness-gated backend code, and the lanes build WITH the feature.
    if out="$(cargo check --locked -p kaya --lib --quiet "$@" 2>&1 \
        && cargo check --locked -p kaya --lib --quiet --features harness "$@" 2>&1)"; then
        echo "check-targets: $name OK"
    else
        echo "$out"
        echo "check-targets: $name FAIL"
        status=1
    fi
}

check native
check ios --target aarch64-apple-ios
check android --target aarch64-linux-android
check windows --target aarch64-pc-windows-msvc

# THE GO BINDING'S ANDROID ARM: the `//go:linkname mainMain main.main`
# pull in bindings/go/mainmain_android.go (docs/go-mobile-plan.md). The
# MATRIX cannot cover it — the validation APK uses the registration
# shape — so this clause cross-builds a single-main fixture for
# android/arm64 as `-buildmode=c-shared` and asks two things: does the
# tagged file compile, and does the linkname RESOLVE. A bodyless func
# compiles whether or not the directive above it is there or spelled
# right; only the link says otherwise.
#
# NO cargo-ndk BUILD IS NEEDED, which is what makes this a fast gate.
# The binding's `#cgo android LDFLAGS` names -lkaya, and a one-symbol
# stub answers for it. CGO_LDFLAGS is searched BEFORE the #cgo
# directive's own -L (measured with `ld -t`), so the stub wins whether
# or not the android lane left a real libkaya.so behind.
go_android() {
    if [ "$want" != "all" ] && [ "$want" != "android" ]; then
        return
    fi
    local ndkbin cc t out jni_count main_count
    if [ -z "${ANDROID_NDK_ROOT:-}" ]; then
        echo "check-targets: go-android FAIL (ANDROID_NDK_ROOT unset; the dev shell sets it)"
        status=1
        return
    fi
    ndkbin="$(echo "$ANDROID_NDK_ROOT"/toolchains/llvm/prebuilt/*/bin)"
    # THE LOWEST PLATFORM THE NDK CARRIES, not the module's minSdk, and
    # deliberately not coupled to it: this checks Go symbol resolution,
    # which no platform level changes, and reading build.gradle.kts would
    # put the Compose interpreter into this gate's cache key.
    local candidates=("$ndkbin"/aarch64-linux-android[0-9]*-clang)
    cc="${candidates[0]}"
    if [ ! -x "$cc" ]; then
        echo "check-targets: go-android FAIL (no aarch64-linux-android*-clang in $ndkbin)"
        status=1
        return
    fi
    t="$(mktemp -d)"
    # A SINGLE main.go WITH NO BUILD TAGS AND NO ANDROID-SPECIFIC LINE —
    # that is the claim, so the fixture must not contain one word more
    # than an app author writes. Its own module with a filesystem
    # replace, because a main package inside dev.kaya would be a guest
    # with no leg and check-steps would rightly say so.
    cat >"$t/go.mod" <<GOMOD
module kayalinknamefixture

go 1.27

require dev.kaya v0.0.0

replace dev.kaya => $ROOT
GOMOD
    cat >"$t/main.go" <<'GOAPP'
package main

import (
	"os"

	kaya "dev.kaya/bindings/go"
)

func main() { os.Exit(kaya.NewApp().Run()) }
GOAPP
    # THE STUB LIVES IN ITS OWN DIRECTORY, beside the fixture rather
    # than in it: `go build .` refuses a package directory containing a
    # .c file when no file in it imports "C".
    mkdir -p "$t/stub"
    printf 'int kaya_link_stub;\n' >"$t/stub/stub.c"
    out="$("$cc" -shared -o "$t/stub/libkaya.so" "$t/stub/stub.c" 2>&1)"
    local stub_rc=$?
    if [ "$stub_rc" -ne 0 ]; then
        echo "$out"
        echo "check-targets: go-android FAIL (could not build the -lkaya stub)"
        status=1
        rm -rf "$t"
        return
    fi
    # -dumpdep MAKES THE LINKER SHOW ITS WORK, for the one mutation a
    # successful link cannot see: if guestMain stopped answering with
    # the app's main, nothing would reference mainMain, dead-code
    # elimination would drop it, and the build would still succeed. The
    # dump is the reachability graph on stderr; the edge asserted below
    # is the attach entry naming the app's own main.
    (cd "$t" && CGO_ENABLED=1 GOOS=android GOARCH=arm64 CC="$cc" \
        GOFLAGS=-mod=mod GOPROXY=off CGO_LDFLAGS="-L$t/stub" \
        go build -buildmode=c-shared -ldflags=-dumpdep -o "$t/libfixture.so" . \
        2>"$t/dep.txt")
    local build_rc=$?
    if [ "$build_rc" -ne 0 ]; then
        # Everything the linker said that was not a dependency edge.
        grep -v ' -> ' "$t/dep.txt" | tail -20
        echo "check-targets: go-android FAIL (the single-main fixture did not"
        echo "  cross-build for android/arm64). A 'relocation target"
        echo "  dev.kaya/bindings/go.mainMain not defined' here means the"
        echo "  //go:linkname in bindings/go/mainmain_android.go is gone or"
        echo "  misspelled, and with it every app that ships one main.go."
        status=1
        rm -rf "$t"
        return
    fi
    out="$(grep -c 'Java_dev_kaya_KayaGo_attach -> dev\.kaya/bindings/go\.mainMain' "$t/dep.txt")"
    if [ "$out" != 1 ]; then
        echo "check-targets: go-android FAIL (the attach entry does not reference"
        echo "  the app's own main: $out edges, want 1). The linkname resolved but"
        echo "  nothing uses it — check that bindings/go/mainmain_android.go's"
        echo "  guestMain still answers with mainMain, and that"
        echo "  bindings/go/android.go still calls guestMain when no guest"
        echo "  registered one. This is the failure the LINK cannot see."
        status=1
        rm -rf "$t"
        return
    fi
    # COUNTED, not merely looked for, so a build that produced nothing
    # cannot pass. The leading space matters: cgo emits a `_cgoexp_…`
    # trampoline ending in the same characters, so an end-anchor alone
    # counts two.
    jni_count="$("$ndkbin/llvm-nm" -D --defined-only "$t/libfixture.so" 2>/dev/null \
        | grep -c ' Java_dev_kaya_KayaGo_attach$')"
    main_count="$("$ndkbin/llvm-nm" "$t/libfixture.so" 2>/dev/null \
        | grep -c ' main\.main$')"
    rm -rf "$t"
    if [ "$jni_count" != 1 ] || [ "$main_count" != 1 ]; then
        echo "check-targets: go-android FAIL (the fixture linked but carries"
        echo "  $jni_count Java_dev_kaya_KayaGo_attach and $main_count main.main;"
        echo "  both must be exactly 1)"
        status=1
        return
    fi
    echo "check-targets: go-android OK"
}

go_android

# LINUX IS THE HOLE IN THE ABOVE: nothing here compiles the GTK backend,
# so a Stage method missed in gtk.rs alone survives every fast gate and
# dies in the matrix. This text check cannot see a wrong signature, but
# it sees a missing method in a second with no docker.
if ! python3 tools/lib/stage-coverage.py; then
    status=1
fi

# The other thing cross-compiling cannot see: a CORE surface that exists
# on one platform only. A cfg'd-out surface whose only consumer is also
# cfg'd out is invisible to a compiler — nothing is missing until
# something asks.
if ! python3 tools/lib/paired-cfg.py; then
    status=1
fi

if [ "$status" = 0 ]; then echo "check-targets: ALL OK"; else echo "check-targets: FAILURES ABOVE"; fi
exit "$status"
