@echo off
cd /d C:\kaya
rem THE LEG'S OWN STATE HOME (docs/tasks-s4-plan.md P7): the harness's
rem scratch -- the act-two marker, the preferences domain and the app's
rem data directory -- is ONE tree per app, and this lane runs many legs
rem of one app at once, so every act one EMPTIES that tree and a pooled
rem neighbour's open SQLite goes readonly under it. Cleared HERE, at the
rem leg's own start, and nowhere else: the second act must KEEP it.
rmdir /s /q C:\kaya\legs\panes_rust 2>nul
mkdir C:\kaya\legs\panes_rust\state 2>nul
set XDG_STATE_HOME=C:\kaya\legs\panes_rust\state
set KAYA_SELFTEST=panes
set KAYA_VERB_TRACE=C:\kaya\flightrec\panes_rust-vtrace.txt
panes.exe > C:\kaya\out_panes_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_panes_rust.txt
