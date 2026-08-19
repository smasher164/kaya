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
# Fetch the Windows App SDK component packages and extract the WinRT
# metadata (.winmd) plus the bootstrap DLL. Output lands in
# third_party/winappsdk/ (gitignored; the bindings are committed).
# Microsoft.WindowsAppSDK is a meta-package as of 2.x; the component
# versions below come from its nuspec (2.2.0).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/third_party/winappsdk"

fetch() {
    local id="$1" version="$2"
    local lower
    lower=$(echo "$id" | tr '[:upper:]' '[:lower:]')
    local dir="$DEST/$id-$version"
    if [ -d "$dir/extracted" ]; then
        echo "cached: $id $version"
        return
    fi
    echo "fetching $id $version"
    mkdir -p "$dir"
    curl -sSfL \
        "https://api.nuget.org/v3-flatcontainer/$lower/$version/$lower.$version.nupkg" \
        -o "$dir/package.nupkg"
    mkdir -p "$dir/extracted"
    (cd "$dir/extracted" && unzip -q ../package.nupkg)
}

fetch Microsoft.WindowsAppSDK.Base 2.0.4
fetch Microsoft.WindowsAppSDK.Foundation 2.1.0
fetch Microsoft.WindowsAppSDK.InteractiveExperiences 2.0.15
fetch Microsoft.WindowsAppSDK.WinUI 2.2.1
# Runtime installer, for provisioning test machines.
fetch Microsoft.WindowsAppSDK.Runtime 2.2.0

echo "== winmd files =="
find "$DEST" -name '*.winmd' | KAYA_DEST="$DEST" python3 -c '
import os, sys
prefix = os.environ["KAYA_DEST"] + "/"
for line in sys.stdin:
    print(line.strip().removeprefix(prefix))' | sort
echo "== bootstrap DLLs (arm64) =="
find "$DEST" -iname '*bootstrap*' -path '*arm64*' | KAYA_DEST="$DEST" python3 -c '
import os, sys
prefix = os.environ["KAYA_DEST"] + "/"
for line in sys.stdin:
    print(line.strip().removeprefix(prefix))' | sort
