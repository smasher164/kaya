@echo off
cd /d C:\kaya
set KAYA_SELFTEST=a11y
a11y.exe > C:\kaya\out_a11y_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_a11y_rust.txt
