#!/usr/bin/env bash
# Runs INSIDE the linux container (tools/validate-linux.py builds the
# image and runs this), under both display protocols. The repo is
# mounted at /work; Linux artifacts go to target-linux so they never
# collide with the host's target directory.
set -uo pipefail

if [ ! -d /work ]; then
    echo "$0: this runs INSIDE the linux container, where the repo is" \
        "mounted at /work. From the host use: nix develop -c" \
        "tools/validate-linux.py (it builds the image and runs this)." >&2
    exit 1
fi
cd /work || exit 1
export CARGO_TARGET_DIR=/work/target-linux
# harness-extract.sh refuses to run outside the dev shell and the
# container is not one; without the fingerprint every leg passes and
# produces no stills at all.
KAYA_DEV_SHELL="$(cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
export KAYA_DEV_SHELL
export PYTHONPATH=/work/bindings/python
# guests/js/node_modules/kaya-gui is a relative symlink to bindings/js
# (docs/js-plan.md §1); the mount usually carries it from the host's
# js-typecheck run, and a fresh clone gets it here.
(cd guests/js && npm install --offline --no-audit --no-fund --no-package-lock --silent)
# Dune resolves external libraries through OCAMLPATH, which only opam
# env provides; the image's bare PATH export is enough for ocamlfind
# but not for dune.
eval "$(opam env 2>/dev/null)" || true

# --lib builds the cdylib (libkaya.so) the foreign suites load;
# --example alone would build only the rlib it depends on.
SCENES="background stall milestone2 entry gallery todos reorder feed grow layout align window panels confirm nav split panes table scroll progress select radio grid textarea sections menus commands a11y a11yrows filedialog clipboard undo dirty ranges save styling typeface toolbar identity assets adaptive"
# Depth-slice scenes, rust only. `windowed` and `canvas` are rust BY
# DESIGN rather than by depth — the compiled conformance scenes every
# lane runs (docs/virtualization-plan.md §6.3, docs/canvas-plan.md
# §3.2); `sizepolicy` waits on the other bindings' `fixed`/`on_draw`/
# `on_tick` spelling (docs/deferred.md's size-policy entry).
DEPTH_SCENES="windowed canvas sizepolicy"
BUILD_EXAMPLES=()
for s in $SCENES $DEPTH_SCENES; do BUILD_EXAMPLES+=(--example "$s"); done

KAYA_T0=$SECONDS
timing() {
    echo "TIMING $1 $((SECONDS - KAYA_T0))s"
    KAYA_T0=$SECONDS
}

# The guest builds pool: dotnet and javac never link libkaya, so they
# start BEFORE the cargo build; everything that links (dune, cabal, go's
# cgo, the C floor) pools after it.
BUILDS_DIR="$(mktemp -d)"
build_names=()
build_pids=()
run_build() {
    local name="$1"
    shift
    ("$@") >"$BUILDS_DIR/$name.log" 2>&1 &
    build_pids+=($!)
    build_names+=("$name")
}
drain_builds() {
    local i=0 pid failed=0
    for pid in "${build_pids[@]}"; do
        if ! wait "$pid"; then
            echo "guest build FAILED: ${build_names[$i]}" >&2
            cat "$BUILDS_DIR/${build_names[$i]}.log" >&2
            failed=1
        fi
        i=$((i + 1))
    done
    build_pids=()
    build_names=()
    [ "$failed" = 0 ] || status=1
}

build_csharp() { dotnet build --nologo -v q /tmp/cs/kaya-guests.csproj >/dev/null; }
build_java() {
    mkdir -p /tmp/java-guests
    javac -encoding UTF-8 -d /tmp/java-guests \
        bindings/java-desktop/dev/kaya/KayaRing.java \
        bindings/java/dev/kaya/*.java \
        guests/java/dev/kaya/guests/*.java
}
    # dotnet writes obj/bin next to the csproj; build in a scratch copy so
    # the host's in-tree dotnet artifacts (different RID) are untouched.
    # Copied BEFORE the early build starts — the pooled build races it.
mkdir -p /tmp/cs
cp guests/csharp/*.cs guests/csharp/kaya-guests.csproj bindings/csharp/*.cs /tmp/cs/
run_build csharp build_csharp
run_build java build_java

# Debuginfo off, AND the link parallelism bounded (docs/traps.md:
# "Container linker OOM scales with the example count").
CARGO_PROFILE_DEV_DEBUG=0 cargo build -j6 --locked --features harness --lib \
    "${BUILD_EXAMPLES[@]}" || exit 1
tools/build-id.py --verify "$CARGO_TARGET_DIR/debug/libkaya.so" || exit 1
timing core-build

# The repo is mounted at /work, not at the compile-time default.
export KAYA_SCENES_DIR=/work/tools/scenes

LIB="$CARGO_TARGET_DIR/debug/libkaya.so"
status=0

# THE ACCESSIBILITY BUS IS PER-LEG, NOT LANE-WIDE: exported lane-wide it
# timed out 11 legs at 180s (python/go/csharp/ocaml; rust and c survived)
# — measured 2026-07-25, and docs/traps.md ("On linux, GTK and the
# harness find the session bus by DIFFERENT means") delegates the four
# languages to this line. The a11y legs below launch the bus INSIDE each
# leg through tools/linux/a11y-leg.sh, which tears it down with the leg.

# HEADLESS SWAY, not Weston, and FLOATING IS NOT OPTIONAL: docs/traps.md,
# "Headless Weston has no seat, so it has no clipboard"
# (docs/clipboard-plan.md §0e).
#
# THE RULE IS `app_id=".*"` BECAUSE THE CLASS HAS TWO SOURCES, and this
# block is where docs/deferred.md's identity entry keeps the measurement.
# MEASURED 2026-08-18 in this image, same binary and same protocol,
# differing only in whether a session bus was running:
#
#   x11, every leg           WM_CLASS = the launcher binary's name
#   wayland, no session bus  app_id   = the launcher binary's name
#   wayland, a11y-leg.sh     app_id   = "dev.kaya.Milestone2"
#
# because on Wayland a GtkApplication window's `app_id` comes from the
# GApplication ID, and that startup path runs only over a session bus,
# which `a11y-leg.sh` launches. AUXILIARY windows are plain
# `gtk4::Window`s and carry the program name on both arms. So a rule
# naming any one id would match a fraction of this lane's legs.
export XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
cat >/tmp/sway.conf <<'SWAY'
for_window [app_id=".*"] floating enable
output * resolution 1600x1000
SWAY
# 1600x1000 ON BOTH PROTOCOLS (the Xvfb screen below matches) and THE
# TEXT SCALE PINNED at 1.0: a stage narrower than a scene's resize, or a
# scaled sp unit, moves a breakpoint and the leg reads as a backend bug.
# check-steps' linux_stage_lint holds both (docs/multicolumn-plan.md D4).
unset GDK_DPI_SCALE GDK_SCALE

# Legs run in a background pool (KAYA_JOBS wide, KAYA_JOBS=1 for serial):
# every leg claims a SESSION of its own from a booted-once pool — an
# Xvfb on x11, a headless sway on wayland.
JOBS="${KAYA_JOBS:-8}"

# THE WAYLAND SESSION POOL, one headless sway per pool slot: one window
# per seat and one clipboard per leg, which is what lets the clipboard,
# undo, ranges and editor legs pool and what a real pointer needs
# (docs/clipboard-plan.md §5b "researched escapes", docs/dnd-plan.md §2).
#
# A slot's runtime dir IS its record — socket name, IPC socket, pid —
# because run_one reads them from the pool's subshells. THE SEAT STAYS
# DEVICELESS: nothing holds a keyboard or a pointer on it, and each
# injection (wtype's F24 tap, the `type` verb, tools/linux/wlpointer)
# adds a transient device for exactly the events it delivers.
wayland_session_boot() { # slot
    local dir="/tmp/xdg-wl-$1" old waited=0 candidate socket="" ipc=""
    # A reboot waits the old compositor out first: its exit unlinks its
    # sockets BY NAME, and a fresh sway in the same dir picks the same
    # name.
    old="$(cat "$dir/sway.pid" 2>/dev/null)"
    if [ -n "$old" ]; then
        kill "$old" 2>/dev/null
        while kill -0 "$old" 2>/dev/null && [ "$waited" -lt 60 ]; do
            waited=$((waited + 1))
            sleep 0.05
        done
    fi
    rm -rf "$dir"
    mkdir -p "$dir" && chmod 700 "$dir"
    XDG_RUNTIME_DIR="$dir" WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
        sway -c /tmp/sway.conf &>"/tmp/sway-$1.log" &
    echo $! >"$dir/sway.pid"
    # NOT a job (x11_display_boot's reason, below).
    disown
    # The socket name is sway's to choose, so it is discovered after
    # start; -S and not -e, since the lock file beside each socket
    # matches the same glob. The IPC socket sits beside the wayland one
    # as sway-ipc.<uid>.<pid>.sock and is reached through SWAYSOCK,
    # which only sway's own children inherit.
    waited=0
    while [ -z "$socket" ] || [ -z "$ipc" ]; do
        for candidate in "$dir"/wayland-[0-9]; do
            [ -S "$candidate" ] && socket="$(basename "$candidate")"
        done
        for candidate in "$dir"/sway-ipc.*.sock; do
            [ -S "$candidate" ] && ipc="$candidate"
        done
        if [ -n "$socket" ] && [ -n "$ipc" ]; then
            break
        fi
        waited=$((waited + 1))
        if [ "$waited" -gt 160 ]; then
            echo "run-suites: sway (wayland slot $1) never created its sockets" >&2
            tail -5 "/tmp/sway-$1.log" >&2
            return 1
        fi
        sleep 0.05
    done
    echo "$socket" >"$dir/socket"
    echo "$ipc" >"$dir/ipc"
}
WAYLAND_POOL=()
for kaya_slot in $(seq 0 $((JOBS - 1))); do
    wayland_session_boot "$kaya_slot" || exit 1
    WAYLAND_POOL+=("$kaya_slot")
done

# THE SEAT IS THE REQUIREMENT, not the compositor's name: a compositor
# without one has no clipboard at all and nothing else here would notice.
if ! SWAYSOCK="$(cat /tmp/xdg-wl-0/ipc)" swaymsg -t get_seats 2>/dev/null | grep -q '"name"'; then
    echo "run-suites: the wayland compositor advertises NO SEAT." >&2
    echo "  A data device is obtained from a seat, so this session has no" >&2
    echo "  clipboard for any client, including kaya's own apps. Headless" >&2
    echo "  Weston is the known example; use a wlroots compositor" >&2
    echo "  (docs/clipboard-plan.md, docs/traps.md)." >&2
    exit 1
fi

# docs/traps.md, "The Linux font fixture has two settings routes".
if ! GTK_A11Y=none GDK_BACKEND=x11 timeout 15 \
    xvfb-run -a -s "-screen 0 1600x1000x24" \
    python3 /work/tools/linux/font-preflight.py; then
    exit 1
fi
if ! GTK_A11Y=none GDK_BACKEND=wayland XDG_RUNTIME_DIR=/tmp/xdg-wl-0 \
    WAYLAND_DISPLAY="$(cat /tmp/xdg-wl-0/socket)" \
    timeout 15 python3 /work/tools/linux/font-preflight.py; then
    exit 1
fi
LEGS_DIR="$(mktemp -d)"
leg_names=()
leg_pids=()

# The flight recorder (tools/lib/flightrec.sh holds the rules).
# /work IS the root here: this runner runs INSIDE the container and has
# no $ROOT (it `cd /work` at the top, under `set -u`).
FLIGHTREC_ROOT=/work
export FLIGHTREC_ROOT
FLIGHTREC_SCRATCH="$(mktemp -d)"
# shellcheck source=tools/lib/flightrec.sh
source /work/tools/lib/flightrec.sh
flightrec_start linux
# A lane that dies mid-run is exactly when the journal matters, and this
# runner has no other EXIT trap to share.
trap 'flightrec_flush; rm -rf "$FLIGHTREC_SCRATCH"' EXIT

# THE X11 DISPLAY POOL, one Xvfb per pool slot, booted once (2026-08-20:
# xvfb-run per leg re-paid ~half a second of server boot on every one of
# ~280 x11 legs). One leg per display at a time — the claim lock in
# run_one — so nothing in flight shares a screen, a pointer or an input
# focus. The a11y session stays per-leg. Pids live in FILES because
# run_one executes in the pool's subshells. Not booted under
# KAYA_RECORD: a film wants a display of its own, so recording keeps
# xvfb-run.
x11_display_boot() { # display-number
    Xvfb ":$1" -screen 0 1600x1000x24 &>"/tmp/xvfb-$1.log" &
    echo $! >"$LEGS_DIR/.x11-pid-$1"
    # NOT a job: run()'s throttle counts running jobs, and eight
    # forever-running servers in the job table deadlocked it on the
    # first leg (2026-08-20).
    disown
    local waited=0
    until [ -S "/tmp/.X11-unix/X$1" ]; do
        waited=$((waited + 1))
        if [ "$waited" -gt 100 ]; then
            echo "run-suites: Xvfb :$1 never made a socket" >&2
            tail -5 "/tmp/xvfb-$1.log" >&2
            return 1
        fi
        sleep 0.05
    done
}
X11_POOL=()
if [ -z "${KAYA_RECORD:-}" ]; then
    for kaya_d in $(seq 100 $((99 + JOBS))); do
        x11_display_boot "$kaya_d" || exit 1
        X11_POOL+=("$kaya_d")
    done
fi

# KAYA_ONLY is a prefix, so `KAYA_ONLY=menus-java` takes both protocols
# and `KAYA_ONLY=menus-java-wayland` takes one. Empty means every leg.
kaya_wanted() { # name proto
    [ -z "${KAYA_ONLY:-}" ] && return 0
    case "$1-$2" in "$KAYA_ONLY"*) return 0 ;; esac
    case "$1" in "$KAYA_ONLY"*) return 0 ;; esac
    return 1
}

run() {
    local proto="$1" name="$2"
    shift 2
    kaya_wanted "$name" "$proto" || return 0
    if [ "$JOBS" = 1 ]; then
        echo "== $name ($proto) =="
        local t0=$SECONDS
        local serial_verdict=PASS
        if run_one "$proto" "$name" "$@"; then
            echo "$name ($proto): PASS ($((SECONDS - t0))s)"
        else
            serial_verdict=FAIL
            echo "$name ($proto): FAIL ($((SECONDS - t0))s)"
            status=1
        fi
        # SERIAL LEGS JOURNAL TOO: this path keeps no log file, so a
        # bundle has nothing to carry, but the record still rides.
        flightrec_leg linux "$name-$proto" "$serial_verdict" "$((SECONDS - t0))" "" ""
        return
    fi
    (
        local t0=$SECONDS
        if run_one "$proto" "$name" "$@" >"$LEGS_DIR/$name-$proto.log" 2>&1; then
            echo PASS >"$LEGS_DIR/$name-$proto.verdict"
        else
            echo FAIL >"$LEGS_DIR/$name-$proto.verdict"
        fi
        echo $((SECONDS - t0)) >"$LEGS_DIR/$name-$proto.secs"
    ) &
    leg_pids+=($!)
    leg_names+=("$name-$proto")
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do
        wait -n || true
    done
}

# Recording mode (KAYA_RECORD=1): every leg runs inside its own Xvfb and
# is filmed there by record-leg.sh. 24-bit screens either way; x11grab
# cannot encode the 8-bit default.
run_one() {
    local proto="$1" name="$2"
    shift 2
    if [ -n "${KAYA_RECORD:-}" ]; then
        local dir="/work/target-linux/recordings/$name-$proto"
        rm -rf "$dir"
        case "$proto" in
            x11)
                KAYA_SELFTEST=1 GDK_BACKEND=x11 timeout 180 \
                    xvfb-run -a -s "-screen 0 1600x1000x24" \
                    /work/tools/linux/record-leg.sh x11 "$dir" "$@"
                ;;
            wayland)
                KAYA_SELFTEST=1 GDK_BACKEND=wayland timeout 180 \
                    xvfb-run -a -s "-screen 0 1600x1000x24" \
                    /work/tools/linux/record-leg.sh wayland "$dir" "$@"
                ;;
        esac
        return
    fi
    case "$proto" in
        x11)
            local kaya_display
            while :; do
                for kaya_display in "${X11_POOL[@]}"; do
                    if mkdir "$LEGS_DIR/.x11-$kaya_display" 2>/dev/null; then
                        break 2
                    fi
                done
                sleep 0.05
            done
            DISPLAY=":$kaya_display" KAYA_SELFTEST=1 GDK_BACKEND=x11 \
                KAYA_VERB_TRACE="$LEGS_DIR/$name-$proto.vtrace" timeout 180 "$@"
            local kaya_rc=$?
            if [ "$kaya_rc" -ne 0 ]; then
                # A failed leg may leave windows behind; the next leg on
                # this display must not meet them. Reboot it, still under
                # the claim.
                kill "$(cat "$LEGS_DIR/.x11-pid-$kaya_display" 2>/dev/null)" 2>/dev/null
                rm -f "/tmp/.X11-unix/X$kaya_display" "/tmp/.X$kaya_display-lock"
                x11_display_boot "$kaya_display"
            fi
            rmdir "$LEGS_DIR/.x11-$kaya_display" 2>/dev/null
            return "$kaya_rc"
            ;;
        wayland)
            local kaya_slot
            while :; do
                for kaya_slot in "${WAYLAND_POOL[@]}"; do
                    if mkdir "$LEGS_DIR/.wl-$kaya_slot" 2>/dev/null; then
                        break 2
                    fi
                done
                sleep 0.05
            done
            local kaya_wl="/tmp/xdg-wl-$kaya_slot"
            XDG_RUNTIME_DIR="$kaya_wl" WAYLAND_DISPLAY="$(cat "$kaya_wl/socket")" \
                SWAYSOCK="$(cat "$kaya_wl/ipc")" KAYA_SELFTEST=1 GDK_BACKEND=wayland \
                KAYA_VERB_TRACE="$LEGS_DIR/$name-$proto.vtrace" timeout 180 "$@"
            local kaya_rc=$?
            if [ "$kaya_rc" -ne 0 ]; then
                wayland_session_boot "$kaya_slot"
            fi
            rmdir "$LEGS_DIR/.wl-$kaya_slot" 2>/dev/null
            return "$kaya_rc"
            ;;
    esac
}

# Wait on the leg jobs by pid — never a bare `wait`, which would also
# wait on unrelated background children (the compositor runs forever; a
# bare wait deadlocked here once).
drain() {
    if [ ${#leg_pids[@]} -gt 0 ]; then
        wait "${leg_pids[@]}" 2>/dev/null || true
    fi
    leg_pids=()
    local name verdict
    for name in "${leg_names[@]}"; do
        verdict=$(cat "$LEGS_DIR/$name.verdict" 2>/dev/null || echo FAIL)
        echo "== $name =="
        if [ "$verdict" != PASS ]; then
            cat "$LEGS_DIR/$name.log" 2>/dev/null
            # An empty log means the guest died or hung BEFORE the
            # harness printed its first line — a different failure from
            # a failed assertion, and the bare verdict cannot tell them
            # apart (the lane-wide GTK_A11Y=atspi legs, 2026-07-25).
            if [ ! -s "$LEGS_DIR/$name.log" ]; then
                echo "$name: note — NO OUTPUT AT ALL. The guest never reached the harness:" \
                    "it hung or died during startup (library load, display, or a blocking" \
                    "connect), so look before the scene, not inside it."
            fi
            # Verdict OK and the leg still failed: TWO causes share it
            # and the note may not pick one (invariant 3) — a nonzero
            # exit path, or a WRAPPER failing after the verdict.
            if grep -q "KAYA_SELFTEST: OK" "$LEGS_DIR/$name.log" 2>/dev/null; then
                echo "$name: note — verdict was OK but the leg exited nonzero: the guest's exit path, or a wrapper clause failing after the verdict — its sentence, if any, is above"
            fi
            status=1
        fi
        local secs bundle
        secs=$(cat "$LEGS_DIR/$name.secs" 2>/dev/null || echo '?')
        bundle=""
        if [ "$verdict" != PASS ]; then
            bundle="$(flightrec_bundle linux "$name")"
            if [ -n "$bundle" ]; then
                # The display pool's state rides too: an X11 leg that
                # failed because its Xvfb died looks exactly like one
                # that failed an assertion, and only the server log
                # tells them apart.
                flightrec_section "$bundle" leg-log "" \
                    cat "$LEGS_DIR/$name.log"
                flightrec_section "$bundle" xvfb "" \
                    sh -c 'cat /tmp/xvfb-*.log 2>/dev/null'
                # crates/kaya/src/vtrace.rs; run_one names the file.
                flightrec_adopt "$bundle" verb-trace "$LEGS_DIR/$name.vtrace"
                flightrec_bundle_report "$bundle"
            fi
        fi
        flightrec_leg linux "$name" "$verdict" "$secs" \
            "$(flightrec_fail_sentence "$LEGS_DIR/$name.log")" "$bundle"
        echo "$name: $verdict (${secs}s)"
    done
    leg_names=()
}

build_c() { make -C guests/c TARGET_DIR="$CARGO_TARGET_DIR/debug" OUT=/tmp/c-guests; }
run_build c build_c

# The wayland pointer injector: built here because the image is built
# before the tree is mounted.
build_wlpointer() {
    mkdir -p /tmp/wlpointer && cd /tmp/wlpointer \
        && wayland-scanner client-header \
            /work/tools/linux/wlpointer/wlr-virtual-pointer-unstable-v1.xml \
            wlr-virtual-pointer-unstable-v1-client-protocol.h \
        && wayland-scanner private-code \
            /work/tools/linux/wlpointer/wlr-virtual-pointer-unstable-v1.xml \
            wlr-virtual-pointer-unstable-v1-protocol.c \
        && cc -O2 -Wall -I/tmp/wlpointer -o /tmp/wlpointer/wlpointer \
            /work/tools/linux/wlpointer/wlpointer.c \
            wlr-virtual-pointer-unstable-v1-protocol.c -lwayland-client
}
run_build wlpointer build_wlpointer

# Its own build dir: _build is shared with the host through the repo
# mount and dune keys targets on source hashes, not platform, so without
# this the container is handed mac binaries as "fresh".
build_ocaml() {
    # dune's incremental view through the virtiofs mount can produce
    # "Unbound module Dune__exe" (2026-07-22); a forced rebuild heals it.
    if ! dune build --build-dir=_build-linux; then
        echo "dune incremental build failed; forcing a full rebuild" >&2
        dune build --force --build-dir=_build-linux || return 1
    fi
    # Freshness BY CONTENT AND NOT BY MTIME: dune keys targets on source
    # HASHES, so a rewrite with identical bytes produces no new artifact
    # and no new mtime, and an mtime rule reported "stale" forever
    # (measured 2026-07-31; docs/traps.md, "A freshness check by mtime,
    # against a build system that hashes").
    local stamp_file=_build-linux/.kaya-ocaml-sources stamp had=""
    stamp=$(cat bindings/ocaml/*.ml guests/ocaml/*.ml \
        | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])')
    [ -f "$stamp_file" ] && had=$(cat "$stamp_file")
    if [ "$stamp" != "$had" ]; then
        echo "ocaml sources moved since the last verified build; forcing a full rebuild" >&2
        dune build --force --build-dir=_build-linux || return 1
        printf '%s\n' "$stamp" >"$stamp_file"
    fi
}
run_build ocaml build_ocaml

# The rpath travels via ghc-options — Linux resolves libkaya only by
# rpath or LD_LIBRARY_PATH.
build_haskell() {
    cd guests/haskell && cabal build all \
        --extra-lib-dirs="$CARGO_TARGET_DIR/debug" \
        --ghc-options="-L$CARGO_TARGET_DIR/debug -optl-Wl,-rpath,$CARGO_TARGET_DIR/debug" -v0
}
run_build haskell build_haskell
hs_bin() { (cd guests/haskell && cabal list-bin "$1" -v0); }

CS_GUEST="/tmp/cs/bin/Debug/net10.0/kaya-guests.dll"
build_go() {
    # ONE BINARY FOR EVERY SCENE: guests/go/cmd imports every scene
    # library and picks one from KAYA_SELFTEST (guests/go/cmd/scenes.go).
    mkdir -p /tmp/go-guests
    go build -o /tmp/go-guests/kaya-go dev.kaya/guests/go/cmd || return 1
}
run_build go build_go

# The pool drains here: csharp/java started before the cargo build (no
# libkaya link), the rest right after it.
drain_builds
timing guest-builds

# THE POINTER ROUTES, PROVEN BEFORE THE FIRST LEG: nothing a scene
# asserts today drives a pointer, so a route nobody exercises would rot
# unseen. tools/linux/dragprobe.py says what it proves. Under
# KAYA_RECORD there is no x11 pool and the skip is PRINTED.
pointer_proof() {
    if ! XDG_RUNTIME_DIR=/tmp/xdg-wl-0 WAYLAND_DISPLAY="$(cat /tmp/xdg-wl-0/socket)" \
        SWAYSOCK="$(cat /tmp/xdg-wl-0/ipc)" GTK_A11Y=none GDK_BACKEND=wayland \
        timeout 60 python3 /work/tools/linux/dragprobe.py wayland /tmp/wlpointer/wlpointer; then
        return 1
    fi
    if [ ${#X11_POOL[@]} -eq 0 ]; then
        echo "run-suites: recording mode boots no x11 pool; the x11 pointer proof is SKIPPED"
        return 0
    fi
    DISPLAY=":${X11_POOL[0]}" GTK_A11Y=none GDK_BACKEND=x11 \
        timeout 60 python3 /work/tools/linux/dragprobe.py x11 xdotool
}
if ! pointer_proof; then
    echo "run-suites: the pointer proof FAILED; no leg runs on a lane whose input route is broken" >&2
    exit 1
fi

# THE IDENTITY LEGS' ASSET, VERIFIED BEFORE ANY LEG RUNS: without the
# mark an identity guest dies inside its build closure on seven legs at
# once. THE PATH IS READ FROM THE DECLARATION, never retyped —
# tools/check-app-identity.py fails a tools/ script that names the mark
# without reading it (docs/app-identity-plan.md ruling 4).
identity_icon="$(python3 -c 'import tomllib; print(tomllib.load(open("guests/assets/identity.toml","rb"))["icon"])' 2>&1)"
identity_rc=$?
if [ "$identity_rc" -ne 0 ]; then
    echo "run-suites: guests/assets/identity.toml could not be read: $identity_icon" >&2
    exit 1
fi
if [ ! -s "$identity_icon" ]; then
    echo "run-suites: the declared app mark \"$identity_icon\" is missing or empty" \
        "inside the container. The repo is mounted at /work and this script runs" \
        "from there, so the guests' repo-relative default should resolve —" \
        "check the mount before doubting the guests." >&2
    exit 1
fi
echo "identity: the declared mark resolves at $identity_icon ($(wc -c <"$identity_icon") bytes)"

for proto in x11 wayland; do
    run "$proto" rust "$CARGO_TARGET_DIR/debug/examples/milestone2"
    run "$proto" c /tmp/c-guests/milestone2
    run "$proto" python env KAYA_LIB="$LIB" python3 guests/python/milestone2.py
    run "$proto" js env KAYA_LIB="$LIB" node guests/js/milestone2.ts
    run "$proto" go /tmp/go-guests/kaya-go
    run "$proto" csharp env KAYA_LIB="$LIB" dotnet exec "$CS_GUEST"
    run "$proto" ocaml env KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/milestone2.exe
    run "$proto" haskell "$(hs_bin milestone2)"
    run "$proto" java env KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    # The inner env overrides run()'s KAYA_SELFTEST=1.
    run "$proto" entry-rust env KAYA_SELFTEST=entry "$CARGO_TARGET_DIR/debug/examples/entry"
    run "$proto" entry-c env KAYA_SELFTEST=entry /tmp/c-guests/entry
    run "$proto" entry-python env KAYA_SELFTEST=entry KAYA_LIB="$LIB" \
        python3 guests/python/entry.py
    run "$proto" entry-js env KAYA_SELFTEST=entry KAYA_LIB="$LIB" \
        node guests/js/entry.ts
    run "$proto" entry-go env KAYA_SELFTEST=entry /tmp/go-guests/kaya-go
    run "$proto" entry-csharp env KAYA_SELFTEST=entry KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" entry-ocaml env KAYA_SELFTEST=entry KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/entry.exe
    run "$proto" entry-haskell env KAYA_SELFTEST=entry "$(hs_bin entry)"
    run "$proto" entry-java env KAYA_SELFTEST=entry KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    run "$proto" gallery-rust env KAYA_SELFTEST=gallery "$CARGO_TARGET_DIR/debug/examples/gallery"
    run "$proto" gallery-c env KAYA_SELFTEST=gallery /tmp/c-guests/gallery
    run "$proto" gallery-python env KAYA_SELFTEST=gallery KAYA_LIB="$LIB" \
        python3 guests/python/gallery.py
    run "$proto" gallery-js env KAYA_SELFTEST=gallery KAYA_LIB="$LIB" \
        node guests/js/gallery.ts
    run "$proto" gallery-go env KAYA_SELFTEST=gallery /tmp/go-guests/kaya-go
    run "$proto" gallery-csharp env KAYA_SELFTEST=gallery KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" gallery-ocaml env KAYA_SELFTEST=gallery KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/gallery.exe
    run "$proto" gallery-haskell env KAYA_SELFTEST=gallery "$(hs_bin gallery)"
    run "$proto" gallery-java env KAYA_SELFTEST=gallery KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    run "$proto" todos-rust env KAYA_SELFTEST=todos "$CARGO_TARGET_DIR/debug/examples/todos"
    run "$proto" todos-c env KAYA_SELFTEST=todos /tmp/c-guests/todos
    run "$proto" todos-python env KAYA_SELFTEST=todos KAYA_LIB="$LIB" \
        python3 guests/python/todos.py
    run "$proto" todos-js env KAYA_SELFTEST=todos KAYA_LIB="$LIB" \
        node guests/js/todos.ts
    run "$proto" todos-go env KAYA_SELFTEST=todos /tmp/go-guests/kaya-go
    run "$proto" todos-csharp env KAYA_SELFTEST=todos KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" todos-ocaml env KAYA_SELFTEST=todos KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/todos.exe
    run "$proto" todos-haskell env KAYA_SELFTEST=todos "$(hs_bin todos)"
    run "$proto" todos-java env KAYA_SELFTEST=todos KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    run "$proto" reorder-rust env KAYA_SELFTEST=reorder "$CARGO_TARGET_DIR/debug/examples/reorder"
    run "$proto" reorder-c env KAYA_SELFTEST=reorder /tmp/c-guests/reorder
    run "$proto" reorder-python env KAYA_SELFTEST=reorder KAYA_LIB="$LIB" \
        python3 guests/python/reorder.py
    run "$proto" reorder-js env KAYA_SELFTEST=reorder KAYA_LIB="$LIB" \
        node guests/js/reorder.ts
    run "$proto" reorder-go env KAYA_SELFTEST=reorder /tmp/go-guests/kaya-go
    run "$proto" reorder-csharp env KAYA_SELFTEST=reorder KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" reorder-ocaml env KAYA_SELFTEST=reorder KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/reorder.exe
    run "$proto" reorder-haskell env KAYA_SELFTEST=reorder "$(hs_bin reorder)"
    run "$proto" reorder-java env KAYA_SELFTEST=reorder KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    run "$proto" feed-rust env KAYA_SELFTEST=feed "$CARGO_TARGET_DIR/debug/examples/feed"
    run "$proto" feed-c env KAYA_SELFTEST=feed /tmp/c-guests/feed
    run "$proto" feed-python env KAYA_SELFTEST=feed KAYA_LIB="$LIB" \
        python3 guests/python/feed.py
    run "$proto" feed-js env KAYA_SELFTEST=feed KAYA_LIB="$LIB" \
        node guests/js/feed.ts
    run "$proto" feed-go env KAYA_SELFTEST=feed /tmp/go-guests/kaya-go
    run "$proto" feed-csharp env KAYA_SELFTEST=feed KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" feed-ocaml env KAYA_SELFTEST=feed KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/feed.exe
    run "$proto" feed-haskell env KAYA_SELFTEST=feed "$(hs_bin feed)"
    run "$proto" feed-java env KAYA_SELFTEST=feed KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    # The C floor stays out of the sugar-tier scenes on purpose — its
    # guests document the explicit wire (see the ledger).
    run "$proto" grow-rust env KAYA_SELFTEST=grow "$CARGO_TARGET_DIR/debug/examples/grow"
    run "$proto" grow-python env KAYA_SELFTEST=grow KAYA_LIB="$LIB" \
        python3 guests/python/grow.py
    run "$proto" grow-js env KAYA_SELFTEST=grow KAYA_LIB="$LIB" \
        node guests/js/grow.ts
    run "$proto" grow-go env KAYA_SELFTEST=grow /tmp/go-guests/kaya-go
    run "$proto" grow-csharp env KAYA_SELFTEST=grow KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" grow-ocaml env KAYA_SELFTEST=grow KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/grow.exe
    run "$proto" grow-haskell env KAYA_SELFTEST=grow "$(hs_bin grow)"
    run "$proto" grow-java env KAYA_SELFTEST=grow KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    run "$proto" align-rust env KAYA_SELFTEST=align "$CARGO_TARGET_DIR/debug/examples/align"
    run "$proto" align-python env KAYA_SELFTEST=align KAYA_LIB="$LIB" \
        python3 guests/python/align.py
    run "$proto" align-js env KAYA_SELFTEST=align KAYA_LIB="$LIB" \
        node guests/js/align.ts
    run "$proto" align-go env KAYA_SELFTEST=align /tmp/go-guests/kaya-go
    run "$proto" align-csharp env KAYA_SELFTEST=align KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" align-ocaml env KAYA_SELFTEST=align KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/align.exe
    run "$proto" align-haskell env KAYA_SELFTEST=align "$(hs_bin align)"
    run "$proto" align-java env KAYA_SELFTEST=align KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    # The advisory 640x400 is honored on X11; a Wayland compositor keeps
    # the last word, which is the request semantics.
    run "$proto" window-rust env KAYA_SELFTEST=window "$CARGO_TARGET_DIR/debug/examples/window"
    run "$proto" window-python env KAYA_SELFTEST=window KAYA_LIB="$LIB" \
        python3 guests/python/window.py
    run "$proto" window-js env KAYA_SELFTEST=window KAYA_LIB="$LIB" \
        node guests/js/window.ts
    run "$proto" window-go env KAYA_SELFTEST=window /tmp/go-guests/kaya-go
    run "$proto" window-csharp env KAYA_SELFTEST=window KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" window-ocaml env KAYA_SELFTEST=window KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/window.exe
    run "$proto" window-haskell env KAYA_SELFTEST=window "$(hs_bin window)"
    run "$proto" window-java env KAYA_SELFTEST=window KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    run "$proto" panels-rust env KAYA_SELFTEST=panels "$CARGO_TARGET_DIR/debug/examples/panels"
    run "$proto" panels-python env KAYA_SELFTEST=panels KAYA_LIB="$LIB" \
        python3 guests/python/panels.py
    run "$proto" panels-js env KAYA_SELFTEST=panels KAYA_LIB="$LIB" \
        node guests/js/panels.ts
    run "$proto" panels-go env KAYA_SELFTEST=panels /tmp/go-guests/kaya-go
    run "$proto" panels-csharp env KAYA_SELFTEST=panels KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" panels-ocaml env KAYA_SELFTEST=panels KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/panels.exe
    run "$proto" panels-haskell env KAYA_SELFTEST=panels "$(hs_bin panels)"
    run "$proto" panels-java env KAYA_SELFTEST=panels KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    # The dirty scene (docs/dirty-plan.md). THROUGH a11y-leg.sh: the
    # marker is a LABEL kaya drew beside the header-bar title, so the
    # only honest read of it is an assistive client's.
    run "$proto" dirty-rust env KAYA_SELFTEST=dirty \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/dirty"
    run "$proto" dirty-python env KAYA_SELFTEST=dirty KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/dirty.py
    run "$proto" dirty-js env KAYA_SELFTEST=dirty KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh node guests/js/dirty.ts
    run "$proto" dirty-go env KAYA_SELFTEST=dirty \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" dirty-csharp env KAYA_SELFTEST=dirty KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" dirty-ocaml env KAYA_SELFTEST=dirty KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/dirty.exe
    run "$proto" dirty-haskell env KAYA_SELFTEST=dirty \
        tools/linux/a11y-leg.sh "$(hs_bin dirty)"
    run "$proto" dirty-java env KAYA_SELFTEST=dirty KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.guests.Main
    run "$proto" dirty-c env KAYA_SELFTEST=dirty \
        tools/linux/a11y-leg.sh /tmp/c-guests/dirty

    # THE STAMPED-ACCESSIBILITY SCENE (docs/tpl-props-plan.md P3). The
    # read is ordinal-by-role — GTK publishes no settable AX identifier
    # — which is why the scene asserts entries and no containers.
    run "$proto" a11yrows-rust env KAYA_SELFTEST=a11yrows \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/a11yrows"
    run "$proto" a11yrows-python env KAYA_SELFTEST=a11yrows KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/a11yrows.py
    run "$proto" a11yrows-js env KAYA_SELFTEST=a11yrows KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh node guests/js/a11yrows.ts
    run "$proto" a11yrows-go env KAYA_SELFTEST=a11yrows \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" a11yrows-csharp env KAYA_SELFTEST=a11yrows KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" a11yrows-ocaml env KAYA_SELFTEST=a11yrows KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/a11yrows.exe
    run "$proto" a11yrows-haskell env KAYA_SELFTEST=a11yrows \
        tools/linux/a11y-leg.sh "$(hs_bin a11yrows)"
    run "$proto" a11yrows-java env KAYA_SELFTEST=a11yrows KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.guests.Main
    run "$proto" a11yrows-c env KAYA_SELFTEST=a11yrows \
        tools/linux/a11y-leg.sh /tmp/c-guests/a11yrows
    # THE STYLING SCENE (docs/styling-plan.md slice 1). `heading` is the
    # .heading label class published as the AT-SPI heading role, which is
    # what expect_ax freezes — hence a11y-leg.sh.
    run "$proto" styling-rust env KAYA_SELFTEST=styling \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/styling"
    run "$proto" styling-python env KAYA_SELFTEST=styling KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/styling.py
    run "$proto" styling-js env KAYA_SELFTEST=styling KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh node guests/js/styling.ts
    run "$proto" styling-go env KAYA_SELFTEST=styling \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" styling-csharp env KAYA_SELFTEST=styling KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" styling-ocaml env KAYA_SELFTEST=styling KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/styling.exe
    run "$proto" styling-haskell env KAYA_SELFTEST=styling \
        tools/linux/a11y-leg.sh "$(hs_bin styling)"
    run "$proto" styling-java env KAYA_SELFTEST=styling KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.guests.Main
    run "$proto" styling-c env KAYA_SELFTEST=styling \
        tools/linux/a11y-leg.sh /tmp/c-guests/styling
    # THE TYPEFACE SCENE (docs/styling-plan.md slice 2b;
    # tools/scenes/typeface.steps states it in full). Through a11y-leg.sh
    # for the closing expect_ax.
    #
    # NO KAYA_FONT_FILE ON THESE LEGS: the guests default to the
    # repo-relative path and /work IS the repo. That variable is for a
    # runner whose guest cannot see the repo — a phone.
    run "$proto" typeface-rust env KAYA_SELFTEST=typeface \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/typeface"
    run "$proto" typeface-python env KAYA_SELFTEST=typeface KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/typeface.py
    run "$proto" typeface-js env KAYA_SELFTEST=typeface KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh node guests/js/typeface.ts
    run "$proto" typeface-go env KAYA_SELFTEST=typeface \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" typeface-csharp env KAYA_SELFTEST=typeface KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" typeface-ocaml env KAYA_SELFTEST=typeface KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/typeface.exe
    run "$proto" typeface-haskell env KAYA_SELFTEST=typeface \
        tools/linux/a11y-leg.sh "$(hs_bin typeface)"
    run "$proto" typeface-java env KAYA_SELFTEST=typeface KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.guests.Main
    # AND NO C LEG: the floor has no typeface guest. check-steps'
    # C-floor sweep reads the BINARY PATH out of this file, COMMENTS
    # INCLUDED, so the path is not written here even to say it is absent.
    run "$proto" assets-rust env KAYA_SELFTEST=assets \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/assets"
    run "$proto" assets-python env KAYA_SELFTEST=assets KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/assets.py
    run "$proto" assets-js env KAYA_SELFTEST=assets KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh node guests/js/assets.ts
    run "$proto" assets-go env KAYA_SELFTEST=assets \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" assets-csharp env KAYA_SELFTEST=assets KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" assets-ocaml env KAYA_SELFTEST=assets KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/assets.exe
    run "$proto" assets-haskell env KAYA_SELFTEST=assets \
        tools/linux/a11y-leg.sh "$(hs_bin assets)"
    run "$proto" assets-java env KAYA_SELFTEST=assets KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.guests.Main
    run "$proto" assets-c env KAYA_SELFTEST=assets /tmp/c-guests/assets
    # THE TOOLBAR SCENE (docs/chrome-plan.md C2). THROUGH a11y-leg.sh:
    # `expect_toolbar_item` addresses a button by the name the AT-SPI BUS
    # answers with, and an icon-only GtkButton with no explicit
    # accessible label publishes `name=''` (docs/chrome/toolbar-gtk.md).
    # Same roster as typeface: no C leg.
    run "$proto" toolbar-rust env KAYA_SELFTEST=toolbar \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/toolbar"
    run "$proto" toolbar-python env KAYA_SELFTEST=toolbar KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/toolbar.py
    run "$proto" toolbar-js env KAYA_SELFTEST=toolbar KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh node guests/js/toolbar.ts
    run "$proto" toolbar-go env KAYA_SELFTEST=toolbar \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" toolbar-csharp env KAYA_SELFTEST=toolbar KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" toolbar-ocaml env KAYA_SELFTEST=toolbar KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/toolbar.exe
    run "$proto" toolbar-haskell env KAYA_SELFTEST=toolbar \
        tools/linux/a11y-leg.sh "$(hs_bin toolbar)"
    run "$proto" toolbar-java env KAYA_SELFTEST=toolbar KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.guests.Main
    # THE IDENTITY SCENE (docs/app-identity-plan.md). The read is of the
    # X SERVER'S OWN COPY, because there is no read-back for an icon list
    # and kaya's model would pass with no lowering at all.
    #
    # THE ICON IS X11-ONLY HERE (ruling 5). MEASURED 2026-08-18: GTK
    # 4.18.6's wayland backend drops the icon-list property and sway
    # 1.10.1 advertises no xdg_toplevel_icon_manager_v1, so the wayland
    # ring runs a WITNESS requiring the leg to fail on the icon steps AND
    # ONLY on them — RED the day GTK reaches 4.20.
    #
    # THE CLASS IS ASSERTED ON BOTH RINGS, outside the leg, since no
    # harness verb reads `WM_CLASS`/`app_id`
    # (tools/linux/identity-class-leg.py).
    case "$proto" in
        x11)
            run "$proto" identity-rust env KAYA_SELFTEST=identity \
                tools/linux/identity-class-leg.py \
                tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/identity"
            run "$proto" identity-python env KAYA_SELFTEST=identity KAYA_LIB="$LIB" \
                tools/linux/identity-class-leg.py \
                tools/linux/a11y-leg.sh python3 guests/python/identity.py
            run "$proto" identity-js env KAYA_SELFTEST=identity KAYA_LIB="$LIB" \
                tools/linux/identity-class-leg.py \
                tools/linux/a11y-leg.sh node guests/js/identity.ts
            run "$proto" identity-go env KAYA_SELFTEST=identity \
                tools/linux/identity-class-leg.py \
                tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
            run "$proto" identity-csharp env KAYA_SELFTEST=identity KAYA_LIB="$LIB" \
                tools/linux/identity-class-leg.py \
                tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
            run "$proto" identity-ocaml env KAYA_SELFTEST=identity KAYA_LIB="$LIB" \
                tools/linux/identity-class-leg.py \
                tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/identity.exe
            run "$proto" identity-haskell env KAYA_SELFTEST=identity \
                tools/linux/identity-class-leg.py \
                tools/linux/a11y-leg.sh "$(hs_bin identity)"
            run "$proto" identity-java env KAYA_SELFTEST=identity KAYA_LIB="$LIB" \
                tools/linux/identity-class-leg.py \
                tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.guests.Main
            ;;
        wayland)
        # The class reader is OUTERMOST, and the nesting matters: the
        # witness converts the icon gap into a PASS, so a class failure
        # inside it would be swallowed.
            run "$proto" identity-witness-rust env KAYA_SELFTEST=identity \
                tools/linux/identity-class-leg.py \
                tools/linux/identity-wayland-witness.sh \
                tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/identity"
            ;;
    esac
    # The stall diagnostic (crates/kaya/src/stall.rs) — the one scene
    # that deliberately blocks the app thread, in EVERY language.
    run "$proto" stall-rust env KAYA_SELFTEST=stall "$CARGO_TARGET_DIR/debug/examples/stall"
    run "$proto" stall-python env KAYA_SELFTEST=stall KAYA_LIB="$LIB" \
        python3 guests/python/stall.py
    run "$proto" stall-js env KAYA_SELFTEST=stall KAYA_LIB="$LIB" \
        node guests/js/stall.ts
    run "$proto" stall-go env KAYA_SELFTEST=stall /tmp/go-guests/kaya-go
    run "$proto" stall-csharp env KAYA_SELFTEST=stall KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" stall-ocaml env KAYA_SELFTEST=stall KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/stall.exe
    run "$proto" stall-haskell env KAYA_SELFTEST=stall "$(hs_bin stall)"
    run "$proto" stall-java env KAYA_SELFTEST=stall KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    run "$proto" confirm-rust env KAYA_SELFTEST=confirm "$CARGO_TARGET_DIR/debug/examples/confirm"
    run "$proto" confirm-python env KAYA_SELFTEST=confirm KAYA_LIB="$LIB" \
        python3 guests/python/confirm.py
    run "$proto" confirm-js env KAYA_SELFTEST=confirm KAYA_LIB="$LIB" \
        node guests/js/confirm.ts
    run "$proto" confirm-go env KAYA_SELFTEST=confirm /tmp/go-guests/kaya-go
    run "$proto" confirm-csharp env KAYA_SELFTEST=confirm KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" confirm-ocaml env KAYA_SELFTEST=confirm KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/confirm.exe
    run "$proto" confirm-haskell env KAYA_SELFTEST=confirm "$(hs_bin confirm)"
    run "$proto" confirm-java env KAYA_SELFTEST=confirm KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    run "$proto" nav-rust env KAYA_SELFTEST=nav "$CARGO_TARGET_DIR/debug/examples/nav"
    # The background scene: its worker parks until a click releases it,
    # so a binding that ran background work ON the app thread cannot
    # deliver its own release and this leg TIMES OUT rather than failing
    # an assertion — the deadlock IS the gate
    # (docs/background-work-plan.md §5).
    run "$proto" background-rust env KAYA_SELFTEST=background \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/background"

    # The filedialog scene: GNOME's own picker, driven for real. Through
    # a11y-leg.sh because EVERY read here is an AT-SPI read — the chooser
    # publishes no accessible ids (docs/traps.md, "What GTK's file
    # chooser publishes, and what it does not").
    run "$proto" filedialog-rust env KAYA_SELFTEST=filedialog \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/filedialog"
    run "$proto" filedialog-python env KAYA_SELFTEST=filedialog KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/filedialog.py
    run "$proto" filedialog-js env KAYA_SELFTEST=filedialog KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh node guests/js/filedialog.ts
    run "$proto" filedialog-go env KAYA_SELFTEST=filedialog \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" filedialog-csharp env KAYA_SELFTEST=filedialog KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" filedialog-ocaml env KAYA_SELFTEST=filedialog KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/filedialog.exe
    run "$proto" filedialog-haskell env KAYA_SELFTEST=filedialog \
        tools/linux/a11y-leg.sh "$(hs_bin filedialog)"
    run "$proto" filedialog-java env KAYA_SELFTEST=filedialog KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.guests.Main
    # The save scene (docs/save-plan.md D5). Through a11y-leg.sh: GTK's
    # save panel publishes no accessible ids at all, so EVERY observation
    # here is a bus read. IN THE POOL: it types through the per-leg
    # accessibility bus and touches no session-wide state.
    run "$proto" save-rust env KAYA_SELFTEST=save \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/save"
    # The C floor's save guest, which does not wait on the sugar sweep.
    # Through a11y-leg.sh like every other leg in this block.
    run "$proto" save-c env KAYA_SELFTEST=save \
        tools/linux/a11y-leg.sh /tmp/c-guests/save
    run "$proto" background-python env KAYA_SELFTEST=background KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/background.py
    run "$proto" background-js env KAYA_SELFTEST=background KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh node guests/js/background.ts
    run "$proto" background-go env KAYA_SELFTEST=background \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" background-csharp env KAYA_SELFTEST=background KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" background-ocaml env KAYA_SELFTEST=background KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/background.exe
    run "$proto" background-haskell env KAYA_SELFTEST=background \
        tools/linux/a11y-leg.sh "$(hs_bin background)"
    run "$proto" background-java env KAYA_SELFTEST=background KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.guests.Main
    run "$proto" background-c env KAYA_SELFTEST=background \
        tools/linux/a11y-leg.sh /tmp/c-guests/background
    # Through a11y-leg.sh: the scene asserts the REAL accessibility tree,
    # and on GTK that read is AT-SPI.
    run "$proto" split-rust env KAYA_SELFTEST=split \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/split"
    run "$proto" split-python env KAYA_SELFTEST=split KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/split.py
    run "$proto" split-js env KAYA_SELFTEST=split KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh node guests/js/split.ts
    run "$proto" split-go env KAYA_SELFTEST=split \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" split-csharp env KAYA_SELFTEST=split KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" split-ocaml env KAYA_SELFTEST=split KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/split.exe
    run "$proto" split-haskell env KAYA_SELFTEST=split \
        tools/linux/a11y-leg.sh "$(hs_bin split)"
    run "$proto" split-java env KAYA_SELFTEST=split KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.guests.Main
    # listdetail runs the SPLIT guests: a scene selects a SCRIPT, never
    # an app. panes is the THREE-pane ceiling on the nested split views
    # (docs/multicolumn-plan.md). Both through a11y-leg.sh.
    run "$proto" panes-rust env KAYA_SELFTEST=panes \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/panes"
    run "$proto" panes-python env KAYA_SELFTEST=panes KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/panes.py
    run "$proto" panes-js env KAYA_SELFTEST=panes KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh node guests/js/panes.ts
    run "$proto" panes-go env KAYA_SELFTEST=panes \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" panes-csharp env KAYA_SELFTEST=panes KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" panes-ocaml env KAYA_SELFTEST=panes KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/panes.exe
    run "$proto" panes-haskell env KAYA_SELFTEST=panes \
        tools/linux/a11y-leg.sh "$(hs_bin panes)"
    run "$proto" panes-java env KAYA_SELFTEST=panes KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.guests.Main
    run "$proto" listdetail-rust env KAYA_SELFTEST=listdetail \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/split"
    run "$proto" listdetail-python env KAYA_SELFTEST=listdetail KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/split.py
    run "$proto" listdetail-js env KAYA_SELFTEST=listdetail KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh node guests/js/split.ts
    run "$proto" listdetail-go env KAYA_SELFTEST=listdetail \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" listdetail-csharp env KAYA_SELFTEST=listdetail KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" listdetail-ocaml env KAYA_SELFTEST=listdetail KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/split.exe
    run "$proto" listdetail-haskell env KAYA_SELFTEST=listdetail \
        tools/linux/a11y-leg.sh "$(hs_bin split)"
    run "$proto" listdetail-java env KAYA_SELFTEST=listdetail KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.guests.Main
    run "$proto" nav-python env KAYA_SELFTEST=nav KAYA_LIB="$LIB" \
        python3 guests/python/nav.py
    run "$proto" nav-js env KAYA_SELFTEST=nav KAYA_LIB="$LIB" \
        node guests/js/nav.ts
    run "$proto" nav-go env KAYA_SELFTEST=nav /tmp/go-guests/kaya-go
    run "$proto" nav-csharp env KAYA_SELFTEST=nav KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" nav-ocaml env KAYA_SELFTEST=nav KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/nav.exe
    run "$proto" nav-haskell env KAYA_SELFTEST=nav "$(hs_bin nav)"
    run "$proto" nav-java env KAYA_SELFTEST=nav KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    # The table scene (docs/tables-plan.md).
    run "$proto" table-rust env KAYA_SELFTEST=table "$CARGO_TARGET_DIR/debug/examples/table"
    run "$proto" table-python env KAYA_SELFTEST=table KAYA_LIB="$LIB" \
        python3 guests/python/table.py
    run "$proto" table-js env KAYA_SELFTEST=table KAYA_LIB="$LIB" \
        node guests/js/table.ts
    run "$proto" table-go env KAYA_SELFTEST=table /tmp/go-guests/kaya-go
    run "$proto" table-csharp env KAYA_SELFTEST=table KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" table-ocaml env KAYA_SELFTEST=table KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/table.exe
    run "$proto" table-haskell env KAYA_SELFTEST=table "$(hs_bin table)"
    run "$proto" table-java env KAYA_SELFTEST=table KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    # ROW WINDOWING'S CONFORMANCE SCENE (docs/virtualization-plan.md
    # §6.3). RUST ALONE, and compiled: it is the one windowing scene the
    # mobile lanes can run too.
    run "$proto" windowed-rust env KAYA_SELFTEST=windowed \
        "$CARGO_TARGET_DIR/debug/examples/windowed"
    # THE ADAPTIVE SCENE (docs/adaptive-layout-plan.md §2).
    run "$proto" adaptive-rust env KAYA_SELFTEST=adaptive \
        "$CARGO_TARGET_DIR/debug/examples/adaptive"
    run "$proto" adaptive-python env KAYA_SELFTEST=adaptive KAYA_LIB="$LIB" \
        python3 guests/python/adaptive.py
    run "$proto" adaptive-js env KAYA_SELFTEST=adaptive KAYA_LIB="$LIB" \
        node guests/js/adaptive.ts
    run "$proto" adaptive-go env KAYA_SELFTEST=adaptive /tmp/go-guests/kaya-go
    run "$proto" adaptive-csharp env KAYA_SELFTEST=adaptive KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" adaptive-ocaml env KAYA_SELFTEST=adaptive KAYA_LIB="$LIB" \
        _build-linux/default/guests/ocaml/adaptive.exe
    run "$proto" adaptive-haskell env KAYA_SELFTEST=adaptive "$(hs_bin adaptive)"
    run "$proto" adaptive-java env KAYA_SELFTEST=adaptive KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    # THE CANVAS SCENE (docs/canvas-plan.md): the core rasterizes and
    # this backend blits a GdkMemoryTexture, so a leg that disagrees with
    # the shared frozen hash is a finding about the BLIT, never about the
    # drawing. THROUGH a11y-leg.sh for its closing `expect_ax`;
    # check-steps' ax_bus() holds that rule.
    run "$proto" canvas-rust env KAYA_SELFTEST=canvas \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/canvas"
    # The same script under the other appearance, per-process rather than
    # by moving the container's session preference — which pins nothing,
    # so Adwaita's default is light and every leg before this one ran it
    # (docs/canvas-plan.md phase 4).
    run "$proto" canvasdark-rust env KAYA_APPEARANCE=dark KAYA_SELFTEST=canvas \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/canvas"
    # THE SIZE-POLICY SCENE (docs/canvas-plan.md §3.2.1). NO a11y-leg.sh:
    # this scene asserts no ax verb, so it needs no session bus.
    run "$proto" sizepolicy-rust env KAYA_SELFTEST=sizepolicy \
        "$CARGO_TARGET_DIR/debug/examples/sizepolicy"
    run "$proto" scroll-rust env KAYA_SELFTEST=scroll "$CARGO_TARGET_DIR/debug/examples/scroll"
    run "$proto" scroll-python env KAYA_SELFTEST=scroll KAYA_LIB="$LIB" \
        python3 guests/python/scroll.py
    run "$proto" scroll-js env KAYA_SELFTEST=scroll KAYA_LIB="$LIB" \
        node guests/js/scroll.ts
    run "$proto" scroll-go env KAYA_SELFTEST=scroll /tmp/go-guests/kaya-go
    run "$proto" scroll-csharp env KAYA_SELFTEST=scroll KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" scroll-ocaml env KAYA_SELFTEST=scroll KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/scroll.exe
    run "$proto" scroll-haskell env KAYA_SELFTEST=scroll "$(hs_bin scroll)"
    run "$proto" scroll-java env KAYA_SELFTEST=scroll KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    # Read off the AT-SPI bus as a real assistive client reads it — the
    # only honest route on GTK, which has no getter for accessible
    # properties.
    run "$proto" a11y-rust env KAYA_SELFTEST=a11y \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/a11y"
    run "$proto" a11y-c env KAYA_SELFTEST=a11y \
        tools/linux/a11y-leg.sh /tmp/c-guests/a11y
    run "$proto" a11y-python env KAYA_SELFTEST=a11y KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/a11y.py
    run "$proto" a11y-js env KAYA_SELFTEST=a11y KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh node guests/js/a11y.ts
    run "$proto" a11y-go env KAYA_SELFTEST=a11y \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" a11y-csharp env KAYA_SELFTEST=a11y KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" a11y-ocaml env KAYA_SELFTEST=a11y KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/a11y.exe
    run "$proto" a11y-haskell env KAYA_SELFTEST=a11y \
        tools/linux/a11y-leg.sh "$(hs_bin a11y)"
    run "$proto" a11y-java env KAYA_SELFTEST=a11y KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.guests.Main
    run "$proto" progress-rust env KAYA_SELFTEST=progress "$CARGO_TARGET_DIR/debug/examples/progress"
    run "$proto" progress-python env KAYA_SELFTEST=progress KAYA_LIB="$LIB" \
        python3 guests/python/progress.py
    run "$proto" progress-js env KAYA_SELFTEST=progress KAYA_LIB="$LIB" \
        node guests/js/progress.ts
    run "$proto" progress-go env KAYA_SELFTEST=progress /tmp/go-guests/kaya-go
    run "$proto" progress-csharp env KAYA_SELFTEST=progress KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" progress-ocaml env KAYA_SELFTEST=progress KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/progress.exe
    run "$proto" progress-haskell env KAYA_SELFTEST=progress "$(hs_bin progress)"
    run "$proto" progress-java env KAYA_SELFTEST=progress KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    run "$proto" select-rust env KAYA_SELFTEST=select "$CARGO_TARGET_DIR/debug/examples/select"
    run "$proto" select-python env KAYA_SELFTEST=select KAYA_LIB="$LIB" \
        python3 guests/python/select.py
    run "$proto" select-js env KAYA_SELFTEST=select KAYA_LIB="$LIB" \
        node guests/js/select.ts
    run "$proto" select-go env KAYA_SELFTEST=select /tmp/go-guests/kaya-go
    run "$proto" select-csharp env KAYA_SELFTEST=select KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" select-ocaml env KAYA_SELFTEST=select KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/select.exe
    run "$proto" select-haskell env KAYA_SELFTEST=select "$(hs_bin select)"
    run "$proto" select-java env KAYA_SELFTEST=select KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    run "$proto" radio-rust env KAYA_SELFTEST=radio "$CARGO_TARGET_DIR/debug/examples/radio"
    run "$proto" radio-python env KAYA_SELFTEST=radio KAYA_LIB="$LIB" \
        python3 guests/python/radio.py
    run "$proto" radio-js env KAYA_SELFTEST=radio KAYA_LIB="$LIB" \
        node guests/js/radio.ts
    run "$proto" radio-go env KAYA_SELFTEST=radio /tmp/go-guests/kaya-go
    run "$proto" radio-csharp env KAYA_SELFTEST=radio KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" radio-ocaml env KAYA_SELFTEST=radio KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/radio.exe
    run "$proto" radio-haskell env KAYA_SELFTEST=radio "$(hs_bin radio)"
    run "$proto" radio-java env KAYA_SELFTEST=radio KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    run "$proto" grid-rust env KAYA_SELFTEST=grid "$CARGO_TARGET_DIR/debug/examples/grid"
    run "$proto" grid-python env KAYA_SELFTEST=grid KAYA_LIB="$LIB" \
        python3 guests/python/grid.py
    run "$proto" grid-js env KAYA_SELFTEST=grid KAYA_LIB="$LIB" \
        node guests/js/grid.ts
    run "$proto" grid-go env KAYA_SELFTEST=grid /tmp/go-guests/kaya-go
    run "$proto" grid-csharp env KAYA_SELFTEST=grid KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" grid-ocaml env KAYA_SELFTEST=grid KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/grid.exe
    run "$proto" grid-haskell env KAYA_SELFTEST=grid "$(hs_bin grid)"
    run "$proto" grid-java env KAYA_SELFTEST=grid KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    run "$proto" textarea-rust env KAYA_SELFTEST=textarea "$CARGO_TARGET_DIR/debug/examples/textarea"
    run "$proto" textarea-python env KAYA_SELFTEST=textarea KAYA_LIB="$LIB" \
        python3 guests/python/textarea.py
    run "$proto" textarea-js env KAYA_SELFTEST=textarea KAYA_LIB="$LIB" \
        node guests/js/textarea.ts
    run "$proto" textarea-go env KAYA_SELFTEST=textarea /tmp/go-guests/kaya-go
    run "$proto" textarea-csharp env KAYA_SELFTEST=textarea KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" textarea-ocaml env KAYA_SELFTEST=textarea KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/textarea.exe
    run "$proto" textarea-haskell env KAYA_SELFTEST=textarea "$(hs_bin textarea)"
    run "$proto" textarea-java env KAYA_SELFTEST=textarea KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    run "$proto" sections-rust env KAYA_SELFTEST=sections "$CARGO_TARGET_DIR/debug/examples/sections"
    run "$proto" sections-python env KAYA_SELFTEST=sections KAYA_LIB="$LIB" \
        python3 guests/python/sections.py
    run "$proto" sections-js env KAYA_SELFTEST=sections KAYA_LIB="$LIB" \
        node guests/js/sections.ts
    run "$proto" sections-go env KAYA_SELFTEST=sections /tmp/go-guests/kaya-go
    run "$proto" sections-csharp env KAYA_SELFTEST=sections KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" sections-ocaml env KAYA_SELFTEST=sections KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/sections.exe
    run "$proto" sections-haskell env KAYA_SELFTEST=sections "$(hs_bin sections)"
    run "$proto" sections-java env KAYA_SELFTEST=sections KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    run "$proto" menus-rust env KAYA_SELFTEST=menus "$CARGO_TARGET_DIR/debug/examples/menus"
    run "$proto" menus-c env KAYA_SELFTEST=menus /tmp/c-guests/menus
    run "$proto" menus-python env KAYA_SELFTEST=menus KAYA_LIB="$LIB" \
        python3 guests/python/menus.py
    run "$proto" menus-js env KAYA_SELFTEST=menus KAYA_LIB="$LIB" \
        node guests/js/menus.ts
    run "$proto" menus-go env KAYA_SELFTEST=menus /tmp/go-guests/kaya-go
    run "$proto" menus-csharp env KAYA_SELFTEST=menus KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" menus-ocaml env KAYA_SELFTEST=menus KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/menus.exe
    run "$proto" menus-haskell env KAYA_SELFTEST=menus "$(hs_bin menus)"
    run "$proto" menus-java env KAYA_SELFTEST=menus KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    run "$proto" commands-rust env KAYA_SELFTEST=commands \
        "$CARGO_TARGET_DIR/debug/examples/commands"
    run "$proto" commands-c env KAYA_SELFTEST=commands /tmp/c-guests/commands
    run "$proto" commands-python env KAYA_SELFTEST=commands KAYA_LIB="$LIB" \
        python3 guests/python/commands.py
    run "$proto" commands-js env KAYA_SELFTEST=commands KAYA_LIB="$LIB" \
        node guests/js/commands.ts
    run "$proto" commands-go env KAYA_SELFTEST=commands /tmp/go-guests/kaya-go
    run "$proto" commands-csharp env KAYA_SELFTEST=commands KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" commands-ocaml env KAYA_SELFTEST=commands KAYA_LIB="$LIB" \
        _build-linux/default/guests/ocaml/commands.exe
    run "$proto" commands-haskell env KAYA_SELFTEST=commands "$(hs_bin commands)"
    run "$proto" commands-java env KAYA_SELFTEST=commands KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    run "$proto" layout-rust env KAYA_SELFTEST=layout "$CARGO_TARGET_DIR/debug/examples/layout"
    run "$proto" layout-python env KAYA_SELFTEST=layout KAYA_LIB="$LIB" \
        python3 guests/python/layout.py
    run "$proto" layout-js env KAYA_SELFTEST=layout KAYA_LIB="$LIB" \
        node guests/js/layout.ts
    run "$proto" layout-go env KAYA_SELFTEST=layout /tmp/go-guests/kaya-go
    run "$proto" layout-csharp env KAYA_SELFTEST=layout KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" layout-ocaml env KAYA_SELFTEST=layout KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/layout.exe
    run "$proto" layout-haskell env KAYA_SELFTEST=layout "$(hs_bin layout)"
    run "$proto" layout-java env KAYA_SELFTEST=layout KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.guests.Main
    # The clipboard scene. Through a11y-leg.sh for its closing expect_ax.
    # POOLED on both protocols: a leg owns its session, so each has a
    # clipboard and a seat of its own (docs/clipboard-plan.md §5b).
    run "$proto" clipboard-rust env KAYA_SELFTEST=clipboard \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/clipboard"
    run "$proto" clipboard-python env KAYA_SELFTEST=clipboard KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/clipboard.py
    run "$proto" clipboard-js env KAYA_SELFTEST=clipboard KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh node guests/js/clipboard.ts
    run "$proto" clipboard-go env KAYA_SELFTEST=clipboard \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" clipboard-csharp env KAYA_SELFTEST=clipboard KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" clipboard-ocaml env KAYA_SELFTEST=clipboard KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/clipboard.exe
    run "$proto" clipboard-haskell env KAYA_SELFTEST=clipboard \
        tools/linux/a11y-leg.sh "$(hs_bin clipboard)"
    run "$proto" clipboard-java env KAYA_SELFTEST=clipboard KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.guests.Main
    # The undo scene (docs/undo-plan.md §3). POOLED for the same reason:
    # the `type` verb's real key events ride a transient virtual keyboard
    # on the leg's OWN seat, where its window is the only one — the
    # exclusivity that held this leg alone (measured 2026-08-03) needs a
    # neighbour to disturb (docs/clipboard-plan.md §5b).
    run "$proto" undo-rust env KAYA_SELFTEST=undo \
        "$CARGO_TARGET_DIR/debug/examples/undo"
    # The text-ranges scene. Through a11y-leg.sh: all three reads go to
    # the accessibility bus.
    run "$proto" ranges-rust env KAYA_SELFTEST=ranges \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/ranges"
    run "$proto" ranges-c env KAYA_SELFTEST=ranges \
        tools/linux/a11y-leg.sh /tmp/c-guests/ranges
    run "$proto" ranges-python env KAYA_SELFTEST=ranges KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/ranges.py
    run "$proto" ranges-js env KAYA_SELFTEST=ranges KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh node guests/js/ranges.ts
    run "$proto" ranges-go env KAYA_SELFTEST=ranges \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" ranges-csharp env KAYA_SELFTEST=ranges KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" ranges-ocaml env KAYA_SELFTEST=ranges KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/ranges.exe
    run "$proto" ranges-haskell env KAYA_SELFTEST=ranges \
        tools/linux/a11y-leg.sh "$(hs_bin ranges)"
    run "$proto" ranges-java env KAYA_SELFTEST=ranges KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.guests.Main
    # THE TEXT EDITOR (docs/editor-plan.md). GO ALONE by the plan's
    # choice, so there is no rust example and `editor` is in neither
    # SCENES nor DEPTH_SCENES (both derive a `cargo build --example`).
    # Through a11y-leg.sh: almost every read it makes is an AT-SPI read.
    run "$proto" editor-go env KAYA_SELFTEST=editor \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    drain
    # THE PORTFOLIO APP (docs/portfolio-plan.md): python alone by design.
    # ALONE BETWEEN DRAINS — 15,000 windowed rows are its own load
    # (docs/virtualization-plan.md §6.2). Through a11y-leg.sh for the
    # chart's expect_ax reads; check-steps refuses this leg without it.
    run "$proto" portfolio-python env KAYA_SELFTEST=portfolio KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/portfolio.py
    drain
    # ROW WINDOWING'S VARIABLE-HEIGHT SCENE (docs/virtualization-plan.md
    # §5): the portfolio's uniform rows drive the EXACT path, this one
    # the CORRECTED path. Python alone, so it stays off the mobile lanes.
    run "$proto" varied-python env KAYA_SELFTEST=varied KAYA_LIB="$LIB" \
        python3 guests/python/varied.py
    drain
done
drain
timing legs

for kaya_slot in "${WAYLAND_POOL[@]}"; do
    kill "$(cat "/tmp/xdg-wl-$kaya_slot/sway.pid" 2>/dev/null)" 2>/dev/null
done

xvfb-run -a bash -c "
    \"$CARGO_TARGET_DIR/debug/examples/milestone2\" &
    sleep 3
    import -window root /work/target-linux/shot-linux.png
    kill %1
" 2>/dev/null || true

flightrec_flush
# Suites accumulate failures rather than abort, so a truncated log must
# still end with the answer.
if [ "$status" = 0 ]; then echo "run-suites: ALL PASS"; else echo "run-suites: FAILURES ABOVE"; fi
exit "$status"
