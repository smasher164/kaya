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
# The packaging gate: build the kaya-gui wheel fresh, install it into a
# throwaway venv, and import through the INSTALLED package. The suites
# run the working tree via PYTHONPATH, so only this leg sees what the
# wheel actually ships.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --no-isolation keeps the build offline and pinned to the flake.
python3 -m build --wheel --no-isolation --outdir "$TMP/dist" bindings/python \
    > "$TMP/build.log" 2>&1 || {
    echo "check-wheel: wheel build failed" >&2
    tail -5 "$TMP/build.log" >&2
    exit 1
}

python3 -m venv "$TMP/venv" || exit 1
# Empty PYTHONPATH: the venv's installed wheel must be the ONLY import
# mechanism here, or a packaging hole hides behind the working tree.
env -u PYTHONPATH "$TMP/venv/bin/pip" install --quiet --no-index "$TMP"/dist/kaya_gui-*.whl || {
    echo "check-wheel: wheel install failed" >&2
    exit 1
}
if ! env -u PYTHONPATH KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    "$TMP/venv/bin/python" - <<'PY'
import kaya
import kaya.wire
import kaya.runtime

assert isinstance(kaya.wire.SPEC_HASH, int)
assert hasattr(kaya, "collection") and hasattr(kaya, "for_each")
PY
then
    echo "check-wheel: installed package failed its import smoke" >&2
    exit 1
fi
echo "check-wheel: OK"
