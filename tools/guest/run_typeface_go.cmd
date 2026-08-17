@echo off
cd /d C:\kaya
rem llvm-mingw directory is versioned; find whichever is present.
for /d %%d in (C:\kaya\llvm-mingw-*) do set MINGW=%%d\bin
set PATH=C:\kaya;%MINGW%;C:\kaya\go127\go\bin;C:\Program Files\Go\bin;%PATH%
set CGO_ENABLED=1
set CC=aarch64-w64-mingw32-clang
rem The vendored font's bytes are what the guest hands the backend;
rem named absolutely so no leg depends on its cwd (deploy-win.sh ships
rem it to the repo-mirror path).
set KAYA_FONT_FILE=C:\kaya\guests\assets\fonts\sora-wght.ttf
set KAYA_SELFTEST=typeface
rem Build INTO C:\kaya: the exe must sit beside resources.pri for
rem ms-appx (XamlControlsResources) to resolve — the adjacency probe.
go build -o C:\kaya\typeface_go.exe dev.kaya/guests/go/cmd > C:\kaya\out_typeface_go.txt 2>&1
if errorlevel 1 goto done
typeface_go.exe >> C:\kaya\out_typeface_go.txt 2>&1
:done
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_typeface_go.txt
