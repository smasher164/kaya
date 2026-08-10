@echo off
cd /d C:\kaya
rem llvm-mingw directory is versioned; find whichever is present.
for /d %%d in (C:\kaya\llvm-mingw-*) do set MINGW=%%d\bin
set PATH=C:\kaya;%MINGW%;C:\kaya\go127\go\bin;C:\Program Files\Go\bin;%PATH%
set CGO_ENABLED=1
set CC=aarch64-w64-mingw32-clang
set KAYA_SELFTEST=todos
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
