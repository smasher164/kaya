@echo off
cd /d C:\kaya
set PATH=C:\kaya;C:\kaya\node24\node-v24.19.0-win-arm64;%PATH%
set KAYA_LIB=C:\kaya\kaya.dll
set KAYA_SELFTEST=a11y
node C:\kaya\a11y.ts > C:\kaya\out_a11y_js.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_a11y_js.txt
