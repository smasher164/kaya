@echo off
cd /d C:\kaya
set KAYA_SELFTEST=textarea
textarea.exe > C:\kaya\out_textarea_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_textarea_rust.txt
