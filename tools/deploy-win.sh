#!/usr/bin/env bash
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
# Compile the windows target before touching the VM.
"$ROOT_FOR_CHECK/tools/check-targets.sh" windows || exit 1

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

echo "== building (aarch64-pc-windows-msvc, release) =="
(cd "$ROOT" && cargo xwin build --release --target aarch64-pc-windows-msvc --lib \
    && cargo xwin build --release --target aarch64-pc-windows-msvc \
        --example milestone2 --example entry --example gallery --example todos)
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

run_ssh 'cmd /c if not exist C:\kaya mkdir C:\kaya'
run_ssh 'cmd /c if not exist C:\kaya\bindings\python mkdir C:\kaya\bindings\python'
run_ssh 'cmd /c if not exist C:\kaya\bindings\go mkdir C:\kaya\bindings\go'

if [ "$PROVISION" = 1 ]; then
    echo "== provisioning Windows App Runtime (one-time) =="
    scp -q "$SDK/WindowsAppRuntimeInstall-arm64.exe" "$HOST:C:/kaya/"
    run_ssh 'C:\kaya\WindowsAppRuntimeInstall-arm64.exe --quiet --force'
fi

# A hung or leftover guest keeps kaya.dll locked: the next deploy's
# copy fails under set -e, or a fresh suite runs beside a zombie. This
# is a dedicated test VM — python/go/dotnet processes are always kaya
# guests — so killing by image name is safe. Swept before deploying,
# after any suite timeout, and on every exit path (trap below).
kill_guests() {
    run_ssh 'cmd /c "taskkill /f /im milestone2.exe 2>nul & taskkill /f /im entry.exe 2>nul & taskkill /f /im gallery.exe 2>nul & taskkill /f /im todos.exe 2>nul & taskkill /f /im python.exe 2>nul & taskkill /f /im go.exe 2>nul & taskkill /f /im dotnet.exe 2>nul & taskkill /f /im cdb.exe 2>nul & exit /b 0"' || true
}
trap kill_guests EXIT
kill_guests

echo "== deploying artifacts =="
scp -q \
    "$TARGET/examples/milestone2.exe" \
    "$TARGET/examples/entry.exe" \
    "$TARGET/examples/gallery.exe" \
    "$TARGET/examples/todos.exe" \
    "$TARGET/kaya.dll" \
    "$BOOTSTRAP" \
    "$ROOT/crates/kaya/examples/milestone2.py" \
    "$ROOT/crates/kaya/examples/milestone2.go" \
    "$ROOT/crates/kaya/examples/entry.py" \
    "$ROOT/crates/kaya/examples/entry.go" \
    "$ROOT/crates/kaya/examples/gallery.py" \
    "$ROOT/crates/kaya/examples/gallery.go" \
    "$ROOT/crates/kaya/examples/todos.py" \
    "$ROOT/crates/kaya/examples/todos.go" \
    "$ROOT/go.mod" \
    "$ROOT/crates/kaya/include/kaya.h" \
    "$ROOT"/tools/guest/*.cmd \
    "$ROOT/tools/guest/minimal-resources.pri" \
    "$ROOT/tools/guest/shot.ps1" \
    "$HOST:C:/kaya/"
# Recreated from scratch every deploy: dotnet run picks up whatever
# sources and project files are in the directory, so a leftover from a
# renamed or removed example would poison the build.
run_ssh 'cmd /c "if exist C:\kaya\cs rmdir /s /q C:\kaya\cs & mkdir C:\kaya\cs"'
run_ssh 'cmd /c "if exist C:\kaya\cs-entry rmdir /s /q C:\kaya\cs-entry & mkdir C:\kaya\cs-entry"'
run_ssh 'cmd /c "if exist C:\kaya\cs-gallery rmdir /s /q C:\kaya\cs-gallery & mkdir C:\kaya\cs-gallery"'
run_ssh 'cmd /c "if exist C:\kaya\cs-todos rmdir /s /q C:\kaya\cs-todos & mkdir C:\kaya\cs-todos"'
scp -q "$ROOT"/bindings/python/*.py "$HOST:C:/kaya/bindings/python/"
scp -q "$ROOT"/bindings/go/*.go "$HOST:C:/kaya/bindings/go/"
scp -q "$ROOT/crates/kaya/examples/milestone2.cs" \
    "$ROOT/crates/kaya/examples/milestone2.csproj" \
    "$ROOT"/bindings/csharp/*.cs \
    "$HOST:C:/kaya/cs/"
scp -q "$ROOT/crates/kaya/examples/entry.cs" \
    "$ROOT/crates/kaya/examples/entry.csproj" \
    "$ROOT"/bindings/csharp/*.cs \
    "$HOST:C:/kaya/cs-entry/"
scp -q "$ROOT/crates/kaya/examples/gallery.cs" \
    "$ROOT/crates/kaya/examples/gallery.csproj" \
    "$ROOT"/bindings/csharp/*.cs \
    "$HOST:C:/kaya/cs-gallery/"
scp -q "$ROOT/crates/kaya/examples/todos.cs" \
    "$ROOT/crates/kaya/examples/todos.csproj" \
    "$ROOT"/bindings/csharp/*.cs \
    "$HOST:C:/kaya/cs-todos/"

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

run_suite() {
    local name="$1"
    run_ssh "del C:\\kaya\\out_$name.txt 2>nul & schtasks /create /tn kaya_$name /tr C:\\kaya\\run_$name.cmd /sc once /st 00:00 /it /rl highest /f >nul && schtasks /run /tn kaya_$name >nul"
    local tries=0
    until run_ssh "type C:\\kaya\\out_$name.txt" 2>/dev/null | grep -q "EXIT="; do
        tries=$((tries + 1))
        if [ "$tries" -gt 60 ]; then
            # A guest that never writes EXIT= is hung: kill it so it
            # cannot hold kaya.dll into the next suite or deploy, and
            # fail this leg loudly.
            echo "$name: timed out waiting for output; killing guests" >&2
            kill_guests
            return 1
        fi
        sleep 5
    done
    echo "== $name =="
    local out
    out=$(run_ssh "type C:\\kaya\\out_$name.txt")
    printf '%s\n' "$out"
    # The suite's verdict lives in the output file, not in any ssh exit
    # code; a failure that isn't parsed here would read as green.
    grep -q "EXIT=0" <<<"$out"
}

status=0
case "$SUITE" in
    all)
        run_suite rust || status=1
        run_suite python || status=1
        run_suite go || status=1
        run_suite csharp || status=1
        run_suite entry_rust || status=1
        run_suite entry_python || status=1
        run_suite entry_go || status=1
        run_suite entry_csharp || status=1
        run_suite gallery_rust || status=1
        run_suite gallery_python || status=1
        run_suite gallery_go || status=1
        run_suite gallery_csharp || status=1
        run_suite todos_rust || status=1
        run_suite todos_python || status=1
        run_suite todos_go || status=1
        run_suite todos_csharp || status=1
        ;;
    probe=*) run_probe "${SUITE#probe=}" || status=1 ;;
    enable-dumps) run_guest_oneshot enable-dumps.cmd out_enable_dumps.txt "EXIT=" || status=1 ;;
    crash-report) run_guest_oneshot crash-report.cmd out_crash_report.txt "REPORTDONE" || status=1 ;;
    analyze-dump) run_guest_oneshot analyze-dump.cmd out_analyze.txt "ANALYZEDONE" || status=1 ;;
    *) run_suite "$SUITE" || status=1 ;;
esac
exit "$status"
