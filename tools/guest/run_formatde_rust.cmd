@echo off
cd /d C:\kaya
rem The locale knob (docs/compliance-plan.md §2.2): a language list per
rem formatter and Language/FlowDirection on every window ground.
set KAYA_LOCALE=de-DE
rem THE LEG'S OWN STATE HOME (docs/tasks-s4-plan.md P7): the harness's
rem scratch -- the act-two marker, the preferences domain and the app's
rem data directory -- is ONE tree per app, and this lane runs many legs
rem of one app at once, so every act one EMPTIES that tree and a pooled
rem neighbour's open SQLite goes readonly under it. Cleared HERE, at the
rem leg's own start, and nowhere else: the second act must KEEP it.
rmdir /s /q C:\kaya\legs\formatde_rust 2>nul
mkdir C:\kaya\legs\formatde_rust\state 2>nul
set XDG_STATE_HOME=C:\kaya\legs\formatde_rust\state
set KAYA_SELFTEST=formatde
set KAYA_VERB_TRACE=C:\kaya\flightrec\formatde_rust-vtrace.txt
format.exe > C:\kaya\out_formatde_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_formatde_rust.txt
