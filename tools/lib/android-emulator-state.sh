#!/usr/bin/env bash

# docs/traps.md, "An Android toolchain move outlives its dev shell".

android_emulator_state_id() { # sdk-root -> two lines
    local sdk_root="$1"
    local emulator_exe image_dir
    emulator_exe="$(realpath "$(command -v emulator)")" || return 1
    image_dir="$(realpath \
        "$sdk_root/system-images/android-35/google_apis/arm64-v8a")" || return 1
    printf '%s\n%s\n' "$emulator_exe" "$image_dir"
}

android_snapshot_state_current() { # marker snapshot-dir emulator image
    local marker="$1" snapshot="$2" emulator_exe="$3" image_dir="$4"
    [ -f "$snapshot/snapshot.pb" ] || return 1
    python3 - "$marker" "$emulator_exe" "$image_dir" <<'PY'
import pathlib
import sys

marker = pathlib.Path(sys.argv[1])
want = [sys.argv[2], sys.argv[3]]
try:
    got = marker.read_text(encoding="utf-8").splitlines()
except OSError:
    raise SystemExit(1)
raise SystemExit(0 if got == want else 1)
PY
}

android_write_snapshot_state() { # marker emulator image
    android_write_state_file "$1" "$2" "$3"
}

android_emulator_identity() { # emulator image avd serial -> four lines
    printf '%s\n%s\n%s\n%s\n' "$1" "$2" "$3" "$4"
}

android_emulator_identity_current() { # actual emulator image avd serial
    local actual="$1" want
    want="$(android_emulator_identity "$2" "$3" "$4" "$5")" || return 1
    [ "$actual" = "$want" ]
}

android_avd_name() { # serial
    adb -s "$1" emu avd name 2>/dev/null | python3 -c '
import sys

for line in sys.stdin:
    line = line.strip()
    if line and line != "OK":
        print(line)
        raise SystemExit(0)
raise SystemExit(1)'
}

android_guest_identity() { # serial guest-path
    adb -s "$1" shell cat "$2" 2>/dev/null | tr -d '\r'
}

android_live_instance_current() { # serial avd emulator image guest-path
    local serial="$1" expected_avd="$2" emulator_exe="$3" image_dir="$4"
    local guest_path="$5" actual identity
    adb -s "$serial" get-state 2>/dev/null | grep -q device || return 1
    actual="$(android_avd_name "$serial")" || return 1
    [ "$actual" = "$expected_avd" ] || return 1
    identity="$(android_guest_identity "$serial" "$guest_path")" || return 1
    android_emulator_identity_current \
        "$identity" "$emulator_exe" "$image_dir" "$expected_avd" "$serial"
}

android_write_guest_identity() { # serial guest-path emulator image avd
    local serial="$1" guest_path="$2" identity observed
    identity="$(android_emulator_identity "$3" "$4" "$5" "$serial")" || return 1
    printf '%s\n' "$identity" \
        | adb -s "$serial" shell "cat > '$guest_path'" || return 1
    observed="$(android_guest_identity "$serial" "$guest_path")" || return 1
    android_emulator_identity_current "$observed" "$3" "$4" "$5" "$serial"
}

android_write_state_file() { # path lines...
    local path="$1"
    shift
    python3 - "$path" "$@" <<'PY'
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
tmp = path.with_name(f".{path.name}.{os.getpid()}")
tmp.write_text("".join(f"{line}\n" for line in sys.argv[2:]), encoding="utf-8")
os.replace(tmp, path)
PY
}

android_snapshot_log_failure() { # log -> measured reason
    python3 - "$1" <<'PY'
import pathlib
import sys

needles = ("Failed to load snapshot", "starting from scratch")
try:
    lines = pathlib.Path(sys.argv[1]).read_text(
        encoding="utf-8", errors="replace").splitlines()
except OSError:
    print("emulator log is unavailable")
    raise SystemExit(0)
for line in lines:
    if any(needle in line for needle in needles):
        print(line.strip())
        raise SystemExit(0)
if not any("Loading snapshot 'default_boot'" in line for line in lines):
    print("no Loading snapshot 'default_boot' line")
    raise SystemExit(0)
raise SystemExit(1)
PY
}

android_snapshot_log_clean() { # log
    [ -f "$1" ] || return 1
    if android_snapshot_log_failure "$1" >/dev/null; then
        return 1
    fi
    return 0
}

android_emulator_state_selftest() {
    local scratch snapshot marker clean no_load failed_a failed_b identity
    local emulator_exe=/nix/store/current-emulator image_dir=/nix/store/current-image
    scratch="$(mktemp -d)" || return 1
    snapshot="$scratch/avd/snapshots/default_boot"
    marker="$scratch/avd/.kaya-default-boot-id"
    clean="$scratch/clean.log"
    no_load="$scratch/no-load.log"
    failed_a="$scratch/failed-a.log"
    failed_b="$scratch/failed-b.log"
    mkdir -p "$snapshot"
    android_write_snapshot_state "$marker" "$emulator_exe" "$image_dir" || return 1
    printf '%s\n' "INFO | Loading snapshot 'default_boot'" >"$clean"
    printf '%s\n' 'quickboot complete' >"$no_load"
    printf '%s\n' "WARNING | Failed to load snapshot 'default_boot'" >"$failed_a"
    printf '%s\n' 'USER_INFO | The emulator is starting from scratch.' >"$failed_b"

    local bad=0
    if android_snapshot_state_current \
        "$marker" "$snapshot" "$emulator_exe" "$image_dir"; then
        bad=1
    fi
    touch "$snapshot/snapshot.pb"
    android_snapshot_state_current \
        "$marker" "$snapshot" "$emulator_exe" "$image_dir" || bad=1
    if android_snapshot_state_current \
        "$marker" "$snapshot" /nix/store/stale-emulator "$image_dir"; then
        bad=1
    fi
    if android_snapshot_state_current \
        "$marker" "$snapshot" "$emulator_exe" /nix/store/stale-image; then
        bad=1
    fi
    identity="$(android_emulator_identity \
        "$emulator_exe" "$image_dir" kaya emulator-5554)" || bad=1
    android_emulator_identity_current \
        "$identity" "$emulator_exe" "$image_dir" kaya emulator-5554 || bad=1
    if android_emulator_identity_current \
        "$identity" /nix/store/stale-emulator "$image_dir" kaya emulator-5554; then
        bad=1
    fi
    if android_emulator_identity_current \
        "$identity" "$emulator_exe" "$image_dir" kaya-tablet emulator-5554; then
        bad=1
    fi
    if android_emulator_identity_current \
        "$identity" "$emulator_exe" "$image_dir" kaya emulator-5556; then
        bad=1
    fi
    android_snapshot_log_clean "$clean" || bad=1
    if android_snapshot_log_clean "$no_load"; then
        bad=1
    fi
    if android_snapshot_log_clean "$failed_a"; then
        bad=1
    fi
    if android_snapshot_log_clean "$failed_b"; then
        bad=1
    fi
    rm -rf "$scratch"
    if [ "$bad" -ne 0 ]; then
        echo "android-emulator-state: selftest FAILED" >&2
        return 1
    fi
    echo "android-emulator-state: selftest OK"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        --selftest)
            android_emulator_state_selftest
            ;;
        --check-log)
            if android_snapshot_log_clean "${2:-}"; then
                echo "android-emulator-state: snapshot log clean"
            else
                reason="$(android_snapshot_log_failure "${2:-}" 2>/dev/null \
                    || echo 'snapshot log missing')"
                echo "android-emulator-state: snapshot fallback: $reason" >&2
                exit 1
            fi
            ;;
        *)
            echo "usage: $0 --selftest | --check-log <emulator-log>" >&2
            exit 2
            ;;
    esac
fi
