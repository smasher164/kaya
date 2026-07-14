#!/usr/bin/env bash
# Deploy milestone-0 artifacts to the Windows VM and run the validations.
#
# Usage: tools/deploy-win.sh user@host [--provision] [rust|python|go|csharp|all]
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

HOST="${1:?usage: deploy-win.sh user@host [--provision] [rust|python|go|all]}"
shift
PROVISION=0
SUITE="all"
for arg in "$@"; do
    case "$arg" in
        --provision) PROVISION=1 ;;
        rust|python|go|csharp|all) SUITE="$arg" ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$ROOT/target/aarch64-pc-windows-msvc/release"
SDK="$ROOT/third_party/winappsdk"
BOOTSTRAP="$SDK/Microsoft.WindowsAppSDK.Foundation-2.1.0/extracted/runtimes/win-arm64/native/Microsoft.WindowsAppRuntime.Bootstrap.dll"

run_ssh() { ssh -n -o BatchMode=yes "$HOST" "$@"; }

echo "== building (aarch64-pc-windows-msvc, release) =="
(cd "$ROOT" && cargo xwin build --release --target aarch64-pc-windows-msvc --lib \
    && cargo xwin build --release --target aarch64-pc-windows-msvc --example milestone0)
"$ROOT/tools/gen-header.sh" --check

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

if [ "$PROVISION" = 1 ]; then
    echo "== provisioning Windows App Runtime (one-time) =="
    scp -q "$SDK/WindowsAppRuntimeInstall-arm64.exe" "$HOST:C:/kaya/"
    run_ssh 'C:\kaya\WindowsAppRuntimeInstall-arm64.exe --quiet --force'
fi

echo "== deploying artifacts =="
scp -q \
    "$TARGET/examples/milestone0.exe" \
    "$TARGET/kaya.dll" \
    "$BOOTSTRAP" \
    "$ROOT/crates/kaya/examples/milestone0.py" \
    "$ROOT/crates/kaya/examples/milestone0.go" \
    "$ROOT/crates/kaya/include/kaya.h" \
    "$ROOT"/tools/guest/*.cmd \
    "$ROOT/tools/guest/shot.ps1" \
    "$HOST:C:/kaya/"
run_ssh 'cmd /c if not exist C:\kaya\cs mkdir C:\kaya\cs'
scp -q "$ROOT/crates/kaya/examples/milestone0.cs" \
    "$ROOT/crates/kaya/examples/milestone0.csproj" \
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
verify_remote "$TARGET/examples/milestone0.exe" 'C:\kaya\milestone0.exe'

run_suite() {
    local name="$1"
    run_ssh "del C:\\kaya\\out_$name.txt 2>nul & schtasks /create /tn kaya_$name /tr C:\\kaya\\run_$name.cmd /sc once /st 00:00 /it /rl highest /f >nul && schtasks /run /tn kaya_$name >nul"
    local tries=0
    until run_ssh "type C:\\kaya\\out_$name.txt" 2>/dev/null | grep -q "EXIT="; do
        tries=$((tries + 1))
        if [ "$tries" -gt 60 ]; then
            echo "$name: timed out waiting for output" >&2
            return 1
        fi
        sleep 5
    done
    echo "== $name =="
    run_ssh "type C:\\kaya\\out_$name.txt"
}

status=0
case "$SUITE" in
    all)
        run_suite rust || status=1
        run_suite python || status=1
        run_suite go || status=1
        run_suite csharp || status=1
        ;;
    *) run_suite "$SUITE" || status=1 ;;
esac
exit "$status"
