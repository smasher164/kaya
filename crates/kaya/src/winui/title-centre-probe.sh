#!/usr/bin/env bash
# Drive title-centre-probe.ps1 against a live guest on the Windows VM.
#
# The probe must run in the VM's INTERACTIVE session — an ssh session has
# its own window station and can neither see the window nor synthesize
# input into it (docs/traps.md) — so the guest and the probe are two
# scheduled tasks created with `schtasks /it`. The guest runs the shipped
# toolbar scene with a trailing `settle` appended through KAYA_SCENES_DIR;
# the shipped scene file is never written, and that settle is the window in
# which the probe measures.
#
#   crates/kaya/src/winui/title-centre-probe.sh akhil@192.168.64.2
#   tools/deploy-win.sh akhil@192.168.64.2 caption-centre
#
# deploy-win.sh's caption-centre phase calls this with KAYA_TCP_NO_DEPLOY=1,
# having already built and shipped what this would rebuild; run by hand it
# deploys first, so either way it measures THIS tree.
#
# Exit status: 0 only if the probe wrote a measurement. Everything the
# lane ASSERTS about that measurement it asserts itself, off the AIMV/
# AIMPLAN lines this prints — see deploy-win.sh's caption_centre phase.
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

# The guest exe and libkaya, built from THIS tree. Skipped when the lane
# is the caller: it has just built and shipped them.
if [ -z "${KAYA_TCP_NO_DEPLOY:-}" ]; then
    ( cd "$ROOT" && tools/deploy-win.sh "$HOST" toolbar_rust ) > "$WORK/deploy.log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "title-centre-probe: the toolbar_rust leg failed (rc=$rc); nothing was measured."
        tail -20 "$WORK/deploy.log"
        exit 1
    fi
fi

# The scratch scene: the shipped steps plus a settle to measure inside.
cp "$ROOT/tools/scenes/toolbar.steps" "$WORK/scenes/toolbar.steps"
cat >> "$WORK/scenes/toolbar.steps" <<'STEPS'

# SCRATCH ONLY, appended by title-centre-probe.sh and never written to the
# shipped file: the settle is the window the external probe measures in.
# LONG ENOUGH FOR A CONTENDED PROBE: at 45s the toolbar left the screen
# before the eleventh width on a matrix whose probe took 75s, and the
# verdict read an "honest under-run" for weeks without naming this
# (2026-09-02, docs/traps.md). The runner kills the guest the moment
# the probe is done, so the quiet path pays none of it.
settle 180000
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
# POLLED, NOT SLEPT: the ps1 ends with "PROVE: done", so waiting is a
# read of that line rather than a 50s guess (measured 2026-08-20: the
# sweep itself finishes in well under half that, and the guess was most
# of this phase's minute). The deadline covers the settle above, and an
# expiry SAYS SO, with how far the sweep got — a count read after a
# cut-off is the deadline's number, not the sweep's.
tries=0
until ssh "$HOST" "cmd /c type $R\\prove.txt" 2>/dev/null | grep -q "^PROVE: done"; do
    tries=$((tries + 1))
    if [ "$tries" -gt 85 ]; then
        aims=$(ssh "$HOST" "cmd /c type $R\\prove.txt" 2>/dev/null | grep -c "^AIM ")
        echo "title-centre-probe: gave up after ~170s waiting for PROVE: done — the probe was CUT OFF with $aims AIM line(s) written; the measurement count below is this deadline's, not the sweep's"
        break
    fi
    sleep 2
done
# The guest's scratch scene holds a 45s settle so the probe has a still
# window to measure; the poll returns long before it ends, and a
# lingering toolbar window would fight the next phase's legs for the
# foreground — so the guest is put down here, not left to its timer.
ssh "$HOST" "taskkill /im toolbar.exe /f >nul 2>&1" >/dev/null 2>&1

echo "== the measurement =="
ssh "$HOST" "cmd /c type $R\\prove.txt" > "$WORK/prove.txt" 2>&1
cat "$WORK/prove.txt"
echo "== the guest's own verdict for the same run =="
ssh "$HOST" "cmd /c type $R\\out.txt" | grep -E "KAYA_SELFTEST|step-failed|panicked|EXIT="
ssh "$HOST" "cmd /c rmdir /s /q $R" >/dev/null 2>&1

# A probe that wrote nothing is a failure, not a silent pass — the one
# thing only the driver can see.
grep -q "^AIMPLAN " "$WORK/prove.txt"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "title-centre-probe: the probe wrote no AIMPLAN line, so it did not reach its sweep."
    echo "  Nothing above is a measurement of the title's aim; the usual cause is that"
    echo "  no window of class WinUIDesktopWin32WindowClass appeared, which the probe"
    echo "  says in its own words above (it lists what WAS on the desktop)."
    exit 1
fi
