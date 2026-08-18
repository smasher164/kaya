#!/usr/bin/env bash
# Drive title-centre-probe.ps1 against a live guest on the Windows VM.
#
# WHY A DRIVER AT ALL: the probe must run in the VM's INTERACTIVE session
# (an ssh session has its own window station and can neither see the window
# nor synthesize input into it), so the guest and the probe are two
# scheduled tasks created with `schtasks /it`. The guest runs the shipped
# toolbar scene with a trailing `settle` appended through KAYA_SCENES_DIR —
# the shipped scene file is never written — and that settle is the window in
# which the probe measures.
#
#   crates/kaya/src/winui/title-centre-probe.sh akhil@192.168.64.2
#
# It builds and deploys first (tools/deploy-win.sh's toolbar_rust leg), so
# what it measures is this tree and not yesterday's exe.
#
# THE DEPLOY DOES NOT CARRY THIS YET: `tools/deploy-win.sh` is where a
# lane-carried probe belongs, and `tools/` was outside the file list of the
# arm that wrote it. Stated here so the next reader does not go looking.
set -u

HOST="${1:?usage: title-centre-probe.sh user@host}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
WORK="${TMPDIR:-/tmp}/kaya-title-centre.$$"
R='C:\Users\akhil\kaya-tc-probe'

cleanup() {
    rm -rf "$WORK"
    ssh "$HOST" "schtasks /delete /tn kaya_tcp_g /f & schtasks /delete /tn kaya_tcp_p /f" >/dev/null 2>&1
}
trap cleanup EXIT

mkdir -p "$WORK/scenes"

# The guest exe and libkaya, built from THIS tree.
( cd "$ROOT" && tools/deploy-win.sh "$HOST" toolbar_rust ) > "$WORK/deploy.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "title-centre-probe: the toolbar_rust leg failed (rc=$rc); nothing was measured."
    tail -20 "$WORK/deploy.log"
    exit 1
fi

# The scratch scene: the shipped steps plus a settle to measure inside.
cp "$ROOT/tools/scenes/toolbar.steps" "$WORK/scenes/toolbar.steps"
cat >> "$WORK/scenes/toolbar.steps" <<'STEPS'

# SCRATCH ONLY, appended by title-centre-probe.sh and never written to the
# shipped file: the settle is the window the external probe measures in.
settle 45000
STEPS

# Guest and probe launchers. Shipped as FILES, never echoed over ssh: two
# escaping layers (bash quoting, then cmd.exe carets) mangle that reliably.
printf '@echo off\r\ncd /d C:\\kaya\r\nset KAYA_SELFTEST=toolbar\r\nset KAYA_SCENES_DIR=%s\\scenes\r\ntoolbar.exe > %s\\out.txt 2>&1\r\necho EXIT=%%ERRORLEVEL%% >> %s\\out.txt\r\n' \
    "$R" "$R" "$R" > "$WORK/guest.cmd"
printf '@echo off\r\nset KAYA_TC_LOG=%s\\prove.txt\r\npowershell -NoProfile -ExecutionPolicy Bypass -File %s\\title-centre-probe.ps1 > %s\\psout.txt 2>&1\r\n' \
    "$R" "$R" "$R" > "$WORK/probe.cmd"
# Scheduled tasks cannot start a GUI app with a console window in shot.
printf '%s\r\n' "CreateObject(\"Wscript.Shell\").Run \"cmd /c \" & WScript.Arguments(0), 0, False" > "$WORK/hidden.vbs"

ssh "$HOST" "cmd /c mkdir $R & cmd /c mkdir $R\\scenes" >/dev/null 2>&1
scp -q "$HERE/title-centre-probe.ps1" "$WORK/guest.cmd" "$WORK/probe.cmd" "$WORK/hidden.vbs" "$HOST:$R\\"
scp -q "$WORK/scenes/toolbar.steps" "$HOST:$R\\scenes\\"

ssh "$HOST" "schtasks /create /tn kaya_tcp_g /tr \"wscript.exe $R\\hidden.vbs $R\\guest.cmd\" /sc once /st 00:00 /it /f" >/dev/null
ssh "$HOST" "schtasks /create /tn kaya_tcp_p /tr \"wscript.exe $R\\hidden.vbs $R\\probe.cmd\" /sc once /st 00:00 /it /f" >/dev/null
ssh "$HOST" "cmd /c del /q $R\\out.txt $R\\prove.txt $R\\psout.txt >nul 2>&1 & schtasks /run /tn kaya_tcp_g" >/dev/null
sleep 7
ssh "$HOST" "schtasks /run /tn kaya_tcp_p" >/dev/null
sleep 50

echo "== the measurement =="
ssh "$HOST" "cmd /c type $R\\prove.txt"
echo "== the guest's own verdict for the same run =="
ssh "$HOST" "cmd /c type $R\\out.txt" | grep -E "KAYA_SELFTEST|step-failed|panicked|EXIT="
ssh "$HOST" "cmd /c rmdir /s /q $R" >/dev/null 2>&1
