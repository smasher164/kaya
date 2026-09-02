@echo off
cd /d C:\kaya
set PATH=C:\kaya;C:\kaya\node24\node-v24.19.0-win-arm64;%PATH%
set KAYA_LIB=C:\kaya\kaya.dll
set KAYA_SELFTEST=clipboard
node C:\kaya\clipboard.ts > C:\kaya\out_clipboard_js.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_clipboard_js.txt
