@echo off
cd /d C:\kaya
rem llvm-mingw directory is versioned; find whichever is present.
for /d %%d in (C:\kaya\llvm-mingw-*) do set MINGW=%%d\bin
set PATH=C:\kaya;%MINGW%;C:\kaya\go127\go\bin;C:\Program Files\Go\bin;%PATH%
set CGO_ENABLED=1
set CC=aarch64-w64-mingw32-clang
rem The vendored mark's bytes are what the guest declares; named
rem absolutely so no leg depends on its cwd (deploy-win.sh ships it to
rem the repo-mirror path, the vendored font's rule one asset over).
set KAYA_ICON_FILE=C:\kaya\guests\assets\icons\kaya-mark.png
set KAYA_SELFTEST=identity
rem Build INTO C:\kaya: the exe must sit beside resources.pri for
rem ms-appx (XamlControlsResources) to resolve — the adjacency probe.
go build -o C:\kaya\identity_go.exe dev.kaya/guests/go/cmd > C:\kaya\out_identity_go.txt 2>&1
if errorlevel 1 goto done
identity_go.exe >> C:\kaya\out_identity_go.txt 2>&1
:done
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_identity_go.txt
