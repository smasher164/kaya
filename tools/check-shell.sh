#!/usr/bin/env bash
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

if [ "$status" = 0 ]; then
    echo "check-shell: OK"
else
    echo "check-shell: FINDINGS ABOVE"
fi
exit "$status"
