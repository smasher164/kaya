@echo off
cd /d C:\kaya
set PATH=C:\kaya;C:\kaya\node24\node-v24.19.0-win-arm64;%PATH%
set KAYA_LIB=C:\kaya\kaya.dll
set KAYA_SELFTEST=tooltips
node C:\kaya\tooltips.ts > C:\kaya\out_tooltips_js.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_tooltips_js.txt
