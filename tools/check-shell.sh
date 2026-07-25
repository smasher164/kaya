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
# Lint every tools/ shell script with shellcheck at warning level. The
# suites' orchestration is shell, and shell's silent failure modes
# (unquoted words, unchecked cd, masked exit codes) have each cost a
# debugging round — catch them at the gate instead.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

command -v shellcheck >/dev/null \
    || { echo "check-shell: shellcheck not found — run inside nix develop"; exit 1; }

# Self-test: a script with a known warning-level defect must produce
# findings, or the shellcheck invocation itself is broken and the
# green gate below would be a lie.
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
printf '#!/bin/sh\ncd /nowhere\necho $undefined_word_splits\n' >"$T/bad.sh"
if shellcheck -S warning "$T/bad.sh" >/dev/null 2>&1; then
    echo "check-shell: self-test failed (shellcheck found nothing in a bad script)"
    exit 1
fi

status=0
for f in tools/*.sh tools/ios/*.sh tools/android/*.sh tools/swiftui/*.sh tools/linux/*.sh; do
    [ -f "$f" ] || continue
    if ! shellcheck -S warning "$f"; then
        status=1
    fi
done

# javac takes the PLATFORM charset, and the hosts disagree: UTF-8 on
# mac and linux, a legacy code page on the Windows VM. A scene label
# with a non-ASCII character therefore reached the wire as mojibake
# from one host only, and no gate could see it (docs/traps.md). Every
# invocation must pin the encoding rather than inherit a default.
unpinned=$(grep -rnE "(javac|run_javac) .*(-d |-proc:only)" tools/ --include="*.sh" \
    | grep -v "encoding UTF-8") || true
if [ -n "$unpinned" ]; then
    echo "check-shell: javac without -encoding UTF-8 (the host charset differs per platform):" >&2
    echo "$unpinned" >&2
    status=1
fi

if [ "$status" = 0 ]; then
    echo "check-shell: OK"
else
    echo "check-shell: FINDINGS ABOVE"
fi
exit "$status"
