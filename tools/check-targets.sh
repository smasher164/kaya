#!/usr/bin/env bash

# Everything runs inside the dev shell: the flake pins every toolchain
# (rust + cross targets, swiftc, ffmpeg, the android sdk). Running
# against anything else is an error, not something to paper over — and
# a shell entered before the flake last changed is just as much a
# bystander toolchain, so the marker carries the fingerprint of
# flake.nix+flake.lock the shell was actually built from.
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# Cross-target compile check: catch per-platform Rust breakage (a
# non-exhaustive match in a cfg'd backend, a missing stub arm) in
# seconds, before any emulator, simulator, or VM is involved. Run
# inside the dev shell; the device scripts run their own target's check
# first, and validate-mac runs all of them as a gate.
#
# Usage: check-targets.sh [native|ios|android|windows|all]   (default all)
#
# The Linux/GTK backend is the one absentee: gtk-sys needs the
# distro's pkg-config world, so its compile check cannot run here.
# It has its own gate — tools/check-gtk.sh, a cargo check inside the
# cached container — which is the one to run after touching gtk.rs.
# Do not read a green here as "every backend compiles".
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
    # Warnings stay quiet (some cfg'd backends carry known ones); the
    # full output appears only when the check fails.
    local out
    # BOTH feature configurations. The harness is off by default, so a
    # default-only check compiles neither Stage impl nor any
    # harness-gated backend code — and deploy-win/run-suites build WITH
    # the feature. Measured 2026-07-25: this gate reported "windows OK"
    # while the windows lane failed to build the WinUI accessibility
    # read, because that code only exists under --features harness.
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

# THE GO BINDING'S ANDROID ARM, which is the second thing in this tree
# that only one lane compiles — and the first one outside Rust.
#
# bindings/go/mainmain_android.go is `//go:build android`, and it is the
# only build-tagged file in the Go binding. It carries the
# `//go:linkname mainMain main.main` pull that lets an ordinary app —
# one main.go, no build tags, no second entry point — be started by
# kaya's JNI attach on Android, where `-buildmode=c-shared` keeps
# main.main in the library and never calls it. bindings/go/android.go's
# header states the doctrine this file breaks and why the break is
# narrow: untagged, the pull would make EVERY consumer of the binding on
# EVERY platform need a main.main at link time.
#
# So this clause is the thing that keeps it from being dark. It builds a
# single-main FIXTURE app for android/arm64 as `-buildmode=c-shared`,
# the artifact shape a real Android app ships, and that one command
# answers two separate questions:
#
#   1. DOES THE TAGGED FILE COMPILE — and does it exist at all. Its
#      `!android` twin (mainmain_other.go) does not answer here, so an
#      android build with the file deleted stops at
#      "undefined: guestMain" rather than quietly falling back.
#   2. DOES THE LINKNAME RESOLVE. This is the only thing anywhere that
#      asks: a bodyless func COMPILES whether or not the directive above
#      it is there or spelled right, and only the LINK says otherwise.
#      Watched failing 2026-08-09 — commenting out the one directive
#      gives "relocation target dev.kaya/bindings/go.mainMain not
#      defined".
#
# It also matters that the fixture is a REAL single-main app: the whole
# validation APK uses the other shape (registration through
# kaya.AndroidMain, because one c-shared library has exactly one
# main.main and it cannot be thirty-one scenes), so the matrix cannot
# cover this path at all.
#
# NO cargo-ndk BUILD IS NEEDED, which is what makes this a fast gate.
# The binding's `#cgo android LDFLAGS` names -lkaya, so the link wants
# libkaya.so — but a shared object may leave symbols undefined, so a
# one-symbol stub built here answers for it. CGO_LDFLAGS is searched
# BEFORE the #cgo directive's own -L (measured with `ld -t`), so the
# stub wins whether or not the android lane has left a real one behind,
# and the gate's answer does not depend on which.
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
    # deliberately not coupled to it: what is being checked here is Go
    # symbol resolution, which no platform level can change, and reading
    # android/*/build.gradle.kts would put the whole Compose interpreter
    # into this gate's cache key for nothing. The LANE cross-builds
    # against the module's minSdk (tools/android/run-emulator.sh) and
    # that is where the platform level is load-bearing.
    local candidates=("$ndkbin"/aarch64-linux-android[0-9]*-clang)
    cc="${candidates[0]}"
    if [ ! -x "$cc" ]; then
        echo "check-targets: go-android FAIL (no aarch64-linux-android*-clang in $ndkbin)"
        status=1
        return
    fi
    t="$(mktemp -d)"
    # A SINGLE main.go WITH NO BUILD TAGS AND NO ANDROID-SPECIFIC LINE.
    # That is the whole claim being checked, so the fixture must not
    # contain one word more than an app author writes. Its own module
    # with a filesystem replace, because a main package inside dev.kaya
    # would be a guest with no leg and check-steps would rightly say so.
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
    # -dumpdep MAKES THE LINKER SHOW ITS WORK, and it is here for the one
    # mutation a successful link cannot see. If guestMain stopped
    # answering with the app's main — `return nil`, the shape a hurried
    # fix takes — nothing would reference mainMain, dead-code elimination
    # would drop it, THE BUILD WOULD STILL SUCCEED, and every single-main
    # app would silently stop starting while the whole matrix (which
    # uses the registration shape) stayed green. Measured 2026-08-09: rc
    # 0, and the edge below goes from 1 to 0. The dump is the linker's
    # symbol reachability graph on stderr; the edge asserted after the
    # build is the attach entry naming the app's own main.
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
    # WHAT THE ARTIFACT MUST CONTAIN, both counted rather than merely
    # looked for, so a build that produced nothing cannot pass: the
    # app's own main (what the linkname resolves to) and the one JNI
    # entry the Kotlin shell calls. The leading space is the point on
    # the second one — cgo emits a `_cgoexp_…` trampoline ending in the
    # same characters, so an end-anchor alone counts two.
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

# LINUX IS THE HOLE IN THE ABOVE. gtk-sys needs the distro's pkg-config
# world, so this gate cannot cross-compile the GTK backend at all and
# check-gtk (docker) is the only thing that compiles it — which makes
# "run check-gtk after touching gtk.rs" an instruction someone has to
# remember. It failed the first time it mattered: the file-dialog slice
# added three Stage methods, mac and windows compiled, this gate went
# green, and the linux lane died on `missing: goto_directory`. The text
# check below cannot see a wrong signature, but it sees the class that
# escaped, in a second, with no docker.
if ! python3 tools/lib/stage-coverage.py; then
    status=1
fi

# The other thing cross-compiling cannot see: a CORE surface that exists
# on one platform only. Every target above compiled happily while the
# picked-file redemption path was #[cfg(unix)] end to end and Windows
# had no way to redeem a handle at all — because the only thing that
# would have referenced it there was a depth-stubbed apply arm. A
# cfg'd-out surface whose only consumer is also cfg'd out is invisible
# to a compiler: nothing is missing until something asks.
if ! python3 tools/lib/paired-cfg.py; then
    status=1
fi

if [ "$status" = 0 ]; then echo "check-targets: ALL OK"; else echo "check-targets: FAILURES ABOVE"; fi
exit "$status"
