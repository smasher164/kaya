#!/usr/bin/env bash
# Runs inside the container (see tools/validate-linux.sh): builds kaya
# against the container's GTK and runs the milestone-0 validations under
# both display protocols — X11 (Xvfb) and Wayland (headless Weston). The
# repo is mounted at /work; Linux build artifacts go to target-linux so
# they never collide with the host's target directory.
set -uo pipefail

# INSIDE THE CONTAINER ONLY. Run on the host this used to die on a bare
# `cd: /work: No such file or directory`, which names neither the cause
# nor the fix — and this is the one lane whose entry point is not the
# script that does the work, so reaching for it directly is the easy
# mistake to make. Every other runner is its own entry point.
if [ ! -d /work ]; then
    echo "$0: this runs INSIDE the linux container, where the repo is" \
        "mounted at /work. From the host use: nix develop -c" \
        "tools/validate-linux.sh (it builds the image and runs this)." >&2
    exit 1
fi
cd /work || exit 1
export CARGO_TARGET_DIR=/work/target-linux
# harness-extract.sh (recording mode) refuses to run outside the dev
# shell, and the container is not one — it is the pinned image, which is
# the same guarantee by other means. Hand it the fingerprint it checks
# for so recording mode works in here; without this every leg passed and
# then produced no stills at all.
KAYA_DEV_SHELL="$(cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
export KAYA_DEV_SHELL
# The one Python import mechanism: the kaya package resolves from
# here (the guests' sys.path shims are gone).
export PYTHONPATH=/work/bindings/python
# Dune resolves external libraries through OCAMLPATH, which only opam
# env provides — the image's bare PATH export is enough for ocamlfind
# (its config is baked in) but not for dune.
eval "$(opam env 2>/dev/null)" || true

# --lib builds the cdylib (libkaya.so) that the foreign suites load;
# --example alone would build only the rlib it depends on.
# THE scene list — the mechanical build/guest surfaces derive from it
# (one registration per new scene; leg blocks stay explicit).
SCENES="background stall milestone2 entry gallery todos reorder feed grow layout align window panels confirm nav split scroll progress select radio grid textarea sections menus commands a11y filedialog clipboard undo dirty ranges save"
# Depth-slice scenes: built and run for rust only until the language
# sweep lands their guests (the validate-mac DEPTH_SCENES convention).
DEPTH_SCENES=""
BUILD_EXAMPLES=()
for s in $SCENES $DEPTH_SCENES; do BUILD_EXAMPLES+=(--example "$s"); done

# Phase timing, the validate-mac convention: greppable lines say
# where the container's wall time went.
KAYA_T0=$SECONDS
timing() {
    echo "TIMING $1 $((SECONDS - KAYA_T0))s"
    KAYA_T0=$SECONDS
}

# The guest builds pool (the validate-mac convention, measured there
# 2026-07-22): dotnet and javac never link libkaya, so they start
# BEFORE the cargo build; everything that links (dune, cabal, go's
# cgo, the C floor) pools after it. Each job logs to its own file;
# a failure prints its log and dies.
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
# dotnet writes obj/bin next to the csproj; build in a scratch copy
# so the host's in-tree dotnet artifacts (different RID) are
# untouched. Copied BEFORE the early build starts (the pooled build
# raced this copy once and built nothing).
mkdir -p /tmp/cs
cp guests/csharp/*.cs guests/csharp/kaya-guests.csproj bindings/csharp/*.cs /tmp/cs/
run_build csharp build_csharp
run_build java build_java

# Debuginfo off: at 18 examples the container's parallel example
# links crossed its memory ceiling and the kernel OOM-killed ld
# ("signal 9" mid-link, 2026-07-22) — aarch64 BFD ld's footprint is
# dominated by debuginfo, and nothing in the container asserts on
# symbols. This removes the pressure at its source instead of racing
# the example count against the container's RAM.
#
# AND the link parallelism is bounded, which is what docs/traps.md said
# to do if it ever recurred despite the debuginfo fix. It did, the day
# the GTK backend took on libadwaita: two more binding rlibs per link
# was enough to put ld back over the ceiling on 18 cores' worth of
# concurrent links. Bounding jobs costs a little wall time on the
# compile and takes the peak out of the link, which is where the
# kernel was actually choosing a victim.
CARGO_PROFILE_DEV_DEBUG=0 cargo build -j6 --locked --features harness --lib \
    "${BUILD_EXAMPLES[@]}" || exit 1
# The library every non-Rust guest here dlopens must be the one
# this build produced, not a survivor of a build that failed.
tools/build-id.sh --verify "$CARGO_TARGET_DIR/debug/libkaya.so" || exit 1
timing core-build

# The Rust backends resolve a scene NAME to tools/scenes/<name>.steps.
# The repo is mounted at /work here, so point at it explicitly rather
# than relying on the compile-time default (which is right for local
# runs but not for a container whose source path differs).
export KAYA_SCENES_DIR=/work/tools/scenes

LIB="$CARGO_TARGET_DIR/debug/libkaya.so"
status=0

# THE ACCESSIBILITY BUS IS PER-LEG, NOT LANE-WIDE. Exporting
# GTK_A11Y=atspi here changed the GTK backend for EVERY leg and timed
# out 11 of them at 180s (python/go/csharp/ocaml; rust and c survived)
# — measured 2026-07-25. One scene's requirement must not alter the
# environment of three hundred legs that never asked for it.
#
# The image carries at-spi2-core + dbus (see the Dockerfile), and
# tools/linux/atspi_probe.py walks the tree by hand. The a11y legs
# below launch the bus INSIDE each leg through
# tools/linux/a11y-leg.sh, which tears it down with the leg.

# HEADLESS SWAY FOR THE WAYLAND LEG, and not Weston, for two measured
# reasons (docs/clipboard-plan.md §0e, docs/traps.md).
#
# 1. HEADLESS WESTON HAS NO wl_seat, and a data device is obtained FROM
#    a seat — so that compositor has no clipboard at all, for any
#    client, including kaya's own GTK apps. Weston registers no seat for
#    the headless backend deliberately; no flag fixes it. Nothing before
#    the clipboard noticed, because kaya's harness clicks by driving the
#    toolkit rather than injecting input, so no leg ever wanted input.
# 2. WLROOTS COMPOSITORS SPEAK data-control, which lets a privileged
#    client read the selection with NO SURFACE AND NO FOCUS. Without it
#    wl-clipboard still works, but by creating a surface and TAKING
#    FOCUS from whatever leg is running. Passive reads are what let the
#    clipboard legs stay in the parallel pool.
#
# FLOATING IS NOT OPTIONAL: sway tiles by default, which forces every
# window to the output size — measured, a window asking for 640x480 got
# 1276x693 — and that would break every expect_window_size leg, none of
# which has anything to do with the clipboard. kaya's GTK windows carry
# application_id("dev.kaya.Milestone2"), so the app_id rule matches.
#
# The socket name is sway's to choose, unlike Weston's --socket, so it
# is discovered after start rather than declared.
export XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
cat >/tmp/sway.conf <<'SWAY'
for_window [app_id=".*"] floating enable
SWAY
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
# checks for the seat. A compositor without one has no clipboard at all
# and nothing else here would notice — the harness drives the toolkit
# rather than injecting input, which is exactly why headless Weston's
# missing seat went unseen until the clipboard needed it. Anyone who
# swaps this compositor again meets this line instead of a mystery.
# swaymsg finds the IPC socket through SWAYSOCK, which only sway's own
# children inherit; from here it has to be located. It sits beside the
# wayland socket as sway-ipc.<uid>.<pid>.sock.
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

# AND THE SEAT MUST STAY KEYBOARDLESS WHILE THE POOL RUNS. The seat
# does need key events for the clipboard legs — Wayland charges an
# input-event serial for TAKING the selection, freshly per copy,
# because wlroots rejects a set_selection whose serial is older than
# the current selection's and every wl-copy seed advances that
# watermark (docs/clipboard-plan.md §5b finding 3, all measured). But
# the fix is NOT a session-held virtual keyboard: with a keyboard on
# the seat, keyboard focus becomes EXCLUSIVE, and eight pooled legs
# share this one session — the moment a holder was added, three
# unrelated legs failed `expect_focused` because only one window can
# hold a real keyboard's focus (measured 2026-08-03; the holder-less
# run of the same tree was ALL PASS). So the keyboard exists only
# TRANSIENTLY, inside the per-step wtype tap the GTK stage runs
# (gtk.rs, freshen_wayland_serial) — and only during clipboard legs,
# which the drains below run ALONE, where a transient keyboard has no
# neighbor to disturb.

# Legs run in a background pool (KAYA_JOBS wide, KAYA_JOBS=1 for the
# old serial behavior): xvfb-run -a gives each X11 leg its own display,
# and Wayland clients share the one headless compositor. Verdicts print
# in submission order at drain; a FAIL prints its log.
JOBS="${KAYA_JOBS:-8}"
LEGS_DIR="$(mktemp -d)"
leg_names=()
leg_pids=()

# ONE LEG, REPEATEDLY, is the only practical way to characterise a rare
# flake — and the only way to prove one fixed. A leg failing 1 in 20
# needs about sixty WHOLE-LANE runs to show up three times, at three
# minutes each; the leg itself takes three SECONDS. Measured the
# expensive way first: six full runs of this lane and six of windows
# reproduced nothing at all (2026-08-02).
#
# KAYA_ONLY is a prefix, so `KAYA_ONLY=menus-java` takes both protocols
# and `KAYA_ONLY=menus-java-wayland` takes one. Empty means every leg,
# which is what every lane run does.
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
        # Per-leg wall time rides the verdict (the bottleneck-hunt
        # instrumentation, uniform across runners).
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
# inside its own Xvfb and is filmed there by record-leg.sh (wayland
# via a nested per-leg Weston on the X11 backend). One window per
# private display: the film is the leg, no crops or tiling needed.
# 24-bit screens either way; x11grab cannot encode the 8-bit default.
run_one() {
    local proto="$1" name="$2"
    shift 2
    if [ -n "${KAYA_RECORD:-}" ]; then
        local dir="/work/target-linux/recordings/$name-$proto"
        rm -rf "$dir"
        case "$proto" in
            x11)
                KAYA_SELFTEST=1 GDK_BACKEND=x11 timeout 180 \
                    xvfb-run -a -s "-screen 0 1024x768x24" \
                    /work/tools/linux/record-leg.sh x11 "$dir" "$@"
                ;;
            wayland)
                KAYA_SELFTEST=1 GDK_BACKEND=wayland timeout 180 \
                    xvfb-run -a -s "-screen 0 1024x768x24" \
                    /work/tools/linux/record-leg.sh wayland "$dir" "$@"
                ;;
        esac
        return
    fi
    case "$proto" in
        x11)
            KAYA_SELFTEST=1 GDK_BACKEND=x11 timeout 180 \
                xvfb-run -a -s "-screen 0 1024x768x24" "$@"
            ;;
        wayland)
            KAYA_SELFTEST=1 GDK_BACKEND=wayland WAYLAND_DISPLAY="$KAYA_WAYLAND_SOCKET" \
                timeout 180 "$@"
            ;;
    esac
}

# Wait on the leg jobs by pid — never a bare `wait`, which would also
# wait on unrelated background children (the Linux suite's Weston runs
# forever; a bare wait deadlocked here once).
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
            # them apart. An empty log means the guest died or hung
            # BEFORE the harness printed its first line — a bad library
            # load, a missing display, or a blocking connect at startup.
            # Measured 2026-07-25: eleven legs reported `FAIL (180s)`
            # with empty logs after GTK_A11Y=atspi was exported
            # lane-wide, and the silence is what made it look like a
            # scene problem instead of a startup problem.
            if [ ! -s "$LEGS_DIR/$name.log" ]; then
                echo "$name: note — NO OUTPUT AT ALL. The guest never reached the harness:" \
                    "it hung or died during startup (library load, display, or a blocking" \
                    "connect), so look before the scene, not inside it."
            fi
            # The confusing failure class: verdict printed OK but the
            # leg still failed — the process never exited (a broken
            # Stage::finish exit path, once bitten on GTK and WinUI).
            if grep -q "KAYA_SELFTEST: OK" "$LEGS_DIR/$name.log" 2>/dev/null; then
                echo "$name: note — verdict was OK but the process did not exit cleanly (finish()/exit-path bug?)"
            fi
            status=1
        fi
        echo "$name: $verdict ($(cat "$LEGS_DIR/$name.secs" 2>/dev/null || echo '?')s)"
    done
    leg_names=()
}

# The C guests: the ABI's home language over the function floor.
build_c() { make -C guests/c TARGET_DIR="$CARGO_TARGET_DIR/debug" OUT=/tmp/c-guests; }
run_build c build_c

# The OCaml guests: one dune build for the binding library and all
# four scenes. Its own build dir: _build is shared with the host
# through the repo mount, and dune keys targets on source hashes, not
# platform — without this the container gets handed mac binaries as
# "fresh" (the same disease target-linux/ exists to prevent for cargo).
build_ocaml() {
    # A failed incremental build self-heals with one forced rebuild
    # (caught 2026-07-22 adding the sections module: dune's
    # incremental view through the virtiofs mount produced "Unbound
    # module Dune__exe"; the same class as the staleness assert
    # below, at build time instead of link time).
    if ! dune build --build-dir=_build-linux; then
        echo "dune incremental build failed; forcing a full rebuild" >&2
        dune build --force --build-dir=_build-linux || return 1
    fi
    # Freshness assert (caught live 2026-07-22: under PARALLEL lanes,
    # two exes rode a previous run's link — dune's incremental view
    # through the virtiofs mount raced the host lane's concurrent
    # builds. The per-guest spec-hash guard caught it at LEG time;
    # this moves the catch to build time and self-heals with one
    # forced rebuild).
    #
    # BY CONTENT, NOT BY MTIME, and the difference is the whole
    # correctness of this check. It used to compare each exe against
    # the newest binding source's TIMESTAMP, which is a rule dune can
    # never satisfy: dune keys targets on source HASHES, so a source
    # that is rewritten with identical bytes — every `gen-bindings.sh`
    # run does exactly that — produces no new artifact and therefore no
    # new mtime. The check then reported "stale" forever, forced a
    # rebuild that correctly did nothing, and failed the lane on a run
    # where every leg passed. Measured 2026-07-31: kaya_wire.ml
    # byte-identical to HEAD, exes two days old, lane red twice running.
    #
    # A stamp of the sources' CONTENT tracks what dune tracks, so it
    # fires when the sources really moved and stays quiet when they did
    # not.
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
# The rpath travels via ghc-options — macOS resolves libkaya by its
# absolute install name, Linux only by rpath or LD_LIBRARY_PATH.
build_haskell() {
    cd guests/haskell && cabal build all \
        --extra-lib-dirs="$CARGO_TARGET_DIR/debug" \
        --ghc-options="-L$CARGO_TARGET_DIR/debug -optl-Wl,-rpath,$CARGO_TARGET_DIR/debug" -v0
}
run_build haskell build_haskell
hs_bin() { (cd guests/haskell && cabal list-bin "$1" -v0); }

# dotnet run and go run rebuild per invocation; build each guest once
# and let the legs exec the outputs.
CS_GUEST="/tmp/cs/bin/Debug/net10.0/kaya-guests.dll"
build_go() {
    # ONE BINARY FOR EVERY SCENE, the mac runner's shape: guests/go/cmd
    # is the guest tree's only main package, it imports all 31 scene
    # libraries, and it picks one from KAYA_SELFTEST — which every Go
    # leg below already passes.
    #
    # This used to be a link per scene, and it was the one tier where a
    # landed guest could still have nothing to run (every other
    # language's build here is a whole-directory sweep — dune, cabal,
    # javac's wildcard, dotnet's glob — and picks a new guest up for
    # free). A scene with no Go body now has no import and no table key
    # in guests/go/cmd/scenes.go, so this line neither sweeps nor skips.
    mkdir -p /tmp/go-guests
    go build -o /tmp/go-guests/kaya-go dev.kaya/guests/go/cmd || return 1
}
run_build go build_go

# ... and the pool drains here: csharp/java started before the cargo
# build (no libkaya link), the rest right after it.
drain_builds
timing guest-builds

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
    # The gallery scene (row + checkbox): the toggle arrives as an
    # occurrence the app answers with the status signal.
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
    # The todos scene (records + field projection): one field's delta
    # travels; the items-left label proves the fold.
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
    # The reorder scene (order as collection data): expect_order reads
    # the toolkit's actual child order back after each keyed move.
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
    # The feed scene (sum-typed elements): per-variant templates,
    # promote = variant-change restamp, witnessed field writes.
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
    # The grow scene (the layout contract: both containers hold
    # nothing but growers, splits read back as shares plus root-fills),
    # every sugar-tier language. The C floor stays out on purpose — its
    # scenes document the explicit wire, and grow there is a separate
    # exercise (see the ledger).
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
    # The align scene: the cross-axis contract (center + baseline),
    # every language.
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
    # The window scene: the primary surface's props — the title
    # materialized in the real title bar, the advisory 640x400
    # honored (X11; a Wayland compositor keeps the last word, which
    # is the request semantics).
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
    # The panels scene: the auxiliary-window grammar (rust depth; the
    # language sweep rides the phase's next slice).
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
    # The dirty scene: unsaved work as window chrome
    # (docs/dirty-plan.md). GTK4 has no window-level edited affordance at
    # any layer, so kaya draws the living GNOME convention — a bullet
    # LABEL beside the header-bar title (GNOME Text Editor's own shape),
    # with the window's title string untouched.
    #
    # THROUGH a11y-leg.sh, and that is the lowering's own consequence
    # rather than a preference: the marker is a widget kaya drew, so the
    # only honest read of it is the one an assistive client makes, and
    # GTK publishes no accessibility tree at all without GTK_A11Y=atspi
    # and a bus to sit on. This wrapper stands up both, per leg — never
    # lane-wide, which once timed out eleven legs that never asked for
    # accessibility.
    #
    # EVERY GUEST THIS LANE CARRIES, which is already the full roster:
    # the sugar sweep landed all seven non-Swift bindings plus the C
    # floor, and each was run here before its leg was wired. The scene
    # stays in DEPTH_SCENES all the same — that is a TREE-WIDE tier, and
    # the mac runner is still filling in its own languages; graduating it
    # is one move made across every runner at once, not per lane. Nothing
    # here depends on which list holds it: both feed the example build
    # and the Go guest build alike.
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
    # the floor takes no sugar at all, so it was writable the day the
    # wire constant existed (the undo-c precedent).
    run "$proto" dirty-c env KAYA_SELFTEST=dirty \
        tools/linux/a11y-leg.sh /tmp/c-guests/dirty
    # The confirm scene: the modal-alert grammar (gtk::AlertDialog),
    # all three answer paths through the REAL dialog button.
    # The stall diagnostic (crates/kaya/src/stall.rs): the one scene
    # that deliberately blocks the app thread, asserting that kaya
    # REPORTS it. EVERY LANGUAGE, because the misuse it guards is
    # available in every one of them — no swift leg here, as this lane
    # has never carried one.
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
    # The nav scene: the serial navigation grammar — the header-bar
    # back button is GTK's back affordance, driven for real; the
    # intercept_back veto class answers with pop_entry.
    run "$proto" nav-rust env KAYA_SELFTEST=nav "$CARGO_TARGET_DIR/debug/examples/nav"
    # The background scene: work off the app thread, posted back. DEPTH
    # TIER — rust only until the sweep lands the other seven. Its worker
    # parks until a click releases it, so a binding that ran background
    # work ON the app thread cannot deliver its own release and this leg
    # TIMES OUT rather than failing an assertion. The deadlock IS the
    # gate (docs/background-work-plan.md §5). Through a11y-leg.sh for
    # the closing expect_ax, which on GTK is an AT-SPI read.
    run "$proto" background-rust env KAYA_SELFTEST=background \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/background"

    # The filedialog scene: GNOME's own picker, driven for real, in
    # every language. Through a11y-leg.sh because EVERY
    # read here is an AT-SPI read, not just the closing expect_ax: the
    # chooser publishes no accessible ids at all, so the directory is
    # the path bar's pressed toggle button and the rows are the list's
    # table rows (measured; docs/traps.md).
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
    # The save scene: the round trip an editor walks — open, save back to
    # the picked handle, save AS a new destination, reopen both
    # (docs/save-plan.md D5). GTK's save panel is the SAME
    # `gtk::FileDialog` the picker legs above drive, with `save()` called
    # on it, so it reads and drives over the same AT-SPI path and needs
    # the same per-leg bus — every observation in this scene is a bus
    # read, not just the closing expect_ax: the panel publishes no
    # accessible ids at all, so the directory is the path bar's pressed
    # toggle and the typed name is the `EditableText` field's contents.
    #
    # IN THE POOL, not alone between drains. The two scenes that take
    # drains here inject REAL key events (undo, ranges) or own the one
    # system clipboard; this one types through the accessibility bus,
    # which is per-leg, and touches no session-wide state at all. Its
    # files live under $TMPDIR/kaya-save-<pid>, so parallel legs cannot
    # collide either.
    run "$proto" save-rust env KAYA_SELFTEST=save \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/save"
    # The C floor's save guest, which does not wait on the sugar sweep:
    # the floor takes no sugar at all, so it was writable the day the
    # wire record existed (the undo-c and dirty-c precedent). Through
    # a11y-leg.sh like every other leg in this block, and for the same
    # reason — every observation the script makes here is an AT-SPI read.
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
    # The C floor, where queue-plus-wake is WRITTEN OUT rather than
    # hidden in a binding: the guest owns the mutex-guarded work list,
    # calls kaya_wake itself, and drains before every wait. It is also
    # the only tier that has to spell each queued item's DESTINATION,
    # since it queues data where the others queue closures.
    run "$proto" background-c env KAYA_SELFTEST=background \
        tools/linux/a11y-leg.sh /tmp/c-guests/background
    # The split scene: adaptive list-detail through
    # AdwNavigationSplitView, with resize_window driving the real
    # size-class transition. All eight languages.
    # Every leg goes through a11y-leg.sh, like the a11y legs: the scene
    # asserts the REAL accessibility tree (that both panes are present
    # AT ONCE, which the stamped presentation cannot prove), and on GTK
    # that read is AT-SPI — which needs the per-leg dbus + at-spi bus
    # this wrapper stands up.
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
    # The listdetail scene: THE SAME GUESTS, asserting the bare
    # invariant at whatever width this lane's window manager hands
    # them. One app, two scripts — a scene selects a SCRIPT, never an
    # app. Through a11y-leg.sh for the same reason: its one real-tree
    # assertion is an AT-SPI read.
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
    # The scroll scene: the viewport's contract through
    # GtkScrolledWindow — its vadjustment is both the observation and
    # the scrolling API.
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
    # The a11y scene: every widget kind's role and NAME read back off
    # the AT-SPI bus, as a real assistive client reads them — the only
    # honest route on GTK, which has no getter for accessible
    # properties (an in-process read would return kaya's own writes).
    # The bus is per-leg (tools/linux/a11y-leg.sh): exported lane-wide
    # it timed out eleven legs that never asked for accessibility.
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
    # The progress scene: fraction + activity mode read back from
    # GtkProgressBar (the pulse ticker IS the activity mode).
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
    # The select scene: the dropdown's contract — GtkDropDown's model
    # holds the options, set_selected is the real pick route, the
    # quiet guard keeps programmatic writes silent.
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
    # The radio scene: grouped CheckButtons, the choice contract
    # inline.
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
    # The grid scene: GtkGrid's natural-width aligned columns + the
    # spacer's grow sugar.
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
    # The textarea scene: GtkTextView, the entry contract multi-line.
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
    # The sections scene: GtkStackSwitcher over GtkStack — the
    # presentation context (echo doctrine both ways + retention).
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
    # The menus scene: the command vocabulary on GTK — GMenu +
    # PopoverMenuBar in a strip above the root, every item a
    # window-scoped GSimpleAction (enablement, toggle state, and radio
    # targets all native), the shortcut resolved through the
    # application's own accel table, context popovers on a live label
    # and on a stamped row (the keys are the noun). All eight
    # languages plus the C floor, byte-identical.
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
    # The commands scene, the DEPTH slice (rust only until the sweep):
    # chords on checkable commands and on single options, the
    # punctuation keys they need, and the `settings` role — which has no
    # placement effect here, so the item stays exactly where the app
    # declared it.
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
    # recordings are compared from, so it has to be a recorded leg here
    # too — in every language.
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
    # The clipboard scene: one clip in several representations, the
    # privileged read, the paste split, and Paste as a standard
    # command. Through a11y-leg.sh: its closing expect_ax is an AT-SPI
    # read. THE LEGS ARE MUTUALLY EXCLUSIVE, ONE DRAIN EACH
    # (docs/clipboard-plan.md §0d, the 2026-08-02 correction): there is
    # one system clipboard per session, and legs writing it
    # concurrently are processes assigning one variable — measured on
    # mac, six of eight failed concurrently and the same eight passed
    # serially. The leading drain also empties the pool of every other
    # leg, so on wayland the serial primer's F24 tap (wtype, §5b
    # finding 3) lands on the clipboard leg's own window and nobody
    # else's.
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
    # The undo scene: one history over two tiers, walked newest-first
    # (docs/undo-plan.md §3). A DEPTH slice — rust-only here until the
    # seven other bindings spell `undoable`, when it moves into SCENES.
    #
    # ALONE BETWEEN DRAINS, and on this lane that is CORRECTNESS rather
    # than insurance: the `type` verb delivers REAL key events, which
    # both protocols route to whatever holds the session's focus. On
    # wayland the injector is a transient virtual keyboard, and a
    # keyboard on the seat makes keyboard focus EXCLUSIVE across the
    # compositor eight pooled legs share (measured 2026-08-03 — a
    # session-held one broke three unrelated legs' expect_focused). The
    # drains give the typing no neighbour to reach. On x11 each leg
    # already owns its Xvfb, and the bracket costs one leg's worth of
    # pool there.
    run "$proto" undo-rust env KAYA_SELFTEST=undo \
        "$CARGO_TARGET_DIR/debug/examples/undo"
    drain
    # The text-ranges scene: HIGHLIGHT a set, SELECT one, REVEAL one,
    # plus the two rules that make them a contract — a keystroke DROPS
    # a declared set (D2) and a select_range mid-composition is REFUSED
    # (D4). Through a11y-leg.sh: all three reads go to the accessibility
    # bus (GtkTextTag attribute runs, the selection, and the viewport
    # geometry the textarea's GtkScrolledWindow made observable), so the
    # leg needs GTK_A11Y=atspi and a bus to sit on.
    #
    # ALONE BETWEEN DRAINS, the undo rule and for the same measured
    # reason: `type " z"` delivers REAL key events, and on wayland the
    # injector is a virtual keyboard whose seat makes keyboard focus
    # exclusive across the compositor the pooled legs share.
    #
    # EVERY GUEST THIS LANE CARRIES — the sugar sweep landed all seven
    # non-Swift bindings plus the C floor while this backend arm was
    # being written, and one frozen script is compared byte-for-byte
    # across all of them. The scene stays in DEPTH_SCENES: graduating it
    # is one move made across every runner at once.
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
    # THE TEXT EDITOR — kaya's forcing artifact (docs/editor-plan.md),
    # and the only script on this lane that drives an APP rather than a
    # feature: launch to an empty buffer, type, save-as, open, edit,
    # undo, save, find with a regex, and the unsaved-work warning on
    # close.
    #
    # GO ALONE, and not as a sweep waiting to happen: the plan chose Go
    # deliberately — an editor in Rust would be kaya testing itself, and
    # every awkward corner of a BINDING would stay invisible — so there
    # is no rust example, and `editor` is in neither SCENES nor
    # DEPTH_SCENES (both derive a `cargo build --example` this app does
    # not want). The Go guest is one binary carrying every scene, so the
    # leg needs nothing but its name.
    #
    # THROUGH a11y-leg.sh, because almost every read this script makes is
    # an AT-SPI read here: GTK's picker and save panel publish no
    # accessible ids at all (the directory is the path bar's pressed
    # toggle, the typed name is the EditableText field's contents), the
    # dirty mark is the header bar's bullet, and the three range reads
    # are tag runs, the selection, and the viewport geometry the
    # textarea's GtkScrolledWindow made observable.
    #
    # ALONE BETWEEN DRAINS, the undo and ranges rule for the same
    # measured reason: `type` delivers REAL key events, and on wayland
    # the injector is a virtual keyboard whose seat makes keyboard focus
    # exclusive across the compositor the pooled legs share.
    run "$proto" editor-go env KAYA_SELFTEST=editor \
        tools/linux/a11y-leg.sh /tmp/go-guests/kaya-go
    drain
done
drain
timing legs

kill "$COMPOSITOR_PID" 2>/dev/null

# Best-effort screenshot of the running scene (X11 leg) for visual
# validation.
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
