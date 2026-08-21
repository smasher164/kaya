@echo off
cd /d C:\kaya
rem llvm-mingw directory is versioned; find whichever is present.
for /d %%d in (C:\kaya\llvm-mingw-*) do set MINGW=%%d\bin
set PATH=C:\kaya;%MINGW%;C:\kaya\go127\go\bin;C:\Program Files\Go\bin;%PATH%
set CGO_ENABLED=1
set CC=aarch64-w64-mingw32-clang
set KAYA_SELFTEST=table
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
