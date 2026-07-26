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

# The gate for the stale-artifact guard (tools/build-id.sh). It answers
# the two questions that make that guard real rather than decorative:
#
#   1. Does a BUILT library actually carry the current id, and does the
#      verifier reject one that carries a different id? A verifier that
#      passes everything is worse than none — it converts "I did not
#      check" into "I checked and it was fine".
#   2. Does every lane verify what it is about to run or ship? The check
#      is a call somebody has to write, so a new lane starts out
#      unguarded; that is exactly the failure this clause holds open.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

LIB="$ROOT/target/debug/libkaya.dylib"
[ -f "$LIB" ] || { echo "check-build-id: build libkaya first (cargo build --locked --lib)"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

status=0
fail() {
    echo "check-build-id: $1" >&2
    status=1
}

# 1a. The real artifact, freshly built, carries the id of this tree.
if ! tools/build-id.sh --verify "$LIB" >/dev/null 2>"$TMP/err"; then
    fail "a freshly built libkaya does not carry this tree's id"
    cat "$TMP/err" >&2
fi

# 1b. Doctor the marker in a COPY of that same library — one hex digit,
# nothing else — and the verifier must reject it. This is the shape a
# stale artifact takes: a real, loadable, correct-looking library built
# from sources that are no longer here.
python3 - "$LIB" "$TMP/stale.dylib" <<'PY'
import pathlib, sys
blob = bytearray(pathlib.Path(sys.argv[1]).read_bytes())
at = blob.find(b"kaya-build-id:")
if at == -1:
    sys.exit("check-build-id: no marker in the library to doctor")
# Flip the first hex digit of the id to something else.
digit = at + len(b"kaya-build-id:")
blob[digit] = ord("f") if blob[digit] != ord("f") else ord("0")
pathlib.Path(sys.argv[2]).write_bytes(blob)
PY
[ -f "$TMP/stale.dylib" ] || fail "could not produce a doctored library for the self-test"
if tools/build-id.sh --verify "$TMP/stale.dylib" >/dev/null 2>&1; then
    fail "self-test failed: a library carrying a DIFFERENT id verified clean"
fi

# 1c. A file with no marker at all must be rejected too, not skipped.
printf 'not a library\n' >"$TMP/empty.bin"
if tools/build-id.sh --verify "$TMP/empty.bin" >/dev/null 2>&1; then
    fail "self-test failed: a file with no build id verified clean"
fi

# 1d. A missing file is a failed build, not a pass by absence.
if tools/build-id.sh --verify "$TMP/does-not-exist" >/dev/null 2>&1; then
    fail "self-test failed: a missing artifact verified clean"
fi

# 2. Coverage. Each lane builds the core and then runs or ships it; the
# list is explicit because a runner that silently stopped verifying
# would otherwise look exactly like one that never needed to.
for lane in \
    tools/validate-mac.sh \
    tools/linux/run-suites.sh \
    tools/ios/run-sim.sh \
    tools/android/run-emulator.sh \
    tools/deploy-win.sh \
    tools/swiftui/build-dylib.sh; do
    if ! grep -q "build-id.sh\" --verify\|build-id.sh --verify" "$lane"; then
        fail "$lane builds the core but never verifies what it runs (build-id.sh --verify)"
    fi
done

if [ "$status" = 0 ]; then
    echo "check-build-id: OK"
else
    echo "check-build-id: FINDINGS ABOVE"
fi
exit "$status"
