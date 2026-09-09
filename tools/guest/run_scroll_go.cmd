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
rmdir /s /q C:\kaya\legs\scroll_go 2>nul
mkdir C:\kaya\legs\scroll_go\state 2>nul
set XDG_STATE_HOME=C:\kaya\legs\scroll_go\state
set KAYA_SELFTEST=scroll
set KAYA_VERB_TRACE=C:\kaya\flightrec\scroll_go-vtrace.txt
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
go build -o C:\kaya\scroll_go.exe dev.kaya/guests/go/cmd > C:\kaya\out_scroll_go.txt 2>&1
if errorlevel 1 goto done
scroll_go.exe >> C:\kaya\out_scroll_go.txt 2>&1
:done
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_scroll_go.txt
