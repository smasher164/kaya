@echo off
cd /d C:\kaya
for /d %%d in (C:\kaya\llvm-mingw-*) do set MINGW=%%d\bin
set PATH=C:\kaya;%MINGW%;C:\kaya\go127\go\bin;C:\Program Files\Go\bin;%PATH%
set CGO_ENABLED=1
set CC=aarch64-w64-mingw32-clang
rem The lane's one Go build, alone, before the pool opens; every Go leg
rem runs a copy of goguest.exe (docs/traps.md: The Windows lane's first
rem matrix after a spec change, and the Windows Go legs linked the guest
rem once each).
del C:\kaya\goguest.exe 2>nul
go build -o C:\kaya\goguest.exe dev.kaya/guests/go/cmd > C:\kaya\out_gowarm.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_gowarm.txt
