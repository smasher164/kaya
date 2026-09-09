@echo off
rem %1 the installed package's location, %2 the tile slot. The caller's
rem environment does not cross Invoke-CommandInDesktopPackage, so every
rem KAYA_ variable this leg needs is set HERE (docs/packaging-plan.md P3).
cd /d C:\kaya
rem THE LEG'S OWN STATE HOME (docs/tasks-s4-plan.md P7): the harness's
rem scratch -- the act-two marker, the preferences domain and the app's
rem data directory -- is ONE tree per app, and this lane runs many legs
rem of one app at once, so every act one EMPTIES that tree and a pooled
rem neighbour's open SQLite goes readonly under it. Cleared HERE, at the
rem leg's own start, and nowhere else: the second act must KEEP it.
rmdir /s /q C:\kaya\legs\taskspkg_rust 2>nul
mkdir C:\kaya\legs\taskspkg_rust\state 2>nul
set XDG_STATE_HOME=C:\kaya\legs\taskspkg_rust\state
set KAYA_SELFTEST=tasks
set KAYA_VERB_TRACE=C:\kaya\flightrec\taskspkg_rust-vtrace.txt
set KAYA_WIN_SLOT=%2
set KAYA_ASSET_DIR=
"%~1\tasks.exe" > C:\kaya\out_taskspkg_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_taskspkg_rust.txt
