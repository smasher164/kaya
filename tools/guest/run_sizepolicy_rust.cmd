@echo off
cd /d C:\kaya
set KAYA_SELFTEST=sizepolicy
sizepolicy.exe > C:\kaya\out_sizepolicy_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_sizepolicy_rust.txt
