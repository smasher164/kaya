@echo off
cd /d C:\kaya
rem llvm-mingw directory is versioned; find whichever is present.
for /d %%d in (C:\kaya\llvm-mingw-*) do set MINGW=%%d\bin
set PATH=C:\kaya;%MINGW%;C:\Program Files\Go\bin;%PATH%
set CGO_ENABLED=1
set CC=aarch64-w64-mingw32-clang
set KAYA_SELFTEST=1
go run C:\kaya\milestone2.go > C:\kaya\out_go.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_go.txt
