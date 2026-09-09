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
rmdir /s /q C:\kaya\legs\table_go 2>nul
mkdir C:\kaya\legs\table_go\state 2>nul
set XDG_STATE_HOME=C:\kaya\legs\table_go\state
set KAYA_SELFTEST=table
set KAYA_VERB_TRACE=C:\kaya\flightrec\table_go-vtrace.txt
rem Build INTO C:\kaya: the exe must sit beside resources.pri for
rem ms-appx (XamlControlsResources) to resolve — the adjacency probe.
rem The table's header cells are Buttons, whose default style lives in
rem that dictionary, so a host launched from a temp build directory
rem fail-fasts at the first layout pass (docs/traps.md).
go build -o C:\kaya\table_go.exe dev.kaya/guests/go/cmd > C:\kaya\out_table_go.txt 2>&1
if errorlevel 1 goto done
table_go.exe >> C:\kaya\out_table_go.txt 2>&1
:done
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_table_go.txt
