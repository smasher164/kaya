@echo off
cd /d C:\kaya
rem llvm-mingw directory is versioned; find whichever is present.
for /d %%d in (C:\kaya\llvm-mingw-*) do set MINGW=%%d\bin
set PATH=C:\kaya;%MINGW%;C:\Program Files\Go\bin;%PATH%
set CGO_ENABLED=1
set CC=aarch64-w64-mingw32-clang
set KAYA_SELFTEST=todos
go run dev.kaya/guests/go/todos > C:\kaya\out_todos_go.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_todos_go.txt
