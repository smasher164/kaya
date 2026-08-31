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
# Compile-check the Compose interpreter and the three Android app
# modules — the swift-typecheck/java-typecheck sibling for Kotlin. The
# emulator must never be the first compiler to see KayaCompose.kt.
#
# The Java task is named EXPLICITLY: compileDebugKotlin does not imply
# it, and the Android SDK is a DIFFERENT java.lang from the desktop JDK
# java-typecheck uses, so that gate cannot stand in for this one.
#
# AND THE MODULE'S HOST-JVM TESTS, since the M3 scheme ruling
# (docs/deferred.md "THE FULL M3 SCHEME"): KayaColorSchemes.of() is a
# pure function and KayaColorSchemesTest is its wall — the four seed
# palettes moving, the error family refusing to — run here because no
# scene freezes a scheme byte, so the emulator would otherwise be the
# first and only thing to prove the brand scheme.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/android" || exit 1

gradle --console=plain -q :kaya:compileDebugKotlin || {
    echo "check-compose: FAIL (KayaCompose.kt does not compile)" >&2
    exit 1
}
gradle --console=plain -q :kaya:testDebugUnitTest || {
    echo "check-compose: FAIL (the kaya module's host-JVM tests fail — the scheme wall is KayaColorSchemesTest)" >&2
    exit 1
}
gradle --console=plain -q :milestone2:compileDebugKotlin \
    :milestone2kt:compileDebugKotlin :milestone2go:compileDebugKotlin || {
    echo "check-compose: FAIL (an Android app module does not compile)" >&2
    exit 1
}
# :milestone2go is absent here and only here: its guest is Go, in a .so,
# and it carries no Java of its own for javac to see.
gradle --console=plain -q :milestone2:compileDebugJavaWithJavac \
    :milestone2kt:compileDebugJavaWithJavac || {
    echo "check-compose: FAIL (a Java guest does not compile for Android)" >&2
    exit 1
}
echo "check-compose: OK"
