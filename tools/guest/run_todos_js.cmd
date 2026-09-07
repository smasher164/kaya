@echo off
cd /d C:\kaya
set PATH=C:\kaya;C:\kaya\node24\node-v24.19.0-win-arm64;%PATH%
set KAYA_LIB=C:\kaya\kaya.dll
set KAYA_SELFTEST=todos
set KAYA_VERB_TRACE=C:\kaya\flightrec\todos_js-vtrace.txt
node C:\kaya\todos.ts > C:\kaya\out_todos_js.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_todos_js.txt
