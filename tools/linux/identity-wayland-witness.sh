#!/usr/bin/env bash
# THE WAYLAND HALF OF THE IDENTITY SCENE, ASSERTED AS THE GAP IT IS
# (docs/app-identity-plan.md ruling 5 and I4a): the leg must fail on the
# icon steps ONLY, as many times as the scene reads an icon, with the
# backend's sentence naming the GDK display object and the lowering
# having run anyway. Each clause below prints what it saw.
set -uo pipefail

if [ "$#" -lt 1 ]; then
    echo "identity-wayland-witness: needs the leg's command line" >&2
    exit 1
fi

# THE EXPECTED COUNT COMES FROM THE SCENE, never from a number typed
# here: a typed count stops matching the day a third read joins.
SCENE="${KAYA_SCENES_DIR:-/work/tools/scenes}/identity.steps"
if [ ! -f "$SCENE" ]; then
    echo "identity-wayland-witness: cannot read $SCENE, so it cannot know how" \
        "many icon reads the scene makes — refusing rather than guessing" >&2
    exit 1
fi
want="$(grep -c '^expect_app_icon' "$SCENE")"
if [ "$want" -lt 1 ]; then
    echo "identity-wayland-witness: $SCENE makes no expect_app_icon read at all," \
        "so this witness would agree with any lowering — refusing" >&2
    exit 1
fi

log="$(mktemp)"
"$@" >"$log" 2>&1
rc=$?
# The leg's own output first, always: every failure below refers to it.
cat "$log"

verdict="$(grep -c '^KAYA_SELFTEST: ' "$log")"
failed="$(grep -c 'KAYA_HARNESS: step-failed' "$log")"
icons="$(grep -c "KAYA_HARNESS: step-failed app icon <no icon read on this display" "$log")"
wayland="$(grep -c "GDK's display object here is GdkWayland" "$log")"
lowered="$(grep -c 'gdk_toplevel_set_icon_list with it on window' "$log")"
rm -f "$log"

if [ "$verdict" -lt 1 ]; then
    echo "identity-wayland-witness: the leg never printed a KAYA_SELFTEST verdict" \
        "(exit $rc) — it died or hung before the harness finished, which this" \
        "witness cannot tell apart from the wayland gap it exists to measure." >&2
    exit 1
fi
if [ "$rc" -eq 0 ]; then
    echo "identity-wayland-witness: the identity scene PASSED under wayland." \
        "That is good news and a red leg on purpose: the gap this witness holds" \
        "open has closed, so wire the identity legs onto the wayland ring in" \
        "tools/linux/run-suites.sh and delete this witness." >&2
    exit 1
fi
if [ "$icons" -ne "$want" ] || [ "$failed" -ne "$want" ]; then
    echo "identity-wayland-witness: the scene makes $want icon reads, and this leg" \
        "reported $failed failed steps of which $icons were the icon read's" \
        "measured-absence sentence. The witness asserts the gap is EXACTLY the" \
        "icon read: any other failing step is a real wayland regression in the" \
        "identity scene and is what this number is here to surface." >&2
    exit 1
fi
if [ "$wayland" -lt 1 ]; then
    echo "identity-wayland-witness: the icon read did not name a GdkWaylandDisplay," \
        "so this leg was not measuring the wayland backend at all — check" \
        "GDK_BACKEND and WAYLAND_DISPLAY before reading the failure above." >&2
    exit 1
fi
if [ "$lowered" -lt 1 ]; then
    echo "identity-wayland-witness: the backend reported no" \
        "gdk_toplevel_set_icon_list call, so the icon lowering was SKIPPED on" \
        "wayland rather than run-and-unobservable. That is the difference" \
        "between a version note and a carve-out, and the arm is written to be" \
        "the first (docs/app-identity-plan.md I4a)." >&2
    exit 1
fi

echo "identity-wayland-witness: the wayland gap is exactly as documented —" \
    "$want icon reads, $want failures, all of them the backend's measured" \
    "sentence about a GdkWaylandDisplay, and the lowering ran anyway" \
    "(GTK 4.20 plus xdg-toplevel-icon-v1 is what closes this)."
exit 0
