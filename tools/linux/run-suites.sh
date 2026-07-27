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
SCENES="milestone2 entry gallery todos reorder feed grow layout align window panels confirm nav scroll progress select radio grid textarea sections menus commands a11y"
# Depth-slice scenes: built and run for rust only until the language
# sweep lands their guests (the validate-mac DEPTH_SCENES convention).
DEPTH_SCENES="split listdetail"
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

# Headless Weston for the Wayland leg.
export XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
weston --backend=headless --socket=kaya-wayland &>/tmp/weston.log &
WESTON_PID=$!
sleep 2

# Legs run in a background pool (KAYA_JOBS wide, KAYA_JOBS=1 for the
# old serial behavior): xvfb-run -a gives each X11 leg its own display,
# and Wayland clients share the one headless compositor. Verdicts print
# in submission order at drain; a FAIL prints its log.
JOBS="${KAYA_JOBS:-8}"
LEGS_DIR="$(mktemp -d)"
leg_names=()
leg_pids=()

run() {
    local proto="$1" name="$2"
    shift 2
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
            KAYA_SELFTEST=1 GDK_BACKEND=wayland WAYLAND_DISPLAY=kaya-wayland \
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
    # forced rebuild). An exe older than the newest binding source is
    # stale by definition.
    local newest exe fresh_exe
    newest=$(ls -t bindings/ocaml/*.ml | head -1)
    for exe in _build-linux/default/guests/ocaml/*.exe; do
        if [ ! "$exe" -nt "$newest" ]; then
            echo "stale ocaml artifact ($exe); forcing a full rebuild" >&2
            dune build --force --build-dir=_build-linux || return 1
            for fresh_exe in _build-linux/default/guests/ocaml/*.exe; do
                [ "$fresh_exe" -nt "$newest" ] || return 1
            done
            return 0
        fi
    done
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
    mkdir -p /tmp/go-guests
    local guest
    for guest in $SCENES; do
        go build -o "/tmp/go-guests/$guest" "dev.kaya/guests/go/$guest" || return 1
    done
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
    run "$proto" go /tmp/go-guests/milestone2
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
    run "$proto" entry-go env KAYA_SELFTEST=entry /tmp/go-guests/entry
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
    run "$proto" gallery-go env KAYA_SELFTEST=gallery /tmp/go-guests/gallery
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
    run "$proto" todos-go env KAYA_SELFTEST=todos /tmp/go-guests/todos
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
    run "$proto" reorder-go env KAYA_SELFTEST=reorder /tmp/go-guests/reorder
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
    run "$proto" feed-go env KAYA_SELFTEST=feed /tmp/go-guests/feed
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
    run "$proto" grow-go env KAYA_SELFTEST=grow /tmp/go-guests/grow
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
    run "$proto" align-go env KAYA_SELFTEST=align /tmp/go-guests/align
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
    run "$proto" window-go env KAYA_SELFTEST=window /tmp/go-guests/window
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
    run "$proto" panels-go env KAYA_SELFTEST=panels /tmp/go-guests/panels
    run "$proto" panels-csharp env KAYA_SELFTEST=panels KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" panels-ocaml env KAYA_SELFTEST=panels KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/panels.exe
    run "$proto" panels-haskell env KAYA_SELFTEST=panels "$(hs_bin panels)"
    run "$proto" panels-java env KAYA_SELFTEST=panels KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
    # The confirm scene: the modal-alert grammar (gtk::AlertDialog),
    # all three answer paths through the REAL dialog button.
    run "$proto" confirm-rust env KAYA_SELFTEST=confirm "$CARGO_TARGET_DIR/debug/examples/confirm"
    run "$proto" confirm-python env KAYA_SELFTEST=confirm KAYA_LIB="$LIB" \
        python3 guests/python/confirm.py
    run "$proto" confirm-go env KAYA_SELFTEST=confirm /tmp/go-guests/confirm
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
    # The split scene: adaptive list-detail. Rust-only (a depth
    # scene); GTK renders the two panes in a Box and resize_window
    # drives the real size-class transition.
    # Through a11y-leg.sh, like the a11y legs: the scene asserts the
    # REAL accessibility tree (that both panes are present AT ONCE,
    # which the stamped presentation cannot prove), and on GTK that
    # read is AT-SPI — which needs the per-leg dbus + at-spi bus this
    # wrapper stands up.
    run "$proto" split-rust env KAYA_SELFTEST=split \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/split"
    # The listdetail scene: the same guest, asserting the bare
    # invariant at whatever width this lane's window manager hands it.
    # Through a11y-leg.sh for the same reason the leg above is: its one
    # real-tree assertion is an AT-SPI read.
    run "$proto" listdetail-rust env KAYA_SELFTEST=listdetail \
        tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/listdetail"
    run "$proto" nav-python env KAYA_SELFTEST=nav KAYA_LIB="$LIB" \
        python3 guests/python/nav.py
    run "$proto" nav-go env KAYA_SELFTEST=nav /tmp/go-guests/nav
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
    run "$proto" scroll-go env KAYA_SELFTEST=scroll /tmp/go-guests/scroll
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
        tools/linux/a11y-leg.sh /tmp/go-guests/a11y
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
    run "$proto" progress-go env KAYA_SELFTEST=progress /tmp/go-guests/progress
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
    run "$proto" select-go env KAYA_SELFTEST=select /tmp/go-guests/select
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
    run "$proto" radio-go env KAYA_SELFTEST=radio /tmp/go-guests/radio
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
    run "$proto" grid-go env KAYA_SELFTEST=grid /tmp/go-guests/grid
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
    run "$proto" textarea-go env KAYA_SELFTEST=textarea /tmp/go-guests/textarea
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
    run "$proto" sections-go env KAYA_SELFTEST=sections /tmp/go-guests/sections
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
    run "$proto" menus-go env KAYA_SELFTEST=menus /tmp/go-guests/menus
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
    run "$proto" commands-go env KAYA_SELFTEST=commands /tmp/go-guests/commands
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
    run "$proto" layout-go env KAYA_SELFTEST=layout /tmp/go-guests/layout
    run "$proto" layout-csharp env KAYA_SELFTEST=layout KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" layout-ocaml env KAYA_SELFTEST=layout KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/layout.exe
    run "$proto" layout-haskell env KAYA_SELFTEST=layout "$(hs_bin layout)"
    run "$proto" layout-java env KAYA_SELFTEST=layout KAYA_LIB="$LIB" \
        java -cp /tmp/java-guests dev.kaya.milestone2kt.Main
done
drain
timing legs

kill "$WESTON_PID" 2>/dev/null

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
