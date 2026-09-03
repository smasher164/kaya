@echo off
cd /d C:\kaya
for /d %%d in (C:\kaya\llvm-mingw-*) do set MINGW=%%d\bin
set PATH=C:\kaya;%MINGW%;C:\kaya\go127\go\bin;C:\Program Files\Go\bin;%PATH%
set CGO_ENABLED=1
set CC=aarch64-w64-mingw32-clang
rem The one cgo compile of the package every Go leg builds, alone,
rem before the pool opens (docs/traps.md: The Windows lane's first
rem matrix after a spec change).
go build -o C:\kaya\warm_go.exe dev.kaya/guests/go/cmd > C:\kaya\out_gowarm.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_gowarm.txt
del C:\kaya\warm_go.exe 2>nul
