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
# metadata plus the bootstrap DLL into third_party/winappsdk/
# (gitignored). The component versions come from Microsoft.WindowsAppSDK
# 2.2.0's nuspec.
#
# Each package names an exact version AND the sha256 of the .nupkg. This
# is a curl, not a package manager, so no lockfile covers it —
# tools/check-pins.py's fifth clause is what guards this door.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/third_party/winappsdk"

# BY HASH, NEVER BY SIZE — a same-length corruption passes a size check
# (the staging rule tools/check-assets.py holds for the asset root).
# check-pins cuts this function out and runs it against both outcomes,
# so the refusal must print what it measured.
verify_sha256() {
    local path="$1" want="$2" label="$3"
    local got
    got=$(shasum -a 256 "$path" | cut -d' ' -f1)
    if [ "$got" = "$want" ]; then
        return 0
    fi
    echo "fetch-winappsdk: $label does not match its recorded hash" >&2
    echo "  file:     $path" >&2
    echo "  recorded: $want" >&2
    echo "  measured: $got" >&2
    echo "  Delete that directory and re-run to refetch. If a fresh download still" >&2
    echo "  disagrees, the recorded number is what is wrong: nuget.org publishes each" >&2
    echo "  version's packageHash (sha512, base64) in its catalog entry — check it" >&2
    echo "  there before editing this file." >&2
    return 1
}

# fetch <Id> <version> <sha256 of the .nupkg>
fetch() {
    local id="$1" version="$2" want="$3"
    local lower
    lower=$(echo "$id" | tr '[:upper:]' '[:lower:]')
    local dir="$DEST/$id-$version"
    local pkg="$dir/package.nupkg"
    local downloaded=0
    if [ ! -f "$pkg" ]; then
        echo "fetching $id $version"
        mkdir -p "$dir"
        # Downloaded aside and moved: a half-written body never becomes
        # the thing the next run calls its cache.
        curl -sSfL \
            "https://api.nuget.org/v3-flatcontainer/$lower/$version/$lower.$version.nupkg" \
            -o "$pkg.part"
        mv "$pkg.part" "$pkg"
        downloaded=1
    fi
    # THE CACHE IS VERIFIED TOO, before the early-out below can skip
    # anything: the directory name carries the version, so a bump
    # refetches, but nothing else says the bytes already on disk are the
    # ones this file names (deploy-win.py's version-keyed go check is the
    # same lesson one machine over).
    if ! verify_sha256 "$pkg" "$want" "$id $version"; then
        exit 1
    fi
    if [ "$downloaded" = 0 ] && [ -d "$dir/extracted" ]; then
        echo "cached: $id $version"
        return
    fi
    # A fresh download always re-extracts: any tree beside it came from
    # bytes nobody verified.
    rm -rf "$dir/extracted"
    mkdir -p "$dir/extracted"
    (cd "$dir/extracted" && unzip -q ../package.nupkg)
}

fetch Microsoft.WindowsAppSDK.Base 2.0.4 \
    e3e13478c4c80c59ed5f8f89542fe49a2985daa484753e93a5858e90c2d46a4d
fetch Microsoft.WindowsAppSDK.Foundation 2.1.0 \
    e18cdae2134afa97a04c3b746dc025b2c44325ab4061ae49c5c8d60f7081a716
fetch Microsoft.WindowsAppSDK.InteractiveExperiences 2.0.15 \
    67dac7a22a66d1e9bf77a29d77028cffc2e22cb71d44e49e70cf7fac0ce6745d
fetch Microsoft.WindowsAppSDK.WinUI 2.2.1 \
    9ce50ddd6f2e2702f05f3575d8565651003e87b55d877fa4bff4369192dc5938
# Runtime installer, for provisioning test machines.
fetch Microsoft.WindowsAppSDK.Runtime 2.2.0 \
    9db02530fe2796c17157278ec46910164a680641c40e334e48be5caa6021953f

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
