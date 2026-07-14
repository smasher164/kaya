@echo off
cd /d C:\kaya
set KAYA_SELFTEST=1
milestone0.exe > C:\kaya\out_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_rust.txt
