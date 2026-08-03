#!/usr/bin/env bash

# Drive probe.rs inside the lane's own image, under sway — the
# compositor the wayland leg moved to, because it is the one with
# data-control (docs/clipboard-plan.md §0e finding 1). Running it
# anywhere else would measure a different clipboard than the lane has.
#
# Throwaway. Nothing in the validation ladder calls this; a human does,
# once, before the GTK arm is written. Answers land on stdout under
# "PROBE".
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

if ! docker info >/dev/null 2>&1; then
    echo "gdkclipprobe: docker is not running" >&2
    exit 1
fi
if [ -z "$(docker image ls -q kaya-linux 2>/dev/null)" ]; then
    echo "gdkclipprobe: the kaya-linux image is missing — build it first" >&2
    exit 1
fi

# The probe is a cargo example so it links against the SAME gtk4 crate
# version the backend does; measuring a different one would answer a
# question nobody asked.
docker run --rm -v "$ROOT:/work" kaya-linux bash -c '
    cd /work || exit 1
    export CARGO_TARGET_DIR=/work/target-linux
    export XDG_RUNTIME_DIR=/tmp/xdg
    mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"

    # GUARD ON THE TOOL THE PROBE ACTUALLY CALLS. Checking sway and
    # installing both meant an image WITH sway and WITHOUT wl-clipboard
    # skipped the install, and every foreign answer came back
    # "<wl-paste failed: No such file or directory>" — a missing reader
    # reads exactly like an empty clipboard.
    if ! command -v sway >/dev/null || ! command -v wl-paste >/dev/null; then
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq sway wl-clipboard >/dev/null 2>&1
    fi
    command -v wl-paste >/dev/null || {
        echo "PROBE FATAL: wl-paste absent; the foreign answers would be lies"
        exit 1
    }

    # Floating, or sway tiles the window to the output and the probe
    # measures a size nobody asked for (the same one line the lane
    # needs).
    printf "for_window [app_id=\".*\"] floating enable\n" >/tmp/sway.conf
    WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
        sway -c /tmp/sway.conf >/tmp/sway.log 2>&1 &
    sleep 3
    export WAYLAND_DISPLAY=wayland-1
    unset DISPLAY

    # Examples are declared explicitly in Cargo.toml with paths into
    # guests/rust, so the probe needs a target of its own. It is added
    # for the length of this run and taken out again by a trap, so an
    # interrupted probe cannot leave the manifest dirty. Adding an
    # example target changes no dependency, so --locked stays honest.
    cp crates/kaya/Cargo.toml /tmp/Cargo.toml.probe
    trap "cp /tmp/Cargo.toml.probe /work/crates/kaya/Cargo.toml" EXIT INT TERM
    printf "\n[[example]]\nname = \"gdkclipprobe\"\npath = \"../../tools/linux/gdkclipprobe/probe.rs\"\n" \
        >>crates/kaya/Cargo.toml
    cargo run --locked --quiet --example gdkclipprobe 2>&1
'
