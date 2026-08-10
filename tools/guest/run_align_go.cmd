@echo off
cd /d C:\kaya
rem llvm-mingw directory is versioned; find whichever is present.
for /d %%d in (C:\kaya\llvm-mingw-*) do set MINGW=%%d\bin
set PATH=C:\kaya;%MINGW%;C:\kaya\go127\go\bin;C:\Program Files\Go\bin;%PATH%
set CGO_ENABLED=1
set CC=aarch64-w64-mingw32-clang
set KAYA_SELFTEST=align
rem Build INTO C:\kaya rather than `go run`, for two reasons that
rem both came with the one-package collapse. The exe must sit beside
rem resources.pri for ms-appx (XamlControlsResources) to resolve --
rem the adjacency probe -- and `go run` launches from a temp build
rem directory. And it names its temp exe after the package's last
rem path element, which is now `cmd`: a hung leg would be a process
rem called cmd.exe, which deploy-win's kill_guests cannot sweep by
rem name without killing the suite's own shells. Built here, every
rem Go leg is still named after its scene.
go build -o C:\kaya\align_go.exe dev.kaya/guests/go/cmd > C:\kaya\out_align_go.txt 2>&1
if errorlevel 1 goto done
align_go.exe >> C:\kaya\out_align_go.txt 2>&1
:done
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_align_go.txt
