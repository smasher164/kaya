@echo off
cd /d C:\kaya
rem llvm-mingw directory is versioned; find whichever is present.
for /d %%d in (C:\kaya\llvm-mingw-*) do set MINGW=%%d\bin
set PATH=C:\kaya;%MINGW%;C:\kaya\go127\go\bin;C:\Program Files\Go\bin;%PATH%
set CGO_ENABLED=1
set CC=aarch64-w64-mingw32-clang
rem NO ASSET LINE HERE ANY MORE: the guest names the mark
rem `asset("icons/kaya-mark.png")` and the core resolves it out
rem of the root the deploy stages and names machine-wide in
rem KAYA_ASSET_DIR — the typeface scene's rule, one asset over.
set KAYA_SELFTEST=identity
rem Build INTO C:\kaya: the exe must sit beside resources.pri for
rem ms-appx (XamlControlsResources) to resolve — the adjacency probe.
go build -o C:\kaya\identity_go.exe dev.kaya/guests/go/cmd > C:\kaya\out_identity_go.txt 2>&1
if errorlevel 1 goto done
identity_go.exe >> C:\kaya\out_identity_go.txt 2>&1
:done
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_identity_go.txt
