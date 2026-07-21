@echo off
cd /d C:\kaya
set KAYA_SELFTEST=align
align.exe > C:\kaya\out_align_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_align_rust.txt
