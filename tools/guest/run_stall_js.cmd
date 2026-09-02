@echo off
cd /d C:\kaya
set PATH=C:\kaya;C:\kaya\node24\node-v24.19.0-win-arm64;%PATH%
set KAYA_LIB=C:\kaya\kaya.dll
set KAYA_SELFTEST=stall
node C:\kaya\stall.ts > C:\kaya\out_stall_js.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_stall_js.txt
