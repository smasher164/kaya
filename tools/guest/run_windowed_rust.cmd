@echo off
cd /d C:\kaya
set KAYA_SELFTEST=windowed
windowed.exe > C:\kaya\out_windowed_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_windowed_rust.txt
