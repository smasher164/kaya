@echo off
cd /d C:\kaya
rem llvm-mingw directory is versioned; find whichever is present.
for /d %%d in (C:\kaya\llvm-mingw-*) do set MINGW=%%d\bin
set PATH=C:\kaya;%MINGW%;C:\kaya\go127\go\bin;C:\Program Files\Go\bin;%PATH%
set CGO_ENABLED=1
set CC=aarch64-w64-mingw32-clang
set KAYA_SELFTEST=panels
rem Build INTO C:\kaya rather than `go run`, for two reasons that
rem both arrived with the one-package collapse. The exe must sit
rem beside resources.pri for ms-appx (XamlControlsResources) to
rem resolve -- the adjacency probe -- and `go run` launches from a
rem temp build directory. And `go run` names its temp exe after the
rem package's last path element, which is now `cmd`: a hung leg
rem would be a process called cmd.exe, which deploy-win's
rem kill_guests cannot sweep by name without killing the suite's
rem own shells. Built here, every Go leg is still named for its
rem scene, which is what that sweep and the wedge check both read.
go build -o C:\kaya\panels_go.exe dev.kaya/guests/go/cmd > C:\kaya\out_panels_go.txt 2>&1
if errorlevel 1 goto done
panels_go.exe >> C:\kaya\out_panels_go.txt 2>&1
:done
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_panels_go.txt
