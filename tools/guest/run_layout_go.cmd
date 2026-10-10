@echo off
cd /d C:\kaya
rem llvm-mingw directory is versioned; find whichever is present.
for /d %%d in (C:\kaya\llvm-mingw-*) do set MINGW=%%d\bin
set PATH=C:\kaya;%MINGW%;C:\kaya\go127\go\bin;C:\Program Files\Go\bin;%PATH%
rem THE LEG'S OWN STATE HOME (docs/tasks-s4-plan.md P7): the harness's
rem scratch -- the act-two marker, the preferences domain and the app's
rem data directory -- is ONE tree per app, and this lane runs many legs
rem of one app at once, so every act one EMPTIES that tree and a pooled
rem neighbour's open SQLite goes readonly under it. Cleared HERE, at the
rem leg's own start, and nowhere else: the second act must KEEP it.
rmdir /s /q C:\kaya\legs\layout_go 2>nul
mkdir C:\kaya\legs\layout_go\state 2>nul
set XDG_STATE_HOME=C:\kaya\legs\layout_go\state
set KAYA_SELFTEST=layout
set KAYA_VERB_TRACE=C:\kaya\flightrec\layout_go-vtrace.txt
rem One Go link a lane, deploy-win's go-warm; the leg runs a copy under its own name
rem (docs/traps.md, the Windows Go legs linked the guest once each).
copy /y C:\kaya\goguest.exe C:\kaya\layout_go.exe >nul 2>&1 || goto nocopy
layout_go.exe > C:\kaya\out_layout_go.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_layout_go.txt
exit /b
:nocopy
echo run_layout_go.cmd: C:\kaya\goguest.exe did not copy to C:\kaya\layout_go.exe; go-warm builds it, and a running layout_go.exe holds the name> C:\kaya\out_layout_go.txt
echo EXIT=1 >> C:\kaya\out_layout_go.txt
