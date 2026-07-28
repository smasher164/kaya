@echo off
cd /d C:\kaya
set KAYA_SELFTEST=background
background.exe > C:\kaya\out_background_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_background_rust.txt
