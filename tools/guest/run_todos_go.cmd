@echo off
cd /d C:\kaya
rem llvm-mingw directory is versioned; find whichever is present.
for /d %%d in (C:\kaya\llvm-mingw-*) do set MINGW=%%d\bin
set PATH=C:\kaya;%MINGW%;C:\kaya\go127\go\bin;C:\Program Files\Go\bin;%PATH%
set CGO_ENABLED=1
set CC=aarch64-w64-mingw32-clang
rem THE LEG'S OWN STATE HOME (docs/tasks-s4-plan.md P7): the harness's
rem scratch -- the act-two marker, the preferences domain and the app's
rem data directory -- is ONE tree per app, and this lane runs many legs
rem of one app at once, so every act one EMPTIES that tree and a pooled
rem neighbour's open SQLite goes readonly under it. Cleared HERE, at the
rem leg's own start, and nowhere else: the second act must KEEP it.
rmdir /s /q C:\kaya\legs\todos_go 2>nul
mkdir C:\kaya\legs\todos_go\state 2>nul
set XDG_STATE_HOME=C:\kaya\legs\todos_go\state
set KAYA_SELFTEST=todos
set KAYA_VERB_TRACE=C:\kaya\flightrec\todos_go-vtrace.txt
rem Build INTO C:\kaya: the exe must sit beside resources.pri for
rem ms-appx (XamlControlsResources) to resolve — the adjacency probe.
rem The scene grew an Edit menu, and MenuBarItem's default style lives
rem in XamlControlsResources, so `go run` (which launches from a temp
rem build directory) fail-fasts at the first layout pass. Never `go run`
rem for a WinUI leg — docs/traps.md, "WinUI resource resolution is
rem anchored to the PROCESS exe's directory".
go build -o C:\kaya\todos_go.exe dev.kaya/guests/go/cmd > C:\kaya\out_todos_go.txt 2>&1
if errorlevel 1 goto done
todos_go.exe >> C:\kaya\out_todos_go.txt 2>&1
:done
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_todos_go.txt
