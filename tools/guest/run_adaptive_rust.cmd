@echo off
cd /d C:\kaya
set KAYA_SELFTEST=adaptive
adaptive.exe > C:\kaya\out_adaptive_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_adaptive_rust.txt
