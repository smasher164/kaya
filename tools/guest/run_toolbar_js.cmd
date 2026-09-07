@echo off
cd /d C:\kaya
set PATH=C:\kaya;C:\kaya\node24\node-v24.19.0-win-arm64;%PATH%
set KAYA_LIB=C:\kaya\kaya.dll
set KAYA_SELFTEST=toolbar
set KAYA_VERB_TRACE=C:\kaya\flightrec\toolbar_js-vtrace.txt
node C:\kaya\toolbar.ts > C:\kaya\out_toolbar_js.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_toolbar_js.txt
