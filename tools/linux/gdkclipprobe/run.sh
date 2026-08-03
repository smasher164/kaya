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
    if ! command -v sway >/dev/null || ! command -v wl-paste >/dev/null \
        || ! command -v wayland-info >/dev/null || ! command -v wtype >/dev/null; then
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq sway wl-clipboard wayland-utils wtype >/dev/null 2>&1
    fi
    command -v wl-paste >/dev/null || {
        echo "PROBE FATAL: wl-paste absent; the foreign answers would be lies"
        exit 1
    }
    command -v wayland-info >/dev/null || {
        echo "PROBE FATAL: wayland-info absent; the seat answer would be a lie"
        exit 1
    }
    command -v wtype >/dev/null || {
        echo "PROBE FATAL: wtype absent; the serial half of the probe cannot run"
        exit 1
    }

    # Floating, or sway tiles the window to the output and the probe
    # measures a size nobody asked for (the same one line the lane
    # needs). -d so the log holds wlroots debug lines: a rejected
    # set_selection is logged at DEBUG and invisible at the default
    # level (candidate 2 in docs/clipboard-plan.md 5b would otherwise
    # fail silently on the compositor side, by design).
    printf "for_window [app_id=\".*\"] floating enable\n" >/tmp/sway.conf
    WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
        sway -d -c /tmp/sway.conf >/tmp/sway.log 2>&1 &
    sleep 3
    export WAYLAND_DISPLAY=wayland-1
    unset DISPLAY

    # Candidate 1, the cheapest and the one that matched the Weston
    # finding: does THIS sway session expose a wl_seat at all, and with
    # what capabilities? Same tool the Weston probe used.
    # (Run 1: a seat exists, capabilities EMPTY — no keyboard, no
    # pointer — so no client can ever receive an input serial, and
    # wlroots rejects every set_selection. Run 2: a modifier-only wtype
    # tap did not help; modifiers are not key events. Run 3: a held
    # virtual keyboard put `keyboard` in the capabilities and a real
    # F24 tap made the selection foreign-visible; the probe now runs
    # the primer variants itself, so the session starts holder-free.)
    SEAT="$(wayland-info -i wl_seat 2>&1)"
    if [ -z "$SEAT" ]; then
        echo "PROBE seat: NO wl_seat advertised"
    else
        echo "PROBE seat: $SEAT" | tr "\n" " "; echo
    fi

    # Examples are declared explicitly in Cargo.toml with paths into
    # guests/rust, so the probe needs a target of its own. It is added
    # for the length of this run and taken out again by a trap, so an
    # interrupted probe cannot leave the manifest dirty. Adding an
    # example target changes no dependency, so --locked stays honest.
    #
    # A SIGKILLed run (docker kill) skips the trap and leaves the block
    # behind, and the next run would then back up the dirty manifest
    # and append a duplicate — so strip any leftover block FIRST, then
    # back up the clean file.
    python3 - <<PYEOF
p = "crates/kaya/Cargo.toml"
lines = open(p).read().split("\n")
out = []
skip = 0
changed = False
for i, ln in enumerate(lines):
    if skip:
        skip -= 1
        continue
    if ln == "[[example]]" and i + 1 < len(lines) and "gdkclipprobe" in lines[i + 1]:
        skip = 2
        changed = True
        continue
    out.append(ln)
if changed:
    text = "\n".join(out)
    while text.endswith("\n\n"):
        text = text[:-1]
    if not text.endswith("\n"):
        text += "\n"
    open(p, "w").write(text)
    print("PROBE note: stripped a leftover gdkclipprobe block from a killed run")
PYEOF
    cp crates/kaya/Cargo.toml /tmp/Cargo.toml.probe
    trap "cp /tmp/Cargo.toml.probe /work/crates/kaya/Cargo.toml" EXIT INT TERM
    printf "\n[[example]]\nname = \"gdkclipprobe\"\npath = \"../../tools/linux/gdkclipprobe/probe.rs\"\n" \
        >>crates/kaya/Cargo.toml
    cargo run --locked --quiet --example gdkclipprobe 2>&1
    rc=$?

    # Candidate 2: wlroots logs a rejected set_selection (bad or absent
    # input serial) at DEBUG and tells the client nothing. If the grep
    # prints a rejection, that is the whole finding.
    echo "PROBE sway.log selection/serial lines:"
    grep -iE "selection|serial|data.device|data.source" /tmp/sway.log \
        | grep -ivE "get_data_device|wl_data_device_manager" | tail -30
    echo "PROBE sway.log input-device lines:"
    grep -iE "virtual|new input|keyboard" /tmp/sway.log \
        | grep -ivE "keymap|xkb_" | tail -15
    exit $rc
'
