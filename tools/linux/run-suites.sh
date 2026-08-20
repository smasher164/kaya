#!/usr/bin/env bash
# Runs inside the container (see tools/validate-linux.sh): builds kaya
# against the container's GTK and runs the validations under both
# display protocols — X11 (Xvfb) and Wayland (headless sway). The repo
# is mounted at /work; Linux artifacts go to target-linux so they never
# collide with the host's target directory.
set -uo pipefail

# INSIDE THE CONTAINER ONLY. Run on the host this used to die on a bare
# `cd: /work: No such file or directory`, and this is the one lane whose
# entry point is not the script that does the work.
if [ ! -d /work ]; then
    echo "$0: this runs INSIDE the linux container, where the repo is" \
        "mounted at /work. From the host use: nix develop -c" \
        "tools/validate-linux.sh (it builds the image and runs this)." >&2
    exit 1
fi
cd /work || exit 1
export CARGO_TARGET_DIR=/work/target-linux
# harness-extract.sh refuses to run outside the dev shell and the
# container is not one, so hand it the fingerprint it checks for.
# Without this every leg passed and then produced no stills at all.
KAYA_DEV_SHELL="$(cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
export KAYA_DEV_SHELL
# The one Python import mechanism: the kaya package resolves from here.
export PYTHONPATH=/work/bindings/python
# Dune resolves external libraries through OCAMLPATH, which only opam
# env provides — the image's bare PATH export is enough for ocamlfind
# but not for dune.
eval "$(opam env 2>/dev/null)" || true

# --lib builds the cdylib (libkaya.so) the foreign suites load;
# --example alone would build only the rlib it depends on.
SCENES="background stall milestone2 entry gallery todos reorder feed grow layout align window panels confirm nav split panes scroll progress select radio grid textarea sections menus commands a11y a11yrows filedialog clipboard undo dirty ranges save styling typeface toolbar identity assets"
# Depth-slice scenes: built and run for rust only until the language
# sweep lands their guests.
DEPTH_SCENES=""
BUILD_EXAMPLES=()
for s in $SCENES $DEPTH_SCENES; do BUILD_EXAMPLES+=(--example "$s"); done

# Phase timing: greppable lines say where the container's wall time
# went.
KAYA_T0=$SECONDS
timing() {
    echo "TIMING $1 $((SECONDS - KAYA_T0))s"
    KAYA_T0=$SECONDS
}

# The guest builds pool: dotnet and javac never link libkaya, so they
# start BEFORE the cargo build; everything that links (dune, cabal, go's
# cgo, the C floor) pools after it. Each job logs to its own file; a
# failure prints its log and dies.
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
        guests/java/dev/kaya/milestone2kt/*.java \
        guests/java-desktop/dev/kaya/milestone2kt/Main.java
}
    # dotnet writes obj/bin next to the csproj; build in a scratch copy so
    # the host's in-tree dotnet artifacts (different RID) are untouched.
    # Copied BEFORE the early build starts (the pooled build raced this
    # copy once and built nothing).
mkdir -p /tmp/cs
cp guests/csharp/*.cs guests/csharp/kaya-guests.csproj bindings/csharp/*.cs /tmp/cs/
run_build csharp build_csharp
run_build java build_java

# Debuginfo off, AND the link parallelism bounded: at 18 examples the
# container's parallel example links crossed its memory ceiling and the
# kernel OOM-killed ld ("signal 9" mid-link, 2026-07-22). aarch64 BFD
# ld's footprint is dominated by debuginfo and nothing here asserts on
# symbols; bounding jobs takes the peak out of the link, which is where
# the kernel was choosing a victim. It recurred once after the
# debuginfo fix alone, when libadwaita added two rlibs per link.
CARGO_PROFILE_DEV_DEBUG=0 cargo build -j6 --locked --features harness --lib \
    "${BUILD_EXAMPLES[@]}" || exit 1
# The library every non-Rust guest here dlopens must be the one this
# build produced, not a survivor of a build that failed.
tools/build-id.sh --verify "$CARGO_TARGET_DIR/debug/libkaya.so" || exit 1
timing core-build

# The Rust backends resolve a scene NAME to tools/scenes/<name>.steps.
# The repo is mounted at /work here, so point at it explicitly rather
# than relying on the compile-time default.
export KAYA_SCENES_DIR=/work/tools/scenes

LIB="$CARGO_TARGET_DIR/debug/libkaya.so"
status=0

# THE ACCESSIBILITY BUS IS PER-LEG, NOT LANE-WIDE. Exporting
# GTK_A11Y=atspi here changed the GTK backend for EVERY leg and timed
# out 11 of them at 180s (python/go/csharp/ocaml; rust and c survived)
# — measured 2026-07-25. The a11y legs below launch the bus INSIDE each
# leg through tools/linux/a11y-leg.sh, which tears it down with the leg;
# tools/linux/atspi_probe.py walks the tree by hand.

# HEADLESS SWAY FOR THE WAYLAND LEG, and not Weston, for two measured
# reasons (docs/clipboard-plan.md §0e, docs/traps.md).
#
# 1. HEADLESS WESTON HAS NO wl_seat, and a data device is obtained FROM
#    a seat — so that compositor has no clipboard at all, for any
#    client. No flag fixes it. Nothing before the clipboard noticed,
#    because kaya's harness clicks by driving the toolkit rather than
#    injecting input.
# 2. WLROOTS COMPOSITORS SPEAK data-control, which lets a privileged
#    client read the selection with NO SURFACE AND NO FOCUS. Without it
#    wl-clipboard works by creating a surface and TAKING FOCUS from
#    whatever leg is running. Passive reads are what let the clipboard
#    legs stay in the parallel pool.
#
# FLOATING IS NOT OPTIONAL: sway tiles by default, which forces every
# window to the output size — measured, a window asking for 640x480 got
# 1276x693 — and that would break every expect_window_size leg.
#
# AND THE RULE IS `app_id=".*"` FOR A REASON, which this comment used to
# get wrong in one direction and then in another. It first claimed kaya's
# windows carry `application_id("dev.kaya.Milestone2")` — the GApplication
# id — and that the rule matches because of it; the correction said the
# class follows `g_get_prgname()`, the LAUNCHER BINARY's name. BOTH ARE
# TRUE, of different legs, and the discriminator is a session bus.
# MEASURED 2026-08-18 in this image, same binary and same protocol,
# differing only in whether one was running:
#
#   x11, every leg           WM_CLASS = the launcher binary's name
#   wayland, no session bus  app_id   = the launcher binary's name
#   wayland, a11y-leg.sh     app_id   = "dev.kaya.Milestone2"
#
# because on Wayland a GtkApplication window's `app_id` comes from the
# GApplication ID, and that startup path runs only when the application
# registers on a session bus. `a11y-leg.sh` launches one, so the identity,
# styling, typeface and toolbar legs take that arm and every other leg
# does not. AUXILIARY windows are plain `gtk4::Window`s with no
# application and carry the program name on both arms.
#
# So this lane's legs advertise `python3`, `dotnet`, `java`, `milestone2`,
# `kaya-go` — and, on the wayland legs that hold a bus, one shared
# `dev.kaya.Milestone2`. A rule naming any one id would match a fraction
# of them; `app_id=".*"` is what makes every leg float.
#
# NONE OF THOSE IS THE APP'S OWN NAME, which is the point of the identity
# arm below: an app that declares an identity now moves the class of the
# windows that already exist (crates/kaya/src/gtk.rs, `reclass_toplevels`)
# rather than only of the ones created afterwards, so a `.desktop` entry
# can match its PRIMARY window. Before that, a kaya app on Wayland
# advertised kaya's own milestone-2 id to the whole desktop.
#
# The socket name is sway's to choose, unlike Weston's --socket, so it
# is discovered after start rather than declared.
export XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
cat >/tmp/sway.conf <<'SWAY'
for_window [app_id=".*"] floating enable
output * resolution 1600x1000
SWAY
# 1600x1000 ON BOTH PROTOCOLS (the Xvfb screen below matches): the
# panes scene resizes to 1400, and a stage smaller than the resize
# leaves the window at whatever the compositor allowed — the breakpoint
# then legitimately shows fewer panes and the leg reads as a backend
# bug rather than a small screen.
#
# THE TEXT SCALE IS PINNED at 1.0 (docs/multicolumn-plan.md D4):
# libadwaita's sp unit scales with the text-scaling factor, so the
# 860sp/500sp rungs are 860px/500px only while nothing scales text.
# The container has no settings daemon, so the default IS 1.0; the
# unsets keep an override from sneaking in through docker -e.
unset GDK_DPI_SCALE GDK_SCALE
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1     sway -c /tmp/sway.conf &>/tmp/sway.log &
COMPOSITOR_PID=$!
KAYA_WAYLAND_SOCKET=""
for _ in $(seq 1 40); do
    for candidate in "$XDG_RUNTIME_DIR"/wayland-[0-9]; do
        # -S and not -e: the lock file beside each socket matches the
        # same glob and is not one.
        if [ -S "$candidate" ]; then
            KAYA_WAYLAND_SOCKET="$(basename "$candidate")"
            break
        fi
    done
    [ -n "$KAYA_WAYLAND_SOCKET" ] && break
    sleep 0.25
done
if [ -z "${KAYA_WAYLAND_SOCKET:-}" ]; then
    echo "run-suites: sway never created a socket" >&2
    tail -5 /tmp/sway.log >&2
    exit 1
fi
export KAYA_WAYLAND_SOCKET

# THE SEAT IS THE REQUIREMENT, not the compositor's name, so the lane
# checks for the seat: a compositor without one has no clipboard at all
# and nothing else here would notice. Anyone who swaps this compositor
# again meets this line instead of a mystery.
# swaymsg finds the IPC socket through SWAYSOCK, which only sway's own
# children inherit, so from here it has to be located: it sits beside
# the wayland socket as sway-ipc.<uid>.<pid>.sock.
for candidate in "$XDG_RUNTIME_DIR"/sway-ipc.*.sock; do
    [ -S "$candidate" ] && export SWAYSOCK="$candidate" && break
done
if ! swaymsg -t get_seats 2>/dev/null | grep -q '"name"'; then
    echo "run-suites: the wayland compositor advertises NO SEAT." >&2
    echo "  A data device is obtained from a seat, so this session has no" >&2
    echo "  clipboard for any client, including kaya's own apps. Headless" >&2
    echo "  Weston is the known example; use a wlroots compositor" >&2
    echo "  (docs/clipboard-plan.md, docs/traps.md)." >&2
    exit 1
fi

# AND THE SEAT MUST STAY KEYBOARDLESS WHILE THE POOL RUNS. The seat does
# need key events for the clipboard legs — Wayland charges an
# input-event serial for TAKING the selection, freshly per copy
# (docs/clipboard-plan.md §5b finding 3) — but the fix is NOT a
# session-held virtual keyboard: with a keyboard on the seat, keyboard
# focus becomes EXCLUSIVE across the one session eight pooled legs
# share, and adding a holder broke three unrelated legs' expect_focused
# (measured 2026-08-03). So the keyboard exists only TRANSIENTLY, inside
# the per-step wtype tap the GTK stage runs (gtk.rs,
# freshen_wayland_serial), and only during clipboard legs, which the
# drains below run ALONE.

# Legs run in a background pool (KAYA_JOBS wide, KAYA_JOBS=1 for serial):
# xvfb-run -a gives each X11 leg its own display, and Wayland clients
# share the one headless compositor. Verdicts print in submission order
# at drain; a FAIL prints its log.
JOBS="${KAYA_JOBS:-8}"
LEGS_DIR="$(mktemp -d)"
leg_names=()
leg_pids=()

# ONE LEG, REPEATEDLY, is the only practical way to characterise a rare
# flake, or to prove one fixed: a leg failing 1 in 20 needs about sixty
# WHOLE-LANE runs to show up three times, at three minutes each, and
# the leg itself takes three SECONDS.
#
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
        if run_one "$proto" "$name" "$@"; then
            echo "$name ($proto): PASS ($((SECONDS - t0))s)"
        else
            echo "$name ($proto): FAIL ($((SECONDS - t0))s)"
            status=1
        fi
        return
    fi
    (
        # Per-leg wall time rides the verdict (uniform across runners).
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

# Recording mode (KAYA_RECORD=1): every leg — both protocols — runs
# inside its own Xvfb and is filmed there by record-leg.sh. 24-bit
# screens either way; x11grab cannot encode the 8-bit default.
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
            KAYA_SELFTEST=1 GDK_BACKEND=x11 timeout 180 \
                xvfb-run -a -s "-screen 0 1600x1000x24" "$@"
            ;;
        wayland)
            KAYA_SELFTEST=1 GDK_BACKEND=wayland WAYLAND_DISPLAY="$KAYA_WAYLAND_SOCKET" \
                timeout 180 "$@"
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
            # A leg that produced NOTHING is a different failure from one
            # that failed an assertion, and the bare verdict cannot tell
            # them apart: an empty log means the guest died or hung BEFORE
            # the harness printed its first line. Measured 2026-07-25:
            # eleven legs reported `FAIL (180s)` with empty logs after
            # GTK_A11Y=atspi went lane-wide, and the silence is what made
            # it look like a scene problem instead of a startup problem.
            if [ ! -s "$LEGS_DIR/$name.log" ]; then
                echo "$name: note — NO OUTPUT AT ALL. The guest never reached the harness:" \
                    "it hung or died during startup (library load, display, or a blocking" \
                    "connect), so look before the scene, not inside it."
            fi
            # The confusing failure class: verdict printed OK but the leg
            # still failed. TWO causes share it and the note may not pick
            # one (invariant 3 — this note said "exit-path bug?" while the
            # real cause was a wrapper clause, twice): the process exited
            # nonzero (the Stage::finish class, bitten on GTK and WinUI),
            # or a WRAPPER around the guest failed after the verdict — the
            # identity class witness prints its refusal above when it is
            # the one.
            if grep -q "KAYA_SELFTEST: OK" "$LEGS_DIR/$name.log" 2>/dev/null; then
                echo "$name: note — verdict was OK but the leg exited nonzero: the guest's exit path, or a wrapper clause failing after the verdict — its sentence, if any, is above"
            fi
            status=1
        fi
        echo "$name: $verdict ($(cat "$LEGS_DIR/$name.secs" 2>/dev/null || echo '?')s)"
    done
    leg_names=()
}

build_c() { make -C guests/c TARGET_DIR="$CARGO_TARGET_DIR/debug" OUT=/tmp/c-guests; }
run_build c build_c

# The OCaml guests: one dune build for the binding library and every
# scene. Its own build dir: _build is shared with the host through the
# repo mount and dune keys targets on source hashes, not platform, so
# without this the container is handed mac binaries as "fresh".
build_ocaml() {
    # A failed incremental build self-heals with one forced rebuild: dune's
    # incremental view through the virtiofs mount can produce "Unbound
    # module Dune__exe" (2026-07-22).
    if ! dune build --build-dir=_build-linux; then
        echo "dune incremental build failed; forcing a full rebuild" >&2
        dune build --force --build-dir=_build-linux || return 1
    fi
    # Freshness assert, BY CONTENT AND NOT BY MTIME: dune keys targets on
    # source HASHES, so a source rewritten with identical bytes — which
    # every gen-bindings.sh run does — produces no new artifact and no new
    # mtime. An mtime rule reported "stale" forever and failed the lane on
    # a run where every leg passed (measured 2026-07-31). A stamp of the
    # sources' CONTENT tracks what dune tracks.
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

# The Haskell guests: one cabal build; list-bin locates the outputs.
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
    # ONE BINARY FOR EVERY SCENE: guests/go/cmd is the guest tree's only
    # main package, it imports every scene library, and it picks one from
    # KAYA_SELFTEST. A scene with no Go body has no import and no table key
    # in guests/go/cmd/scenes.go, so this line neither sweeps nor skips.
    mkdir -p /tmp/go-guests
    go build -o /tmp/go-guests/kaya-go dev.kaya/guests/go/cmd || return 1
}
run_build go build_go

# ... and the pool drains here: csharp/java started before the cargo
# build (no libkaya link), the rest right after it.
drain_builds
timing guest-builds

# THE IDENTITY LEGS' ASSET, VERIFIED RATHER THAN ASSUMED, and LOUD
# BEFORE ANY LEG RUNS: without the mark an identity guest dies inside
# its build closure on seven legs at once, and the reader has to work
# back from seven stack traces to one absent asset.
#
# THE PATH IS READ FROM THE DECLARATION, never retyped — the identity is
# written down once in guests/assets/identity.toml
# (docs/app-identity-plan.md ruling 4), and tools/check-app-identity.sh
# fails a tools/ script that names the mark without reading it.
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
    run "$proto" go /tmp/go-guests/kaya-go
    run "$proto" csharp env KAYA_LIB="$LIB" dotnet exec "$CS_GUEST"
    run "$proto" ocaml env KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/milestone2.exe
    run "$proto" haskell "$(hs_bin milestone2)"
    run "$proto" java env KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    # The entry scene: the inner env overrides run()'s KAYA_SELFTEST=1.
    run "$proto" entry-rust env KAYA_SELFTEST=entry "$CARGO_TARGET_DIR/debug/examples/entry"
    run "$proto" entry-c env KAYA_SELFTEST=entry /tmp/c-guests/entry
    run "$proto" entry-python env KAYA_SELFTEST=entry KAYA_LIB="$LIB" \
        python3 guests/python/entry.py
    run "$proto" entry-go env KAYA_SELFTEST=entry /tmp/go-guests/kaya-go
    run "$proto" entry-csharp env KAYA_SELFTEST=entry KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" entry-ocaml env KAYA_SELFTEST=entry KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/entry.exe
    run "$proto" entry-haskell env KAYA_SELFTEST=entry "$(hs_bin entry)"
    run "$proto" entry-java env KAYA_SELFTEST=entry KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    run "$proto" gallery-rust env KAYA_SELFTEST=gallery "$CARGO_TARGET_DIR/debug/examples/gallery"
    run "$proto" gallery-c env KAYA_SELFTEST=gallery /tmp/c-guests/gallery
    run "$proto" gallery-python env KAYA_SELFTEST=gallery KAYA_LIB="$LIB" \
        python3 guests/python/gallery.py
    run "$proto" gallery-go env KAYA_SELFTEST=gallery /tmp/go-guests/kaya-go
    run "$proto" gallery-csharp env KAYA_SELFTEST=gallery KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" gallery-ocaml env KAYA_SELFTEST=gallery KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/gallery.exe
    run "$proto" gallery-haskell env KAYA_SELFTEST=gallery "$(hs_bin gallery)"
    run "$proto" gallery-java env KAYA_SELFTEST=gallery KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    run "$proto" todos-rust env KAYA_SELFTEST=todos "$CARGO_TARGET_DIR/debug/examples/todos"
    run "$proto" todos-c env KAYA_SELFTEST=todos /tmp/c-guests/todos
    run "$proto" todos-python env KAYA_SELFTEST=todos KAYA_LIB="$LIB" \
        python3 guests/python/todos.py
    run "$proto" todos-go env KAYA_SELFTEST=todos /tmp/go-guests/kaya-go
    run "$proto" todos-csharp env KAYA_SELFTEST=todos KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" todos-ocaml env KAYA_SELFTEST=todos KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/todos.exe
    run "$proto" todos-haskell env KAYA_SELFTEST=todos "$(hs_bin todos)"
    run "$proto" todos-java env KAYA_SELFTEST=todos KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    run "$proto" reorder-rust env KAYA_SELFTEST=reorder "$CARGO_TARGET_DIR/debug/examples/reorder"
    run "$proto" reorder-c env KAYA_SELFTEST=reorder /tmp/c-guests/reorder
    run "$proto" reorder-python env KAYA_SELFTEST=reorder KAYA_LIB="$LIB" \
        python3 guests/python/reorder.py
    run "$proto" reorder-go env KAYA_SELFTEST=reorder /tmp/go-guests/kaya-go
    run "$proto" reorder-csharp env KAYA_SELFTEST=reorder KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" reorder-ocaml env KAYA_SELFTEST=reorder KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/reorder.exe
    run "$proto" reorder-haskell env KAYA_SELFTEST=reorder "$(hs_bin reorder)"
    run "$proto" reorder-java env KAYA_SELFTEST=reorder KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    run "$proto" feed-rust env KAYA_SELFTEST=feed "$CARGO_TARGET_DIR/debug/examples/feed"
    run "$proto" feed-c env KAYA_SELFTEST=feed /tmp/c-guests/feed
    run "$proto" feed-python env KAYA_SELFTEST=feed KAYA_LIB="$LIB" \
        python3 guests/python/feed.py
    run "$proto" feed-go env KAYA_SELFTEST=feed /tmp/go-guests/kaya-go
    run "$proto" feed-csharp env KAYA_SELFTEST=feed KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" feed-ocaml env KAYA_SELFTEST=feed KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/feed.exe
    run "$proto" feed-haskell env KAYA_SELFTEST=feed "$(hs_bin feed)"
    run "$proto" feed-java env KAYA_SELFTEST=feed KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    # The grow scene, every sugar-tier language. The C floor stays out on
    # purpose — its scenes document the explicit wire (see the ledger).
    run "$proto" grow-rust env KAYA_SELFTEST=grow "$CARGO_TARGET_DIR/debug/examples/grow"
    run "$proto" grow-python env KAYA_SELFTEST=grow KAYA_LIB="$LIB" \
        python3 guests/python/grow.py
    run "$proto" grow-go env KAYA_SELFTEST=grow /tmp/go-guests/kaya-go
    run "$proto" grow-csharp env KAYA_SELFTEST=grow KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" grow-ocaml env KAYA_SELFTEST=grow KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/grow.exe
    run "$proto" grow-haskell env KAYA_SELFTEST=grow "$(hs_bin grow)"
    run "$proto" grow-java env KAYA_SELFTEST=grow KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    run "$proto" align-rust env KAYA_SELFTEST=align "$CARGO_TARGET_DIR/debug/examples/align"
    run "$proto" align-python env KAYA_SELFTEST=align KAYA_LIB="$LIB" \
        python3 guests/python/align.py
    run "$proto" align-go env KAYA_SELFTEST=align /tmp/go-guests/kaya-go
    run "$proto" align-csharp env KAYA_SELFTEST=align KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" align-ocaml env KAYA_SELFTEST=align KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/align.exe
    run "$proto" align-haskell env KAYA_SELFTEST=align "$(hs_bin align)"
    run "$proto" align-java env KAYA_SELFTEST=align KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    # The window scene: the advisory 640x400 is honored on X11; a Wayland
    # compositor keeps the last word, which is the request semantics.
    run "$proto" window-rust env KAYA_SELFTEST=window "$CARGO_TARGET_DIR/debug/examples/window"
    run "$proto" window-python env KAYA_SELFTEST=window KAYA_LIB="$LIB" \
        python3 guests/python/window.py
    run "$proto" window-go env KAYA_SELFTEST=window /tmp/go-guests/kaya-go
    run "$proto" window-csharp env KAYA_SELFTEST=window KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" window-ocaml env KAYA_SELFTEST=window KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/window.exe
    run "$proto" window-haskell env KAYA_SELFTEST=window "$(hs_bin window)"
    run "$proto" window-java env KAYA_SELFTEST=window KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    # The panels scene: the auxiliary-window grammar (rust depth).
    run "$proto" panels-rust env KAYA_SELFTEST=panels "$CARGO_TARGET_DIR/debug/examples/panels"
    run "$proto" panels-python env KAYA_SELFTEST=panels KAYA_LIB="$LIB" \
        python3 guests/python/panels.py
    run "$proto" panels-go env KAYA_SELFTEST=panels /tmp/go-guests/kaya-go
    run "$proto" panels-csharp env KAYA_SELFTEST=panels KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" panels-ocaml env KAYA_SELFTEST=panels KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/panels.exe
    run "$proto" panels-haskell env KAYA_SELFTEST=panels "$(hs_bin panels)"
    run "$proto" panels-java env KAYA_SELFTEST=panels KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    # The dirty scene (docs/dirty-plan.md). GTK4 has no window-level edited
    # affordance at any layer, so kaya draws the living GNOME convention — a
    # bullet LABEL beside the header-bar title — with the window's title
    # string untouched.
    #
    # THROUGH a11y-leg.sh, and that is the lowering's own consequence: the
    # marker is a widget kaya drew, so the only honest read of it is an
    # assistive client's.
    #
    # Every guest this lane carries. The scene stays in DEPTH_SCENES all
    # the same — that is a TREE-WIDE tier, and graduating it is one move
    # made across every runner at once.
    run "$proto" dirty-rust env KAYA_SELFTEST=dirty \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/dirty"
    run "$proto" dirty-python env KAYA_SELFTEST=dirty KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/dirty.py
    run "$proto" dirty-go env KAYA_SELFTEST=dirty \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" dirty-csharp env KAYA_SELFTEST=dirty KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" dirty-ocaml env KAYA_SELFTEST=dirty KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/dirty.exe
    run "$proto" dirty-haskell env KAYA_SELFTEST=dirty \
        tools/linux/a11y-leg.sh "$(hs_bin dirty)"
    run "$proto" dirty-java env KAYA_SELFTEST=dirty KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    # The C floor's dirty guest, which does not wait on the sugar sweep:
    # the floor takes no sugar at all.
    run "$proto" dirty-c env KAYA_SELFTEST=dirty \
        tools/linux/a11y-leg.sh /tmp/c-guests/dirty

    # THE STAMPED-ACCESSIBILITY SCENE (docs/tpl-props-plan.md P3). On this
    # backend the read is ordinal-by-role (GTK publishes no settable AX
    # identifier), which is why the scene asserts entries and no
    # containers.
    run "$proto" a11yrows-rust env KAYA_SELFTEST=a11yrows \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/a11yrows"
    run "$proto" a11yrows-python env KAYA_SELFTEST=a11yrows KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/a11yrows.py
    run "$proto" a11yrows-go env KAYA_SELFTEST=a11yrows \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" a11yrows-csharp env KAYA_SELFTEST=a11yrows KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" a11yrows-ocaml env KAYA_SELFTEST=a11yrows KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/a11yrows.exe
    run "$proto" a11yrows-haskell env KAYA_SELFTEST=a11yrows \
        tools/linux/a11y-leg.sh "$(hs_bin a11yrows)"
    run "$proto" a11yrows-java env KAYA_SELFTEST=a11yrows KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    run "$proto" a11yrows-c env KAYA_SELFTEST=a11yrows \
        tools/linux/a11y-leg.sh /tmp/c-guests/a11yrows
    # THE STYLING SCENE (docs/styling-plan.md slice 1). On this backend the
    # brand is libadwaita's accent override from the core's derived words,
    # and `heading` is the .heading label class published as the AT-SPI
    # heading role — which is what expect_ax freezes, hence a11y-leg.sh.
    run "$proto" styling-rust env KAYA_SELFTEST=styling \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/styling"
    run "$proto" styling-python env KAYA_SELFTEST=styling KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/styling.py
    run "$proto" styling-go env KAYA_SELFTEST=styling \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" styling-csharp env KAYA_SELFTEST=styling KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" styling-ocaml env KAYA_SELFTEST=styling KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/styling.exe
    run "$proto" styling-haskell env KAYA_SELFTEST=styling \
        tools/linux/a11y-leg.sh "$(hs_bin styling)"
    run "$proto" styling-java env KAYA_SELFTEST=styling KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    run "$proto" styling-c env KAYA_SELFTEST=styling \
        tools/linux/a11y-leg.sh /tmp/c-guests/styling
    # THE TYPEFACE SCENE (docs/styling-plan.md slice 2b): the brand
    # typeface swaps the FAMILY and nothing else. WHAT IT EXISTS TO CATCH IS
    # THE SILENT FALLBACK — Pango substitutes for a family it does not
    # have, so only `expect_typeface` tells a typo, a stale lowering and a
    # working swap apart: it reads the family the TEXT SYSTEM resolved,
    # never the request echoed back. tools/scenes/typeface.steps states it
    # in full, including why the font is VENDORED. Through a11y-leg.sh for
    # the closing expect_ax.
    #
    # NO KAYA_FONT_FILE ON THESE LEGS, measured rather than assumed: the
    # guests default to the repo-relative path and /work IS the repo. That
    # variable is for a runner whose guest cannot see the repo — a phone.
    run "$proto" typeface-rust env KAYA_SELFTEST=typeface \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/typeface"
    run "$proto" typeface-python env KAYA_SELFTEST=typeface KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/typeface.py
    run "$proto" typeface-go env KAYA_SELFTEST=typeface \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" typeface-csharp env KAYA_SELFTEST=typeface KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" typeface-ocaml env KAYA_SELFTEST=typeface KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/typeface.exe
    run "$proto" typeface-haskell env KAYA_SELFTEST=typeface \
        tools/linux/a11y-leg.sh "$(hs_bin typeface)"
    run "$proto" typeface-java env KAYA_SELFTEST=typeface KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    # AND NO C LEG, unlike styling's roster one block up: the floor has no
    # typeface guest, so there is no binary to run. check-steps' C-floor
    # sweep reads the BINARY PATH out of this file, COMMENTS INCLUDED, so
    # the path is not written here even to say it is absent.
    run "$proto" assets-rust env KAYA_SELFTEST=assets \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/assets"
    run "$proto" assets-python env KAYA_SELFTEST=assets KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/assets.py
    run "$proto" assets-go env KAYA_SELFTEST=assets \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" assets-csharp env KAYA_SELFTEST=assets KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" assets-ocaml env KAYA_SELFTEST=assets KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/assets.exe
    run "$proto" assets-haskell env KAYA_SELFTEST=assets \
        tools/linux/a11y-leg.sh "$(hs_bin assets)"
    run "$proto" assets-java env KAYA_SELFTEST=assets KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    # AND THE C FLOOR: guests/c/assets.c writes kaya_asset_open,
    # kaya_asset_blob and kaya_asset_why_not longhand, and this is one of
    # the two lanes that run it.
    run "$proto" assets-c env KAYA_SELFTEST=assets /tmp/c-guests/assets
    # THE TOOLBAR SCENE (docs/chrome-plan.md C2). On this backend the
    # buttons are packed into the window's AdwHeaderBar bound to the same
    # win.kmi-<id> actions the menu rows use, so the scene's round trip is
    # one source of truth rather than two copies.
    #
    # THROUGH a11y-leg.sh, for a sharper reason than styling's: GTK
    # publishes no getter for accessible properties, so
    # `expect_toolbar_item` addresses a button by the name the AT-SPI BUS
    # answers with — and an icon-only GtkButton with no explicit accessible
    # label publishes `name=''` (measured), which a tooltip would paper
    # over and no in-process read could see.
    #
    # Same roster as typeface: no C leg, no guests/c/toolbar.c.
    run "$proto" toolbar-rust env KAYA_SELFTEST=toolbar \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/toolbar"
    run "$proto" toolbar-python env KAYA_SELFTEST=toolbar KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/toolbar.py
    run "$proto" toolbar-go env KAYA_SELFTEST=toolbar \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" toolbar-csharp env KAYA_SELFTEST=toolbar KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" toolbar-ocaml env KAYA_SELFTEST=toolbar KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/toolbar.exe
    run "$proto" toolbar-haskell env KAYA_SELFTEST=toolbar \
        tools/linux/a11y-leg.sh "$(hs_bin toolbar)"
    run "$proto" toolbar-java env KAYA_SELFTEST=toolbar KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    # THE IDENTITY SCENE (docs/app-identity-plan.md). The read is of the X
    # SERVER'S OWN COPY — `xprop -id <xid> _NET_WM_ICON`, decoded to the
    # four quadrant centres — because there is no read-back for an icon
    # list and kaya's model would pass with no lowering at all.
    #
    # THROUGH a11y-leg.sh for toolbar's reason: the scene promotes one
    # command and asserts `expect_toolbar_item "Save"`. Same roster as
    # typeface and toolbar — no C leg, no guests/c/identity.c.
    #
    # ================= AND THE TWO RINGS ARE NOT THE SAME =============
    # THE ICON IS X11-ONLY ON THIS LANE (docs/app-identity-plan.md ruling
    # 5). MEASURED in this image 2026-08-18: GTK is 4.18.6, whose wayland
    # backend drops the icon-list property, and `wayland-info` lists no
    # xdg_toplevel_icon_manager_v1 on sway 1.10.1.
    #
    # So the wayland ring runs a WITNESS rather than the scene
    # (tools/linux/identity-wayland-witness.sh), which requires the leg to
    # fail on the icon steps AND ONLY on them. It goes RED the day the
    # image's GTK reaches 4.20 and the compositor speaks the protocol,
    # which is the day to move this leg onto the scene proper. ONE witness
    # and not seven: what it measures is a GTK-and-compositor fact no
    # binding can change.
    #
    # ============ AND THE CLASS IS ASSERTED ON BOTH RINGS ==============
    # A window's CLASS — `WM_CLASS` on X11, `app_id` on wayland — is what
    # ties a running window to its `.desktop` entry. No harness verb reads
    # it and the scene files are shared verbatim, so it is asserted HERE,
    # outside the leg: tools/linux/identity-class-leg.py wraps every
    # identity leg on both rings and requires every MAPPED toplevel to
    # carry the declared name.
    #
    # THE TWO PROTOCOLS ARE THE SAME ON THIS RING, unlike the icon, and
    # that is measured: X11 takes `XSetClassHint` on the realized surface
    # and wayland takes `xdg_toplevel.set_app_id` after map, which xdg-shell
    # explicitly permits. The wayland leg asserts the class through sway's
    # OWN TREE while still witnessing the icon gap.
    case "$proto" in
        x11)
            run "$proto" identity-rust env KAYA_SELFTEST=identity \
                tools/linux/identity-class-leg.py \
                tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/identity"
            run "$proto" identity-python env KAYA_SELFTEST=identity KAYA_LIB="$LIB" \
                tools/linux/identity-class-leg.py \
                tools/linux/a11y-leg.sh python3 guests/python/identity.py
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
                tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
            ;;
        wayland)
        # The class reader is OUTERMOST, and the nesting is load-bearing: the
        # witness converts the icon gap into a PASS, so a class failure inside
        # it would be swallowed by the clause expecting this leg to fail.
            run "$proto" identity-witness-rust env KAYA_SELFTEST=identity \
                tools/linux/identity-class-leg.py \
                tools/linux/identity-wayland-witness.sh \
                tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/identity"
            ;;
    esac
    # The confirm scene, and the stall diagnostic
    # (crates/kaya/src/stall.rs) — the one scene that deliberately blocks
    # the app thread, in EVERY language, because the misuse it guards is
    # available in every one of them.
    run "$proto" stall-rust env KAYA_SELFTEST=stall "$CARGO_TARGET_DIR/debug/examples/stall"
    run "$proto" stall-python env KAYA_SELFTEST=stall KAYA_LIB="$LIB" \
        python3 guests/python/stall.py
    run "$proto" stall-go env KAYA_SELFTEST=stall /tmp/go-guests/kaya-go
    run "$proto" stall-csharp env KAYA_SELFTEST=stall KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" stall-ocaml env KAYA_SELFTEST=stall KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/stall.exe
    run "$proto" stall-haskell env KAYA_SELFTEST=stall "$(hs_bin stall)"
    run "$proto" stall-java env KAYA_SELFTEST=stall KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    run "$proto" confirm-rust env KAYA_SELFTEST=confirm "$CARGO_TARGET_DIR/debug/examples/confirm"
    run "$proto" confirm-python env KAYA_SELFTEST=confirm KAYA_LIB="$LIB" \
        python3 guests/python/confirm.py
    run "$proto" confirm-go env KAYA_SELFTEST=confirm /tmp/go-guests/kaya-go
    run "$proto" confirm-csharp env KAYA_SELFTEST=confirm KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" confirm-ocaml env KAYA_SELFTEST=confirm KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/confirm.exe
    run "$proto" confirm-haskell env KAYA_SELFTEST=confirm "$(hs_bin confirm)"
    run "$proto" confirm-java env KAYA_SELFTEST=confirm KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    run "$proto" nav-rust env KAYA_SELFTEST=nav "$CARGO_TARGET_DIR/debug/examples/nav"
    # The background scene. DEPTH TIER — rust only until the sweep. Its
    # worker parks until a click releases it, so a binding that ran
    # background work ON the app thread cannot deliver its own release and
    # this leg TIMES OUT rather than failing an assertion: the deadlock IS
    # the gate (docs/background-work-plan.md §5). Through a11y-leg.sh for
    # the closing expect_ax.
    run "$proto" background-rust env KAYA_SELFTEST=background \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/background"

    # The filedialog scene: GNOME's own picker, driven for real. Through
    # a11y-leg.sh because EVERY read here is an AT-SPI read — the chooser
    # publishes no accessible ids, so the directory is the path bar's
    # pressed toggle and the rows are the list's table rows
    # (docs/traps.md).
    run "$proto" filedialog-rust env KAYA_SELFTEST=filedialog \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/filedialog"
    run "$proto" filedialog-python env KAYA_SELFTEST=filedialog KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/filedialog.py
    run "$proto" filedialog-go env KAYA_SELFTEST=filedialog \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" filedialog-csharp env KAYA_SELFTEST=filedialog KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" filedialog-ocaml env KAYA_SELFTEST=filedialog KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/filedialog.exe
    run "$proto" filedialog-haskell env KAYA_SELFTEST=filedialog \
        tools/linux/a11y-leg.sh "$(hs_bin filedialog)"
    run "$proto" filedialog-java env KAYA_SELFTEST=filedialog KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    # The save scene (docs/save-plan.md D5). Through a11y-leg.sh: GTK's
    # save panel publishes no accessible ids at all, so EVERY observation
    # here is a bus read — the directory is the path bar's pressed toggle
    # and the typed name is the `EditableText` field's contents.
    #
    # IN THE POOL, not alone between drains: it types through the
    # accessibility bus, which is per-leg, and touches no session-wide
    # state. Its files live under $TMPDIR/kaya-save-<pid>.
    run "$proto" save-rust env KAYA_SELFTEST=save \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/save"
    # The C floor's save guest, which does not wait on the sugar sweep.
    # Through a11y-leg.sh like every other leg in this block.
    run "$proto" save-c env KAYA_SELFTEST=save \
        tools/linux/a11y-leg.sh /tmp/c-guests/save
    run "$proto" background-python env KAYA_SELFTEST=background KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/background.py
    run "$proto" background-go env KAYA_SELFTEST=background \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" background-csharp env KAYA_SELFTEST=background KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" background-ocaml env KAYA_SELFTEST=background KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/background.exe
    run "$proto" background-haskell env KAYA_SELFTEST=background \
        tools/linux/a11y-leg.sh "$(hs_bin background)"
    run "$proto" background-java env KAYA_SELFTEST=background KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    # The C floor, where queue-plus-wake is WRITTEN OUT rather than hidden
    # in a binding — and the only tier that spells each queued item's
    # DESTINATION, since it queues data where the others queue closures.
    run "$proto" background-c env KAYA_SELFTEST=background \
        tools/linux/a11y-leg.sh /tmp/c-guests/background
    # The split scene, all eight languages. Every leg goes through
    # a11y-leg.sh: the scene asserts the REAL accessibility tree, and on
    # GTK that read is AT-SPI.
    run "$proto" split-rust env KAYA_SELFTEST=split \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/split"
    run "$proto" split-python env KAYA_SELFTEST=split KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/split.py
    run "$proto" split-go env KAYA_SELFTEST=split \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" split-csharp env KAYA_SELFTEST=split KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" split-ocaml env KAYA_SELFTEST=split KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/split.exe
    run "$proto" split-haskell env KAYA_SELFTEST=split \
        tools/linux/a11y-leg.sh "$(hs_bin split)"
    run "$proto" split-java env KAYA_SELFTEST=split KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    # The listdetail scene: THE SAME GUESTS, asserting the bare invariant
    # at whatever width this lane's window manager hands them — a scene
    # selects a SCRIPT, never an app. Through a11y-leg.sh: its one
    # real-tree assertion is an AT-SPI read.
    # The panes scene: the THREE-pane ceiling on the nested split views
    # (docs/multicolumn-plan.md), all seven of this lane's languages.
    # Through a11y-leg.sh: the scene reads the real AT-SPI tree.
    run "$proto" panes-rust env KAYA_SELFTEST=panes \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/panes"
    run "$proto" panes-python env KAYA_SELFTEST=panes KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/panes.py
    run "$proto" panes-go env KAYA_SELFTEST=panes \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" panes-csharp env KAYA_SELFTEST=panes KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" panes-ocaml env KAYA_SELFTEST=panes KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/panes.exe
    run "$proto" panes-haskell env KAYA_SELFTEST=panes \
        tools/linux/a11y-leg.sh "$(hs_bin panes)"
    run "$proto" panes-java env KAYA_SELFTEST=panes KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    run "$proto" listdetail-rust env KAYA_SELFTEST=listdetail \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/split"
    run "$proto" listdetail-python env KAYA_SELFTEST=listdetail KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/split.py
    run "$proto" listdetail-go env KAYA_SELFTEST=listdetail \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" listdetail-csharp env KAYA_SELFTEST=listdetail KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" listdetail-ocaml env KAYA_SELFTEST=listdetail KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/split.exe
    run "$proto" listdetail-haskell env KAYA_SELFTEST=listdetail \
        tools/linux/a11y-leg.sh "$(hs_bin split)"
    run "$proto" listdetail-java env KAYA_SELFTEST=listdetail KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    run "$proto" nav-python env KAYA_SELFTEST=nav KAYA_LIB="$LIB" \
        python3 guests/python/nav.py
    run "$proto" nav-go env KAYA_SELFTEST=nav /tmp/go-guests/kaya-go
    run "$proto" nav-csharp env KAYA_SELFTEST=nav KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" nav-ocaml env KAYA_SELFTEST=nav KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/nav.exe
    run "$proto" nav-haskell env KAYA_SELFTEST=nav "$(hs_bin nav)"
    run "$proto" nav-java env KAYA_SELFTEST=nav KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    run "$proto" scroll-rust env KAYA_SELFTEST=scroll "$CARGO_TARGET_DIR/debug/examples/scroll"
    run "$proto" scroll-python env KAYA_SELFTEST=scroll KAYA_LIB="$LIB" \
        python3 guests/python/scroll.py
    run "$proto" scroll-go env KAYA_SELFTEST=scroll /tmp/go-guests/kaya-go
    run "$proto" scroll-csharp env KAYA_SELFTEST=scroll KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" scroll-ocaml env KAYA_SELFTEST=scroll KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/scroll.exe
    run "$proto" scroll-haskell env KAYA_SELFTEST=scroll "$(hs_bin scroll)"
    run "$proto" scroll-java env KAYA_SELFTEST=scroll KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    # The a11y scene, read off the AT-SPI bus as a real assistive client
    # reads it — the only honest route on GTK, which has no getter for
    # accessible properties. The bus is per-leg (a11y-leg.sh).
    run "$proto" a11y-rust env KAYA_SELFTEST=a11y \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/a11y"
    run "$proto" a11y-c env KAYA_SELFTEST=a11y \
        tools/linux/a11y-leg.sh /tmp/c-guests/a11y
    run "$proto" a11y-python env KAYA_SELFTEST=a11y KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/a11y.py
    run "$proto" a11y-go env KAYA_SELFTEST=a11y \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    run "$proto" a11y-csharp env KAYA_SELFTEST=a11y KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    run "$proto" a11y-ocaml env KAYA_SELFTEST=a11y KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/a11y.exe
    run "$proto" a11y-haskell env KAYA_SELFTEST=a11y \
        tools/linux/a11y-leg.sh "$(hs_bin a11y)"
    run "$proto" a11y-java env KAYA_SELFTEST=a11y KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    run "$proto" progress-rust env KAYA_SELFTEST=progress "$CARGO_TARGET_DIR/debug/examples/progress"
    run "$proto" progress-python env KAYA_SELFTEST=progress KAYA_LIB="$LIB" \
        python3 guests/python/progress.py
    run "$proto" progress-go env KAYA_SELFTEST=progress /tmp/go-guests/kaya-go
    run "$proto" progress-csharp env KAYA_SELFTEST=progress KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" progress-ocaml env KAYA_SELFTEST=progress KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/progress.exe
    run "$proto" progress-haskell env KAYA_SELFTEST=progress "$(hs_bin progress)"
    run "$proto" progress-java env KAYA_SELFTEST=progress KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    run "$proto" select-rust env KAYA_SELFTEST=select "$CARGO_TARGET_DIR/debug/examples/select"
    run "$proto" select-python env KAYA_SELFTEST=select KAYA_LIB="$LIB" \
        python3 guests/python/select.py
    run "$proto" select-go env KAYA_SELFTEST=select /tmp/go-guests/kaya-go
    run "$proto" select-csharp env KAYA_SELFTEST=select KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" select-ocaml env KAYA_SELFTEST=select KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/select.exe
    run "$proto" select-haskell env KAYA_SELFTEST=select "$(hs_bin select)"
    run "$proto" select-java env KAYA_SELFTEST=select KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    run "$proto" radio-rust env KAYA_SELFTEST=radio "$CARGO_TARGET_DIR/debug/examples/radio"
    run "$proto" radio-python env KAYA_SELFTEST=radio KAYA_LIB="$LIB" \
        python3 guests/python/radio.py
    run "$proto" radio-go env KAYA_SELFTEST=radio /tmp/go-guests/kaya-go
    run "$proto" radio-csharp env KAYA_SELFTEST=radio KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" radio-ocaml env KAYA_SELFTEST=radio KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/radio.exe
    run "$proto" radio-haskell env KAYA_SELFTEST=radio "$(hs_bin radio)"
    run "$proto" radio-java env KAYA_SELFTEST=radio KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    run "$proto" grid-rust env KAYA_SELFTEST=grid "$CARGO_TARGET_DIR/debug/examples/grid"
    run "$proto" grid-python env KAYA_SELFTEST=grid KAYA_LIB="$LIB" \
        python3 guests/python/grid.py
    run "$proto" grid-go env KAYA_SELFTEST=grid /tmp/go-guests/kaya-go
    run "$proto" grid-csharp env KAYA_SELFTEST=grid KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" grid-ocaml env KAYA_SELFTEST=grid KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/grid.exe
    run "$proto" grid-haskell env KAYA_SELFTEST=grid "$(hs_bin grid)"
    run "$proto" grid-java env KAYA_SELFTEST=grid KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    run "$proto" textarea-rust env KAYA_SELFTEST=textarea "$CARGO_TARGET_DIR/debug/examples/textarea"
    run "$proto" textarea-python env KAYA_SELFTEST=textarea KAYA_LIB="$LIB" \
        python3 guests/python/textarea.py
    run "$proto" textarea-go env KAYA_SELFTEST=textarea /tmp/go-guests/kaya-go
    run "$proto" textarea-csharp env KAYA_SELFTEST=textarea KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" textarea-ocaml env KAYA_SELFTEST=textarea KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/textarea.exe
    run "$proto" textarea-haskell env KAYA_SELFTEST=textarea "$(hs_bin textarea)"
    run "$proto" textarea-java env KAYA_SELFTEST=textarea KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    run "$proto" sections-rust env KAYA_SELFTEST=sections "$CARGO_TARGET_DIR/debug/examples/sections"
    run "$proto" sections-python env KAYA_SELFTEST=sections KAYA_LIB="$LIB" \
        python3 guests/python/sections.py
    run "$proto" sections-go env KAYA_SELFTEST=sections /tmp/go-guests/kaya-go
    run "$proto" sections-csharp env KAYA_SELFTEST=sections KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" sections-ocaml env KAYA_SELFTEST=sections KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/sections.exe
    run "$proto" sections-haskell env KAYA_SELFTEST=sections "$(hs_bin sections)"
    run "$proto" sections-java env KAYA_SELFTEST=sections KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    # The menus scene: all eight languages plus the C floor.
    run "$proto" menus-rust env KAYA_SELFTEST=menus "$CARGO_TARGET_DIR/debug/examples/menus"
    run "$proto" menus-c env KAYA_SELFTEST=menus /tmp/c-guests/menus
    run "$proto" menus-python env KAYA_SELFTEST=menus KAYA_LIB="$LIB" \
        python3 guests/python/menus.py
    run "$proto" menus-go env KAYA_SELFTEST=menus /tmp/go-guests/kaya-go
    run "$proto" menus-csharp env KAYA_SELFTEST=menus KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" menus-ocaml env KAYA_SELFTEST=menus KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/menus.exe
    run "$proto" menus-haskell env KAYA_SELFTEST=menus "$(hs_bin menus)"
    run "$proto" menus-java env KAYA_SELFTEST=menus KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    # The commands scene, the DEPTH slice (rust only until the sweep).
    run "$proto" commands-rust env KAYA_SELFTEST=commands \
        "$CARGO_TARGET_DIR/debug/examples/commands"
    run "$proto" commands-c env KAYA_SELFTEST=commands /tmp/c-guests/commands
    run "$proto" commands-python env KAYA_SELFTEST=commands KAYA_LIB="$LIB" \
        python3 guests/python/commands.py
    run "$proto" commands-go env KAYA_SELFTEST=commands /tmp/go-guests/kaya-go
    run "$proto" commands-csharp env KAYA_SELFTEST=commands KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" commands-ocaml env KAYA_SELFTEST=commands KAYA_LIB="$LIB" \
        _build-linux/default/guests/ocaml/commands.exe
    run "$proto" commands-haskell env KAYA_SELFTEST=commands "$(hs_bin commands)"
    run "$proto" commands-java env KAYA_SELFTEST=commands KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    # The layout scene: the cross-backend observation vehicle the
    # recordings are compared from, so it is a recorded leg here too.
    run "$proto" layout-rust env KAYA_SELFTEST=layout "$CARGO_TARGET_DIR/debug/examples/layout"
    run "$proto" layout-python env KAYA_SELFTEST=layout KAYA_LIB="$LIB" \
        python3 guests/python/layout.py
    run "$proto" layout-go env KAYA_SELFTEST=layout /tmp/go-guests/kaya-go
    run "$proto" layout-csharp env KAYA_SELFTEST=layout KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" layout-ocaml env KAYA_SELFTEST=layout KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/layout.exe
    run "$proto" layout-haskell env KAYA_SELFTEST=layout "$(hs_bin layout)"
    run "$proto" layout-java env KAYA_SELFTEST=layout KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    # The clipboard scene. Through a11y-leg.sh for its closing expect_ax.
    # THE LEGS ARE MUTUALLY EXCLUSIVE, ONE DRAIN EACH
    # (docs/clipboard-plan.md §0d): there is one system clipboard per
    # session, and legs writing it concurrently are processes assigning one
    # variable. The leading drain also empties the pool, so on wayland the
    # serial primer's F24 tap lands on the clipboard leg's own window.
    drain
    run "$proto" clipboard-rust env KAYA_SELFTEST=clipboard \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/clipboard"
    drain
    run "$proto" clipboard-python env KAYA_SELFTEST=clipboard KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/clipboard.py
    drain
    run "$proto" clipboard-go env KAYA_SELFTEST=clipboard \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    drain
    run "$proto" clipboard-csharp env KAYA_SELFTEST=clipboard KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    drain
    run "$proto" clipboard-ocaml env KAYA_SELFTEST=clipboard KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/clipboard.exe
    drain
    run "$proto" clipboard-haskell env KAYA_SELFTEST=clipboard \
        tools/linux/a11y-leg.sh "$(hs_bin clipboard)"
    drain
    run "$proto" clipboard-java env KAYA_SELFTEST=clipboard KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    drain
    # The undo scene (docs/undo-plan.md §3), a DEPTH slice.
    #
    # ALONE BETWEEN DRAINS, and here that is CORRECTNESS: the `type` verb
    # delivers REAL key events, and on wayland the injector is a transient
    # virtual keyboard whose seat makes keyboard focus EXCLUSIVE across the
    # compositor eight pooled legs share (measured 2026-08-03 — a
    # session-held one broke three unrelated legs' expect_focused). On x11
    # each leg already owns its Xvfb.
    run "$proto" undo-rust env KAYA_SELFTEST=undo \
        "$CARGO_TARGET_DIR/debug/examples/undo"
    drain
    # The text-ranges scene. Through a11y-leg.sh: all three reads go to
    # the accessibility bus. ALONE BETWEEN DRAINS, the undo rule and for
    # the same measured reason. Stays in DEPTH_SCENES even though every
    # guest exists — graduating is one move across every runner at once.
    run "$proto" ranges-rust env KAYA_SELFTEST=ranges \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/ranges"
    drain
    run "$proto" ranges-c env KAYA_SELFTEST=ranges \
        tools/linux/a11y-leg.sh /tmp/c-guests/ranges
    drain
    run "$proto" ranges-python env KAYA_SELFTEST=ranges KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh python3 guests/python/ranges.py
    drain
    run "$proto" ranges-go env KAYA_SELFTEST=ranges \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    drain
    run "$proto" ranges-csharp env KAYA_SELFTEST=ranges KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh dotnet exec "$CS_GUEST"
    drain
    run "$proto" ranges-ocaml env KAYA_SELFTEST=ranges KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh _build-linux/default/guests/ocaml/ranges.exe
    drain
    run "$proto" ranges-haskell env KAYA_SELFTEST=ranges \
        tools/linux/a11y-leg.sh "$(hs_bin ranges)"
    drain
    run "$proto" ranges-java env KAYA_SELFTEST=ranges KAYA_LIB="$LIB" \
        tools/linux/a11y-leg.sh java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    drain
    # THE TEXT EDITOR (docs/editor-plan.md), the only script here that
    # drives an APP rather than a feature. GO ALONE by the plan's choice,
    # so there is no rust example and `editor` is in neither SCENES nor
    # DEPTH_SCENES (both derive a `cargo build --example`).
    #
    # THROUGH a11y-leg.sh: almost every read this script makes is an
    # AT-SPI read here. ALONE BETWEEN DRAINS: `type` delivers REAL key
    # events, and on wayland the injector is a virtual keyboard whose seat
    # makes keyboard focus exclusive across the shared compositor.
    run "$proto" editor-go env KAYA_SELFTEST=editor \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    drain
done
drain
timing legs

kill "$COMPOSITOR_PID" 2>/dev/null

xvfb-run -a bash -c "
    \"$CARGO_TARGET_DIR/debug/examples/milestone2\" &
    sleep 3
    import -window root /work/target-linux/shot-linux.png
    kill %1
" 2>/dev/null || true

# The one-line verdict: suites accumulate failures rather than abort,
# so a truncated log must still end with the answer.
if [ "$status" = 0 ]; then echo "run-suites: ALL PASS"; else echo "run-suites: FAILURES ABOVE"; fi
exit "$status"
