#!/usr/bin/env bash

# Everything runs inside the dev shell: the flake pins every toolchain
# (rust + cross targets, swiftc, ffmpeg, the android sdk). Running
# against anything else is an error, not something to paper over — and
# a shell entered before the flake last changed is just as much a
# bystander toolchain, so the marker carries the fingerprint of
# flake.nix+flake.lock the shell was actually built from.
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# Deploy milestone-0 artifacts to the Windows VM and run the validations.
#
# Usage: tools/deploy-win.sh user@host [--provision] [rust|python|go|csharp|all]
#        tools/deploy-win.sh user@host probe=<exe>   # aliveness probe, e.g. probe=entry
#
# Convention: everything that lands on the VM as a FILE is shipped with
# scp from this repo (tools/guest/*.cmd and the built artifacts) —
# never constructed remotely by echoing escaped text over ssh. Two
# escaping layers (bash quoting, then cmd.exe carets) mangle such
# constructions reliably; run_ssh is for running commands only. New
# guest-side scripts go in tools/guest/, where the deploy's glob ships
# them automatically.
#
# Requirements in the guest (one-time; snapshot afterward, portsh-style):
#   - OpenSSH server with key auth, sshd start type Automatic
#   - a logged-in console session (WinUI cannot run in the SSH service
#     session; tests run via scheduled tasks with /it)
#   - for --provision: nothing else (installs the Windows App Runtime)
#   - for the python/go/csharp suites: winget install Python.Python.3.13 /
#     GoLang.Go / Microsoft.DotNet.SDK.10, and an llvm-mingw ucrt-aarch64
#     release unpacked under C:\kaya (cgo needs a C compiler; policy is
#     clang everywhere)
#
# Builds before deploying (release: the hybrid CRT policy in build.rs
# makes release artifacts self-contained; debug builds still import
# vcruntime), so the VM can never run yesterday's artifacts against
# today's sources. Run inside the dev shell (cargo-xwin comes from the
# flake).
set -euo pipefail

ROOT_FOR_CHECK="$(cd "$(dirname "$0")/.." && pwd)"
# Phase timing: greppable "TIMING <phase> <n>s" lines say where a
# run's wall time went — build, deploy, or suites.
KAYA_T0=$SECONDS
timing() {
    echo "TIMING $1 $((SECONDS - KAYA_T0))s"
    KAYA_T0=$SECONDS
}
# Compile the windows target before touching the VM.
"$ROOT_FOR_CHECK/tools/check-targets.sh" windows || exit 1
timing check-targets

HOST="${1:?usage: deploy-win.sh user@host [--provision] [rust|python|go|all]}"
shift
PROVISION=0
SUITE="all"
for arg in "$@"; do
    case "$arg" in
        --provision) PROVISION=1 ;;
        rust|python|go|csharp|all) SUITE="$arg" ;;
        entry_rust|entry_python|entry_go|entry_csharp) SUITE="$arg" ;;
        gallery_rust|gallery_python|gallery_go|gallery_csharp) SUITE="$arg" ;;
        todos_rust|todos_python|todos_go|todos_csharp) SUITE="$arg" ;;
        reorder_rust|reorder_python|reorder_go|reorder_csharp) SUITE="$arg" ;;
        feed_rust|feed_python|feed_go|feed_csharp) SUITE="$arg" ;;
        grow_rust|grow_python|grow_go|grow_csharp) SUITE="$arg" ;;
        align_rust|align_python|align_go|align_csharp) SUITE="$arg" ;;
        window_rust|window_python|window_go|window_csharp) SUITE="$arg" ;;
        layout_rust|layout_python|layout_go|layout_csharp) SUITE="$arg" ;;
        probe=*) SUITE="$arg" ;;
        enable-dumps|crash-report|analyze-dump) SUITE="$arg" ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$ROOT/target/aarch64-pc-windows-msvc/release"
SDK="$ROOT/third_party/winappsdk"
BOOTSTRAP="$SDK/Microsoft.WindowsAppSDK.Foundation-2.1.0/extracted/runtimes/win-arm64/native/Microsoft.WindowsAppRuntime.Bootstrap.dll"

run_ssh() { ssh -n -o BatchMode=yes "$HOST" "$@"; }

# The VM must be up before anything else: check reachability, and if the
# guest is down, boot it through UTM and wait for sshd. The trailing
# grace period lets the console session finish logging in — the suites
# run as scheduled tasks with /it, which need it.
VM_NAME="${KAYA_WIN_VM:-Windows}"
utmctl_bin() {
    command -v utmctl 2>/dev/null || echo /Applications/UTM.app/Contents/MacOS/utmctl
}
if ! ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$HOST" 'exit 0' 2>/dev/null; then
    echo "== $HOST unreachable; starting VM \"$VM_NAME\" =="
    "$(utmctl_bin)" start "$VM_NAME"
    tries=0
    until ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$HOST" 'exit 0' 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -gt 60 ]; then
            echo "VM \"$VM_NAME\" did not become reachable" >&2
            exit 1
        fi
        sleep 5
    done
    sleep 30
fi
timing vm-ready

echo "== building (aarch64-pc-windows-msvc, release) =="
(cd "$ROOT" && cargo xwin build --release --target aarch64-pc-windows-msvc --lib \
    && cargo xwin build --release --target aarch64-pc-windows-msvc \
        --example milestone2 --example entry --example gallery --example todos --example reorder --example feed \
        --example grow --example layout --example align --example window)
"$ROOT/tools/gen-header.sh" --check
"$ROOT/tools/gen-bindings.sh" --check

# Every kaya_* function declared in kaya.h must be exported by the DLL;
# a missing export would otherwise surface as a remote link or load
# error, or worse, pass by resolving against a stale deployed copy.
declared=$(sed -nE 's/^[A-Za-z_].*[ *](kaya_[a-z0-9_]+)\(.*/\1/p' "$ROOT/crates/kaya/include/kaya.h" | sort -u)
exported=$(objdump -p "$TARGET/kaya.dll" | awk '/Export Table:/,/^$/' | grep -oE 'kaya_[a-z0-9_]+' | sort -u)
missing=$(comm -23 <(echo "$declared") <(echo "$exported"))
if [ -n "$missing" ]; then
    echo "kaya.dll does not export functions declared in kaya.h:" >&2
    echo "$missing" >&2
    exit 1
fi
timing build

run_ssh 'cmd /c if not exist C:\kaya mkdir C:\kaya'
run_ssh 'cmd /c if not exist C:\kaya\bindings\python mkdir C:\kaya\bindings\python'
run_ssh 'cmd /c if not exist C:\kaya\bindings\go mkdir C:\kaya\bindings\go'
for guest in milestone2 entry gallery todos reorder feed grow layout align window; do
    run_ssh "cmd /c if not exist C:\\kaya\\guests\\go\\$guest mkdir C:\\kaya\\guests\\go\\$guest"
    # The whole package, not just main.go: guests with generated sum
    # surfaces (kaya-gen) carry a checked-in *_kaya.go beside it.
    scp -q "$ROOT/guests/go/$guest/"*.go "$HOST:C:/kaya/guests/go/$guest/"
done

if [ "$PROVISION" = 1 ]; then
    echo "== provisioning Windows App Runtime (one-time) =="
    scp -q "$SDK/WindowsAppRuntimeInstall-arm64.exe" "$HOST:C:/kaya/"
    run_ssh 'C:\kaya\WindowsAppRuntimeInstall-arm64.exe --quiet --force'
fi

# Go 1.27rc2 on the VM (generic methods; pre-release until August
# 2026): fetched once, idempotently; the go guest scripts prepend
# C:\kaya\go127\go\bin so it wins over any stable install.
run_ssh 'cmd /c if exist C:\kaya\go127\go\bin\go.exe (echo go127 present) else (powershell -Command "Invoke-WebRequest -Uri https://go.dev/dl/go1.27rc2.windows-arm64.zip -OutFile C:\kaya\go127.zip; Expand-Archive -Path C:\kaya\go127.zip -DestinationPath C:\kaya\go127 -Force; Remove-Item C:\kaya\go127.zip")'

# A hung or leftover guest keeps kaya.dll locked: the next deploy's
# copy fails under set -e, or a fresh suite runs beside a zombie. This
# is a dedicated test VM — python/go/dotnet processes are always kaya
# guests — so killing by image name is safe. Swept before deploying,
# after any suite timeout, and on every exit path (trap below).
kill_guests() {
    run_ssh 'cmd /c "taskkill /f /im milestone2.exe 2>nul & taskkill /f /im entry.exe 2>nul & taskkill /f /im gallery.exe 2>nul & taskkill /f /im todos.exe 2>nul & taskkill /f /im reorder.exe 2>nul & taskkill /f /im feed.exe 2>nul & taskkill /f /im grow.exe 2>nul & taskkill /f /im align.exe 2>nul & taskkill /f /im window.exe 2>nul & taskkill /f /im layout.exe 2>nul & taskkill /f /im python.exe 2>nul & taskkill /f /im go.exe 2>nul & taskkill /f /im dotnet.exe 2>nul & taskkill /f /im cdb.exe 2>nul & exit /b 0"' || true
}
LEGS_DIR="$(mktemp -d)"
cleanup() {
    kill_guests
    rm -rf "$LEGS_DIR"
}
trap cleanup EXIT
kill_guests

echo "== deploying artifacts =="
scp -q \
    "$TARGET/examples/milestone2.exe" \
    "$TARGET/examples/entry.exe" \
    "$TARGET/examples/gallery.exe" \
    "$TARGET/examples/todos.exe" \
    "$TARGET/examples/reorder.exe" \
    "$TARGET/examples/feed.exe" \
    "$TARGET/examples/grow.exe" \
    "$TARGET/examples/align.exe" \
    "$TARGET/examples/window.exe" \
    "$TARGET/examples/layout.exe" \
    "$TARGET/kaya.dll" \
    "$BOOTSTRAP" \
    "$ROOT/guests/python/milestone2.py" \
    "$ROOT/guests/python/entry.py" \
    "$ROOT/guests/python/gallery.py" \
    "$ROOT/guests/python/grow.py" \
    "$ROOT/guests/python/align.py" \
    "$ROOT/guests/python/window.py" \
    "$ROOT/guests/python/layout.py" \
    "$ROOT/guests/python/todos.py" \
    "$ROOT/guests/python/reorder.py" \
    "$ROOT/guests/python/feed.py" \
    "$ROOT/go.mod" \
    "$ROOT/crates/kaya/include/kaya.h" \
    "$ROOT"/tools/guest/*.cmd \
    "$ROOT"/tools/guest/*.vbs \
    "$ROOT/tools/guest/minimal-resources.pri" \
    "$ROOT/tools/guest/shot.ps1" \
    "$HOST:C:/kaya/"
# Recreated from scratch every deploy: dotnet run picks up whatever
# sources and project files are in the directory, so a leftover from a
# renamed or removed example would poison the build.
run_ssh 'cmd /c "if exist C:\kaya\cs rmdir /s /q C:\kaya\cs & mkdir C:\kaya\cs"'
# Recreated from scratch every deploy: a stale flat-module layout
# (kaya_app.py) beside the kaya/ package would be a second import
# mechanism.
run_ssh 'cmd /c "if exist C:\kaya\bindings\python rmdir /s /q C:\kaya\bindings\python & mkdir C:\kaya\bindings\python"'
scp -q -r "$ROOT"/bindings/python/kaya "$HOST:C:/kaya/bindings/python/"
scp -q "$ROOT"/bindings/go/*.go "$HOST:C:/kaya/bindings/go/"
scp -q "$ROOT"/guests/csharp/*.cs "$ROOT/guests/csharp/kaya-guests.csproj" \
    "$ROOT"/bindings/csharp/*.cs \
    "$HOST:C:/kaya/cs/"

# What landed must be what was built: Windows keeps loaded DLLs locked,
# so an overwrite can fail while everything else copies fine, and the
# suites would then run against the previous deploy.
verify_remote() {
    local local_path="$1" remote_path="$2"
    local want got
    want=$(shasum -a 256 "$local_path" | awk '{print tolower($1)}')
    got=$(run_ssh "powershell -Command \"(Get-FileHash $remote_path -Algorithm SHA256).Hash\"" \
        | tr -d '\r' | tr '[:upper:]' '[:lower:]')
    if [ "$want" != "$got" ]; then
        echo "$remote_path does not match $local_path after copy" >&2
        exit 1
    fi
}
verify_remote "$TARGET/kaya.dll" 'C:\kaya\kaya.dll'
verify_remote "$TARGET/examples/milestone2.exe" 'C:\kaya\milestone2.exe'
verify_remote "$TARGET/examples/entry.exe" 'C:\kaya\entry.exe'
verify_remote "$TARGET/examples/gallery.exe" 'C:\kaya\gallery.exe'
verify_remote "$TARGET/examples/todos.exe" 'C:\kaya\todos.exe'
verify_remote "$TARGET/examples/reorder.exe" 'C:\kaya\reorder.exe'
verify_remote "$TARGET/examples/feed.exe" 'C:\kaya\feed.exe'
verify_remote "$TARGET/examples/grow.exe" 'C:\kaya\grow.exe'
verify_remote "$TARGET/examples/align.exe" 'C:\kaya\align.exe'
verify_remote "$TARGET/examples/layout.exe" 'C:\kaya\layout.exe'
timing deploy

# Recording mode (KAYA_RECORD=1): a WGC capturer (tools/guest/
# record-win, built on the VM) films kaya windows for the whole run,
# saving frames named by VM-clock epoch ms. GDI-family capture shows
# WinUI's DirectComposition content as blank; WGC reads the compositor
# and is window-scoped, so nothing else on the desktop enters the
# film. Anchoring never crosses machines: frame names and harness
# epochs share the VM clock. Per-leg films are assembled host-side
# from each leg's frame range, so extraction reuses harness-extract
# unchanged.
rec_suite_start() {
    [ -n "${KAYA_RECORD:-}" ] || return 0
    command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null \
        || { echo "recording mode needs ffmpeg/ffprobe — run inside nix develop"; exit 1; }
    "$ROOT/tools/harness-extract.sh" --selftest || exit 1
    # Build the capturer on the VM, once per source version (the
    # marker carries the content hash).
    local rw_hash
    rw_hash=$(cat "$ROOT/tools/guest/record-win/Program.cs" \
        "$ROOT/tools/guest/record-win/record-win.csproj" | shasum | cut -c1-12)
    run_ssh 'cmd /c if not exist C:\kaya\record-win mkdir C:\kaya\record-win' || true
    scp -q "$ROOT/tools/guest/record-win/Program.cs" \
        "$ROOT/tools/guest/record-win/record-win.csproj" "$HOST:C:/kaya/record-win/"
    if ! run_ssh "cmd /c dir C:\\kaya\\record-win\\.built-$rw_hash >nul 2>nul"; then
        echo "== building record-win on the VM =="
        run_ssh 'cmd /c "cd /d C:\kaya\record-win && dotnet build -c Release -v q"' \
            || { echo "recording: record-win build failed on the VM"; exit 1; }
        run_ssh "cmd /c del C:\\kaya\\record-win\\.built-* 2>nul & cmd /c echo built > C:\\kaya\\record-win\\.built-$rw_hash" || true
    fi
    # The guest display must never sleep: a slept display stops DWM
    # composition and every window is GENUINELY white on screen — the
    # stills pass the count guard while showing nothing. The fix
    # (powercfg monitor-timeout 0) lives in VM state, so assert it
    # here rather than remember it.
    if ! run_ssh 'powercfg /q SCHEME_CURRENT SUB_VIDEO VIDEOIDLE' 2>/dev/null \
        | grep -q 'AC Power Setting Index: 0x00000000'; then
        echo "recording: the VM display can sleep, which blanks every window."
        echo "run on the VM:  powercfg /change monitor-timeout-ac 0"
        exit 1
    fi
    # A recorder left over from an aborted run would fight this one.
    run_ssh 'cmd /c "taskkill /f /im record-win.exe 2>nul & exit /b 0"' || true
    run_ssh 'cmd /c "if exist C:\kaya\frames rmdir /s /q C:\kaya\frames & mkdir C:\kaya\frames"' || true
    run_ssh "schtasks /create /tn kaya_record /tr \"wscript C:\\kaya\\run-hidden.vbs record.cmd\" /sc once /st 00:00 /it /rl highest /f >nul && schtasks /run /tn kaya_record >nul"
    # Hold the suites until the capturer is up; per-window capture
    # attaches in well under the scenes' opening settle.
    local tries=0
    until run_ssh 'type C:\kaya\out_record.txt 2>nul' 2>/dev/null \
        | grep -q RECORDER_READY; do
        tries=$((tries + 1))
        if [ "$tries" -gt 60 ]; then
            echo "recording: record-win never came up:" >&2
            run_ssh 'type C:\kaya\out_record.txt' >&2 || true
            exit 1
        fi
        sleep 1
    done
}

rec_suite_stop() {
    [ -n "${KAYA_RECORD:-}" ] || return 0
    # The stop file is the recorder's own shutdown protocol; the
    # taskkill is the bound on it never noticing.
    run_ssh 'cmd /c echo stop > C:\kaya\frames\stop' || true
    sleep 3
    run_ssh 'cmd /c "taskkill /f /im record-win.exe 2>nul & exit /b 0"' || true
    local recdir="$ROOT/target/recordings/windows"
    rm -rf "$recdir"
    mkdir -p "$recdir"
    # Plain tar: the VM's bsdtar would write real zip for a .zip name
    # (-a), which the host's GNU tar refuses to read.
    run_ssh 'cmd /c "cd /d C:\kaya && tar -c -f frames.tar frames"' \
        || { echo "recording: could not pack frames"; return 1; }
    scp -q "$HOST:C:/kaya/frames.tar" "$recdir/" \
        || { echo "recording: could not pull frames"; return 1; }
    (cd "$recdir" && tar -xf frames.tar && rm frames.tar)
    local count
    count=$(find "$recdir/frames" -name '*.png' | wc -l | tr -d ' ')
    if [ "$count" = 0 ]; then
        echo "recording: the capturer produced no frames"
        run_ssh 'type C:\kaya\out_record.txt' || true
        return 1
    fi
    # Per leg: transcript from the VM, then a film assembled from the
    # leg's own frame range (concat with real inter-frame durations),
    # anchored at its first frame's epoch. Same window per leg, so
    # frame sizes agree within each film.
    local name failed=0
    local pids=()
    for name in "${SUITES_RUN[@]}"; do
        local dir="$recdir/$name"
        mkdir -p "$dir"
        run_ssh "type C:\\kaya\\out_$name.txt" | tr -d '\r' >"$dir/leg.log" 2>/dev/null
        (
            epoch=$(grep -m1 -o 'KAYA_HARNESS: epoch [0-9]*' "$dir/leg.log" | grep -o '[0-9]*$')
            last_off=$(grep -o 'KAYA_HARNESS: +[0-9]*ms' "$dir/leg.log" \
                | grep -o '[0-9]*' | sort -n | tail -1)
            if [ -z "$epoch" ]; then
                echo "$name: no harness epoch in transcript"
                exit 1
            fi
            slot=$(cat "$LEGS_DIR/$name.slot" 2>/dev/null || echo 0)
            echo "$slot" >"$dir/slot"
            lo=$((epoch - 1500))
            hi=$((epoch + last_off + 2000))
            find "$recdir/frames" -name "${slot}-*.png" \
                | awk -F'[/.]' -v lo="$lo" -v hi="$hi" \
                    '{n = split($(NF-1), a, "-"); ts = a[n]; if (ts+0 >= lo && ts+0 <= hi) print ts}' \
                | sort -n >"$dir/frames.txt"
            if [ ! -s "$dir/frames.txt" ]; then
                echo "$name: no frames overlap the leg's transcript"
                exit 1
            fi
            anchor=$(head -1 "$dir/frames.txt")
            awk -v dir="$recdir/frames" -v slot="$slot" 'NR>1 {print "file \x27" dir "/" slot "-" prev ".png\x27"; print "duration " ($1 - prev) / 1000}
                {prev=$1}
                END {print "file \x27" dir "/" slot "-" prev ".png\x27"; print "duration 0.2"}' \
                "$dir/frames.txt" >"$dir/concat.txt"
            # Tiled windows have odd content sizes; h264 wants even.
            ffmpeg -loglevel error -f concat -safe 0 -i "$dir/concat.txt" \
                -fps_mode vfr -vf "pad=ceil(iw/2)*2:ceil(ih/2)*2" \
                -pix_fmt yuv420p -c:v libx264 -preset ultrafast \
                -y "$dir/video.mkv"
            "$ROOT/tools/harness-extract.sh" "$dir/video.mkv" "$dir/leg.log" \
                "$anchor" "$dir/steps"
        ) >"$dir/extract.log" 2>&1 || : >"$dir/extract-failed" &
        pids+=($!)
    done
    [ ${#pids[@]} -eq 0 ] || wait "${pids[@]}" 2>/dev/null || true
    for name in "${SUITES_RUN[@]}"; do
        cat "$recdir/$name/extract.log" 2>/dev/null
        [ ! -e "$recdir/$name/extract-failed" ] || failed=1
    done
    [ "$failed" = 0 ] || { echo "recording: extraction failures above"; return 1; }
}
SUITES_RUN=()

# Run a shipped one-shot guest script via schtasks and print the file
# it writes once its done-marker appears.
run_guest_oneshot() {
    local script="$1" outfile="$2" marker="$3"
    run_ssh "schtasks /create /tn kaya_oneshot /tr C:\\kaya\\$script /sc once /st 00:00 /it /rl highest /f >nul && schtasks /run /tn kaya_oneshot >nul"
    local tries=0
    until run_ssh "type C:\\kaya\\$outfile" 2>/dev/null | grep -q "$marker"; do
        tries=$((tries + 1))
        if [ "$tries" -gt 60 ]; then
            echo "$script: no $marker after 60 polls" >&2
            return 1
        fi
        sleep 2
    done
    run_ssh "type C:\\kaya\\$outfile"
}

# Start <exe> with no selftest via the shipped probe.cmd and report
# whether it survives scene construction — the first question when a
# suite exits with a stowed exception and no output.
run_probe() {
    # probe=<exe> or probe=<exe>,<selftest-script>
    local exe="${1%%,*}" script=""
    case "$1" in *,*) script="${1#*,}" ;; esac
    run_ssh "del C:\\kaya\\out_probe.txt 2>nul & schtasks /create /tn kaya_probe /tr \"C:\\kaya\\probe.cmd $exe $script\" /sc once /st 00:00 /it /rl highest /f >nul && schtasks /run /tn kaya_probe >nul"
    local tries=0
    until run_ssh "type C:\\kaya\\out_probe.txt" 2>/dev/null | grep -q "PROBEDONE"; do
        tries=$((tries + 1))
        if [ "$tries" -gt 60 ]; then
            echo "probe: no PROBEDONE after 60 polls" >&2
            return 1
        fi
        sleep 2
    done
    run_ssh "type C:\\kaya\\out_probe.txt"
}

# Suites run in a pool KAYA_WIN_JOBS wide (default 4): each leg claims
# a tile slot, launches its scheduled task through the hidden-window
# shim with the slot argument (windows tile; titles carry the slot for
# the recorder), and polls its own output file. Verdicts print in
# submission order at drain. Note: a timed-out leg's kill_guests sweep
# is VM-wide and takes concurrent legs with it — acceptable, since a
# hung guest already means the run has failed.
WIDTH="${KAYA_WIN_JOBS:-4}"
leg_names=()
leg_pids=()

run_one_suite() {
    local name="$1" slot="$2"
    run_ssh "del C:\\kaya\\out_$name.txt 2>nul & schtasks /create /tn kaya_$name /tr \"wscript C:\\kaya\\run-hidden.vbs run_$name.cmd $slot\" /sc once /st 00:00 /it /rl highest /f >nul && schtasks /run /tn kaya_$name >nul"
    local tries=0
    until run_ssh "type C:\\kaya\\out_$name.txt" 2>/dev/null | grep -q "EXIT="; do
        tries=$((tries + 1))
        if [ "$tries" -gt 300 ]; then
            # A guest that never writes EXIT= is hung: kill it so it
            # cannot hold kaya.dll into the next suite or deploy, and
            # fail this leg loudly.
            echo "$name: timed out waiting for output; killing guests" >&2
            kill_guests
            return 1
        fi
        sleep 1
    done
    local out
    out=$(run_ssh "type C:\\kaya\\out_$name.txt")
    printf '%s\n' "$out"
    # The suite's verdict lives in the output file, not in any ssh exit
    # code; a failure that isn't parsed here would read as green.
    #
    # The verdict TEXT is the authority and the exit code only
    # corroborates it. EXIT=0 alone was not enough: WinUI's window-Closed
    # handler used to overwrite a failing run's exit code with 0 (Exit()
    # closes the window, the handler fires, last writer won), so a scene
    # that printed FAILED still exited 0 and the leg reported PASS. Any
    # future way of losing the code is caught here regardless of cause.
    if grep -q "KAYA_SELFTEST: FAILED" <<<"$out"; then
        return 1
    fi
    grep -q "EXIT=0" <<<"$out"
}

run_suite() {
    local name="$1"
    SUITES_RUN+=("$name")
    leg_names+=("$name")
    (
        local slot=
        local i
        while [ -z "$slot" ]; do
            i=0
            while [ "$i" -lt "$WIDTH" ]; do
                if mkdir "$LEGS_DIR/.slot-$i" 2>/dev/null; then
                    slot=$i
                    break
                fi
                i=$((i + 1))
            done
            [ -n "$slot" ] || sleep 0.2
        done
        echo "$slot" >"$LEGS_DIR/$name.slot"
        local verdict=FAIL
        if run_one_suite "$name" "$slot"; then
            verdict=PASS
        fi
        rmdir "$LEGS_DIR/.slot-$slot" 2>/dev/null
        echo "$verdict" >"$LEGS_DIR/$name.verdict"
    ) >"$LEGS_DIR/$name.log" 2>&1 &
    leg_pids+=($!)
    while [ "$(jobs -rp | wc -l)" -ge "$WIDTH" ]; do
        wait -n || true
    done
}

drain_suites() {
    if [ ${#leg_pids[@]} -gt 0 ]; then
        wait "${leg_pids[@]}" 2>/dev/null || true
    fi
    leg_pids=()
    local name verdict
    for name in "${leg_names[@]}"; do
        verdict=$(cat "$LEGS_DIR/$name.verdict" 2>/dev/null || echo FAIL)
        echo "== $name =="
        cat "$LEGS_DIR/$name.log" 2>/dev/null
        [ "$verdict" = PASS ] || status=1
        echo "$name: $verdict"
    done
    leg_names=()
}

status=0
rec_suite_start
case "$SUITE" in
    all)
        run_suite rust
        run_suite python
        run_suite go
        run_suite csharp
        run_suite entry_rust
        run_suite entry_python
        run_suite entry_go
        run_suite entry_csharp
        run_suite gallery_rust
        run_suite gallery_python
        run_suite gallery_go
        run_suite gallery_csharp
        run_suite todos_rust
        run_suite todos_python
        run_suite todos_go
        run_suite todos_csharp
        run_suite reorder_rust
        run_suite reorder_python
        run_suite reorder_go
        run_suite reorder_csharp
        run_suite feed_rust
        run_suite feed_python
        run_suite feed_go
        run_suite feed_csharp
        # The grow scene (the layout contract, asserted as shares and
        # root-fills) and the layout observation scene, every language
        # this platform runs.
        run_suite grow_rust
        run_suite grow_python
        run_suite grow_go
        run_suite grow_csharp
        # The align scene (the cross-axis contract: center + baseline),
        # every language this platform runs.
        run_suite align_rust
        run_suite align_python
        run_suite align_go
        run_suite align_csharp
        # The window scene: the primary surface's props — title
        # materialized, the advisory 640x400 honored.
        run_suite window_rust
        run_suite window_python
        run_suite window_go
        run_suite window_csharp
        run_suite layout_rust
        run_suite layout_python
        run_suite layout_go
        run_suite layout_csharp
        ;;
    probe=*) run_probe "${SUITE#probe=}" || status=1 ;;
    enable-dumps) run_guest_oneshot enable-dumps.cmd out_enable_dumps.txt "EXIT=" || status=1 ;;
    crash-report) run_guest_oneshot crash-report.cmd out_crash_report.txt "REPORTDONE" || status=1 ;;
    analyze-dump) run_guest_oneshot analyze-dump.cmd out_analyze.txt "ANALYZEDONE" || status=1 ;;
    *) run_suite "$SUITE" ;;
esac
drain_suites
timing suites
rec_suite_stop || status=1
[ -z "${KAYA_RECORD:-}" ] || timing recording-pull+stills
exit "$status"
