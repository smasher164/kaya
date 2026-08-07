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
# Compile-check the Compose interpreter. check-verbs holds its SOURCE
# current by string-matching, but no mac-side gate ever COMPILED
# KayaCompose.kt — the Android emulator run was the first compiler to
# see it, minutes into a suite (caught live 2026-07-22: a missing
# verticalScroll import produced a zero-verdict emulator run). This
# is the swift-typecheck/java-typecheck sibling for the Kotlin layer:
# seconds warm under the gradle daemon.
#
# The three APP modules compile here too, for the same reason one level
# up: they carry per-scene registration (each MainActivity's scene
# arm) and the hardware-chord override that forwards to the
# interpreter's dispatch table. That code is Kotlin no other gate
# sees.
#
# AND THE JAVA TASK EXPLICITLY, because compileDebugKotlin does not
# imply it: milestone2kt drags in every Java guest, but those are
# javac's to compile, under a different gradle task. This gate claimed
# to cover them for four milestones while running only the Kotlin
# half. What it missed is the whole reason to compile them HERE rather
# than trust java-typecheck: that gate uses the desktop JDK, and the
# Android SDK is a DIFFERENT java.lang. A guest reaching for
# ProcessHandle (Java 9, absent from Android at any API level this
# repo targets) type-checks clean on the mac, passes every fast gate,
# and fails minutes into the emulator lane. Measured 2026-07-31.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/android" || exit 1

gradle --console=plain -q :kaya:compileDebugKotlin || {
    echo "check-compose: FAIL (KayaCompose.kt does not compile)" >&2
    exit 1
}
gradle --console=plain -q :milestone2:compileDebugKotlin \
    :milestone2kt:compileDebugKotlin :milestone2go:compileDebugKotlin || {
    echo "check-compose: FAIL (an Android app module does not compile)" >&2
    exit 1
}
# The Java half of the two JVM-carrying modules — the guests, against
# the ANDROID java.lang rather than the desktop one. See the note above.
# :milestone2go is absent here and only here: its guest is Go, in a .so
# built by tools/android/run-emulator.sh, and it carries no Java of its
# own for javac to see.
gradle --console=plain -q :milestone2:compileDebugJavaWithJavac \
    :milestone2kt:compileDebugJavaWithJavac || {
    echo "check-compose: FAIL (a Java guest does not compile for Android)" >&2
    exit 1
}
echo "check-compose: OK"
