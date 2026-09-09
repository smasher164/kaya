@echo off
cd /d C:\kaya
set PATH=C:\kaya;C:\kaya\node24\node-v24.19.0-win-arm64;%PATH%
set KAYA_LIB=C:\kaya\kaya.dll
rem THE LEG'S OWN STATE HOME (docs/tasks-s4-plan.md P7): the harness's
rem scratch -- the act-two marker, the preferences domain and the app's
rem data directory -- is ONE tree per app, and this lane runs many legs
rem of one app at once, so every act one EMPTIES that tree and a pooled
rem neighbour's open SQLite goes readonly under it. Cleared HERE, at the
rem leg's own start, and nowhere else: the second act must KEEP it.
rmdir /s /q C:\kaya\legs\menus_js 2>nul
mkdir C:\kaya\legs\menus_js\state 2>nul
set XDG_STATE_HOME=C:\kaya\legs\menus_js\state
set KAYA_SELFTEST=menus
set KAYA_VERB_TRACE=C:\kaya\flightrec\menus_js-vtrace.txt
node C:\kaya\menus.ts > C:\kaya\out_menus_js.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_menus_js.txt
