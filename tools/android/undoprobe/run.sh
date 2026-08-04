#!/usr/bin/env bash

# P3-compose (docs/undo-plan.md §0, D7) — the whole campaign in one
# transcript. Throwaway; nothing in the validation ladder calls this.
#
#  A  the LEGACY path kaya ships today (M3 TextField(value:, onValueChange:)):
#     is there an undo stack at all, does Ctrl+Z drive it, does a
#     programmatic write enter it, does an undo echo to the app?
#  B  the TextFieldState path (foundation 1.7.5): does a programmatic
#     write enter undoState history, does clearHistory() give D7
#     semantics, and what does the observation channel report?
#  C  the touch-only affordance: does the text toolbar offer Undo?
#
# Results on stdout — the receiver answers through ORDERED broadcast
# result data, which `am broadcast` prints directly (no logcat race).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SC="${KAYA_PROBE_OUT:-/tmp}"
SER="${1:-emulator-5558}"
PKG=dev.kaya.undoprobe
CTRL=113
SHIFT=59
Z=54

cmd() {
    adb -s "$SER" shell am broadcast -a $PKG.CMD -p $PKG "$@" 2>&1 |
        tr -d '\r' | grep -o 'data=.*'
}
ctrl_z() { adb -s "$SER" shell input keycombination $CTRL $Z; sleep 1; }
ctrl_shift_z() { adb -s "$SER" shell input keycombination $CTRL $SHIFT $Z; sleep 1; }
type_text() { adb -s "$SER" shell input text "$1"; sleep 1; }
# A FRESH PROCESS between scenarios: the legacy field's undo stack is
# unreachable from the app, so it survives every "reset" the probe can
# perform — measured in A7, where a third Ctrl+Z resurrected text from a
# scenario two minutes earlier.
restart() {
    adb -s "$SER" shell am force-stop $PKG
    adb -s "$SER" shell am start -W -n $PKG/.ProbeActivity >/dev/null
    sleep 2
}

cd "$HERE" || exit 1
gradle --console=plain --offline -q :app:assembleDebug
BUILD_RC=$?
if [ "$BUILD_RC" -ne 0 ]; then
    echo "build failed ($BUILD_RC)" >&2
    exit 1
fi
adb -s "$SER" install -r app/build/outputs/apk/debug/app-debug.apk >/dev/null

echo "=== A. THE LEGACY PATH (what KayaCompose.kt renders today) ==="
echo "== A1 user types 'abc' with a hardware keyboard, then Ctrl+Z =="
restart
cmd --es cmd focus_legacy >/dev/null
type_text abc
cmd --es cmd state
ctrl_z
cmd --es cmd state
echo "== A2 Ctrl+Shift+Z (redo) =="
ctrl_shift_z
cmd --es cmd state

echo "== A3 the D7 shape: the app overwrites the field, then Ctrl+Z =="
restart
cmd --es cmd focus_legacy >/dev/null
type_text user
cmd --es cmd state
cmd --es cmd write_legacy --es text APPWROTE
sleep 6
ctrl_z
cmd --es cmd state

echo "== A4 the same with NO user typing at all: one app write, Ctrl+Z =="
restart
cmd --es cmd focus_legacy >/dev/null
cmd --es cmd write_legacy --es text APPWROTE
sleep 6
cmd --es cmd state
ctrl_z
cmd --es cmd state

echo "=== B. THE TextFieldState PATH (foundation 1.7.5) ==="
echo "== B1 user types, then the app calls undoState.undo()/redo() =="
restart
cmd --es cmd focus_tfs >/dev/null
type_text hello
cmd --es cmd state
cmd --es cmd tfs_undo
cmd --es cmd tfs_redo

echo "== B2 hardware Ctrl+Z / Ctrl+Shift+Z at the same field =="
ctrl_z
cmd --es cmd state
ctrl_shift_z
cmd --es cmd state

echo "== B3 does a programmatic setTextAndPlaceCursorAtEnd enter history? =="
restart
cmd --es cmd focus_tfs >/dev/null
type_text user
cmd --es cmd state
cmd --es cmd tfs_settext --es text APPWROTE
ctrl_z
cmd --es cmd state

echo "== B4 the same for state.edit { replace(...) } =="
restart
cmd --es cmd focus_tfs >/dev/null
type_text user
cmd --es cmd state
cmd --es cmd tfs_edit --es text APPEDIT
ctrl_z
cmd --es cmd state

echo "== B5 an explicit clearHistory() clears BOTH stacks =="
restart
cmd --es cmd focus_tfs >/dev/null
type_text user
cmd --es cmd tfs_undo
cmd --es cmd tfs_clearhistory
ctrl_shift_z
cmd --es cmd state

echo "== B6 a NO-OP app write (same text) still clears history =="
restart
cmd --es cmd focus_tfs >/dev/null
type_text user
cmd --es cmd state
cmd --es cmd tfs_edit_same

echo "== B7 the observation channel: which writes does snapshotFlow report? =="
restart
cmd --es cmd state
cmd --es cmd focus_tfs >/dev/null
type_text ab
cmd --es cmd state
cmd --es cmd tfs_settext --es text APPWROTE
cmd --es cmd tfs_undo
ctrl_z
cmd --es cmd state

echo "=== D. THE ONLY LEVER THE LEGACY PATH LEAVES: REMOUNT THE FIELD ==="
echo "== D1 write + remount (bump the composition key), re-focus, Ctrl+Z =="
restart
cmd --es cmd focus_legacy >/dev/null
type_text user
cmd --es cmd state
cmd --es cmd write_legacy_remount --es text APPWROTE
cmd --es cmd focus_legacy
type_text Q
cmd --es cmd state
sleep 6
ctrl_z
cmd --es cmd state
ctrl_z
cmd --es cmd state
echo "== D2 CONTROL: the same script with a plain write, no remount =="
restart
cmd --es cmd focus_legacy >/dev/null
type_text user
cmd --es cmd write_legacy --es text APPWROTE
cmd --es cmd focus_legacy >/dev/null
type_text Q
cmd --es cmd state
sleep 6
ctrl_z
cmd --es cmd state

echo "=== E. WHO OWNS THE CHORD (the Android form of P5's double-fire) ==="
echo "== E1 nothing focused: does Ctrl+Z reach Activity.dispatchKeyShortcutEvent? =="
restart
ctrl_z
cmd --es cmd state
echo "== E2 legacy focused, undoable content present =="
restart
cmd --es cmd focus_legacy >/dev/null
type_text abc
cmd --es cmd clearkeys >/dev/null
ctrl_z
cmd --es cmd state
echo "== E3 legacy focused, stack EXHAUSTED =="
ctrl_z
ctrl_z
cmd --es cmd clearkeys >/dev/null
ctrl_z
cmd --es cmd state
echo "== E4 TFS focused, canUndo=true =="
restart
cmd --es cmd focus_tfs >/dev/null
type_text abc
cmd --es cmd clearkeys >/dev/null
ctrl_z
cmd --es cmd state
echo "== E5 TFS focused, canUndo=false (history cleared) =="
cmd --es cmd tfs_clearhistory >/dev/null
cmd --es cmd clearkeys >/dev/null
ctrl_z
cmd --es cmd state

echo "=== F. WHERE THE CARET LANDS AFTER A PROGRAMMATIC WRITE ==="
echo "== F1 TFS: write, then type one char =="
restart
cmd --es cmd focus_tfs >/dev/null
type_text ab
cmd --es cmd tfs_settext --es text APP
type_text Z
cmd --es cmd state
echo "== F2 LEGACY: the same =="
restart
cmd --es cmd focus_legacy >/dev/null
type_text ab
cmd --es cmd write_legacy --es text APP
type_text Z
cmd --es cmd state

echo "=== C. THE TOUCH-ONLY AFFORDANCE (no hardware keyboard) ==="
restart
cmd --es cmd focus_tfs >/dev/null
type_text hello
echo "== C1 long-press the TFS field =="
adb -s "$SER" shell input swipe 60 88 60 88 900
sleep 2
adb -s "$SER" exec-out uiautomator dump /dev/tty 2>/dev/null > "$SC/dump-tfs.xml"
adb -s "$SER" exec-out screencap -p > "$SC/toolbar-tfs.png"
python3 "$HERE/labels.py" "$SC/dump-tfs.xml"
echo "== C2 long-press the LEGACY field =="
adb -s "$SER" shell input keyevent 4 >/dev/null 2>&1
cmd --es cmd write_legacy --es text hello >/dev/null
cmd --es cmd focus_legacy >/dev/null
adb -s "$SER" shell input swipe 150 40 150 40 900
sleep 2
adb -s "$SER" exec-out uiautomator dump /dev/tty 2>/dev/null > "$SC/dump-legacy.xml"
adb -s "$SER" exec-out screencap -p > "$SC/toolbar-legacy.png"
python3 "$HERE/labels.py" "$SC/dump-legacy.xml"

adb -s "$SER" shell am force-stop $PKG >/dev/null 2>&1
echo "PROBEDONE"
