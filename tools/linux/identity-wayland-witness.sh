#!/usr/bin/env bash
# THE WAYLAND HALF OF THE IDENTITY SCENE, ASSERTED AS THE GAP IT IS.
#
# WHY THIS EXISTS AT ALL. The identity scene demands `expect_app_icon`
# twice, tools/scenes/*.steps are shared verbatim by every platform, and
# on this lane's wayland ring that demand cannot be met: GTK 4.18.6's
# wayland backend drops a toplevel's icon list, sway 1.10.1 advertises no
# xdg_toplevel_icon_manager_v1, and no wayland protocol reads an icon
# back to a client even where one is set (docs/app-identity-plan.md
# ruling 5 and I4a — the runtime blob route is what an UNINSTALLED binary
# has, and an installed app's identity comes from a `.desktop` file on
# both protocols instead). The alternative was to run the identity legs
# on the X11 ring alone and leave the wayland ring silent. A silent skip
# asserts nothing, and a gap nobody measures is a gap nobody notices
# changing.
#
# WHAT THIS ASSERTS, and each clause is a claim a skip cannot make:
#
#   1. the leg FAILS under wayland — if it starts passing, the platform
#      moved and the honest response is to run the scene here, not to
#      keep witnessing a gap that has closed;
#   2. it fails on the icon steps AND ONLY on the icon steps, so the
#      rest of the identity scene — including the NAME half, which IS
#      observable on wayland — is under test on this ring;
#   3. the number of icon failures equals the number of `expect_app_icon`
#      lines in the scene, READ FROM THE SCENE rather than typed here;
#   4. the failing sentence is the backend's measured one, naming the
#      GDK display object it actually found;
#   5. the LOWERING STILL RAN — the backend decoded the blob and called
#      `gdk_toplevel_set_icon_list` on wayland too. This is the clause
#      that makes the arm's protocol-agnostic construction a tested
#      claim rather than a comment: the day GTK and the compositor
#      support the protocol, the same code path already feeds it.
#
# IT REFUSES A VERDICT RATHER THAN GUESSING. A leg that produced no
# harness output at all, or that never reached the harness's own verdict
# line, fails HERE with what it saw — an inverted assertion that cannot
# tell "the gap is exactly as documented" from "the guest died at
# startup" would be worse than no assertion, since it would go green on
# a lane where nothing ran.
set -uo pipefail

if [ "$#" -lt 1 ]; then
    echo "identity-wayland-witness: needs the leg's command line" >&2
    exit 1
fi

# THE EXPECTED COUNT COMES FROM THE SCENE, never from a number in this
# file: tools/scenes/identity.steps is byte-frozen and shared, and a
# count typed here would silently stop matching it the day a third
# `expect_app_icon` joins.
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
# The leg's own output first, always: a witness that hid it would make
# every failure below unreadable.
cat "$log"

verdict="$(grep -c '^KAYA_SELFTEST: ' "$log")"
failed="$(grep -c 'KAYA_HARNESS: step-failed' "$log")"
# The two halves of the backend's sentence: the measured display object,
# and the record that the lowering ran anyway.
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
